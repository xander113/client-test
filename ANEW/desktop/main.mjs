import { app, BrowserWindow, dialog, ipcMain, Menu, session } from 'electron';
import { randomUUID } from 'node:crypto';
import { readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';

import { MAX_SCENE_BYTES, validateScene } from '../shared/scene.mjs';
import { startRenderService } from '../services/render/service.mjs';
import { startWorldService } from '../services/worlds/service.mjs';
import { decodeSessionMessage, isPose, WorldApi } from './world-api.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const packageInfo = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const product = packageInfo.potProduct ?? (process.argv.includes('--studio') ? 'studio' : 'client');
const windows = new Map();
let local;
let primary;
let thumbnailService;
let quitting = false;
let renderCredential;

app.setName(product === 'studio' ? 'Pot Studio' : 'Pot Client');
if (process.platform === 'win32') {
  app.setAppUserModelId(product === 'studio' ? 'org.potproject.studio' : 'org.potproject.client');
}

async function localNetwork(dataDir) {
  const credential = randomUUID();
  const server = await startWorldService({
    host: '127.0.0.1',
    port: 0,
    dataDir,
    readToken: credential,
    writeToken: credential,
    renderEndpoint: thumbnailService.url,
    renderToken: renderCredential,
  });
  return {
    api: new WorldApi(server.url, { readToken: credential, writeToken: credential }),
    close: () => server.close(),
  };
}

async function configuredApi() {
  if (!process.env.POT_API_ENDPOINT) return local.api;
  try {
    const hosted = new WorldApi(process.env.POT_API_ENDPOINT, {
      readToken: process.env.POT_API_READ_TOKEN,
      writeToken: process.env.POT_API_WRITE_TOKEN,
      mode: 'hosted',
    });
    await hosted.health();
    // Verify browse access before selecting a hosted service for this launch.
    await hosted.list();
    return hosted;
  } catch {
    console.warn('Pot is using its local world service because the hosted catalog is unavailable.');
    return local.api;
  }
}

function stateFor(event) {
  const state = windows.get(event.sender.id);
  if (!state || !event.senderFrame || event.senderFrame !== event.sender.mainFrame ||
      event.senderFrame.url !== state.url) {
    throw new Error('This window cannot access Pot services.');
  }
  return state;
}

function forStudio(state) {
  if (state.mode !== 'studio') throw new Error('This action requires Pot Studio.');
}

function stopSession(state) {
  const socket = state.socket;
  state.socket = null;
  if (!socket) return;
  if (socket.readyState === WebSocket.OPEN) socket.close(1000, 'Left world');
  else socket.terminate();
}

function sendSession(state, message) {
  if (!state.win.isDestroyed()) state.win.webContents.send('pot:session', message);
}

function joinSession(state, worldId) {
  stopSession(state);
  const socket = state.api.connect(worldId);
  state.socket = socket;
  state.lastMove = 0;

  return new Promise((resolve, reject) => {
    let welcomed = false;
    const welcomeTimeout = setTimeout(() => {
      socket.terminate();
      reject(new Error('The world service did not start the session.'));
    }, 8_000);
    socket.on('message', (data, isBinary) => {
      if (isBinary || state.socket !== socket) return;
      try {
        const message = decodeSessionMessage(data);
        if (!message) return;
        if (message.type === 'welcome') {
          welcomed = true;
          clearTimeout(welcomeTimeout);
          resolve();
        }
        if (welcomed) sendSession(state, message);
      } catch {
        socket.close(1007, 'Invalid session message');
      }
    });
    socket.on('error', () => {
      if (!welcomed) reject(new Error('Pot could not join this session.'));
    });
    socket.on('close', () => {
      clearTimeout(welcomeTimeout);
      if (!welcomed) reject(new Error('Pot could not join this session.'));
      if (state.socket === socket) {
        state.socket = null;
        if (welcomed) sendSession(state, { type: 'closed', message: 'The session ended.' });
      }
    });
  });
}

function newWindow(mode, api = primary, sceneId = null, network = null) {
  const studio = mode === 'studio';
  const title = studio ? 'Pot Studio' : 'Pot Client';
  const win = new BrowserWindow({
    title,
    width: studio ? 1440 : 1280,
    height: studio ? 930 : 860,
    minWidth: studio ? 1000 : 820,
    minHeight: 600,
    show: false,
    backgroundColor: '#f7faf8',
    icon: path.join(root, 'build', 'icons', studio ? 'studio.png' : 'client.png'),
    webPreferences: {
      preload: path.join(root, 'desktop', 'preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      webSecurity: true,
    },
  });
  const renderer = new URL(`../dist/${mode}/index.html`, import.meta.url);
  const state = { win, mode, api, sceneId, url: renderer.href, socket: null, project: null };
  const id = win.webContents.id;
  windows.set(id, state);
  win.webContents.on('will-navigate', (event) => event.preventDefault());
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-attach-webview', (event) => event.preventDefault());
  win.webContents.on('will-prevent-unload', (event) => {
    const answer = dialog.showMessageBoxSync(win, {
      type: 'warning',
      title: 'Unsaved project',
      message: 'Close this window and discard unsaved changes?',
      buttons: ['Keep editing', 'Discard changes'],
      cancelId: 0,
      defaultId: 0,
    });
    if (answer === 1) event.preventDefault();
  });

  win.once('ready-to-show', () => win.show());
  win.on('closed', () => {
    stopSession(state);
    windows.delete(id);
    if (network) void network.close().catch(console.error);
  });
  void win.loadFile(fileURLToPath(renderer)).catch((error) => {
    if (win.isDestroyed()) return;
    dialog.showErrorBox(title, `Pot could not load this window. ${error.message}`);
    win.destroy();
  });
  return win;
}

async function readProject(filename) {
  const file = await stat(filename);
  if (!file.isFile() || file.size > MAX_SCENE_BYTES) throw new Error('The project file exceeds Pot\'s size limit.');
  const data = await readFile(filename);
  if (data.length > MAX_SCENE_BYTES) throw new Error('The project file is too large.');
  return validateScene(JSON.parse(data.toString('utf8')));
}

async function writeProject(filename, scene) {
  const temp = path.join(path.dirname(filename), `.${randomUUID()}.tmp`);
  const document = JSON.stringify(scene, null, 2) + '\n';
  if (Buffer.byteLength(document) > MAX_SCENE_BYTES) throw new Error('The project is too large to save.');
  try {
    await writeFile(temp, document, { flag: 'wx', mode: 0o600, flush: true });
    await rename(temp, filename);
  } finally {
    await rm(temp, { force: true }).catch(() => {});
  }
}

const projectFilter = [{ name: 'Pot project', extensions: ['pot.json', 'json'] }];

async function openProject(state) {
  forStudio(state);
  const result = await dialog.showOpenDialog(state.win, {
    properties: ['openFile'],
    filters: projectFilter,
  });
  if (result.canceled) return null;
  const filename = result.filePaths[0];
  const scene = await readProject(filename);
  state.project = { id: scene.id, filename };
  return scene;
}

async function saveProject(state, input, saveAs) {
  forStudio(state);
  const scene = validateScene(input);
  let filename = state.project?.id === scene.id ? state.project.filename : null;
  if (!filename || saveAs) {
    const result = await dialog.showSaveDialog(state.win, {
      filters: projectFilter,
      defaultPath: filename ?? `${scene.id}.pot.json`,
      properties: ['showOverwriteConfirmation'],
    });
    if (result.canceled) return false;
    filename = result.filePath;
    if (!filename.toLowerCase().endsWith('.json')) filename += '.pot.json';
  }
  await writeProject(filename, scene);
  state.project = { id: scene.id, filename };
  return true;
}

async function playtest(state, input) {
  forStudio(state);
  const scene = validateScene(input);
  const network = await localNetwork();
  try {
    await network.api.publish(scene);
    newWindow('client', network.api, scene.id, network);
  } catch (error) {
    await network.close();
    throw error;
  }
}

const actions = {
  worlds: ({ api }) => api.list(),
  'load-world': ({ api }, id) => api.load(id),
  thumbnail: ({ api }, id) => api.thumbnail(id),
  'launch-world': ({ sceneId }) => sceneId,
  'network-mode': ({ api }) => api.mode,
  'open-project': openProject,
  'save-project': saveProject,
  'publish-world': (state, scene) => {
    forStudio(state);
    return state.api.publish(scene);
  },
  playtest,
  join: joinSession,
  leave: stopSession,
};

for (const [name, handler] of Object.entries(actions)) {
  ipcMain.handle(`pot:${name}`, (event, ...args) => handler(stateFor(event), ...args));
}
ipcMain.on('pot:move', (event, pose) => {
  const state = windows.get(event.sender.id);
  const now = performance.now();
  if (!state || event.senderFrame !== event.sender.mainFrame || event.senderFrame?.url !== state.url ||
      state.socket?.readyState !== WebSocket.OPEN || !isPose(pose) ||
      now - state.lastMove < 33 || state.socket.bufferedAmount > 32768) return;
  state.lastMove = now;
  const { x, y, z, yaw } = pose;
  state.socket.send(JSON.stringify({ type: 'move', x, y, z, yaw }));
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
app.on('activate', () => {
  if (!windows.size && primary && !quitting) newWindow(product);
});
app.on('will-quit', (event) => {
  if (!local) return;
  event.preventDefault();
  if (quitting) return;
  quitting = true;
  const deadline = setTimeout(() => app.exit(0), 4000);
  void Promise.allSettled([local.close(), thumbnailService.close()]).then(() => {
    clearTimeout(deadline);
    app.exit(0);
  });
});

async function start() {
  session.defaultSession.setPermissionCheckHandler(() => false);
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    ...(process.platform === 'darwin' ? [{ role: 'appMenu' }] : []),
    { role: 'fileMenu' },
    { role: 'editMenu' },
    { label: 'Window', submenu: [{ role: 'minimize' }, { role: 'togglefullscreen' }] },
  ]));
  renderCredential = randomUUID();
  thumbnailService = await startRenderService({ host: '127.0.0.1', port: 0, token: renderCredential });
  local = await localNetwork(path.join(app.getPath('appData'), 'Pot', 'worlds'));
  primary = await configuredApi();
  newWindow(product);
}

void app.whenReady().then(start).catch(async (error) => {
  dialog.showErrorBox(app.getName(), `Pot could not start. ${error.message}`);
  if (thumbnailService && !local) await thumbnailService.close().catch(console.error);
  app.quit();
});
