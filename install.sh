#!/usr/bin/env bash
#
# Yapper for Linux - universal installer.
#
# Detects your distribution and installs the best available package:
#
#   Debian / Ubuntu / Linux Mint / Pop!_OS   -> .deb
#   Fedora / RHEL / CentOS / openSUSE        -> .rpm
#   Arch / Manjaro / EndeavourOS             -> .pkg.tar.zst
#   anything else (or --flatpak)             -> .flatpak  (universal)
#   no package manager usable                -> AppImage in ~/.local/bin
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/FirFall/yapper-linux/main/install.sh | bash
#
# Options:
#   --flatpak     always use the universal Flatpak, even if a native package exists
#   --appimage    just drop the AppImage in ~/.local/bin, install nothing system-wide
#   --uninstall   remove a previous install
#   --help

set -euo pipefail

REPO="FirFall/yapper-linux"
APP_ID="io.github.FirFall.Yapper"
BIN_NAME="yapper"
DISPLAY_NAME="Yapper"

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  BOLD="$(printf '\033[1m')"; DIM="$(printf '\033[2m')"
  RED="$(printf '\033[1;31m')"; GREEN="$(printf '\033[1;32m')"
  BLUE="$(printf '\033[1;34m')"; YELLOW="$(printf '\033[1;33m')"; OFF="$(printf '\033[0m')"
else
  BOLD=""; DIM=""; RED=""; GREEN=""; BLUE=""; YELLOW=""; OFF=""
fi

say()  { printf '%s==>%s %s\n' "$BLUE" "$OFF" "$*"; }
ok()   { printf '%s ok %s %s\n' "$GREEN" "$OFF" "$*"; }
warn() { printf '%swarn%s %s\n' "$YELLOW" "$OFF" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

MODE="auto"
case "${1:-}" in
  --flatpak) MODE="flatpak" ;;
  --appimage) MODE="appimage" ;;
  --uninstall) MODE="uninstall" ;;
  --help | -h)
    cat <<'USAGE'
Yapper for Linux - universal installer.

  curl -fsSL https://raw.githubusercontent.com/FirFall/yapper-linux/main/install.sh | bash

Detects your distribution and installs the best available package:
  .deb        Debian, Ubuntu, Linux Mint, Pop!_OS, elementary, Zorin
  .rpm        Fedora, RHEL, CentOS, Rocky, AlmaLinux, openSUSE, Silverblue
  .pkg.tar.zst Arch, Manjaro, EndeavourOS, CachyOS
  .flatpak    universal fallback, works on every distribution
  AppImage    last resort, installed to ~/.local/bin with a menu entry

Options:
  --flatpak     always use the universal Flatpak
  --appimage    install only the AppImage into ~/.local/bin
  --uninstall   remove a previous install
  --help        show this message

Environment:
  GITHUB_TOKEN  optional, avoids GitHub API rate limits
USAGE
    exit 0
    ;;
  '') ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# sudo only when not already root and only if sudo exists
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo"
  elif have doas; then SUDO="doas"
  fi
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64 | amd64) ARCH="x86_64" ;;
  aarch64 | arm64) ARCH="aarch64" ;;
  *) die "unsupported CPU architecture: $ARCH" ;;
esac

# electron-builder labels x64/arm64 in the native packages
case "$ARCH" in
  x86_64) EB_ARCH="x64"; DEB_ARCH="amd64"; RPM_ARCH="x86_64"; FLATPAK_ARCH="x86_64" ;;
  aarch64) EB_ARCH="arm64"; DEB_ARCH="arm64"; RPM_ARCH="aarch64"; FLATPAK_ARCH="aarch64" ;;
esac

DISTRO_ID=""; DISTRO_LIKE=""; DISTRO_NAME=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-}"
  DISTRO_LIKE="${ID_LIKE:-}"
  DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
fi

say "Detected ${BOLD}${DISTRO_NAME:-unknown distribution}${OFF} (${ARCH})"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

TMP_DIR=""

cleanup() {
  [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fetch() {
  # fetch <url> <dest>
  if have curl; then
    curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
  elif have wget; then
    wget -q --tries=3 -O "$2" "$1"
  else
    die "neither curl nor wget is installed"
  fi
}

latest_release_json() {
  local url="https://api.github.com/repos/${REPO}/releases/latest"
  if have curl; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    wget -qO- "$url"
  fi
}

# asset_url <suffix-regex>
# Returns the browser_download_url of the first asset matching the suffix.
asset_url() {
  printf '%s' "$RELEASE_JSON" |
    grep -o '"browser_download_url": *"[^"]*"' |
    cut -d'"' -f4 |
    grep -E "$1" |
    head -n1
}

load_release() {
  if [ -n "${RELEASE_JSON:-}" ]; then return 0; fi
  say "Looking up the latest Yapper release..."
  RELEASE_JSON="$(latest_release_json || true)"

  if [ -z "$RELEASE_JSON" ] || ! printf '%s' "$RELEASE_JSON" | grep -q browser_download_url; then
    die "could not find any downloadable release for ${REPO}.
Check your internet connection, or build from source:
  https://github.com/${REPO}#building-from-source"
  fi

  VERSION="$(printf '%s' "$RELEASE_JSON" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | head -n1)"
  VERSION="${VERSION#v}"
  [ -n "$VERSION" ] || VERSION="latest"
  ok "Latest release: ${VERSION}"
}

download_asset() {
  # download_asset <regex> <outfile>
  local url
  url="$(asset_url "$1")"
  [ -n "$url" ] || return 1
  fetch "$url" "$2" || return 1
  [ -s "$2" ] || return 1
  return 0
}

# Verify against SHA256SUMS if the release publishes one. Best effort: a missing
# checksum file is not fatal, a mismatch is.
verify_checksum() {
  local file="$1" sums="$2"
  [ -f "$sums" ] || return 0
  local base expected actual
  base="$(basename "$file")"
  expected="$(grep -E "[ *]${base}\$" "$sums" | awk '{print $1}' | head -n1)"
  [ -n "$expected" ] || return 0

  if have sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  elif have shasum; then
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    warn "no sha256 tool available, skipping checksum verification"
    return 0
  fi

  if [ "$expected" != "$actual" ]; then
    die "checksum mismatch for $base
  expected $expected
  got      $actual"
  fi
  ok "Checksum verified"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

uninstall() {
  say "Removing ${DISPLAY_NAME}"

  if have flatpak && flatpak info --user "$APP_ID" >/dev/null 2>&1; then
    flatpak uninstall --user -y "$APP_ID"
    ok "Removed Flatpak"
  fi
  if have flatpak && flatpak info --system "$APP_ID" >/dev/null 2>&1; then
    $SUDO flatpak uninstall --system -y "$APP_ID"
    ok "Removed system Flatpak"
  fi

  if have dpkg && dpkg -s yapper >/dev/null 2>&1; then
    $SUDO apt-get remove -y yapper && ok "Removed .deb package"
  fi
  if have rpm && rpm -q yapper >/dev/null 2>&1; then
    $SUDO dnf remove -y yapper 2>/dev/null || $SUDO rpm -e yapper
    ok "Removed .rpm package"
  fi
  if have pacman && pacman -Q yapper >/dev/null 2>&1; then
    $SUDO pacman -R --noconfirm yapper && ok "Removed pacman package"
  fi

  rm -f "${HOME}/.local/bin/${BIN_NAME}" \
        "${HOME}/.local/share/applications/${BIN_NAME}.desktop" \
        "${HOME}/.local/share/icons/hicolor/512x512/apps/${BIN_NAME}.png"
  rm -rf "${HOME}/.local/share/yapper-appimage"

  # User data lives here; left alone on purpose.
  printf '\n%sYour settings are kept in %s/.config/%s%s\n' "$DIM" "$HOME" "$BIN_NAME" "$OFF"
  ok "Done"
}

# ---------------------------------------------------------------------------
# Installers
# ---------------------------------------------------------------------------

install_flatpak() {
  have flatpak || die "flatpak is not installed.
  Debian/Mint/Ubuntu: sudo apt install flatpak
  Fedora:             sudo dnf install flatpak
  Arch:               sudo pacman -S flatpak"

  load_release
  TMP_DIR="$(mktemp -d)"
  local bundle="${TMP_DIR}/${DISPLAY_NAME}-${VERSION}-${FLATPAK_ARCH}.flatpak"

  say "Downloading the universal Flatpak bundle"
  download_asset "\.flatpak$" "$bundle" || die "no Flatpak bundle in release ${VERSION} (arch ${FLATPAK_ARCH})."
  download_asset "SHA256SUMS" "${TMP_DIR}/SHA256SUMS" || true
  verify_checksum "$bundle" "${TMP_DIR}/SHA256SUMS"

  say "Installing (this also pulls in the Flatpak runtime the first time)"
  flatpak install --user -y --noninteractive "$bundle"

  ok "${DISPLAY_NAME} installed as a Flatpak"
  printf '\nRun it from your application menu, or:\n  flatpak run %s\n' "$APP_ID"
}

install_appimage() {
  load_release
  TMP_DIR="$(mktemp -d)"
  local appimage="${TMP_DIR}/${DISPLAY_NAME}-${VERSION}-${EB_ARCH}.AppImage"

  say "Downloading the AppImage"
  download_asset "\.AppImage$" "$appimage" || die "no AppImage in release ${VERSION} (arch ${EB_ARCH})."
  download_asset "SHA256SUMS" "${TMP_DIR}/SHA256SUMS" || true
  verify_checksum "$appimage" "${TMP_DIR}/SHA256SUMS"

  local dir="${HOME}/.local/share/yapper-appimage/bin"
  mkdir -p "$dir" "${HOME}/.local/bin" "${HOME}/.local/share/applications"
  mkdir -p "${HOME}/.local/share/icons/hicolor/512x512/apps"

  install -m 755 "$appimage" "${dir}/${DISPLAY_NAME}.AppImage"
  ln -sf "${dir}/${DISPLAY_NAME}.AppImage" "${HOME}/.local/bin/${BIN_NAME}"

  # Grab the icon from the AppImage itself (no FUSE needed for --appimage-extract),
  # falling back to the copy published in the repository.
  local icon="${HOME}/.local/share/icons/hicolor/512x512/apps/${BIN_NAME}.png"
  if (cd "$TMP_DIR" && "${dir}/${DISPLAY_NAME}.AppImage" --appimage-extract '*.png' >/dev/null 2>&1); then
    local extracted
    extracted="$(find "${TMP_DIR}/squashfs-root" -maxdepth 2 -name '*.png' -size +1k | head -n1 || true)"
    [ -n "$extracted" ] && cp -f "$extracted" "$icon" || true
  fi
  if [ ! -s "$icon" ]; then
    fetch "https://raw.githubusercontent.com/${REPO}/main/flatpak/icons/512x512/apps/${APP_ID}.png" "$icon" 2>/dev/null \
      || warn "could not fetch an icon; the app will still work"
  fi

  cat > "${HOME}/.local/share/applications/${BIN_NAME}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${DISPLAY_NAME}
GenericName=Chat Client
Comment=Unofficial Yapper client - chat, servers, voice and screen sharing
Exec=${HOME}/.local/bin/${BIN_NAME} %U
Icon=${BIN_NAME}
Terminal=false
Categories=Network;InstantMessaging;Chat;
Keywords=chat;voice;servers;yapper;
StartupNotify=true
EOF

  if have update-desktop-database; then
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi
  if have gtk-update-icon-cache; then
    gtk-update-icon-cache -q -t -f "${HOME}/.local/share/icons/hicolor" 2>/dev/null || true
  fi

  ok "${DISPLAY_NAME} installed to ${dir}"
  printf '\nRun it with:\n  %s\n' "$BIN_NAME"
  case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) warn "${HOME}/.local/bin is not on your PATH. Add it with:
  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc" ;;
  esac
}

install_deb() {
  load_release
  TMP_DIR="$(mktemp -d)"
  local deb="${TMP_DIR}/${DISPLAY_NAME}-${VERSION}-${DEB_ARCH}.deb"

  say "Downloading the .deb package"
  download_asset "\.deb$" "$deb" || die "no .deb in release ${VERSION} (arch ${DEB_ARCH})."
  download_asset "SHA256SUMS" "${TMP_DIR}/SHA256SUMS" || true
  verify_checksum "$deb" "${TMP_DIR}/SHA256SUMS"

  say "Installing with apt"
  if have apt-get; then
    $SUDO apt-get install -y "$deb"
  else
    $SUDO dpkg -i "$deb" || die "dpkg failed - you may need to run: sudo apt --fix-broken install"
  fi
  ok "${DISPLAY_NAME} installed"
}

install_rpm() {
  load_release
  TMP_DIR="$(mktemp -d)"
  local rpm="${TMP_DIR}/${DISPLAY_NAME}-${VERSION}-${RPM_ARCH}.rpm"

  say "Downloading the .rpm package"
  download_asset "\.rpm$" "$rpm" || die "no .rpm in release ${VERSION} (arch ${RPM_ARCH})."
  download_asset "SHA256SUMS" "${TMP_DIR}/SHA256SUMS" || true
  verify_checksum "$rpm" "${TMP_DIR}/SHA256SUMS"

  if have rpm-ostree; then
    # Fedora Silverblue / Kinoite and friends
    say "Installing with rpm-ostree"
    $SUDO rpm-ostree install "$rpm"
    warn "Reboot required to finish the rpm-ostree deployment."
  elif have dnf; then
    say "Installing with dnf"
    $SUDO dnf install -y "$rpm"
  elif have zypper; then
    say "Installing with zypper"
    $SUDO zypper --non-interactive install --allow-unsigned-rpm "$rpm"
  else
    say "Installing with rpm"
    $SUDO rpm -Uvh "$rpm"
  fi
  ok "${DISPLAY_NAME} installed"
}

install_pacman() {
  load_release
  TMP_DIR="$(mktemp -d)"
  local pkg="${TMP_DIR}/${DISPLAY_NAME}-${VERSION}-${EB_ARCH}.pkg.tar.zst"

  say "Downloading the pacman package"
  download_asset "\.pkg\.tar\.zst$" "$pkg" || die "no pacman package in release ${VERSION}."
  download_asset "SHA256SUMS" "${TMP_DIR}/SHA256SUMS" || true
  verify_checksum "$pkg" "${TMP_DIR}/SHA256SUMS"

  say "Installing with pacman"
  $SUDO pacman -U --noconfirm "$pkg"
  ok "${DISPLAY_NAME} installed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$MODE" = "uninstall" ]; then
  uninstall
  exit 0
fi

if [ "$MODE" = "flatpak" ]; then
  install_flatpak
  exit 0
fi

if [ "$MODE" = "appimage" ]; then
  install_appimage
  exit 0
fi

# Auto: prefer a native package for this distribution, then Flatpak, then
# a no-install AppImage.
case "${DISTRO_ID}:${DISTRO_LIKE}" in
  *arch* | *manjaro* | *endeavouros* | *cachyos* | *garuda*)
    if have pacman; then install_pacman; exit 0; fi
    ;;
esac

case "${DISTRO_ID}:${DISTRO_LIKE}" in
  *debian* | *ubuntu* | *linuxmint* | *pop* | *elementary* | *zorin* | *kali* | *raspbian* | *mx* | *neon*)
    if have apt-get; then install_deb; exit 0; fi
    ;;
esac

case "${DISTRO_ID}:${DISTRO_LIKE}" in
  *fedora* | *rhel* | *centos* | *rocky* | *almalinux* | *opensuse* | *suse* | *amzn*)
    if have rpm; then install_rpm; exit 0; fi
    ;;
esac

# Fallbacks for anything we did not recognise by name.
if have apt-get && have dpkg; then install_deb; exit 0; fi
if have pacman; then install_pacman; exit 0; fi
if have rpm; then install_rpm; exit 0; fi
if have flatpak; then
  warn "no matching native package for this distribution - using the universal Flatpak"
  install_flatpak
  exit 0
fi

warn "no supported package manager found - falling back to a no-install AppImage"
install_appimage
