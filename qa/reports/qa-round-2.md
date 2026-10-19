# Ribbon QA round 2

Date: 2026-10-13 (overnight run, fix commit 8cbde64, HEAD 9419a1e). No product code edited.
Raw data: `/Users/moses/projects/ribbon-scratch/` (`scen2/*.jsonl` replays, `mini_maketest.out`, `mini_props.out`, `bundle2.log`, `winlist`, `axprobe`).

## Bottom line

- Part A (live, this Mac): BLOCKED. The screen stayed locked (`CGSessionCopyCurrentDictionary` reports `CGSSessionScreenIsLocked=1`, loginwindow is the console owner) for the whole run, roughly 20 minutes. Under the lock, AX returns the app element with role `AXApplication` in place of each window (title "RibbonDummy", position and size 0,0), so Ribbon discovered zero windows. The instruction that "AX window moves still work" did not hold: I could not read or move a single dummy window. No live item could be verified.
- Part B (Mac mini, Swift 6.2.4 / SDK 26.2): PASS. Build and tests are clean. The 20k-case property run passes, and the round-1 tooling bug (proptest ignoring `PROPTEST_CASES`) is fixed.
- Replay (core `ribbon-sim`, all 25 scenarios plus 6 repros): no engine crash. Two round-1 P1s (blank ribbon with floating focus) are fixed in the engine. The app-minimum-width P1 is not fixed. Undo scope and three P2s are fixed or changed, as detailed below.
- OmniWM Dev was quit at the start and relaunched at the end (pid 77213, `pgrep -x OmniWM` confirmed). Ribbon and RibbonDummy processes were stopped.

## Pass/fail table

| # | Check | Result | Evidence |
|---|---|---|---|
| A1 | Close focused window x5, focus to neighbor | BLOCKED | Lock; AX returns app element |
| A2 | Initial apply, relaunch x3 with 5 windows, within 4pt | BLOCKED | Lock |
| A3 | Undo after focus moves reverts layout only | Replay PASS (sim); live BLOCKED | `b3` replay: stack, focus_index 1, focus_index 3, undo restores pre-stack layout and focus 3 in one step |
| A4 | toggle_float x2, check_plans clean | Replay PASS | `b4` replay: 7 plans, 0 problems. Focus is null while floating (by design) |
| A5 | Glide animation timeline and rapid-fire end state | BLOCKED | Lock |
| A6 | Min-width refusal | SKIPPED | Could not reach live windows; RibbonDummy has no min-size support |
| A7 | Idle 5s, no plans, CPU ~0% | BLOCKED | Lock |
| A8 | check_plans on live plans | NOT RUN LIVE (no live plans). Replays checked instead, see Part B | |
| A9 | Quit via fifo restores windows on screen | BLOCKED | Lock |

### Round-1 bug status

| Round-1 item | Status | Evidence |
|---|---|---|
| B1 (P1) Close focused window focuses an unrelated window | UNVERIFIED (live blocked). Static fix only: 120 ms debounce on OS focus events plus a 350 ms ignore window after engine focus changes (`Controller.osFocused`) | Replays cannot model the OS focus raise |
| B2 (P1) First window left untiled on fresh 4-window launch | UNVERIFIED (live blocked). Static fix only: a delayed 0.6 s `gather` after start | |
| B3 (P2) Undo spent on focus moves | FIXED | `b3` replay (see A3). Focus-only commands are no longer undoable. `s04` and `s17` plans differ from round 1 for this reason |
| B4 (P2) toggle_float leaves focus null, checker violation | CHECKER FIXED, engine unchanged. Focus is still null while floating, and re-tiling a float appends it at the far right (`b4` row 7) | `check_plans.py` now has a float exception, 0 problems |
| B5 (P2) Quit restores launch size | UNVERIFIED (live blocked) | |
| Mini P1-1 Blank ribbon with floating focus after display change or close | FIXED in engine | `r02`: scroll clamps on each removal (viewport 0.668 to 0.602 to 0.502, columns 4 and 3 on screen). `r03`: after display 1920 to 1280 the viewport moves to 0.6688 and columns 5 and 6 stay on screen. `analyze.py` reports 0 problems for both |
| Mini P1-2 App min-width clamp adopted as a user drag | NOT FIXED in engine | `r06`: column 2 goes 0.5 to 0.53 after a `window_resized` to w=1000. Nothing was dragged. Only the live AX check could confirm the app-side behavior |
| Mini P2-1 Focus direction ignored from a floating window | NOT FIXED, now a silent no-op | `p21` and `r01`: `focus_right` from floating leaves focus null and the viewport unchanged (it previously went to the leftmost column) |
| Mini P2-2 Tile-from-float jumps viewport to the end | FIXED | `r05`: window 9 is inserted after the focused column, viewport 0.2005 to 0.167 (was 0.20 to 0.67) |
| Mini P2-3 Unknown `focus_window` id shows HUD | FIXED | `r04`: `show_map=false` |
| Mini tooling: props.rs ignores `PROPTEST_CASES` | FIXED | `props.rs` now reads the env var, default 300. Mini run with `PROPTEST_CASES=20000`: 3/3 pass |
| Mini tooling: check_plans false positive on floating focus | FIXED | Checker now accepts floating focus with no focused column |

## Part B evidence

**Sync**: `rsync -az --delete --exclude .build --exclude target --exclude build` to `moses@100.94.131.70:projects/ribbon/`: OK.

**`make test` on mini** (`ssh BatchMode`, `tail -40`, log in `mini_maketest.out`):
- Core `cargo test` (debug): 54 unit tests pass (round 1 reported 48), props 3/3 pass.
- `ribbon-sim` bin: 0 tests.
- `Ribbon --selftest`: "selftest passed" (all checks ok).
- Build log: `swift build -c release` completed in 4.15 s with only `Compiling Controller.swift` and `Linking`. No `warning:` or `error:` lines. This was an incremental build, not the clean rebuild round 1 did, because the rsync excluded `.build`.
- Caveat: the tail cut earlier output. A separate grep over the full `cargo test` output found no `warning` or `error` lines. An extra `swift build` grep (`mini_props.out`) also returned nothing.

**Property run** (`PROPTEST_CASES=20000 cargo test --release --test props`, mini):
```
test undo_restores_previous_state ... ok
test invariants_hold ... ok
test deterministic ... ok
test result: ok. 3 passed; 0 failed; finished in 0.75s
```
The run prints no per-case count. The 20000 setting is confirmed by reading the source, not by a failing-case check.

**Replays** (locally with `core/target/release/ribbon-sim`, built with `cargo build --release --manifest-path core/Cargo.toml`; plans in `ribbon-scratch/scen2/`):
- All 25 scenario files replayed with exit 0. `config-center-scroll.json` is a config, not a scenario (rc 2 when passed as events), and `s12` loads it correctly.
- Total plans: 487 across the 25 scenario files.
- `check_plans.py --display 0,30,1920,1050`: 0 problems in every r- and s-file except `s08` (16) and `s18` (12). Both have a mid-session display change, so the fixed display is wrong for part of the run. The same was true in round 1. `analyze.py` reports 0 behavioral problems for both.
- Engine error plans, all intentional and not layout failures: `s04` (focus_index without arg), `s09` (`-1`, `"abc"`, missing arg), `s10` (unknown command), `s11` (focus_window without arg).
- Diff against round-1 plan logs: identical for 19 of 25 scenarios. Changed: `r01` (1 plan), `r02` (3), `r03` (2), `r05` (2), `s04` (16), `s07` (3, not analyzed further), `s17` (10). The `r` diffs are the fixes above. `s04` and `s17` changed because of undo scope.

## Remaining bugs (prioritized)

### P0
None found in replays, fuzz, or the mini build.

### P1

**P1-1 (carry-over, still open): app minimum-width echo treated as a user drag.**
Repro (`qa/scenarios/r06_min_size_echo_widens_column.json`):
```
display 1920x1050; add 1,2,3,4; focus_index 2; window_resized id=2 frame.w=1000
```
Observed: column 2 `width_frac` 0.5 to 0.53, and the layout keeps the app's refused width. Expected: a size the app reports because it clamped our write should not change the layout, or the minimum should be an explicit rule. Needs the live AX check (A6 was skipped).

**P1-2 (unverified, blocks sign-off): live close-focus and first-apply fixes (B1, B2) have no evidence yet.**
The fix is timing-based (120 ms debounce, 350 ms ignore window, 0.6 s gather). Run A1 and A2 first, once the screen is unlocked.

### P2

**P2-1: focus_left and focus_right from a floating window do nothing.**
Repro (`qa/scenarios/...` pattern; minimal events): `display; add 1; add 2; add 3; add 10 floating=true; window_focused 10; command focus_right`.
Observed: focus stays null, viewport unchanged. Expected: focus the column in the pressed direction, or the one nearest the dialog.

**P2-2: suspected focus-click drop (static risk, unverified).**
`Controller.osFocused` ignores any OS focus event for 350 ms after an engine-driven focus change unless the window is the one the engine focused. A user click on another window within that window is dropped silently. Repro: trigger `focus_right` and click a different window within 350 ms. Verify live.

**P2-3: re-tiling a floating window appends it at the far right.**
Repro: `display; add 1; add 2; add 3; focus_index 1; toggle_float; toggle_float`. The window returns as the last column (`b4` row 7). Spec is silent. This is the UX question round 1 raised.

**P2-4 (carry-over): quit restores launch size, discarding user resize.** Unverified; needs the live A9 run.

**P2-5 (carry-over, UX): focus_index beyond range silently clamps to the last column.** Pressing 9 with 3 windows focuses window 3.

**P2-6 (carry-over): engine error plans are only logged (NSLog), never shown.**

## Not done / needs a human

- Live AX, animation, close-focus, initial-apply, quit, and idle checks (A1, A2, A5, A7, A9). Rerun Part A once the screen is unlocked. The helpers are in `ribbon-scratch/` (`winlist` for CG state, `axprobe` for AX state, `frames` for the existing ground-truth reader).
- Real hotkeys and the live HUD look, as in round 1.
