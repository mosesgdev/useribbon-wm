# Ribbon app (Swift shell)

SwiftUI/AppKit menu-bar app (LSUIElement) around the Rust core (`../core`, linked as `libribbon_core.a`).

- `Sources/Ribbon/Core` FFI wrapper (`Engine`) and Codable wire types
- `Sources/Ribbon/Platform` AX windows, observers, frame applier, hotkeys, screens, restore
- `Sources/Ribbon/UI` menu bar, ribbon-map HUD, command bar, onboarding, shortcuts, settings, theme
- `Sources/Ribbon/App` entry point, `Controller` (glue), `--selftest`, `--snapshot`
- `Sources/RibbonDummy` QA helper: `RibbonDummy --count 3 --title-prefix Dummy [--close-after-seconds N]`

Build from the repo root: `make selftest`, `make bundle` (signed `build/Ribbon.app`), `make run`.
Flags: `Ribbon --selftest` (FFI round trip, no AX), `Ribbon --snapshot <dir>` (offscreen PNGs with fake data; glass is drawn flat).

QA environment variables:
- `RIBBON_ONLY_PIDS=1,2` / `RIBBON_ONLY_BUNDLES=com.x` manage only those apps; everything else is never touched.
- `RIBBON_CMD_FIFO=/path` named pipe; each line is a command (`focus_right`, `focus_index 2`, `pause`, `resume`, `quit`) or raw event JSON.
- `RIBBON_PLAN_LOG=/path` every plan JSON is appended as one line.
