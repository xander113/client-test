const { contextBridge, ipcRenderer } = require('electron');

const invoke = (action, ...args) => ipcRenderer.invoke(`pot:${action}`, ...args);

contextBridge.exposeInMainWorld('pot', Object.freeze({
  getWorlds: () => invoke('worlds'),
  loadWorld: (id) => invoke('load-world', id),
  getThumbnail: (id) => invoke('thumbnail', id),
  getLaunchWorld: () => invoke('launch-world'),
  getNetworkMode: () => invoke('network-mode'),
  openProject: () => invoke('open-project'),
  saveProject: (scene, saveAs) => invoke('save-project', scene, saveAs === true),
  publishWorld: (scene) => invoke('publish-world', scene),
  playtest: (scene) => invoke('playtest', scene),
  joinWorld: (id) => invoke('join', id),
  leaveWorld: () => invoke('leave'),
  move: ({ x, y, z, yaw }) => ipcRenderer.send('pot:move', { x, y, z, yaw }),
  onSession: (callback) => {
    const handler = (_event, message) => callback(message);
    ipcRenderer.on('pot:session', handler);
    return () => ipcRenderer.removeListener('pot:session', handler);
  },
}));
