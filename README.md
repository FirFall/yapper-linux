# Yapper for Linux

An **unofficial** desktop client for [Yapper](https://www.yapper.website/) — chat,
servers, voice and screen sharing — packaged properly for Linux.

Works on **Linux Mint, Ubuntu, Debian, Fedora, Arch, Manjaro, openSUSE, Pop!\_OS,
elementary, Zorin, Silverblue** and anything else, in three ways:

| Format               | Works on                                        | Install                              |
| -------------------- | ----------------------------------------------- | ------------------------------------ |
| **`.flatpak`**       | everything (universal, sandboxed)               | `flatpak install ./Yapper-*.flatpak` |
| **`.deb`**           | Debian, Ubuntu, Linux Mint, Pop!\_OS, Zorin     | `sudo apt install ./Yapper-*.deb`    |
| **`.rpm`**           | Fedora, RHEL, Rocky, AlmaLinux, openSUSE        | `sudo dnf install ./Yapper-*.rpm`    |
| **`.pkg.tar.zst`**   | Arch, Manjaro, EndeavourOS, CachyOS             | `sudo pacman -U ./Yapper-*.pkg.tar.zst` |
| **`.AppImage`**      | everything (no installation at all)             | `chmod +x` and run it                |

> **Not official.** This is a community wrapper around the Yapper web app.
> It is not affiliated with or endorsed by Yapper.

---

## Install

### The easy way (any distribution)

This detects your distro and installs the best package for it:

```bash
curl -fsSL https://raw.githubusercontent.com/FirFall/yapper-linux/main/install.sh | bash
```

Useful options:

```bash
# always use the universal Flatpak, even if you have a native package manager
curl -fsSL https://raw.githubusercontent.com/FirFall/yapper-linux/main/install.sh | bash -s -- --flatpak

# install only the AppImage into ~/.local/bin (nothing system-wide)
curl -fsSL https://raw.githubusercontent.com/FirFall/yapper-linux/main/install.sh | bash -s -- --appimage

# remove it again
curl -fsSL https://raw.githubusercontent.com/FirFall/yapper-linux/main/install.sh | bash -s -- --uninstall
```

### The universal way (Flatpak)

One file works on every distribution. [Download the latest `.flatpak`
bundle](https://github.com/FirFall/yapper-linux/releases/latest), then:

```bash
flatpak install --user ./Yapper-*.flatpak
flatpak run io.github.FirFall.Yapper
```

If you don't have Flatpak yet:

```bash
# Debian / Ubuntu / Linux Mint
sudo apt install flatpak

# Fedora
sudo dnf install flatpak

# Arch / Manjaro
sudo pacman -S flatpak
```

Flatpak will offer to install the runtime it needs the first time. It is about
400 MB, once, shared with any other Flatpak you use.

### Debian, Ubuntu and Linux Mint

```bash
sudo apt install ./Yapper-*.deb
```

### Fedora, RHEL, openSUSE

```bash
sudo dnf install ./Yapper-*.rpm          # Fedora / RHEL
sudo zypper install ./Yapper-*.rpm       # openSUSE

# Fedora Silverblue / Kinoite (immutable)
sudo rpm-ostree install ./Yapper-*.rpm   # then reboot
```

### Arch, Manjaro, EndeavourOS

```bash
sudo pacman -U ./Yapper-*.pkg.tar.zst
```

### AppImage (no installation)

```bash
chmod +x ./Yapper-*.AppImage
./Yapper-*.AppImage
```

---

## What you get over a browser tab

- **Its own window and taskbar entry**, with a tray icon.
- **Stays signed in.** Cookies and the login token persist between restarts.
- **Screen sharing that actually works.** Uses the system picker
  (XDG desktop portal / PipeWire), on Wayland *and* X11.
- **Voice and video.** Microphone and camera permissions are handled in-app,
  and the app identifies itself as Chrome so the site offers WebRTC.
- **Desktop notifications** for messages.
- **Works inside the Flatpak sandbox**, including the Chromium sandbox
  (that is what the `zypak` integration is for).
- Single instance — launching it again just focuses the existing window.

### Keyboard shortcuts

| Shortcut         | Action                   |
| ---------------- | ------------------------ |
| `Ctrl` + `N`     | New window               |
| `Ctrl` + `R`     | Reload                   |
| `Ctrl` + `Q`     | Quit                     |
| `Ctrl` + `+` / `-` | Zoom in / out          |
| `F11`            | Full screen              |
| `Ctrl` + `Shift` + `I` | Developer tools   |

Closing the window keeps Yapper running in the tray so notifications keep
arriving. Use **File → Quit**, or the tray menu, to exit completely.

---

## Troubleshooting

**Blank window or graphics glitches**

Turn off hardware acceleration:

```bash
echo "no-gpu" >> ~/.config/yapper/flags.conf
```

For Flatpak the config lives at
`~/.var/app/io.github.FirFall.Yapper/config/yapper/flags.conf`, or you can do:

```bash
flatpak override --user --env=YAPPER_DISABLE_GPU=1 io.github.FirFall.Yapper
```

**It refuses to start: "The SUID sandbox helper binary was found, but is not configured correctly"**

Chromium's sandbox needs either a root-owned setuid `chrome-sandbox` helper or
unprivileged user namespaces. VMs, containers and hardened kernels often have
neither — Ubuntu 24.04+ blocks unprivileged user namespaces with AppArmor, and
an AppImage can never ship a setuid helper — in which case Chromium aborts
instead of degrading. The app detects this and falls back automatically. Force
it yourself with:

```bash
YAPPER_NO_SANDBOX=1 yapper
# or, inside the sandbox:
flatpak override --user --env=YAPPER_NO_SANDBOX=1 io.github.FirFall.Yapper
```

**The window is blank, or it dies with a SIGBUS/SIGSEGV on start**

`/dev/shm` is too small — 64 MB is the default in containers and in many VMs.
The app switches Chromium's shared memory to `/tmp` automatically when `/dev/shm`
is under 128 MB, but you can force it:

```bash
echo "disable-dev-shm-usage" >> ~/.config/yapper/flags.conf
```

**Running inside a VM and getting artefacts, tearing or very slow repaints**

The VM has no 3D acceleration, so software rendering is the sane option:

```bash
echo "no-gpu" >> ~/.config/yapper/flags.conf
```

**Screen sharing shows the whole screen instead of a window**

Make sure `xdg-desktop-portal` and a backend for your desktop are installed:

```bash
# GNOME
sudo apt install xdg-desktop-portal-gnome
# KDE
sudo apt install xdg-desktop-portal-kde
# wlroots (Sway, Hyprland)
sudo apt install xdg-desktop-portal-wlr
```

**No tray icon**

GNOME removed the tray. Install the AppIndicator extension:

```bash
sudo apt install gnome-shell-extension-appindicator
```

**Notifications don't show**

Check that notifications are allowed for Yapper in your system settings. Under
Flatpak the app needs the notification portal, which is installed by default.

**I want to sign out**

**File → Sign Out & Clear Data…** removes cookies, cache and the saved login.

---

## Building from source

You need Node.js 18+.

```bash
git clone https://github.com/FirFall/yapper-linux.git
cd yapper-linux
npm install
npm start          # run it straight from source
```

### Native packages

Build on Linux (or in Docker — see below):

```bash
./scripts/build-linux.sh          # AppImage, .deb, .rpm, pacman, tar.gz
```

The `.pkg.tar.zst` (Arch) target needs `bsdtar`:

```bash
sudo apt install libarchive-tools   # Debian
sudo dnf install bsdtar             # Fedora
sudo pacman -S libarchive           # Arch
```

Building on Windows or macOS? Use the electron-builder container:

```bash
docker run --rm -it -v "$PWD:/project" -w /project \
  electronuserland/builder:24 \
  bash -c "npm install && npx electron-builder --linux AppImage deb rpm tar.gz"
```

### The universal Flatpak bundle

```bash
sudo apt install flatpak flatpak-builder    # or your distro's equivalent
./scripts/build-flatpak.sh
```

That builds the AppImage, then wraps it in a Flatpak and writes
`dist/Yapper-<version>-x86_64.flatpak`.

### Icons

The icon is generated from `build/icon.svg` (`sharp` is a devDependency, so a
normal `npm install` is enough):

```bash
npm run icons
```

### Releases

Pushing a tag builds every format on GitHub Actions and publishes them to a
GitHub Release:

```bash
git tag v1.0.1
git push origin v1.0.1
```

---

## How it works

```
src/main.js             Electron main process: window, tray, menus, permissions,
                        screen sharing, session persistence
src/preload.js          Tiny, isolated bridge exposed to the web page
src/picker.html         Local "choose what to share" window, used when no
                        desktop portal is available
flatpak/                Flatpak manifest, launcher, .desktop and AppStream
                        metadata. Wraps the AppImage built by electron-builder.
electron-builder.yml    deb / rpm / pacman / AppImage / tar.gz configuration
install.sh              Distro-detecting one-line installer
```

The Flatpak uses `org.electronjs.Electron2.BaseApp`, which supplies `zypak` so
Chromium's sandbox works inside the sandbox, plus `libsecret` and
`libappindicator`. The Electron runtime itself ships inside the AppImage that
gets wrapped, so the app version and the Electron version stay in lockstep.

---

## Contributing

Issues and pull requests are welcome at
[FirFall/yapper-linux](https://github.com/FirFall/yapper-linux/issues).

Please don't report problems with this Linux app to the Yapper team — they
didn't make it.

## License

MIT — see [LICENSE](LICENSE). "Yapper" and the Yapper logo belong to their
respective owners and are used only to describe what this client connects to.
