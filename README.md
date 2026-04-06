<div align="center">

# deceiverMe

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-11%2B-000000?logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.x-F05138?logo=swift&logoColor=white)](https://swift.org)

**Native macOS menu bar app — timed cursor drift, sessions, and optional display + system idle prevention.**

[Overview](#overview) · [Features](#features) · [User guide](#user-guide) · [Build](#build) · [Reference](#reference) · [Troubleshooting](#troubleshooting)

<br/>

</div>

## Overview

deceiverMe nudges the cursor on a schedule (pixels, direction, interval). Use it for **demos**, **long sessions**, or **keeping the display and system from idling** (power option; on by default) — only on **machines you own or are allowed to control**.

| | |
| :--- | :--- |
| **Bundle** | `deceiverMe.app` |
| **Executable** | `MouseMoverNative` |
| **Bundle ID** | `com.deceiverme.app` |
| **Source** | Single Swift file + `packaging/Info.plist` |
| **Build** | `./build.sh` → universal binary, ad-hoc codesign, optional zip |

---

## Features

### Cursor drift

- **Stride** — pixels per move (default `5`)
- **Bearing** — right, left, up, down, or **Orbit** (small circular step)
- **Cadence** — seconds between moves (default `10`)
- Uses **CoreGraphics** (`CGEvent` / `.cghidEventTap`); cursor is clamped inside the **main display** with a margin

### Sessions and timing

| Mode | Behavior |
| :--- | :--- |
| **Open end** | Runs until you stop |
| **Timed arc** | Stops after **N hours** of **active** time (paused time does not count) |
| **Land at date & time** | Stops when the system clock passes the chosen moment |

**Menu presets** (one-shot; override saved defaults): saved recipe, open horizon, 1 h / 4 h / 8 h arcs.

### Studio window

Title: **Studio — deceiverMe**. Main areas:

| Element | Description |
| :--- | :--- |
| Badge | `IDLE` / `LIVE` / `HOLD` |
| Hero clock | Session elapsed `HH:MM:SS` |
| Horizon | Time left, `∞` if open-ended |
| Ticks | Move count |
| Carry-through | Progress bar (or indeterminate if no end) |
| Buttons | **Begin**, **Hold** / **Continue**, **Finish**, **Tune drift…** |

**Begin** is only enabled when fully idle.

### Menu bar

- **Icon** — concentric rings (template)
- **Live** — may show elapsed; **hold** shows `· hold` next to time
- **Begin drift** — submenu with presets
- **Hold** / **Continue**, **Finish drift**
- **Open studio** — `⌘W`
- **Tune drift…** — `⌘,`
- **Quit** — `⌘Q`

### Preferences

**Tune drift — deceiverMe** · section **Motion recipe**

| Control | Purpose |
| :--- | :--- |
| Stride, Bearing, Cadence | Movement |
| Default horizon | Open end / timed arc / land at |
| Arc length (hours) | For timed arc |
| Land at | Date-time picker |
| Ping when this drift lands | End notification |
| Keep display & system awake while drifting | `ProcessInfo.beginActivity` with **idle display + system sleep disabled** while running and not paused |
| Global shortcut | Display + **Record shortcut…** |
| Save recipe / Close | Persist or dismiss |

Saving is **blocked while a session is running** (alert).

### Global hotkey

Carbon **RegisterEventHotKey**. Default **`⌘⇧Space`**: idle → start with saved recipe; running → pause toggle.

### Notifications

**UserNotifications**: title `Drift landed`, subtitle `deceiverMe`, body = reason. Banners on macOS 11+.

### URL scheme

Scheme: **`deceiverme`**

| URL | Action |
| :--- | :--- |
| `deceiverme://start` | Start (saved recipe) |
| `deceiverme://start?duration=3600` | Start, 3600 s arc |
| `deceiverme://start?until=<unix>` | Start, deadline = Unix epoch seconds |
| `deceiverme://stop` | Stop |
| `deceiverme://pause` or `toggle` | Start if idle else pause toggle |

```bash
open "deceiverme://start?duration=1800"
open "deceiverme://stop"
```

---

## User guide

1. **Build or install** `deceiverMe.app` (see [Build](#build)).
2. **Open** the app — menu bar icon appears; studio window can stay open.
3. **Grant Accessibility** when prompted (System Settings → Privacy & Security → Accessibility).
4. Set **Tune drift…** (stride, bearing, cadence, horizon, options) → **Save recipe**.
5. **Begin** from the studio or **Begin drift** in the menu (or hotkey / URL).
6. Use **Hold** / **Continue** and **Finish** as needed.

---

## Build

### Requirements

- macOS with **Xcode Command Line Tools**  
  `xcode-select --install`

### Command

```bash
chmod +x build.sh   # first time only
./build.sh
```

The script:

1. Validates `MouseMoverNative/MouseMoverNative.swift` and `packaging/Info.plist`
2. Copies `Info.plist`, writes `PkgInfo`
3. Compiles with **`-O -whole-module-optimization`** for both slices (universal) or one arch (native)
4. Runs **`lipo`** when building universal (Intel + Apple Silicon, macOS 11+)
5. Ensures the executable exists and is non-empty
6. **`codesign --force --deep --sign -`** and **`codesign --verify`** (unless skipped)
7. Creates **`dist/deceiverMe-macos.zip`** with **`ditto`** (unless skipped)

### Outputs

```
deceiverMe.app/          ← at repository root (gitignored)
dist/deceiverMe-macos.zip
```

### Environment variables

| Variable | Effect |
| :--- | :--- |
| `BUILD_STYLE=native` | Single-arch for current CPU only |
| `SKIP_CODESIGN=1` | No codesign |
| `SKIP_ZIP=1` | No zip |

```bash
BUILD_STYLE=native ./build.sh
SKIP_ZIP=1 ./build.sh
```

**Native plist minimum:** `x86_64` → 10.13, `arm64` → 11.0 (script patches `LSMinimumSystemVersion`).

> `deceiverMe.app/` and `dist/` are listed in `.gitignore`.

---

## Reference

### How it runs (technical)

1. `NSApplication` + `NSStatusItem` + studio `NSWindow`
2. `Timer` every `moveInterval` → `moveMouse()`
3. `AXIsProcessTrustedWithOptions` before first start
4. `shouldAutoStop` on tick → optional `stopMovement(notify:reason:)`
5. 1 Hz UI refresh for menu + studio

### UserDefaults keys

| Key | Meaning |
| :--- | :--- |
| `pixelMove` | Stride (points) |
| `direction` | `MovementDirection` raw value |
| `moveInterval` | Cadence (seconds) |
| `totalDuration` | Arc length (seconds) |
| `prefsSessionKind` | `0` open / `1` timed / `2` until |
| `sessionUntilEpoch` | Deadline (`timeIntervalSince1970`) |
| `notifyOnSessionEnd` | Bool (default true if missing) |
| `preventIdleSleepWhileRunning` | Bool (default **true** if key missing) |
| `hotkeyKeyCode` | Carbon virtual key |
| `hotkeyCarbonModifiers` | Carbon modifiers bitmask |

### Repository layout

```
.
├── LICENSE
├── README.md
├── build.sh
├── packaging/
│   └── Info.plist
└── MouseMoverNative/
    └── MouseMoverNative.swift
```

---

## Permissions

**Accessibility** — required for cursor control.

`System Settings` → `Privacy & Security` → `Accessibility` → enable **deceiverMe** (or **MouseMoverNative** if listed).

Restart the app after changes.

**Notifications** — optional; allow if you use “Ping when this drift lands”.

---

## Troubleshooting

| Issue | What to do |
| :--- | :--- |
| Build fails at **swiftc** | Install CLT; check Swift errors in the terminal |
| **codesign** fails | Read the printed error; or `SKIP_CODESIGN=1 ./build.sh` for local-only |
| Zip missing | Ensure `SKIP_ZIP` is not set; check `dist/` is writable |
| App won’t open | Right-click → Open; review Gatekeeper / quarantine |
| Cursor never moves | Accessibility off → add app and restart |
| Hotkey dead | Pick another combo in **Record shortcut…** |
| Can’t save preferences | Stop the session first |
| Screen still locks | Leave **Keep display & system awake** on in **Tune drift**; confirm a **live** session (not Hold). **MDM** or **Lock Screen after …** policies can still force lock. Synthetic mouse moves alone do not always reset idle timers. |

---

## Security and ethics

- No bundled **network** or telemetry.
- Cursor control and idle-sleep assertions are **sensitive** in managed environments — follow **policy**.
- **Ad-hoc** sign is fine for personal builds; wide distribution usually needs **Developer ID** + **notarization**.

---

## Contributing

Issues and PRs welcome. Run `./build.sh` successfully before submitting Swift changes.

---

## License

[MIT](LICENSE) © 2026 deceiverMe contributors.
