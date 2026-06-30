const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('perfAPI', {
  onData:      (cb)    => ipcRenderer.on('perf-data', (_, d) => cb(d)),
  setOpacity:  (v)     => ipcRenderer.send('set-opacity', v),
  setAot:      (flag)  => ipcRenderer.send('set-aot', flag),
  getSettings: ()      => ipcRenderer.sendSync('get-settings')
});
