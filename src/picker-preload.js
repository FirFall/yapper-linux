'use strict';

/**
 * Preload for the local screen-share chooser window.
 * Only two things are exposed: the list of capturable sources, and a pick call.
 */

const { contextBridge, ipcRenderer } = require('electron');

const PICK_SOURCE_CHANNEL = 'yapper:screen-source-picked';
const PICK_LIST_CHANNEL = 'yapper:screen-sources';

contextBridge.exposeInMainWorld('yapperPicker', {
  onSources(handler) {
    ipcRenderer.on(PICK_LIST_CHANNEL, (_event, sources) => handler(sources));
  },
  pick(id) {
    ipcRenderer.send(PICK_SOURCE_CHANNEL, id ?? null);
  },
});
