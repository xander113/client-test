import { app, BrowserWindow, dialog, ipcMain, Menu, session } from 'electron';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Runtime } from './native.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const packageInfo = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8'));
const product = packageInfo.potProduct ?? (process.argv.includes('--studio') ? 'studio' : 'client');
const studio = product === 'studio';
const windows = new Map();
let runtime;
let quitting = false;

app.setName(studio ? 'Pot Studio' : 'Pot Client');
if (process.platform === 'win32') {
  app.setAppUserModelId(studio ? 'org.potproject.studio' : 'org.potproject.client');
}

function windowFor(event) {
  const state = windows.get(event.sender.id);
  if (!state || event.senderFrame !== event.sender.mainFrame || event.senderFrame?.url !== state.url) {
    throw new Error('This window cannot access Pot.');
  }
  return state;
}

function forStudio() {
  if (!studio) throw new Error('This action requires Pot Studio.');
}

function newWindow() {
  const win = new BrowserWindow({
    title: app.getName(),
    width: studio ? 1440 : 1240,
    height: studio ? 930 : 820,
    minWidth: studio ? 900 : 720,
    minHeight: 570,
    show: false,
    backgroundColor: '#f6f7f5',
    icon: path.join(root, 'build', 'icons', `${product}.png`),
    webPreferences: {
      preload: path.join(root, 'desktop', 'preload.cjs'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
    },
  });
  const renderer = new URL(`../dist/${product}/index.html`, import.meta.url);
  const id = win.webContents.id;
  windows.set(id, { win, id, url: renderer.href, file: null, lastInput: 0 });
  win.webContents.on('will-navigate', (event) => event.preventDefault());
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-attach-webview', (event) => event.preventDefault());
  if (studio) {
    win.webContents.on('will-prevent-unload', (event) => {
      const choice = dialog.showMessageBoxSync(win, {
        type: 'warning',
        title: 'Unsaved project',
        message: 'Close this project and discard your changes?',
        buttons: ['Keep editing', 'Discard changes'],
        cancelId: 0,
        defaultId: 0,
      });
      if (choice === 1) event.preventDefault();
    });
  }
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => {
    windows.delete(id);
    if (!studio && !quitting) void runtime.call('leave', id).catch(() => {});
  });
  void win.loadFile(fileURLToPath(renderer)).catch(() => {
    if (win.isDestroyed()) return;
    dialog.showErrorBox(app.getName(), 'Pot could not load its interface.');
    win.destroy();
  });
}

async function openProject(state) {
  forStudio();
  const selection = await dialog.showOpenDialog(state.win, {
    properties: ['openFile'],
    filters: [{ name: 'Pot project', extensions: ['pot', 'json'] }],
  });
  if (selection.canceled) return null;
  const filename = selection.filePaths[0];
  const scene = await runtime.call('open', state.id, { path: filename });
  state.file = {
    id: scene.id,
    filename: path.extname(filename).toLowerCase() === '.pot' ? filename : null,
  };
  return scene;
}

async function saveProject(state, scene, saveAs) {
  forStudio();
  let filename = state.file?.id === scene?.id ? state.file.filename : null;
  if (!filename || saveAs) {
    const selection = await dialog.showSaveDialog(state.win, {
      filters: [{ name: 'Pot project', extensions: ['pot'] }],
      defaultPath: filename ?? `${String(scene?.name || 'Project').replace(/[^ a-z0-9_-]/gi, '_').slice(0, 60)}.pot`,
      properties: ['showOverwriteConfirmation'],
    });
    if (selection.canceled) return false;
    filename = selection.filePath;
    if (path.extname(filename).toLowerCase() !== '.pot') filename += '.pot';
  }
  await runtime.call('save', state.id, { path: filename, scene });
  state.file = { id: scene.id, filename };
  return true;
}

const actions = {
  worlds: ({ id }) => runtime.call('worlds', id),
  'load-world': ({ id }, world) => runtime.call('load', id, { world }),
  thumbnail: async ({ id }, world) => {
    const png = await runtime.call('thumbnail', id, { world });
    return `data:image/png;base64,${Buffer.from(png).toString('base64')}`;
  },
  'network-mode': ({ id }) => runtime.call('mode', id),
  'sample-project': ({ id }) => { forStudio(); return runtime.call('sample', id); },
  'open-project': openProject,
  'save-project': saveProject,
  'publish-world': ({ id }, scene) => { forStudio(); return runtime.call('publish', id, { scene }); },
  join: ({ id }, world) => runtime.call('join', id, { world }),
  leave: ({ id }) => runtime.call('leave', id),
};

for (const [action, handler] of Object.entries(actions)) {
  ipcMain.handle(`pot:${action}`, (event, ...args) => handler(windowFor(event), ...args));
}
ipcMain.on('pot:input', (event, input) => {
  try {
    const state = windowFor(event);
    const now = performance.now();
    if (now - state.lastInput < 22 || studio) return;
    state.lastInput = now;
    runtime.input(state.id, { x: input.x, z: input.z, yaw: input.yaw, jump: input.jump });
  } catch {
    // A closed window or malformed input has no active session to update.
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
app.on('activate', () => {
  if (!windows.size && runtime && !quitting) newWindow();
});
app.on('will-quit', (event) => {
  if (!runtime) return;
  event.preventDefault();
  if (quitting) return;
  quitting = true;
  void runtime.close().finally(() => app.exit(0));
});

async function start() {
  session.defaultSession.setPermissionCheckHandler(() => false);
  session.defaultSession.setPermissionRequestHandler((_contents, _permission, cb) => cb(false));
  Menu.setApplicationMenu(process.platform === 'darwin'
    ? Menu.buildFromTemplate([{ role: 'appMenu' }, { role: 'editMenu' }, { role: 'windowMenu' }])
    : null);
  const binary = process.platform === 'win32' ? 'potd.exe' : 'potd';
  const binaries = app.isPackaged ? process.resourcesPath : path.join(root, '.native', `${process.platform}-${process.arch}`);
  runtime = new Runtime(path.join(binaries, binary), path.join(app.getPath('appData'), 'Pot', 'worlds'),
    (id, event) => {
      const state = windows.get(id);
      if (state && !state.win.isDestroyed()) state.win.webContents.send('pot:session', event);
    });
  await runtime.call('mode', 0);
  newWindow();
}

void app.whenReady().then(start).catch((error) => {
  dialog.showErrorBox(app.getName(), error.message);
  app.quit();
});
