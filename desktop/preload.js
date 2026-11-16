const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('kumori', {
  http: (req) => ipcRenderer.invoke('http', req),
  load: () => ipcRenderer.invoke('store:get'),
  save: (data) => ipcRenderer.invoke('store:set', data),
  open: (url) => ipcRenderer.invoke('open', url),
  ping: (url) => ipcRenderer.invoke('ping', url),
  lockPointer: () => ipcRenderer.invoke('lock-pointer'),
  version: () => ipcRenderer.invoke('version'),
  platform: process.platform,
});
