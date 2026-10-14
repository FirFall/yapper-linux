#!/usr/bin/env bash
#
# Yapper - universal Flatpak bundle builder.
#
# Produces: dist/Yapper-<version>-<arch>.flatpak
#
# The result is a single self-contained bundle. Anyone can install it with:
#   flatpak install ./Yapper-1.0.0-x86_64.flatpak
# on any distribution that has Flatpak (Linux Mint, Debian, Ubuntu, Fedora,
# Arch, openSUSE, ...). No distro-specific packaging involved.
#
# Requirements:
#   - flatpak and flatpak-builder
#   - node + npm (for building the AppImage it wraps)
#
# Usage:
#   ./scripts/build-flatpak.sh [--arch x86_64|aarch64]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_ID="io.github.FirFall.Yapper"
MANIFEST="flatpak/${APP_ID}.yml"
BUILD_DIR="build-flatpak"
REPO_DIR="dist/flatpak-repo"
VERSION="$(node -p "require('./package.json').version" 2>/dev/null || echo 1.0.0)"

ARCH="$(uname -m)"
if [ "${1:-}" = "--arch" ] && [ -n "${2:-}" ]; then
  ARCH="$2"
fi

if [ "$ARCH" = "amd64" ]; then ARCH="x86_64"; fi
if [ "$ARCH" = "arm64" ]; then ARCH="aarch64"; fi

# electron-builder calls the architectures x64 and arm64.
case "$ARCH" in
  x86_64) EB_ARCH="x64" ;;
  aarch64) EB_ARCH="arm64" ;;
  *) EB_ARCH="$ARCH" ;;
esac

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v flatpak >/dev/null 2>&1 || die "flatpak is not installed.
  Debian/Mint/Ubuntu: sudo apt install flatpak flatpak-builder
  Fedora:             sudo dnf install flatpak flatpak-builder
  Arch:               sudo pacman -S flatpak flatpak-builder"

command -v flatpak-builder >/dev/null 2>&1 || die "flatpak-builder is not installed (see above)."
command -v node >/dev/null 2>&1 || die "node is not installed - it is needed to build the AppImage."

# ---------------------------------------------------------------------------
# 1. Build the AppImage that the Flatpak wraps
# ---------------------------------------------------------------------------

APPIMAGE="$(find dist -name 'Yapper-*.AppImage' -not -path '*/__*' 2>/dev/null | head -n1 || true)"

if [ "${SKIP_APPIMAGE:-0}" = "1" ]; then
  if [ -n "$APPIMAGE" ] && [ -f "$APPIMAGE" ]; then
    log "Reusing existing $APPIMAGE"
  else
    die "SKIP_APPIMAGE=1 but no AppImage found in dist/. Did the previous build step produce it?"
  fi
else
  log "Building the AppImage (npm run dist)"
  if [ ! -d node_modules ]; then
    npm install --no-audit --no-fund
  fi
  npx electron-builder --linux AppImage --"$EB_ARCH" --publish never
  APPIMAGE="$(find dist -name 'Yapper-*.AppImage' -not -path '*/__*' 2>/dev/null | head -n1 || true)"
fi

[ -n "$APPIMAGE" ] || die "no AppImage was produced in dist/."

log "Using $APPIMAGE"

# ---------------------------------------------------------------------------
# 2. Stage it next to the manifest (the manifest references it as a local file)
# ---------------------------------------------------------------------------

cp -f "$APPIMAGE" flatpak/yapper.AppImage

# ---------------------------------------------------------------------------
# 3. Make sure the runtime and base app are available
# ---------------------------------------------------------------------------

RUNTIME_VERSION="$(grep -E "^runtime-version:" "$MANIFEST" | head -n1 | cut -d"'" -f2)"
BASE_VERSION="$(grep -E "^base-version:" "$MANIFEST" | head -n1 | cut -d"'" -f2)"

log "Ensuring Flathub runtimes for $RUNTIME_VERSION are installed"
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y --noninteractive flathub \
  "org.freedesktop.Platform//${RUNTIME_VERSION}" \
  "org.freedesktop.Sdk//${RUNTIME_VERSION}" \
  "org.electronjs.Electron2.BaseApp//${BASE_VERSION}"

# ---------------------------------------------------------------------------
# 4. Build the Flatpak into a local OSTree repo
# ---------------------------------------------------------------------------

log "Building the Flatpak"
rm -rf "$BUILD_DIR" "$REPO_DIR"
mkdir -p "$REPO_DIR"

flatpak-builder \
  --user \
  --force-clean \
  --repo="$REPO_DIR" \
  --arch="$ARCH" \
  --default-branch=stable \
  ${DISABLE_ROFILES_FUSE:+--disable-rofiles-fuse} \
  "$BUILD_DIR" \
  "$MANIFEST"

# ---------------------------------------------------------------------------
# 5. Export a single-file .flatpak bundle
# ---------------------------------------------------------------------------

OUT="dist/Yapper-${VERSION}-${ARCH}.flatpak"
log "Exporting $OUT"

flatpak build-bundle \
  --arch="$ARCH" \
  "$REPO_DIR" \
  "$OUT" \
  "$APP_ID" \
  stable

rm -f flatpak/yapper.AppImage

log "Done: $OUT"
printf '\nInstall it with:\n  flatpak install --user %s\n\n' "$OUT"
printf 'Then run it from your app menu, or with:\n  flatpak run %s\n' "$APP_ID"
