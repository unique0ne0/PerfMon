const { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage, shell } = require('electron');
const path = require('path');
const si = require('systeminformation');

let win = null;
let tray = null;
let updateInterval = null;
let intervalMs = 1000;

// ─── 앱 단일 인스턴스 보장 ───────────────────────────────────────────
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) { app.quit(); }
else {
  app.on('second-instance', () => { if (win) { win.show(); win.focus(); } });
}

// ─── 시작 ────────────────────────────────────────────────────────────
app.whenReady().then(() => {
  createWindow();
  createTray();
  startMonitoring();

  // Windows 시작프로그램 자동 등록
  if (process.platform === 'win32') {
    app.setLoginItemSettings({
      openAtLogin: true,
      path: process.execPath,
      args: ['--autostart']
    });
  }
});

// ─── 창 생성 ─────────────────────────────────────────────────────────
function createWindow() {
  // 저장된 위치 불러오기
  const Store = getStore();
  const pos   = Store.pos || { x: 100, y: 100 };
  const size  = Store.size || { w: 78, h: 200 };

  win = new BrowserWindow({
    x: pos.x,
    y: pos.y,
    width:  size.w,
    height: size.h,
    minWidth:  60,
    minHeight: 120,
    frame: false,
    transparent: true,
    alwaysOnTop: true,
    resizable: true,
    skipTaskbar: true,
    hasShadow: false,
    // Windows 11 rounded corners 방지 (원하면 제거)
    roundedCorners: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js')
    }
  });

  win.loadFile(path.join(__dirname, 'index.html'));

  // 모든 가상 데스크탑에 표시
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  // 창 닫으면 완전 종료 대신 숨기기 (트레이에서 다시 열기 가능)
  win.on('close', (e) => {
    e.preventDefault();
    win.hide();
  });

  // 창 이동/크기 변경 시 위치 저장
  win.on('moved', saveWinState);
  win.on('resized', saveWinState);
}

function saveWinState() {
  if (!win) return;
  const [x, y] = win.getPosition();
  const [w, h] = win.getSize();
  saveStore({ pos: { x, y }, size: { w, h } });
}

// ─── 간단한 JSON 설정 저장 (electron-store 없이) ─────────────────────
const fs   = require('fs');
const cfgPath = path.join(app.getPath('userData'), 'perfmon-config.json');

function getStore() {
  try { return JSON.parse(fs.readFileSync(cfgPath, 'utf8')); }
  catch { return {}; }
}
function saveStore(data) {
  try {
    const cur = getStore();
    fs.writeFileSync(cfgPath, JSON.stringify({ ...cur, ...data }, null, 2));
  } catch {}
}

// ─── 트레이 ──────────────────────────────────────────────────────────
function createTray() {
  // 16x16 파란 점 아이콘 (ico 파일 없을 때 fallback)
  const img = nativeImage.createFromDataURL(
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAABmJLR0QA/wD/AP+gvaeTAAAATUlEQVQ4jWNgGAWkACYGBob/1DL8//9/IzUMYGBg+E8tA4iGUQMMGBgY/lPLAAaGUQMMGBj+U8sABobRMGCg2oD/1DKAgWE0DBioBgAA9CoJ4Lc3PQAAAABJRU5ErkJggg=='
  );
  tray = new Tray(img);

  const buildMenu = () => Menu.buildFromTemplate([
    { label: '📊 PerfMon Overlay', enabled: false },
    { type: 'separator' },
    {
      label: win && win.isVisible() ? '창 숨기기' : '창 보이기',
      click: () => { win && (win.isVisible() ? win.hide() : win.show()); rebuildTrayMenu(); }
    },
    { type: 'separator' },
    {
      label: '업데이트 주기',
      submenu: [
        { label: '빠름 (500ms)', type: 'radio', checked: intervalMs===500,  click: () => restartMonitoring(500)  },
        { label: '보통 (1초)',   type: 'radio', checked: intervalMs===1000, click: () => restartMonitoring(1000) },
        { label: '느림 (2초)',   type: 'radio', checked: intervalMs===2000, click: () => restartMonitoring(2000) }
      ]
    },
    {
      label: '시작프로그램',
      submenu: [
        { label: '자동 시작 ON',  click: () => setAutoStart(true)  },
        { label: '자동 시작 OFF', click: () => setAutoStart(false) }
      ]
    },
    { type: 'separator' },
    { label: '완전 종료', click: () => { app.exit(0); } }
  ]);

  function rebuildTrayMenu() { tray.setContextMenu(buildMenu()); }
  tray.setToolTip('PerfMon Overlay');
  tray.setContextMenu(buildMenu());
  tray.on('click', () => { if (win) win.isVisible() ? win.focus() : win.show(); rebuildTrayMenu(); });
}

function setAutoStart(enable) {
  if (process.platform !== 'win32') return;
  app.setLoginItemSettings({ openAtLogin: enable, path: process.execPath });
}

// ─── 성능 데이터 수집 ────────────────────────────────────────────────
function startMonitoring() {
  // 첫 호출은 기준값(델타 베이스라인)으로 버림
  si.fsStats().catch(() => {});
  si.networkStats().catch(() => {});

  updateInterval = setInterval(async () => {
    try {
      const [cpuLoad, mem, fsStats, nets, cpuTemp] = await Promise.all([
        si.currentLoad().catch(() => ({ currentLoad: 0 })),
        si.mem().catch(() => ({ used: 0, total: 1 })),
        si.fsStats().catch(() => ({})),
        si.networkStats().catch(() => []),
        si.cpuTemperature().catch(() => ({ main: null }))
      ]);

      // CPU
      const cpu = Math.round(cpuLoad.currentLoad);

      // 메모리
      const memPct   = Math.round((mem.used / mem.total) * 100);
      const memUsed  = (mem.used  / 1073741824).toFixed(1);
      const memTotal = (mem.total / 1073741824).toFixed(0);

      // 디스크 Read / Write (bytes/s → MB/s)  ※ fsStats.rx_sec/wx_sec 사용
      const diskR = ((fsStats.rx_sec || 0) / 1048576).toFixed(2);
      const diskW = ((fsStats.wx_sec || 0) / 1048576).toFixed(2);

      // 네트워크 Down / Up (bytes/s → KB/s)
      let netDn = 0, netUp = 0;
      if (nets && nets.length > 0) {
        // 루프백 제외하고 가장 활발한 인터페이스
        const iface = nets.find(n => !n.iface.toLowerCase().includes('lo')) || nets[0];
        netDn = Math.round((iface.rx_sec || 0) / 1024);
        netUp = Math.round((iface.tx_sec || 0) / 1024);
      }

      // CPU 온도 (있을 때만)
      const temp = cpuTemp.main ? Math.round(cpuTemp.main) : null;

      const payload = { cpu, memPct, memUsed, memTotal, diskR, diskW, netDn, netUp, temp };

      if (win && !win.isDestroyed()) {
        win.webContents.send('perf-data', payload);
      }
    } catch (e) {
      // 권한 오류 등 무시
    }
  }, intervalMs);
}

function restartMonitoring(ms) {
  clearInterval(updateInterval);
  intervalMs = ms;
  startMonitoring();
}

// ─── IPC ─────────────────────────────────────────────────────────────
ipcMain.on('set-opacity',  (_, v)    => { if (win) win.setOpacity(v); saveStore({ opacity: v }); });
ipcMain.on('set-aot',      (_, flag) => { if (win) win.setAlwaysOnTop(flag); });
ipcMain.on('get-settings', (e)       => { e.returnValue = getStore(); });

app.on('window-all-closed', () => { /* 트레이 앱은 창 닫아도 유지 */ });
