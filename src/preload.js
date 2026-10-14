'use strict';

/**
 * Preload for the main Yapper window.
 *
 * Runs in an isolated world, so nothing here can be reached from the page's
 * own JavaScript unless it is explicitly put on the context bridge.
 *
 * Keep this deliberately tiny: the goal is to look like a normal browser,
 * with just enough desktop awareness for the site to behave well.
 */

const { contextBridge } = require('electron');

const info = Object.freeze({
  platform: process.platform,
  isDesktopApp: true,
  isFlatpak: Boolean(process.env.FLATPAK_ID),
  version: process.env.npm_package_version || '1.0.0',
});

try {
  contextBridge.exposeInMainWorld('yapperDesktop', info);
} catch {
  // contextIsolation disabled - the flag below still applies.
}

// Announce the desktop shell in the DOM so the site (or user CSS) can adapt.
// Wrapped in a try/catch because document may not exist yet at preload time.
window.addEventListener('DOMContentLoaded', () => {
  try {
    document.documentElement.dataset.yapperDesktop = 'linux';
    if (info.isFlatpak) document.documentElement.dataset.yapperFlatpak = 'true';
  } catch {
    /* ignore */
  }
});
