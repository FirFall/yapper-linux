#!/usr/bin/env node
/**
 * Rasterises build/icon.svg into the PNG sizes Electron and the Linux
 * packaging formats expect.
 *
 *   build/icon.png                     512x512 master (electron-builder)
 *   build/icons/<size>x<size>.png      flat set for electron-builder
 *   build/hicolor/<size>x<size>/apps/  hicolor layout
 *   flatpak/icons/<size>x<size>/apps/  named for the Flatpak app id
 *
 * Usage: npm run icons
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SVG = path.join(ROOT, 'build', 'icon.svg');
const ICONS_DIR = path.join(ROOT, 'build', 'icons');
const HICOLOR_DIR = path.join(ROOT, 'build', 'hicolor');
const FLATPAK_ICONS_DIR = path.join(ROOT, 'flatpak', 'icons');
const APP_ID = 'io.github.FirFall.Yapper';

// Sizes a Linux desktop wants. 512 is the AppStream/Flathub maximum.
const SIZES = [16, 24, 32, 48, 64, 128, 256, 512];

async function main() {
  if (!fs.existsSync(SVG)) {
    console.error(`Missing source icon: ${SVG}`);
    process.exit(1);
  }

  let sharp;
  try {
    sharp = require('sharp');
  } catch {
    console.error('This script needs "sharp". Install it with:\n  npm install --no-save sharp\n');
    process.exit(1);
  }

  const svg = fs.readFileSync(SVG);
  fs.mkdirSync(ICONS_DIR, { recursive: true });

  for (const size of SIZES) {
    const png = await sharp(svg, { density: 384 })
      .resize(size, size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .png({ compressionLevel: 9 })
      .toBuffer();

    const flat = path.join(ICONS_DIR, `${size}x${size}.png`);
    fs.writeFileSync(flat, png);

    const hicolor = path.join(HICOLOR_DIR, `${size}x${size}`, 'apps');
    fs.mkdirSync(hicolor, { recursive: true });
    fs.writeFileSync(path.join(hicolor, `${size}x${size}.png`), png);

    // Flatpak sources are referenced by explicit filename in the manifest.
    const flatpak = path.join(FLATPAK_ICONS_DIR, `${size}x${size}`, 'apps');
    fs.mkdirSync(flatpak, { recursive: true });
    fs.writeFileSync(path.join(flatpak, `${APP_ID}.png`), png);

    console.log(`wrote ${path.relative(ROOT, flat)}`);
  }

  const master = await sharp(svg, { density: 384 }).resize(512, 512).png().toBuffer();
  fs.writeFileSync(path.join(ROOT, 'build', 'icon.png'), master);
  console.log('wrote build/icon.png');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
