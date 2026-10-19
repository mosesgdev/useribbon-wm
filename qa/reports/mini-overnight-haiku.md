# Ribbon overnight QA on Mac mini (Haiku run), 2026-10-14

## Environment (mini, moses@100.94.131.70)
- macOS 27.0.1 (build 26A434), `sw_vers`
- Swift 6.2.4 (swiftlang-6.2.4.1.4, clang-1700.6.4.2), target arm64-apple-macosx28.0
- SDK 26.2 (`xcrun --show-sdk-version`)
- Display: 1920x1080, visible frame used for checks 0,30,1920,1050
- Accessibility not granted to SSH sessions, so no live window moves were attempted.

## Pass/fail table

| Step | Check | Result |
|---|---|---|
| 1 | rsync + clean build (`rm -rf app/.build core/target`) | PASS, core and app built from scratch |
| 1 | `make test` (cargo test + selftest) | PASS, exit 0; 75 core unit tests + 3 integration tests ok, 0 failed |
| 1 | Warnings in `make test` and `make bundle` logs | none (0 matches for "warning") |
| 1 | `make bundle` | PASS, rc 0; signed ad-hoc because identity "OmniWM Dev" is absent on mini (expected fallback) |
| 2 | Property fuzz, 4 seeds x 1,000,000 cases | PASS, 12 property runs, 0 failures |
| 3 | 26 scenario files through ribbon-sim + check_plans (single display 0,30,1920,1050) | 19 files with no issues or only expected error-input events, see Findings |
| 3 | 12 ux-sim files (6 personas + 6 repros) | 0 invariant problems when display follows display events |
| 3 | 3 new mini personas (g1, g2, g3; 150/150/200 events) | 0 invariant violations; analyzer flags scroll jumps only |
| 4 | `Ribbon --snapshot` | PASS, rc 0, 9 PNGs written |
| 4 | Snapshot rendering review | HUD, onboarding, shortcuts render; commandbar search field anomaly (P3) |
| 5 | `Ribbon --selftest` | PASS, rc 0 |
| 5 | ribbon-sim garbage inputs (invalid JSON, empty, huge ints, bad UTF-8, truncated, 200 KB name, zero display, missing file, stdin garbage, bad config) | PASS, no panics; each malformed input exits 2 with a message; zero-size display and huge names run to completion |

## Fuzz
Command: `PROPTEST_CASES=1000000 PROPTEST_RNG_SEED=s cargo test --release --test props` for s = 1..4, run on the mini.
Log: `/tmp/ribbon-overnight-fuzz.log` on the mini.

| Seed | Properties | Cases per property | Result | Time |
|---|---|---|---|---|
| 1 | 3 | 1,000,000 | ok, 3 passed | 38.7 s |
| 2 | 3 | 1,000,000 | ok, 3 passed | 38.9 s |
| 3 | 3 | 1,000,000 | ok, 3 passed | 39.3 s |
| 4 | 3 | 1,000,000 | ok, 3 passed | 39.4 s |

Total: 12 property runs, 12,000,000 generated cases configured (3 properties x 4 seeds x 1M), 0 failures, 0 panics. The run finished in about 4 minutes, well inside the 75-minute cap. Proptest does not print per-case counts, so 12M is the configured total, not a counted one.

## Persona metrics (1920x1080 personas, mini)

| Persona | Events | Commands | Avg changed/user event | Max changed | Focus fully visible | Min column width | Tiny-column plans (<400px) | Scroll events | Big scrolls | Invariant violations |
|---|---|---|---|---|---|---|---|---|---|---|
| g1 parent (school portal, mail, calendar, chat) | 150 | 101 | 1.58 | 5 | 100% | 379 px (0.205) | 50 | 68 | 2 | 0 (2 jump flags) |
| g2 writer (research tabs, full-width toggles) | 150 | 111 | 1.93 | 6 | 100% | 623 px (0.333) | 0 | 77 | 4 | 0 (4 jump flags) |
| g3 support (20 chat windows, open/close churn) | 200 | 74 | 3.35 | 20 | 100% | 623 px (0.333) | 0 | 154 | 5 | 0 (5 jump flags) |
| a_developer_ultrawide (3840, reference) | 118 | - | - | - | - | - | - | - | - | 0 |
| e_display_swap | 121 | 80 | 2.81 | 8 | 100% | 360 px | 16 | 84 | 4 | 0 (4 jump flags) |
| f_chaos | 150 | 101 | 1.00 | 6 | 100% | 623 px | 0 | 41 | 1 | 0 (1 jump flag, 2 expected error replies) |

Analyzer and check_plans are run from qa/ux-sim/analyze.py (py3.9 OK) and the new
qa/mini-overnight/analyze_mini.py. Full traces are in qa/mini-overnight/out/.

## Findings

### P2-1: Scroll jumps of one full column or more on single focus steps
- Repro: `python3 qa/mini-overnight/analyze_mini.py` then read `qa/mini-overnight/out/g2_writer_research_fullwidth.problems.txt`. Example: `g2#86: JUMP +1932 px for one focus_right (column ~1896 px)`, `g2#117: JUMP -1931 px for one focus_left`. Similar: `g3#172`, `g1#81`, `g1#105`, `d_tab_hoarder#77`.
- Why it matters: moving focus to a neighbour that is itself a full-width window slides the whole viewport by a full screen (1896 px on 1920). It is consistent with scrolling-WM semantics, but a reviewer would call it a scroll jump, especially when a writer toggles full width repeatedly.
- Suggested check: confirm in the live app whether the slide is animated and whether the jump is intended. Treat as UX review, not a correctness bug.

### P2-2: Columns drop below 400 px on 1920 when the layout is crowded
- Repro: `python3 qa/mini-overnight/gen_mini_personas.py && ... ribbon-sim qa/mini-overnight/g1_parent_school_mail_chat.json` and check `tiny_col_plans` (50 plans) and `min_col_px` 379 (0.205 of 1920) in the g1 metrics. Triggers are stack/unstack/move_left/move_right/cycle_width sequences (see `tiny_triggers` in the metrics).
- Why it matters: four or more windows with stacking squeeze a column to about 380 px on a 1920 display, where a school portal or mail text column is hard to read.
- Suggested check: review the min-width rule in layout.rs for the 1920 case. Not a crash; UX.

### P3-1: Commandbar search field renders as a yellow bar with a no-entry sign in snapshots (light and dark)
- Repro: `ssh moses@100.94.131.70 'cd ~/projects/ribbon && app/.build/release/Ribbon --snapshot /tmp/ribbon-snaps'`, then view `qa/mini-overnight/snapshots/commandbar.png` and `commandbar-dark.png`.
- Likely a snapshot artifact of an offscreen NSTextField, since the rest of the bar renders correctly. Needs a live check on a real display with Accessibility granted before it is treated as a product bug.

### P3-2: check_plans.py applies one display to every file, producing false positives
- Repro: `python3 qa/check_plans.py --display 0,30,1920,1050 /tmp/rq/s08_display_shrinks_midsession.jsonl` reports 16 problems. Using the display from the event stream (`qa/mini-overnight/check_per_display.py qa/scenarios/s08_display_shrinks_midsession.json <plans>`) reports 0. Same for s18 (9 vs 0), e_display_swap (482 vs 0 across display changes) and repro_undo_after_display_swap (10 vs 0).
- Fix: have check_plans follow display events, or use check_per_display.py. Tooling only.

### P3-3: Intentional invalid commands surface as engine errors (expected, documented here so they are not re-filed)
- s04 line 7 and s09 (`focus_index needs a numeric arg`), s10 (`unknown command: query_nothing_here`), s11 (`focus_window needs a window id`), f_chaos (`bogus_command`). These are error-path tests. The engine returns a plan with `error` set and does not crash.

### P3-4: One event can reflow 20 windows at once in the chat-churn persona
- g3 `max_changed_user` = 20 (avg 3.35). Probably a stack or full re-tile after a window is added with many windows open. Expected for a tiled layout, but worth a glance for flicker in the live app.

## Verdict
CONDITIONAL PASS. Build, unit, integration, selftest, bundle and FFI robustness all pass on a clean mini build with no warnings. No crashes, panics or invariant violations on any 1920x1080 persona or scenario once display changes are respected. Open items are UX review items (P2-1, P2-2) and tooling (P3-2), plus one snapshot anomaly (P3-1) that needs a live check. No P1 found.

Note on live verification: all of this is sim and snapshot evidence. There was no live window movement and no Accessibility session on the mini, so nothing here confirms the live app behaves as the sim predicts.
