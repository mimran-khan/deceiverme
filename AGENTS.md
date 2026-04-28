## Learned User Preferences

- For attached implementation plans: do not edit the plan file itself; use the todos that already exist (mark the first item `in_progress`, advance in order, do not recreate the todo list), and finish every todo before stopping.
- UI feedback can be blunt; if the UI still reads as unpolished after a round of changes, expect another iteration cycle rather than declaring the makeover done.
- User-visible strings should read as plain English, not metaphor or internal jargon: prefer labels like Start/Stop, Settings, Dashboard, Time left, and Moves rather than drift/recipe/studio-style terminology.

## Learned Workspace Facts

- Primary native UI is Swift/AppKit in `MouseMoverNative/MouseMoverNative.swift`; the shipped app/product name in the UI is **deceiverMe**, built via `build.sh`, producing `deceiverMe.app` at the repo root.
- Theme and colors are centralized in a private `DMTheme` palette; large multi-function UI rewrites may use scripted whole-block replacement (for example Python) when single-shot search-and-replace is brittle on very large contiguous edits.
- Integrated system telemetry (SMC temps, CPU %, RAM, network) appears in the menu and Dashboard window; **`build.sh` links `-framework IOKit`** with the other frameworks.
- GitHub repo: `https://github.com/mimran-khan/deceiverme`; author page: `https://mimran-khan.github.io/`.
