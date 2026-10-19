# ribbon_core

Pure Rust layout engine for Ribbon (see `../SPEC.md`). Events in, layout plan out; no macOS calls.
Exposed to Swift through `include/ribbon_core.h` (staticlib `libribbon_core.a`).

## Build / test

```sh
. ~/.cargo/env
cargo test                              # unit + proptest property tests (open-source edition)
cargo build --release                   # target/release/libribbon_core.a
cargo clippy --all-targets -- -D warnings
PROPTEST_CASES=5000 cargo test --test props   # soak
```

Layout: `src/model.rs` (serde JSON types), `src/layout.rs` (pure geometry + scroll math),
`src/engine.rs` (state machine, undo/redo), `src/lib.rs` (C ABI, the only `unsafe`).
Panics are caught at the FFI boundary (no `panic = "abort"`) and returned as a Plan with `error` set.

## Editions
The core builds in two editions, and `ribbon_core_edition()` says which one a library is (`"plus"` or `"free"`). This repo
holds the open-source one. The Plus edition (`--features plus`), built from a private repo, adds pinning (EDITIONS.md).

- `src/free/` holds the open-source twin of every Plus module: the same functions doing nothing. No pin ever exists in this
  edition, a pin command is a silent no-op, and a session a Plus build saved with a pinned column restores with that column back
  in the ribbon at its saved slot and width.
- Everything else is shared: the data model that carries or tolerates a pin (`Pin`, `Entry::pin`, `SessionPin`, `MapPin`,
  `PlanFrame::pinned`, a band without an inset) and `engine.rs` calling the twin functions wherever a pin matters.

## Simulator

```sh
cargo run --bin ribbon-sim -- examples/basic.json       # one Plan JSON per line
cargo run --bin ribbon-sim -- --config cfg.json < events.json
```

## JSON shapes

Events: internally tagged by `"type"` (snake_case): `display{id,frame}`, `window_added{id,pid,app,title,frame,floating?,width_hint?,take_focus?}`,
`window_removed{id}`, `window_replaced{old,new,pid,app,title}` (native tab switch: `new` takes `old`'s place, no glide), `window_minimized{id}`, `app_hidden{pid}`, `app_shown{pid,front?,take_focus?}`, `window_focused{id}`, `window_title{id,title}`, `window_resized{id,frame}`,
`command{name,arg?}`, `query`. Desktop commands: `switch_desktop{n}`, `move_to_desktop{n}`, `switch_desktop_back`. `frame` = `{x,y,w,h}` numbers.
Plan: `{frames:[{id,x,y,w,h,on_screen}] (integers), focus:u32|null, changed:[u32], map:{columns:[{windows:[{id,app,title}],
width_frac,focused,visible}], viewport:{start,end}, focused_index:int|null, desktop:1-9, desktops:[{index,count,active,windows}] (9)}, show_map, error:string|null,
toast:string|null, jump:bool, floating_parked:[u32], shelf:[{id,app,title,desk,hidden}]}`.

## Decisions (where the spec was open)

- **Desktops**: nine, engine-side. The active desktop's `State`, undo/redo, anchor and focus history live in the `Engine` fields;
  the other eight sit in `Engine::others` and swap in on `switch_desktop` (`switch_to`), so single-desktop code paths are unchanged.
  `WinInfo.desk` says where each window lives. Undo entries are `Vec<(desktop, State)>` (one element normally; `move_to_desktop` stores source and
  target so undo/redo move the window back and forth). Inactive desktops are laid out normally, then forced to `x = right - 1`, `on_screen = false`.

- **`focus`** is set only when the engine wants the OS to focus a window: any focus change caused by a command,
  add, or remove, plus `focus_window`, `undo`/`redo` and `gather` (always). It is `null` for `window_focused`
  (the OS is already there), title, resize, query, display events.
- **`show_map`**: true for every recognised command (even at an edge, as orientation feedback), window add,
  removal of a known window, an effective `window_focused`, and a changed display. False for query, title,
  resize, duplicate/unknown-id events, and unknown commands.
- **`changed`** diffs against the previously emitted plan (whole frame incl. `on_screen`); ids newly in `frames`
  count as changed. `gather` clears the memory so all frames are listed. Error plans do not affect it.
- **Floating windows** live in the window map (and `State.floating`) but are in no column and have no frames.
  They can hold focus (`map.focused_index` is `null`, no column `focused`). `focus_*` while a floating window is
  focused moves relative to the last focused tiled column (the anchor; with none, it enters at the first visible
  column); other column commands no-op. The anchor keeps scroll clamped on display change, removal and `gather`.
  `toggle_float` to tile inserts right of the anchor. A floating window added does not steal focus unless nothing is focused.
- **`window_added.take_focus`** (optional, default `true`): the host says `false` for a window an app in the background opened. It joins
  where it would go (right of the anchor, or as the newest tab after the active one), but focus, the shown tab and the viewport stay as
  they are: no `reveal`, and the plan's `focus` is `null` (no focus request to the OS, even when the desktop had no focus and the core
  falls back to this window). A column inserted left of the viewport (or at its edge) adds its width to `scroll`, so the columns in view
  keep their screen position; beside a pin the scroll settles on the nearest rest offset (a ribbon narrower than its band rests
  against the pin, so a column added at its end moves the others to make room). A floating window never takes focus then. The
  host's `window_focused` for the window (its app came to the front) focuses and reveals it as usual. The plan's `show_map` is false: the
  map would only flash over what the user is doing. A window coming back from the shelf with `take_focus` false (and `app_shown` with
  `take_focus` false, an app unhidden in the background) returns to its usual place (its desktop, right of that desktop's focused
  column, several in their old order; back into the pin it left without changing the pin's shown tab), with no focus, desktop switch,
  scroll or map.
- **Scroll**: `scroll` is a px offset into the content. `keep_visible` clamps to `[0, content - avail]`;
  `center` mode and the `center` command center exactly (may be negative for the first/last column) and do not clamp
  until the next `keep_visible` reveal. Reveal runs after focus, add, remove, move, width change, resize, display.
- **Visibility/on_screen**: a column is on screen if its (rounded) x-range overlaps the display by >0 pt;
  otherwise it is parked at `right-1` or `left-w+1` (1pt overlap, `on_screen=false`). y is unchanged.
  Window rows inside a column keep the same x; `map.visible` uses the unrounded viewport (not display) range.
- **Width**: `Frac(f)` -> `f*(avail+gap)-gap`; `Px` after `window_resized`. A resize within 2px of the current width is
  treated as an echo of our own frame and ignored; otherwise it snaps to a preset within 24px or stays px.
  `map.width_frac` is the equivalent fraction. `cycle_width` picks the next preset strictly above the current fraction
  (wraps); `cycle_width_back` the previous below. `toggle_full` on an already-full column with nothing to restore
  goes to `default_width`. Any width change clears the restore memory. `grow_width` / `shrink_width` move the fraction by
  0.05 from wherever the column is (a preset, a dragged px width), clamped like `set_width`; at a limit nothing changes
  (no undo step, the restore memory stays) and the toast says so.
- **Height**: `Column.heights` is `None` (equal split) or one share per window (sum 1). `cycle_height` needs a stack of >=2
  (else toast "Stack windows first", nothing recorded); it picks the next of ⅓/½/⅔ above the focused window's share,
  skipping presets the minimum clamp would collapse. `window_resized` also adopts `frame.h` for a stacked window (echo within
  2px ignored, clamp to `max(120px, 0.15*avail_h)` per window, snap to a preset within 24px). Any change of a column's window set
  resets it to equal heights; equal shares are stored as `None`. `grow_height` / `shrink_height` move the focused window's
  share by 0.05 within the same minimum (the others split the rest equally); `move_up` / `move_down` swap it with its
  neighbour, share included (in a tabbed column that moves the tab). A lone window always fills the column: a shorter
  height would need shares that sum to less than 1 (and somewhere to put the rest), which layout, sessions and drags do
  not model.
- **Navigation**: left/right keep the row index (clamped); no wrap at edges (edge commands are no-ops and not
  recorded in undo). `focus_index` is 1-based and clamps to the last column; `0` is a no-op; bad/missing arg gives
  `error`. `arg` may be a number or numeric string. `stack` moves only the focused window to the bottom of the
  left column (no-op at column 0); `unstack` keeps the column's width. `stack_right` is its mirror: the window becomes the
  first row of the column on its right (no-op at the last column). `move_first` / `move_last` carry the focused column,
  whole, to the start / end of the ribbon. The pinned column refuses `move_first`, `move_last` and `stack_right` like the
  other structural moves (it answers "Unpin it first"), and takes the height and reorder commands inside itself.
- **Removal focus**: stack-mate above (else below), else left column, else right column; floating-only leftovers
  as a last resort.
- **Undo** covers layout changes only (move, width, full, stack/unstack, float); navigation (`focus_*`, `focus_index`,
  `focus_window`, `center`) is never recorded. `focus_window` with an unknown id is a silent no-op (`show_map` false).
  Snapshots `(columns, widths, heights, restore, floating, scroll, focus)`; recorded only when a command actually
  changes state; a new recorded command clears redo; max 50. Restoring reconciles with windows that were added or
  removed since (unknown ids dropped, new tiled windows get a column at the end).
- **Displays**: v0 keeps the last `display` event only. With no display yet, state is tracked and `frames` is empty.
- **Duplicate `window_added`** refreshes app/title only. Unknown commands return a normal plan with `error` set.
- **Bad config JSON** falls back to defaults; values are clamped (`Config::sanitized`).
