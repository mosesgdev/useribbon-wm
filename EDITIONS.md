# Editions: Free and Plus

Ribbon is open-core. The public repo builds the **free** edition. The **Plus** edition (a notarized one-click DMG) adds features on top,
pinning first. The public repo is generated from the private one by an export script that deletes the Plus code and keeps everything
else, so this page is the contract that keeps that export a deletion and nothing more.

| | free | plus |
|---|---|---|
| where it is built | the public repo, by anyone (`make`) | the private repo (`make`, `make release`) |
| core | `cargo build` | `cargo build --features plus` |
| app | no flag | `swift build -Xswiftc -DRIBBON_PLUS` |
| `ribbon_core_edition()` | `"free"` | `"plus"` |
| Plus code | not in the tree | `core/src/plus/`, `app/Sources/Ribbon/Plus/` |

## Licenses

The free edition, which is everything the export keeps, is licensed under the GPL-3.0-or-later ([LICENSE](LICENSE)). The Plus
code (`core/src/plus/`, `app/Sources/Ribbon/Plus/`) is proprietary, all rights reserved, and never leaves the private repo. That works
because one owner holds the copyright to both. A contribution to the public repo arrives under the GPL, so it can go into Plus only
with its author's permission; keep Plus features in code you wrote yourself, or ask contributors to agree to that before merging.

## Building an edition

`make` picks the edition: **plus where the checkout has `core/src/plus`, else free**, so the exported repo builds free with no
arguments and the private one builds plus. `make EDITION=free …` and `make EDITION=plus …` choose one.

- Each edition has its own cargo target dir (`core/target/EDITION`) and its own SwiftPM scratch path (`app/.build/EDITION`). The Makefile
  hands the linker the core of the same edition (`-Xlinker -L…`; `Package.swift` names no path), so a build never links the other
  edition's core and switching editions rebuilds nothing. A core that is not the one the binary was linked with (found by checksum, not
  by date) makes `make app` link again. A hand-run `swift build` finds no core on purpose: use `make`.
- `make bundle`, `install`, `run` and `release` build the checkout's edition. `build/Ribbon.app` is whichever edition was bundled last.
- `make test` runs `cargo test` and `Ribbon --selftest` for every edition the checkout can build (free, and plus where `core/src/plus`
  exists); `make test EDITION=plus` runs one. `make print-EDITION` (or any other Makefile variable) prints a value for scripts.
- Plus features run only when **both** the app (built with `RIBBON_PLUS`) and its core (built with `--features plus`) are Plus.
  `Ribbon --selftest` **fails** when the two disagree; at launch a mismatch is logged and the app runs as free, with no Plus feature
  registered. The Makefile cannot produce a mismatch; it takes forcing a link by hand.

## Where code goes

**Rust** (`core/`)

- `core/src/plus/NAME.rs` holds a Plus feature's algorithms. `engine.rs` declares it as a child module of `engine` (so it sees the
  engine's private fields), one pair of lines per feature:

  ```rust
  #[cfg(feature = "plus")] #[path = "plus/pin.rs"] mod pin;
  #[cfg(not(feature = "plus"))] #[path = "free/pin.rs"] mod pin;
  ```

- `core/src/free/NAME.rs` is its **twin**: the same functions with the same signatures, doing nothing (no pin ever exists, a pin command
  is a silent no-op) plus whatever the free edition must do with data a Plus build wrote (a saved pin folds back into the ribbon).
  Tests: `plus/NAME_tests.rs` for the feature, `free/NAME_tests.rs` for the twin; each is a child module of its file.
- The **data model stays shared**: `model.rs` types, `Engine` fields, `Entry`, `Session`, the plan's optional fields. They carry or
  tolerate a feature's data, are `Option`/default-able, and are correct when it is absent. A file or message a Plus build wrote must load
  in free. The algorithms that create, place, move, resize, suspend, restore or step onto the feature are Plus.
- `engine.rs` calls the hook functions wherever the feature matters. It never reaches into the feature's fields or constants.

**Swift** (`app/Sources/Ribbon/`)

- `Plus/` is compiled only into Plus. **Every file is wrapped whole in `#if RIBBON_PLUS … #endif`.**
- `Free/` holds the stand-ins for what a Plus file declares: the same type or method name and signature, doing nothing. Shared code calls
  them without an `#if`. **Every file is wrapped whole in `#if !RIBBON_PLUS … #endif`.**
- File names are unique in the target (SwiftPM), so a stand-in is `FreeNAME.swift` beside `Plus/NAME.swift`.
- **Shared files have no `#if RIBBON_PLUS` region** (today: none). If one ever must, it uses only `#if`, `#else`, `#endif` (the export
  runs `unifdef -URIBBON_PLUS`, which keeps the `#else` branch and does not know `#elseif`) and it is the only way that code can be written.
- No Swift multi-line string (`"""`) in `Plus/` or `Free/`: unifdef lexes C and gives up on it ("Unterminated string literal", exit 2,
  output cut off). That is also why the export runs unifdef **only** on the files that name `RIBBON_PLUS`, never on every Swift file.

**The one rule that holds the rest together: shared code never references `Plus/` or `plus/` except through the stub twins and the
registry.** In shared (and Free/) files that means:

- a type, method or function a shared file uses exists in both editions (the real one in Plus/ or plus/, the twin in Free/ or free/), or
  is the registry (`RibbonFeature`, `FeatureRegistry`, `PlusFeatureList`);
- no comment, string or test in a shared or Free file names a Plus file or a symbol only Plus declares ("see `ControllerPin.swift`");
  say "the Plus edition" instead;
- the only literal mentions are the Makefile's `core/src/plus` (edition detection) and the `#[path = "plus/NAME.rs"]` lines of `engine.rs`;
- user-visible words of a Plus feature live in Plus files only. The free binary must not contain them.

`scripts/check-public-build.sh` enforces this by building the public tree (below).

## The feature registry

A shared file never edits a menu, a table or a list for a Plus feature. `App/Features.swift` is the only way in:

1. A type in `Plus/` conforms to `RibbonFeature` and describes what it adds. Each slot has a default of nothing:

   | slot | what it adds | read by |
   |---|---|---|
   | `hotkeys` | actions with a default shortcut (`after`: the row they follow) | `Hotkeys.table`, the shortcut store, the sheet |
   | `windowCommands` | engine commands that change the focused window (the command bar names that window) | `BarItem.actsOnWindow` |
   | `barRows` | command bar rows, with detail, keywords, and `standIn` for a bar with no window to name | `BarModel` |
   | `menuItems` | menu bar items that run an engine command | `MenuBar` (`onFeatureCommand`) |
   | `settingsTabs`, `settingsRows` | a Settings tab of its own, or a control at the end of a built-in tab | `SettingsTab`, `SettingsView` |
   | `shortcutGroups` | a group of the Shortcuts sheet no built-in shortcut belongs to | `ShortcutsView` |
   | `selfTests` | the feature's own `--selftest` checks | `SelfTest` (counted with the rest) |

2. `Plus/PlusEdition.swift` lists it in `PlusFeatureList.all`. `Free/FreeEdition.swift` lists none.
3. `FeatureRegistry.shared` is empty unless the app and its core are both Plus, so every table reads the same code in both editions and
   a free build gets exactly the built-in rows.

Pieces a feature has to draw *into* (the tab bar's button, the strip's tile, the toast's sketch, the swipe overlay's blur strip, what the
Controller does for a pinned column) go through a type or method that Plus/ and Free/ both declare (`PinTabButton`, `TabMenuFeature`,
`PlusToast`/`PlusDiagram`, `OverlayEdge`/`PinEdge`, `PinState` and the `Controller` hooks of `Plus/ControllerPin.swift` and
`Free/FreeControllerPin.swift`, the strip's `heldCaption`/`pinTile` in `PinHUD.swift`/`FreePinHUD.swift`).

Saved state follows the same rule. A shortcut override saved for an action the running edition has no row for (a Plus build wrote it) is
kept in the saved file, but is no row and no count (`ShortcutStore` keeps it aside and writes it back), so a file written by a Plus build
loads cleanly in free and is all there when Plus returns. A session saved with a pinned column restores in free with that column back in
the ribbon at its saved slot and width, no window lost.

## Adding the next Plus feature

Say it is called Foo.

1. **Core, if it needs the engine.** `core/src/plus/foo.rs` (hooks as `pub(super) fn` in an `impl Engine`, `#[cfg(test)] mod foo_tests;`),
   `core/src/free/foo.rs` (the twin: same signatures, nothing happens, plus whatever it takes to read data a Plus build wrote), the two
   `mod foo;` lines in `engine.rs`, and the calls to the hooks where Foo matters. New data goes into shared types as optional,
   `#[serde(default)]` fields. Add `proptest` coverage that free never produces Foo.
2. **Swift.** `Plus/FooFeature.swift` (`struct FooFeature: RibbonFeature`, `#if RIBBON_PLUS`) with its slots, and one line in
   `PlusFeatureList.all`. For anything it draws into a shared view: a hook in the shared file that calls a type declared in
   `Plus/Foo….swift` and, with the same name and signature, in `Free/FreeFoo….swift` (inert). Its tests are Plus files listed in the
   feature's `selfTests`, not in `SelfTest.swift`.
3. **Words.** Titles, toasts, tooltips, accessibility labels of Foo are string literals in Plus files only.
4. **Gates** (below). `check-public-build.sh` derives what to look for (the types, functions and strings only the deleted files hold), so
   it needs no edit; a new `#[path = "plus/foo.rs"]` line is recognised by its shape.

## The gates

Run all of them before a change to the split is done:

```sh
cargo test --manifest-path core/Cargo.toml                    # free core
cargo test --manifest-path core/Cargo.toml --features plus    # plus core (adds the feature's tests)
make test                      # check-editions, then cargo test + Ribbon --selftest for each edition the checkout can build
make EDITION=free bundle SIGN=-   &&  build/Ribbon.app/Contents/MacOS/Ribbon --selftest
make EDITION=plus bundle SIGN=-    &&  build/Ribbon.app/Contents/MacOS/Ribbon --selftest
scripts/check-public-build.sh  # the public tree: export-public.sh of HEAD, then make test, make bundle, --selftest
```

- `make check-editions` (`scripts/check-editions.sh`, run first by `make test`, no build): how Plus/ and Free/ files are wrapped, that
  file names are unique, that no shared file has a `RIBBON_PLUS` region, and what `unifdef -URIBBON_PLUS` makes of the Plus/ and Free/ files
  (and that it can read them at all). In the exported tree, which has no Plus/ folder, it has nothing to check.
- Plus must stay exactly itself: its `cargo test --features plus` and `--selftest` names are the old ones plus the new. Compare names
  with the previous commit, not only counts.
- `scripts/check-public-build.sh [REF]` (`STATIC_ONLY=1` for the few-second part without the build; `KEEP=1` keeps the copy) writes the
  public tree of the committed REF with `scripts/export-public.sh` (below), and then fails on: an edition that does not auto-detect as free, a `RIBBON_PLUS` directive left, any code file that names a deleted file, a
  type or function only the deleted files declare, or a RIBBON_PLUS region outside Free/. It then runs `make test` and `make bundle` in the
  copy, the bundle's `--selftest`, and looks in the free binary for every user-visible string only the deleted files held.
- A free binary is also checked by hand with `strings`: none of "Unpin it first", "Pinned", "Pin to the", "On every desktop", … belongs
  in it (the script does this for every Plus-only string).

## What is shared on purpose

Code that only reads a feature's optional data and does nothing without it stays shared: the wire types (`CorePin`, `MapPin`,
`SavedPin`, `PlanFrame.pinned`), the strip's geometry (`HUDStrip`), the drop rule and its marks, `TabLayout`'s button metrics and the
swipe writer's release. They draw and say nothing without a pin; moving them would mean rewriting the shared algorithms they sit in.
Their checks stay and run in both editions. Everything that draws, words, offers or routes the pin is in `Plus/`.

## Exporting the public repo

```sh
scripts/export-public.sh OUT [REF]   # OUT: an empty directory, or a checkout of the public repo
```

It writes the committed tree of REF (default HEAD) minus the Plus edition. Into a checkout of the public repo it replaces everything
but `.git` and commits the result as one commit, "Ribbon <short sha>: <subject>", so the public history is one commit per export and
never carries the private one. It never pushes: look at the commit, then `git -C OUT push`. What it does to the tree:

- deletes `core/src/plus/`, `app/Sources/Ribbon/Plus/`, `docs/ribbon-pinned-column.html`, and itself and `check-public-build.sh`;
- `unifdef -URIBBON_PLUS -m` on the Free/ files that name `RIBBON_PLUS`;
- `engine.rs` keeps only the free twin of each Plus module, and `--features plus` stops with a `compile_error!` that says the Plus
  edition is not in the repo. The `plus` feature stays declared in `core/Cargo.toml` (with a comment saying so), because the
  `cfg(feature = "plus")` checks left in `lib.rs` and the tests would otherwise warn as unexpected cfgs;
- Markdown passages only Plus has go. A doc marks them so the private copy still reads whole (comments render as nothing):

  | in the private doc | in the public one |
  |---|---|
  | `<!-- plus -->` and `<!-- /plus -->` on lines of their own around a passage | the passage and the markers are gone |
  | `text<!-- plus --> (Plus words)<!-- /plus --> more` inside one line | `text more` |
  | a table row ending in `<!-- plus-row -->` | the row is gone |
  | a line that is only `<!-- free: TEXT -->` | `TEXT` (what the public doc says instead) |

  SPEC.md's pinned column, the ⌃⌥K row, the README's pinned-width note and core/README.md's edition notes are marked this way. A
  Plus-only doc of its own is added to the delete list in the script.

It fails if a marker, a `RIBBON_PLUS` directive or the Plus code is left. The Makefile's test for `core/src/plus` is the only code in
the public tree that names a deleted path, and `check-public-build.sh` allows exactly that.
