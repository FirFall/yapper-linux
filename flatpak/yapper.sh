#!/usr/bin/env bash
#
# Yapper Flatpak launcher.
#
# This is the entry point Flatpak runs (see `command: yapper` in the manifest).
# It sets up a writable temp dir, decides whether the session is Wayland or X11,
# and then hands off to zypak. zypak is what lets Chromium's sandbox work inside
# a Flatpak, where setuid helpers are not allowed.

set -euo pipefail

export FLATPAK_ID="${FLATPAK_ID:-io.github.FirFall.Yapper}"

# Electron and Chromium want a writable TMPDIR. Flatpak already gives us a
# private one under XDG_RUNTIME_DIR.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  export TMPDIR="${XDG_RUNTIME_DIR}/app/${FLATPAK_ID}"
  mkdir -p "${TMPDIR}"
else
  export TMPDIR="$(mktemp -d)"
fi

declare -a FLAGS=()

# Wayland session with no X display: opt into the native Wayland backend.
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ] && [ -z "${DISPLAY:-}" ]; then
  FLAGS+=(--ozone-platform=wayland)
  FLAGS+=(--enable-wayland-ime)
  FLAGS+=(--wayland-text-input-version=3)
elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
  FLAGS+=(--ozone-platform-hint=auto)
fi

# Escape hatch for users whose GPU driver misbehaves inside the sandbox:
#   flatpak override --user --env=YAPPER_DISABLE_GPU=1 io.github.FirFall.Yapper
if [ "${YAPPER_DISABLE_GPU:-0}" = "1" ]; then
  FLAGS+=(--disable-gpu)
fi

# Optional extra flags: ~/.var/app/<app-id>/config/yapper/flags.conf
FLAGS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/yapper/flags.conf"
if [ -s "${FLAGS_FILE}" ]; then
  while IFS= read -r line; do
    case "${line}" in
      '' | '#'*) continue ;;
    esac
    FLAGS+=("${line}")
  done < "${FLAGS_FILE}"
fi

exec zypak-wrapper /app/lib/yapper/yapper "${FLAGS[@]}" "$@"
