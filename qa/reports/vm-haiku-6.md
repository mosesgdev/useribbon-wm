# Ribbon VM QA report (haiku-6)

Build: `main` at 84f9938, clean tree. `build/Ribbon.app` (built after the HEAD commit) and `app/.build/release/RibbonDummy` were deployed to VM `ribbon-test` (macOS 27.0, arm64). The VM was not started or stopped, and the host Ribbon (`~/Applications/Ribbon.app`) was not touched. Helpers and screenshots: `/Users/moses/projects/ribbon-scratch/vm/qa6/`.

Launch for items 1, 3 and 4: guest script `~/rt/launch.sh` with `RIBBON_ONLY_PIDS` (TextEdit), `RIBBON_CMD_FIFO`, `RIBBON_PLAN_LOG` and `RIBBON_QA_OUT` set; `RIBBON_DIRECT_SWIPE` unset. Only one Ribbon ran at a time. I stopped my own PID before running `vmsmoke`.

Environment caveats:
- The VM's "Viewer has disconnected / Your screen is being controlled" notification sits over the top-centre of the screen.
- Pointer input did not reach Ribbon's tab bar in item 4. Keyboard input and FIFO commands worked.
- `osascript` against TextEdit timed out (AppleEvent -1712), so window names came from Ribbon's plan log.

## Summary

| # | Item | Result | Evidence |
|---|------|--------|----------|
| 1 | Same-app tab naming | PASS | Toast `Tab group: alpha-notes.txt + beta-plan.txt`; tab_bars titles `alpha-notes.txt` and `beta-plan.txt`; `qa6/s4-menu.png` shows both titled tabs. |
| 2 | Height floors, no ping-pong | PARTIAL | Live: 0 plan lines over 6 s idle and 0 over 6 s after a tab toggle. A real height-floor case could not be run (RibbonDummy has no min-height option). `--selftest` passed, including refusal and crowded-tab-floor checks. |
| 3 | Smooth swipe offer card | BLOCKED (environment) | `qa_swipe 400 300` ran (20 plan lines). No card at about 1.5 s (`qa6/s6-card1.png`), and `smoothSwipeOffered` was not written. The VM already grants Screen Recording to Ribbon, so the card path is not reached. |
| 4 | ⌃⌥Tab cycling and "Move to its own column" | PARTIAL | ⌃⌥Tab cycled the active tab 832 → 830 → 832 → 830 → 832 (4 presses, after one initial miss). Right-click menu and "Move to its own column" NOT VERIFIED: pointer input did not reach the tab bar. |
| 5 | `vmsmoke` | PASS | `ALL PASS (58 checks)`; `check_plans.py`: 140 plans, 0 problems. |

## Details

### 1. Same-app tab naming: PASS
- Windows: `Untitled`, `alpha-notes.txt`, `beta-plan.txt`. `toggle_tabs` grouped `alpha-notes.txt` (830) and `beta-plan.txt` (832).
- qa_state: `tabs [{"active": 832, "column": 1, "count": 2, "rect": [518, 42, 494, 32]}]`, `tabBars: 1`.
- Plan log toast: `"Tab group: alpha-notes.txt + beta-plan.txt"`. No "TextEdit, TextEdit".

### 2. Height floors: PARTIAL
- Live stack of TextEdit windows: 0 new plan lines over 6 s idle. After `toggle_tabs` (ungroup), 0 new plan lines over 6 s. No oscillation.
- Not run live: RibbonDummy supports only `--min-width`, and no app with a large minimum height was available. The `<15 lines` threshold was therefore not exercised against a real floor.
- `Ribbon --selftest` in the VM: `selftest passed` (504 lines). Relevant checks: `reconcile: 5 quick refusals still allowed`, `refuse guard: same size against the same plan is not retried`, `refuse guard: a changed planned width allows another report`, `tabs: floor when very crowded`.

### 3. Smooth swipe offer card: BLOCKED (environment)
- Preconditions: `smoothSwipeOffered` absent (`defaults delete` run); `RIBBON_DIRECT_SWIPE` unset.
- `qa_swipe 400 300`: card not visible at about 1.5 s; key still absent 3 s later.
- Cause: the card is offered only from `Controller.scrollEnded` on the non-snapshot path (`asyncAfter 0.6`). Snapshot mode is `SnapshotStore.permitted && RIBBON_DIRECT_SWIPE == nil`, and `permitted` is `CGPreflightScreenCaptureAccess()`. The guest TCC database grants `kTCCServiceScreenCapture` to `com.makeautomation.ribbon` (auth_value 2), so the card is correctly never offered in this VM.
- Not done: `tccutil reset ScreenCapture` would remove the grant, and restoring it needs a manual System Settings step. The second-appearance check is therefore not meaningful here. The once-only guard is verified by code reading only.
- Retest needs a VM where Ribbon lacks Screen Recording.

### 4. Tab bar: PARTIAL
- ⌃⌥Tab routes `focus_previous` to `next_tab` in a tabbed column. Active tab alternated 832 ↔ 830 over 4 presses. The first press after grouping did not register; not reproduced in 3 more presses.
- Right-click menu: not verified. Tried VNC `click 3` (twice), VNC `mousedown/up 3`, VNC option-click, and a guest CGEvent helper (`~/rt/rclick`, left and right). After each, qa_state was unchanged and no menu appeared in screenshots.
- "Move to its own column" (`popOut`) has no FIFO command, so its effect could not be read from qa_state.
- Menu wiring: `app/Sources/Ribbon/UI/TabBars.swift` lines 274-298.

### 5. vmsmoke: PASS
- `ALL PASS (58 checks)`, including swipe smoothness (snapshot p95 17.2 ms, latency 0.07 frames), stack floor (widths [890, 890], no write loop), focus mode, undo, and `check_plans.py` (140 plans, 0 problems).
- Full log: `/Users/moses/projects/ribbon-scratch/vm/qa6/smoke.log`.

## Failures and follow-ups (by severity)

1. (Medium, unverified) Right-click "Move to its own column" could not be exercised. Repro: tab group of two windows, right-click a tab, pick "Move to its own column", then qa_state `tabs`. Re-check on a VM session or host with working pointer input.
2. (Low, test gap) Smooth-swipe card cannot appear while Screen Recording is granted. Repro: VM as-is, `defaults delete com.makeautomation.ribbon smoothSwipeOffered`, `qa_swipe 400 300`. Needs a VM without the grant.
3. (Low, test gap) No live height-floor test: RibbonDummy lacks a min-height option. Only unit coverage.
4. (Low, intermittent) First ⌃⌥Tab after `toggle_tabs` via FIFO did not register once. Not reproduced in 3 more presses.
