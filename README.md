<div align="center">

<img src="https://img.shields.io/badge/deceiver-Me-000000?style=for-the-badge&logo=apple&logoColor=white" alt="deceiverMe" height="40"/>

### Native macOS menu bar app for timed cursor movement, session management, system monitoring, and idle prevention.

<br/>

[![Release](https://img.shields.io/github/v/release/mimran-khan/deceiverme?include_prereleases&style=for-the-badge&logo=github&color=blue)](https://github.com/mimran-khan/deceiverme/releases/latest)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-11%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.x-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)

[![Stars](https://img.shields.io/github/stars/mimran-khan/deceiverme?style=for-the-badge&logo=github&label=Stars)](https://github.com/mimran-khan/deceiverme/stargazers)
[![Forks](https://img.shields.io/github/forks/mimran-khan/deceiverme?style=for-the-badge&logo=github&label=Forks)](https://github.com/mimran-khan/deceiverme/network/members)
[![Issues](https://img.shields.io/github/issues/mimran-khan/deceiverme?style=for-the-badge&logo=github&label=Issues)](https://github.com/mimran-khan/deceiverme/issues)
[![Downloads](https://img.shields.io/github/downloads/mimran-khan/deceiverme/total?style=for-the-badge&logo=github&label=Downloads)](https://github.com/mimran-khan/deceiverme/releases)

[![Watchers](https://img.shields.io/github/watchers/mimran-khan/deceiverme?style=social)](https://github.com/mimran-khan/deceiverme/watchers)
[![Repo Views](https://komarev.com/ghpvc/?username=mimran-khan&label=repo%20views&color=0e75b6&style=flat)](https://github.com/mimran-khan/deceiverme)

<br/>

[**Overview**](#overview) · [**Screenshots**](#screenshots) · [**Features**](#features) · [**Quick Start**](#quick-start) · [**Build**](#build-from-source) · [**Contributing**](#contributing) · [**License**](#license)

</div>

<br/>

## Screenshots

<p align="center">
  <img src="screenshots/dashboard.png" alt="Dashboard" width="420"/>
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src="screenshots/settings.png" alt="Settings" width="380"/>
</p>

<p align="center"><sub><b>Left:</b> Dashboard with live session stats &nbsp;|&nbsp; <b>Right:</b> Settings panel</sub></p>

<br/>

## Overview

deceiverMe moves the cursor on a configurable schedule — set the pixel step, direction, and interval. Use it for **demos**, **long-running sessions**, or **keeping the display and system from idling** on machines you own or are authorised to control.

> **Single-file, zero dependencies.** One Swift file + one `Info.plist`. Compiles to a universal binary (Intel + Apple Silicon) with ad-hoc codesign.

| | |
| :--- | :--- |
| **App** | `deceiverMe.app` |
| **Source** | [`MouseMoverNative.swift`](MouseMoverNative/MouseMoverNative.swift) + [`Info.plist`](packaging/Info.plist) |
| **Build** | `./build.sh` → universal binary, ad-hoc codesign, optional zip |
| **Repo** | [github.com/mimran-khan/deceiverme](https://github.com/mimran-khan/deceiverme) |
| **Author** | [mimran-khan](https://mimran-khan.github.io/) |

<p align="right">(<a href="#screenshots">back to top</a>)</p>

---

## Features

### Cursor Movement

- **Configurable step size** — pixels per move (default `5`)
- **Five directions** — right, left, up, down, or **circular**
- **Adjustable interval** — seconds between moves (default `10`)
- **Safe bounds** — cursor clamped to main display via CoreGraphics

### Session Modes

| Mode | Behaviour |
| :--- | :--- |
| **Run forever** | Runs until manually stopped |
| **Fixed duration** | Auto-stops after *N* hours of active time (paused time excluded) |
| **Stop at date & time** | Stops when system clock passes the chosen moment |

Quick-start presets from the menu: *Saved Settings*, *Run Forever*, *1 h*, *4 h*, *8 h*.

### Dashboard

Live control centre accessible from the menu bar:

- **Status badge** — `Idle` / `Running` / `Paused`
- **Session clock** — elapsed `HH:MM:SS`, time remaining, move count, progress bar
- **System monitor** — CPU/GPU temperature, CPU %, RAM, network throughput
- **Action buttons** — Start, Pause/Resume, Stop, Settings
- **Version tag** — current version at a glance

### Auto-Update

On every Dashboard open, the app queries the [GitHub Releases API](https://api.github.com/repos/mimran-khan/deceiverme/releases/latest):

- **New release detected** → a notification banner appears at the bottom
- **One-click update** → downloads the `.zip`, extracts, replaces the running app, and relaunches automatically
- **Up to date** → banner stays hidden
- **Fallback** → if the zip asset is missing, the button opens the release page instead

The check is a single background HTTPS GET — no telemetry, no data leaves your machine beyond the version query.

### System Monitor

Real-time telemetry in the Dashboard and menu bar:

| Metric | Source |
| :--- | :--- |
| CPU temperature | SMC (dynamic key discovery — Apple Silicon & Intel) |
| GPU temperature | SMC (dynamic key discovery) |
| CPU usage | `host_processor_info` |
| RAM usage | `host_statistics64` |
| Network throughput | `getifaddrs` (↓ / ↑) |

### Menu Bar

- **Dock-free** — runs as an `LSUIElement` agent; no Dock icon, no app-switcher entry
- **Close = hide** — closing the Dashboard hides the window; the app keeps running in the menu bar
- **Status icon** — concentric rings (template image)
- **Banner rotation** — live elapsed time, system stats
- **Start submenu** — presets (saved settings, run forever, 1 h / 4 h / 8 h)
- **Pause / Resume**, **Stop**
- **Dashboard** `⌘W` · **Settings** `⌘,` · **Quit** `⌘Q`

### Global Hotkey

Default **`⌘⇧Space`** — toggles start / pause. Customisable in Settings via **Record shortcut…**.

### URL Scheme

Scheme: `deceiverme://`

```bash
open "deceiverme://start"                  # start with saved settings
open "deceiverme://start?duration=1800"     # start, 30 min session
open "deceiverme://start?until=1700000000"  # start, stop at Unix epoch
open "deceiverme://stop"                    # stop
open "deceiverme://pause"                   # toggle pause
```

### Notifications

Session-end alerts via `UserNotifications` (banners on macOS 11+). Toggle in Settings.

<p align="right">(<a href="#screenshots">back to top</a>)</p>

---

## Quick Start

1. **Download** the latest `.zip` from [Releases](https://github.com/mimran-khan/deceiverme/releases/latest), or [build from source](#build-from-source).
2. **Move** `deceiverMe.app` to `/Applications`.
3. **Open** the app — the menu bar icon appears.
4. **Grant Accessibility** when prompted:
   `System Settings` → `Privacy & Security` → `Accessibility` → enable **deceiverMe**.
5. Open **Settings** → configure pixels, direction, interval, session mode → **Save**.
6. **Start** from the Dashboard, menu bar, hotkey, or URL scheme.

<p align="right">(<a href="#screenshots">back to top</a>)</p>

---

## Build from Source

### Prerequisites

- macOS 11+ with **Xcode Command Line Tools**

```bash
xcode-select --install
```

### Build

```bash
chmod +x build.sh   # first time only
./build.sh
```

The script compiles with `-O -whole-module-optimization`, builds a universal binary (Intel + Apple Silicon), ad-hoc codesigns, and produces a distributable zip.

### Output

```
deceiverMe.app/               ← repository root (gitignored)
dist/deceiverMe-macos.zip     ← distributable archive
```

### Build Options

| Variable | Effect |
| :--- | :--- |
| `BUILD_STYLE=native` | Single-arch for current CPU only |
| `SKIP_CODESIGN=1` | Skip codesigning |
| `SKIP_ZIP=1` | Skip zip creation |

```bash
BUILD_STYLE=native ./build.sh
SKIP_ZIP=1 ./build.sh
```

<p align="right">(<a href="#screenshots">back to top</a>)</p>

---

<details>
<summary><b>Reference</b> — internals, defaults, and repo layout</summary>

<br/>

### How It Runs

1. `NSApplication` + `NSStatusItem` + Dashboard `NSWindow`
2. `Timer` on `RunLoop.main` (`.common` mode) fires every `moveInterval` → `moveMouse()`
3. `AXIsProcessTrustedWithOptions` before first start
4. `shouldAutoStop` on tick → optional `stopMovement(notify:reason:)`
5. 1 Hz UI refresh for menu + Dashboard
6. SMC temperature polling via persistent IOKit connection with dynamic key discovery

### UserDefaults Keys

| Key | Purpose |
| :--- | :--- |
| `pixelMove` | Pixels per move |
| `direction` | `MovementDirection` raw value |
| `moveInterval` | Interval (seconds) |
| `totalDuration` | Duration (seconds) |
| `prefsSessionKind` | `0` forever / `1` fixed / `2` stop at |
| `sessionUntilEpoch` | Deadline (`timeIntervalSince1970`) |
| `notifyOnSessionEnd` | Bool |
| `preventIdleSleepWhileRunning` | Bool (default `true`) |
| `hotkeyKeyCode` | Carbon virtual key |
| `hotkeyCarbonModifiers` | Carbon modifiers bitmask |

### Repository Layout

```
.
├── LICENSE
├── README.md
├── AGENTS.md
├── build.sh
├── .gitignore
├── screenshots/
│   ├── dashboard.png
│   └── settings.png
├── packaging/
│   └── Info.plist
└── MouseMoverNative/
    └── MouseMoverNative.swift
```

</details>

---

## Permissions

| Permission | Required | How to enable |
| :--- | :--- | :--- |
| **Accessibility** | Yes | `System Settings` → `Privacy & Security` → `Accessibility` → enable **deceiverMe** |
| **Notifications** | Optional | Allow when prompted for session-end alerts |

Restart the app after changing permissions.

---

## Troubleshooting

<details>
<summary>Click to expand</summary>

<br/>

| Issue | Fix |
| :--- | :--- |
| Build fails at `swiftc` | Install CLT; check Swift errors in terminal |
| `codesign` fails | Read the error; or `SKIP_CODESIGN=1 ./build.sh` |
| Zip missing | Ensure `SKIP_ZIP` is not set; check `dist/` is writable |
| App won't open | Right-click → Open; review Gatekeeper / quarantine |
| Cursor never moves | Accessibility off → add app and restart |
| Hotkey not working | Pick another combo in **Record shortcut…** |
| Can't save settings | Stop the running session first |
| Screen still locks | Enable **Keep display & system awake** in Settings; confirm session is active (not paused). MDM policies can override. |
| Temperatures show `—` | SMC access requires running without sandboxing; ad-hoc signed builds work on personal machines. v1.3.0+ uses dynamic key discovery to support all Apple Silicon generations (M1–M4). |

</details>

---

## Security & Privacy

- **No telemetry** — the only outbound request is the GitHub Releases API update check.
- Cursor control and idle-sleep assertions are sensitive in managed environments — follow your org's policy.
- Ad-hoc signing is fine for personal builds; wide distribution needs **Developer ID** + **notarization**.

---

## Contributing

Contributions, issues, and feature requests are welcome.

1. Fork the repo
2. Create your branch (`git checkout -b feature/amazing-feature`)
3. Make changes and ensure `./build.sh` passes
4. Commit (`git commit -m 'feat: add amazing feature'`)
5. Push (`git push origin feature/amazing-feature`)
6. Open a Pull Request

See [Issues](https://github.com/mimran-khan/deceiverme/issues) for known bugs and planned features.

---

## License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for details.

---

<div align="center">

**[deceiverMe](https://github.com/mimran-khan/deceiverme)** is built and maintained by [mimran-khan](https://mimran-khan.github.io/)

If you find this useful, consider giving a ⭐

</div>
