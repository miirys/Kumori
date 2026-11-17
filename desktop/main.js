// The desktop shell: one window, and the few things a web page may not do itself.
const { app, BrowserWindow, ipcMain, shell, session, safeStorage } = require('electron');
const path = require('node:path');
const fs = require('node:fs');
const net = require('node:net');

// Hardware video decoding, HEVC included where the GPU has it. Linux needs it asked for.
app.commandLine.appendSwitch('enable-features', [
  'PlatformHEVCDecoderSupport', 'WebRtcAllowH265Receive', 'AcceleratedVideoDecodeLinuxGL', 'AcceleratedVideoDecodeLinuxZeroCopyGL',
  'VaapiVideoDecoder', 'VaapiIgnoreDriverChecks',
].join(','));
app.commandLine.appendSwitch('ignore-gpu-blocklist');
// Video starts without a click.
app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');

const NVIDIA = /(^|\.)(nvidia\.com|geforcenow\.com|geforce\.com|nvidiagrid\.net)$/;
const allowed = (url) => { try { const u = new URL(url); return u.protocol === 'https:' && NVIDIA.test(u.hostname); } catch { return false; } };

let win = null;

function storePath() { return path.join(app.getPath('userData'), 'kumori.dat'); }
function readStore() {
  try {
    const raw = fs.readFileSync(storePath());
    const text = raw[0] === 0x7b ? raw.toString('utf8') : safeStorage.decryptString(raw);
    return JSON.parse(text);
  } catch { return {}; }
}
function writeStore(data) {
  const text = JSON.stringify(data);
  // The sign-in is kept encrypted with the system keychain where there is one.
  const out = safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(text) : Buffer.from(text, 'utf8');
  fs.mkdirSync(path.dirname(storePath()), { recursive: true });
  fs.writeFileSync(storePath(), out, { mode: 0o600 });
}

ipcMain.handle('http', async (_e, { url, method, headers, body }) => {
  if (!allowed(url)) return { error: 'blocked' };
  try {
    const r = await fetch(url, { method, headers, body: body ?? undefined, signal: AbortSignal.timeout(20000), redirect: 'follow' });
    return { status: r.status, text: await r.text() };
  } catch (e) {
    return { error: String(e?.message ?? e) };
  }
});
ipcMain.handle('store:get', () => readStore());
ipcMain.handle('store:set', (_e, data) => { writeStore(data); });
ipcMain.handle('open', (_e, url) => { if (/^https:\/\//.test(url)) shell.openExternal(url); });
ipcMain.handle('version', () => app.getVersion());
// A page may only take the mouse pointer right after a click. Games hide and show their
// cursor whenever they like, so the pointer is asked for from here, which counts as one.
ipcMain.handle('lock-pointer', () => win?.webContents.executeJavaScript('window.__takePointer && window.__takePointer()', true));
/** Round trip of a TCP connection to a region's front door: a good stand-in for distance. */
ipcMain.handle('ping', (_e, url) => new Promise((resolve) => {
  if (!allowed(url)) return resolve(null);
  const t0 = process.hrtime.bigint();
  const sock = net.connect({ host: new URL(url).hostname, port: 443 });
  const done = (v) => { sock.destroy(); resolve(v); };
  sock.setTimeout(1500, () => done(null));
  sock.once('connect', () => done(Number((process.hrtime.bigint() - t0) / 1000000n)));
  sock.once('error', () => done(null));
}));

function createWindow() {
  win = new BrowserWindow({
    width: 1360, height: 820, minWidth: 880, minHeight: 560, backgroundColor: '#16111B', autoHideMenuBar: true, show: false, title: 'Kumori',
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true, backgroundThrottling: false },
  });
  win.removeMenu();
  win.once('ready-to-show', () => win.show());
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.loadFile(path.join(__dirname, 'app', 'index.html'));
  if (process.env.KUMORI_DEVTOOLS) win.webContents.openDevTools({ mode: 'detach' });
}

app.whenReady().then(() => {
  const ses = session.defaultSession;
  // The rig's signalling socket only answers GeForce NOW's own web client.
  ses.webRequest.onBeforeSendHeaders({ urls: ['wss://*/*'] }, (details, cb) => {
    const h = details.requestHeaders;
    h.Origin = 'https://play.geforcenow.com';
    h['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
    cb({ requestHeaders: h });
  });
  const ok = new Set(['pointerLock', 'fullscreen', 'keyboardLock']);
  ses.setPermissionRequestHandler((_wc, permission, cb) => cb(ok.has(permission)));
  ses.setPermissionCheckHandler((_wc, permission) => ok.has(permission));
  createWindow();
});

const single = app.requestSingleInstanceLock();
if (!single) app.quit();
app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.on('window-all-closed', () => app.quit());
