'use strict';

/**
 * Yapper - unofficial Linux desktop client.
 *
 * A thin, well-behaved Electron shell around https://www.yapper.website/.
 * NOT affiliated with, endorsed by, or supported by Yapper.
 *
 * What this adds over a browser tab:
 *   - its own window, taskbar entry and tray icon
 *   - persistent login (cookies survive restarts)
 *   - system screen-share picker (XDG portal / PipeWire aware)
 *   - microphone, camera and notification permissions handled in-app
 *   - voice + screen sharing on both Wayland and X11
 *   - single instance: re-launching focuses the existing window
 */

const {
  app,
  BrowserWindow,
  Menu,
  Tray,
  Notification,
  dialog,
  desktopCapturer,
  ipcMain,
  nativeImage,
  shell,
  session,
} = require('electron');

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const net = require('node:net');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const APP_URL = 'https://www.yapper.website/';
const PROBE_URL = 'https://www.yapper.website/icon.svg';
const REPO_URL = 'https://github.com/FirFall/yapper-linux';
const PARTITION = 'persist:yapper';
const PICK_SOURCE_CHANNEL = 'yapper:screen-source-picked';
const PICK_LIST_CHANNEL = 'yapper:screen-sources';

/** Hosts the app may navigate to inside its own window. */
const INTERNAL_HOSTS = [
  'yapper.website',
  'yappers.site',
];

/** Things the site legitimately needs. Everything else is denied. */
const ALLOWED_PERMISSIONS = new Set([
  'media',
  'mediaKeySystem',
  'audioCapture',
  'videoCapture',
  'display-capture',
  'fullscreen',
  'notifications',
  'clipboard-read',
  'clipboard-sanitized-write',
  'background-sync',
  'idle-detection',
  'speaker-selection',
  'accessibility-events',
]);

const isFlatpak = Boolean(process.env.FLATPAK_ID);

// ---------------------------------------------------------------------------
// Optional user flags: ~/.config/yapper/flags.conf
// ---------------------------------------------------------------------------

function applyUserFlags() {
  const configHome = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
  const flagFile = path.join(configHome, 'yapper', 'flags.conf');

  let lines;
  try {
    if (!fs.existsSync(flagFile)) return;
    lines = fs.readFileSync(flagFile, 'utf8').split('\n');
  } catch {
    return;
  }

  for (const raw of lines) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const eq = line.indexOf('=');
    const key = (eq === -1 ? line : line.slice(0, eq)).replace(/^--/, '');
    const value = eq === -1 ? undefined : line.slice(eq + 1);

    if (key === 'no-gpu') {
      app.disableHardwareAcceleration();
      continue;
    }
    if (value === undefined) app.commandLine.appendSwitch(key);
    else app.commandLine.appendSwitch(key, value);
  }
}

/** Exactly what the session type allows, decided once. */
function detectWayland() {
  const display = process.env.WAYLAND_DISPLAY || 'wayland-0';
  if (process.env.XDG_RUNTIME_DIR && fs.existsSync(path.join(process.env.XDG_RUNTIME_DIR, display))) {
    return true;
  }
  return fs.existsSync('/' + display);
}

applyUserFlags();

const onWayland = detectWayland();

// PipeWire is the modern screen-capture path on both Wayland and X11.
const enabledFeatures = ['WebRTCPipeWireCapturer'];
if (onWayland) {
  enabledFeatures.push('WaylandWindowDecorations');
  app.commandLine.appendSwitch('ozone-platform-hint', 'auto');
  app.commandLine.appendSwitch('enable-wayland-ime');
  app.commandLine.appendSwitch('wayland-text-input-version', '3');
} else {
  app.commandLine.appendSwitch('ozone-platform', 'x11');
}
// A single appendSwitch call: repeating it would make the last value win and
// silently drop the earlier features.
app.commandLine.appendSwitch('enable-features', enabledFeatures.join(','));

app.setName('Yapper');

if (process.platform === 'linux') {
  // Notifications look up an icon by desktop file name. Flatpak installs
  // <app-id>.desktop, native packages install yapper.desktop.
  const desktopName = `${desktopFileBase()}.desktop`;
  if (typeof app.setDesktopName === 'function') app.setDesktopName(desktopName);

  // On Wayland this value *is* the application id, and the desktop environment
  // matches it against the installed <name>.desktop file to pick the taskbar
  // icon and to group windows. It has to match exactly, including case, or the
  // launcher shows a generic icon while the app is running.
  app.commandLine.appendSwitch('class', desktopFileBase());
}

/** Base name of the installed .desktop file, without the extension. */
function desktopFileBase() {
  return isFlatpak ? process.env.FLATPAK_ID : 'yapper';
}

// ---------------------------------------------------------------------------
// Single instance
// ---------------------------------------------------------------------------

if (!app.requestSingleInstanceLock()) {
  app.quit();
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Window state
// ---------------------------------------------------------------------------

const stateFile = () => path.join(app.getPath('userData'), 'window-state.json');

function loadWindowState() {
  const fallback = { width: 1280, height: 800 };
  try {
    const raw = JSON.parse(fs.readFileSync(stateFile(), 'utf8'));
    const state = {
      width: Math.max(640, Number(raw.width) || fallback.width),
      height: Math.max(480, Number(raw.height) || fallback.height),
    };
    if (Number.isInteger(raw.x)) state.x = raw.x;
    if (Number.isInteger(raw.y)) state.y = raw.y;
    if (raw.maximized) state.maximized = true;
    return state;
  } catch {
    return fallback;
  }
}

function saveWindowState(win) {
  if (!win || win.isDestroyed()) return;
  try {
    const bounds = win.isMaximized() || win.isFullScreen() ? win.getNormalBounds() : win.getBounds();
    fs.writeFileSync(stateFile(), JSON.stringify({ ...bounds, maximized: win.isMaximized() }, null, 2));
  } catch {
    /* not worth bothering the user about */
  }
}

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

function isInternalUrl(rawUrl) {
  try {
    const { hostname, protocol } = new URL(rawUrl);
    if (protocol !== 'https:' && protocol !== 'http:') return false;
    return INTERNAL_HOSTS.some((host) => hostname === host || hostname.endsWith('.' + host));
  } catch {
    return false;
  }
}

function openExternal(rawUrl) {
  try {
    const { protocol } = new URL(rawUrl);
    if (!['http:', 'https:', 'mailto:'].includes(protocol)) return;
    shell.openExternal(rawUrl);
  } catch {
    /* malformed URL, ignore */
  }
}

// ---------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------

/** @type {BrowserWindow | null} */
let mainWindow = null;
/** @type {Tray | null} */
let tray = null;
let isQuitting = false;

function createWindow() {
  const state = loadWindowState();

  mainWindow = new BrowserWindow({
    width: state.width,
    height: state.height,
    x: state.x,
    y: state.y,
    minWidth: 640,
    minHeight: 480,
    show: false,
    // Matches the site's theme-color so there is no white flash on launch.
    backgroundColor: '#141519',
    title: 'Yapper',
    autoHideMenuBar: true,
    icon: path.join(__dirname, '..', 'build', 'icons', '512x512.png'),
    webPreferences: {
      partition: PARTITION,
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false, // the preload needs require('electron')
      spellcheck: true,
      backgroundThrottling: false, // keeps voice and notifications responsive
      plugins: true, // built-in PDF viewer for links pasted in chat
    },
  });

  if (state.maximized) mainWindow.maximize();

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
    mainWindow.focus();
  });

  mainWindow.on('close', (event) => {
    saveWindowState(mainWindow);
    if (!isQuitting && tray) {
      // Keep running in the tray so notifications keep arriving.
      event.preventDefault();
      mainWindow.hide();
    }
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  // window.open / target=_blank: internal links get a real app window,
  // everything else goes to the user's browser.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (isInternalUrl(url)) {
      return {
        action: 'allow',
        overrideBrowserWindowOptions: {
          autoHideMenuBar: true,
          backgroundColor: '#141519',
          webPreferences: {
            partition: PARTITION,
            contextIsolation: true,
            nodeIntegration: false,
            sandbox: false,
          },
        },
      };
    }
    openExternal(url);
    return { action: 'deny' };
  });

  const load = () => {
    mainWindow.loadURL(APP_URL).catch(reportLoadFailure);
  };

  mainWindow.webContents.on('did-fail-load', (_e, errorCode, errorDescription, validatedURL, isMainFrame) => {
    // -3 is ERR_ABORTED, which fires routinely during client-side redirects.
    if (isMainFrame && errorCode !== -3) {
      reportLoadFailure({ message: `${errorDescription} (${errorCode})`, url: validatedURL });
    }
  });

  mainWindow.webContents.on('render-process-gone', (_e, details) => {
    dialog
      .showMessageBox(mainWindow, {
        type: 'error',
        title: 'Yapper stopped responding',
        message: 'The Yapper window crashed and needs to be reloaded.',
        detail: `Reason: ${details.reason}`,
        buttons: ['Reload', 'Quit'],
        defaultId: 0,
        cancelId: 1,
      })
      .then(({ response }) => (response === 0 ? load() : quitApp()));
  });

  load();
  return mainWindow;
}

function showWindow() {
  if (!mainWindow) {
    createWindow();
    return;
  }
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.show();
  mainWindow.focus();
}

function quitApp() {
  isQuitting = true;
  saveWindowState(mainWindow);
  app.quit();
}

async function reportLoadFailure(err) {
  if (!mainWindow || mainWindow.isDestroyed()) return;

  const online = await isOnline();
  const { response } = await dialog.showMessageBox(mainWindow, {
    type: 'warning',
    title: 'Yapper',
    message: online ? 'Could not reach Yapper.' : 'You appear to be offline.',
    detail: online
      ? `Yapper could not be loaded.\n\n${err?.message || 'Unknown error'}`
      : 'Yapper needs an internet connection. Reconnect and try again.',
    buttons: ['Try again', 'Open in browser', 'Quit'],
    defaultId: 0,
    cancelId: 2,
  });

  if (response === 0) mainWindow.loadURL(APP_URL).catch(() => {});
  else if (response === 1) openExternal(APP_URL);
  else quitApp();
}

function isOnline() {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => finish(false), 4000);

    try {
      const request = net.request({ method: 'HEAD', url: PROBE_URL });
      request.on('response', () => {
        request.abort();
        finish(true);
      });
      request.on('error', () => finish(false));
      request.end();
    } catch {
      finish(false);
    }
  });
}

// ---------------------------------------------------------------------------
// Tray
// ---------------------------------------------------------------------------

function createTray() {
  const image = nativeImage.createFromPath(path.join(__dirname, '..', 'build', 'icons', '256x256.png'));
  if (image.isEmpty()) return;

  tray = new Tray(image.resize({ width: 22, height: 22 }));
  tray.setToolTip('Yapper');
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: 'Open Yapper', click: showWindow },
      { type: 'separator' },
      { label: 'Reload', click: () => mainWindow?.webContents.reload() },
      { label: 'Mute / Unmute', click: () => toggleMic() },
      { type: 'separator' },
      { label: 'Quit', click: quitApp },
    ]),
  );
  tray.on('click', showWindow);
}

function toggleMic() {
  // The site owns mute state; just nudge the page to focus the voice controls.
  mainWindow?.webContents.executeJavaScript(
    'window.dispatchEvent(new KeyboardEvent("keydown",{key:"m",ctrlKey:true,shiftKey:true,bubbles:true}))',
  ).catch(() => {});
}

// ---------------------------------------------------------------------------
// Screen sharing
// ---------------------------------------------------------------------------

/**
 * Fallback chooser used when the desktop portal is unavailable
 * (bare X11 with no xdg-desktop-portal). Uses a real HTML file plus a preload
 * so no node integration is exposed to page content.
 */
function promptScreenSource(sources) {
  return new Promise((resolve) => {
    const items = sources.map((source) => ({
      id: source.id,
      name: source.name,
      // Screens and windows both get a preview.
      thumb: source.thumbnail?.isEmpty() ? null : source.thumbnail.toDataURL(),
    }));

    const win = new BrowserWindow({
      width: 520,
      height: 480,
      title: 'Choose what to share',
      parent: mainWindow ?? undefined,
      modal: Boolean(mainWindow),
      resizable: false,
      minimizable: false,
      maximizable: false,
      autoHideMenuBar: true,
      backgroundColor: '#141519',
      webPreferences: {
        preload: path.join(__dirname, 'picker-preload.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: false,
      },
    });

    let done = false;
    const settle = (result) => {
      if (done) return;
      done = true;
      ipcMain.removeListener(PICK_SOURCE_CHANNEL, onPicked);
      if (!win.isDestroyed()) win.destroy();
      resolve(result);
    };

    const onPicked = (event, id) => {
      if (event.sender !== win.webContents) return;
      settle(id ? sources.find((s) => s.id === id) ?? null : null);
    };

    ipcMain.on(PICK_SOURCE_CHANNEL, onPicked);
    win.on('closed', () => settle(null));

    win.webContents.once('did-finish-load', () => {
      if (!win.isDestroyed()) win.webContents.send(PICK_LIST_CHANNEL, items);
    });

    win.loadFile(path.join(__dirname, 'picker.html'));
  });
}

function configureSession() {
  const ses = session.fromPartition(PARTITION);

  // Present as real Chrome. Some sites refuse to offer voice/WebRTC to
  // anything that identifies itself as Electron.
  const userAgent = ses
    .getUserAgent()
    .replace(/ Electron\/[\d.]+/, '')
    .replace(new RegExp(` ${app.getName()}/[\\d.]+`), '');
  ses.setUserAgent(userAgent);
  app.userAgentFallback = userAgent;

  ses.setPermissionRequestHandler((webContents, permission, callback, details) => {
    const origin = details?.requestingUrl || webContents?.getURL?.() || '';
    if (!isInternalUrl(origin)) return callback(false);

    if (permission === 'media') {
      // Voice channels need the mic, video calls need the camera.
      const types = details?.mediaTypes ?? [];
      return callback(types.some((t) => t === 'audio' || t === 'video'));
    }
    callback(ALLOWED_PERMISSIONS.has(permission));
  });

  ses.setPermissionCheckHandler((_webContents, permission, requestingOrigin) =>
    isInternalUrl(requestingOrigin) && ALLOWED_PERMISSIONS.has(permission),
  );

  // Screen sharing. Electron >= 30 supports useSystemPicker, which hands the
  // choice to the XDG desktop portal (GNOME / KDE / wlroots). That is also what
  // makes screen sharing work correctly inside the Flatpak sandbox.
  if (typeof ses.setDisplayMediaRequestHandler === 'function') {
    ses.setDisplayMediaRequestHandler(
      async (request, callback) => {
        try {
          const sources = await desktopCapturer.getSources({
            types: ['screen', 'window'],
            thumbnailSize: { width: 320, height: 180 },
            fetchWindowIcons: true,
          });
          if (!sources.length) return callback({});

          const chosen = await promptScreenSource(sources);
          if (!chosen) return callback({});

          const response = { video: chosen };
          // Loopback audio (sharing system sound) is only implemented on Windows.
          if (request.audioRequested && process.platform === 'win32') response.audio = 'loopback';
          return callback(response);
        } catch (err) {
          console.warn('[yapper] screen share failed:', err?.message);
          return callback({});
        }
      },
      { useSystemPicker: true },
    );
  }

  ses.on('will-download', (_event, item) => {
    item.once('done', (_e, status) => {
      if (status !== 'completed') return;
      new Notification({
        title: 'Download complete',
        body: path.basename(item.getSavePath()),
      }).show();
    });
  });
}

// ---------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------

function showAbout() {
  dialog.showMessageBox(mainWindow ?? undefined, {
    type: 'info',
    title: 'About Yapper',
    message: `Yapper ${app.getVersion()}`,
    detail: [
      'Unofficial desktop client for Yapper.',
      `Electron ${process.versions.electron} - ${isFlatpak ? 'Flatpak' : 'native package'}.`,
      '',
      'This app is not affiliated with, endorsed by, or supported by Yapper.',
      'Yapper and its logo belong to their respective owners.',
    ].join('\n'),
    buttons: ['OK'],
  });
}

async function clearSession() {
  const { response } = await dialog.showMessageBox(mainWindow ?? undefined, {
    type: 'warning',
    title: 'Sign out',
    message: 'Sign out and clear all local Yapper data?',
    detail: 'Cookies, cache and the saved login will be deleted. This cannot be undone.',
    buttons: ['Cancel', 'Clear data'],
    defaultId: 0,
    cancelId: 0,
  });
  if (response !== 1) return;

  const ses = session.fromPartition(PARTITION);
  await ses.clearStorageData();
  await ses.clearCache();
  mainWindow?.webContents.reload();
}

function buildMenu() {
  Menu.setApplicationMenu(
    Menu.buildFromTemplate([
      {
        label: 'File',
        submenu: [
          { label: 'New Window', accelerator: 'CmdOrCtrl+N', click: () => createWindow() },
          { type: 'separator' },
          { label: 'Sign Out & Clear Data...', click: clearSession },
          { type: 'separator' },
          { label: 'Quit', accelerator: 'CmdOrCtrl+Q', click: quitApp },
        ],
      },
      {
        label: 'Edit',
        submenu: [
          { role: 'undo' },
          { role: 'redo' },
          { type: 'separator' },
          { role: 'cut' },
          { role: 'copy' },
          { role: 'paste' },
          { role: 'pasteAndMatchStyle' },
          { role: 'selectAll' },
        ],
      },
      {
        label: 'View',
        submenu: [
          { role: 'reload' },
          { role: 'forceReload' },
          { type: 'separator' },
          { role: 'resetZoom' },
          { role: 'zoomIn' },
          { role: 'zoomOut' },
          { type: 'separator' },
          { role: 'togglefullscreen' },
          { label: 'Open in Browser', click: () => openExternal(APP_URL) },
          { role: 'toggleDevTools' },
        ],
      },
      {
        label: 'Help',
        submenu: [
          { label: 'Yapper Website', click: () => openExternal(APP_URL) },
          { label: 'Report a Bug in this Linux App', click: () => openExternal(`${REPO_URL}/issues`) },
          { type: 'separator' },
          { label: 'About Yapper (unofficial)', click: showAbout },
        ],
      },
    ]),
  );
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

app.on('second-instance', showWindow);
app.on('activate', showWindow);

app.on('window-all-closed', () => {
  // Stay alive in the tray so notifications keep working.
  if (!tray && !isQuitting) app.quit();
});

app.on('before-quit', () => {
  isQuitting = true;
  saveWindowState(mainWindow);
});

app.on('web-contents-created', (_event, contents) => {
  // Never let page content navigate the app window away from Yapper.
  contents.on('will-navigate', (event, url) => {
    if (contents.getType() === 'window' && !isInternalUrl(url)) {
      event.preventDefault();
      openExternal(url);
    }
  });
});

app
  .whenReady()
  .then(() => {
    configureSession();
    buildMenu();
    createWindow();
    createTray();
  })
  .catch((err) => {
    console.error('[yapper] fatal startup error:', err);
    dialog.showErrorBox('Yapper failed to start', String(err?.stack || err));
    app.exit(1);
  });

process.on('uncaughtException', (err) => {
  console.error('[yapper] uncaught exception:', err);
});
