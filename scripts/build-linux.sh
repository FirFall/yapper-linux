#!/usr/bin/env bash
#
# Yapper - build every native Linux package format in one go.
#
# Output (in dist/):
#   Yapper-<version>-x64.AppImage            universal, no installation
#   Yapper-<version>-amd64.deb               Debian, Ubuntu, Linux Mint, Pop!_OS
#   Yapper-<version>-x86_64.rpm              Fedora, RHEL, openSUSE
#   Yapper-<version>-x64.pkg.tar.zst         Arch, Manjaro, EndeavourOS
#   Yapper-<version>-x64.tar.gz              portable tarball
#
# Run this on a Linux machine (or in the electronuserland/builder container).
# On Windows/macOS use Docker instead - see the README.
#
# Usage:
#   ./scripts/build-linux.sh                    # build for this machine's arch
#   ./scripts/build-linux.sh --x64              # force x64
#   ./scripts/build-linux.sh --arm64            # force arm64

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

ARCH_FLAGS=()
case "${1:-}" in
  --x64) ARCH_FLAGS=(--x64) ;;
  --arm64) ARCH_FLAGS=(--arm64) ;;
  '') ;;
  *) die "unknown option: $1" ;;
esac

if [ "$(uname -s)" != "Linux" ]; then
  die "Linux packages must be built on Linux.
Easiest cross-platform route: Docker
  docker run --rm -it -v \"\$(pwd):/project\" -w /project electronuserland/builder:24 \\
    bash -c \"npm install && npx electron-builder --linux\""
fi

command -v node >/dev/null 2>&1 || die "node is not installed."
command -v npm >/dev/null 2>&1 || die "npm is not installed."

# ---------------------------------------------------------------------------
# Extra host tools the individual targets need
# ---------------------------------------------------------------------------

# The pacman (Arch) target shells out to bsdtar.
if ! command -v bsdtar >/dev/null 2>&1; then
  printf '\033[1;33mwarning:\033[0m bsdtar not found - the .pkg.tar.zst (Arch) target will be skipped.\n'
  printf '         Debian/Ubuntu/Mint: sudo apt install libarchive-tools\n'
  printf '         Fedora:             sudo dnf install bsdtar\n'
  printf '         Arch:               sudo pacman -S libarchive\n'
fi

# AppImage needs FUSE only to *run*; electron-builder can still build it.
log "Installing dependencies"
if [ ! -d node_modules ]; then
  npm install --no-audit --no-fund
fi

# Make sure the icons exist (they are committed, but this keeps them fresh
# if the source SVG was changed).
log "Generating icons"
npm run --silent icons || true

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

TARGETS=()
TARGETS+=(AppImage)
TARGETS+=(deb)
TARGETS+=(rpm)
TARGETS+=(tar.gz)

if command -v bsdtar >/dev/null 2>&1; then
  TARGETS+=(pacman)
fi

log "Building: ${TARGETS[*]}"
mkdir -p dist

npx electron-builder --linux "${TARGETS[@]}" "${ARCH_FLAGS[@]}" --publish never

log "Artifacts"
ls -lh dist/*.AppImage dist/*.deb dist/*.rpm dist/*.pkg.tar.zst dist/*.tar.gz 2>/dev/null || true

cat <<'EOF'

Install them with:

  Debian / Ubuntu / Linux Mint
    sudo apt install ./dist/Yapper-<version>-amd64.deb

  Fedora / RHEL / openSUSE
    sudo dnf install ./dist/Yapper-<version>-x86_64.rpm

  Arch / Manjaro / EndeavourOS
    sudo pacman -U ./dist/Yapper-<version>-x64.pkg.tar.zst

  Any distribution, no installation
    chmod +x ./dist/Yapper-<version>-x64.AppImage && ./dist/Yapper-<version>-x64.AppImage

For the universal Flatpak bundle:
  ./scripts/build-flatpak.sh
EOF
