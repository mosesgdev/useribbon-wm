//! Property tests: random event sequences must never break the engine's invariants.
//! They run against whichever edition is built (`--features plus` for Plus). The pin commands are generated for both: Plus
//! pins with them, the open-source edition must take them and do nothing.

use std::collections::{BTreeMap, BTreeSet};

use proptest::prelude::*;
use ribbon_core::engine::Engine;
use ribbon_core::model::{Config, Event, Plan, PlanFrame, Rect};
use serde_json::json;

const DISPLAY: Rect = Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 };
const COMMANDS: &[&str] = &[
    "focus_previous", "focus_left", "focus_right", "focus_up", "focus_down", "move_left", "move_right", "cycle_width",
    "cycle_width_back", "cycle_height", "toggle_full", "stack", "unstack", "center", "focus_index", "focus_window",
    "toggle_float", "move_to_index", "gather", "bogus", "switch_desktop", "switch_desktop", "move_to_desktop",
    "switch_desktop_back", "focus_first", "focus_last", "equalize_heights",
    "toggle_tabs", "toggle_tabs", "next_tab", "prev_tab",
    "move_first", "move_last", "move_up", "move_down", "stack_right", "grow_width", "shrink_width", "grow_height", "shrink_height",
];
const POSITIONS: &[&str] = &["before", "after", "into"];
/// Display widths: too narrow for a pin, room for ¼ but not ⅓, and an ultrawide.
const WIDTHS: &[f64] = &[1000.0, 1728.0, 3440.0];
const PIN_COMMANDS: &[&str] = &["pin", "pin", "pin_other_side", "unpin", "pin_width", "pin_every_desktop"];

fn event() -> impl Strategy<Value = Event> {
    let id = 1u32..8;
    prop_oneof![
        3 => (id.clone(), any::<bool>()).prop_map(|(id, floating)| Event::WindowAdded {
            id, pid: 1, app: format!("a{id}"), title: "t".into(), frame: DISPLAY, floating, width_hint: None, take_focus: true
        }),
        2 => id.clone().prop_map(|id| Event::WindowRemoved { id }),
        2 => (id.clone(), id.clone()).prop_map(|(old, new)| Event::WindowReplaced { old, new, pid: 1, app: format!("a{new}"), title: "r".into() }),
        2 => id.clone().prop_map(|id| Event::WindowFocused { id }),
        1 => id.clone().prop_map(|id| Event::WindowTitle { id, title: "x".into() }),
        2 => (id.clone(), 50.0f64..3000.0, 20.0f64..1200.0).prop_map(|(id, w, h)| Event::WindowResized {
            id, frame: Rect { x: 0.0, y: 0.0, w, h }
        }),
        12 => (0..COMMANDS.len(), 0u32..10).prop_map(|(i, n)| Event::Command {
            name: COMMANDS[i].into(),
            arg: Some(json!(n)),
        }),
        3 => (id.clone(), 1u32..6, 0..POSITIONS.len(), 0u32..4).prop_map(|(id, column, p, row)| Event::Command {
            name: "move_window_to".into(),
            arg: Some(json!({"id": id, "column": column, "position": POSITIONS[p], "row": row})),
        }),
        4 => (0..PIN_COMMANDS.len(), 0usize..10).prop_map(|(i, a)| Event::Command {
            name: PIN_COMMANDS[i].into(),
            arg: [None, Some(json!("left")), Some(json!("right")), Some(json!("near")), Some(json!("far")), Some(json!(3)), Some(json!(5)), Some(json!(0.25)), Some(json!(true)), Some(json!(false))][a].clone(),
        }),
        1 => (id.clone(), 0u32..3, any::<bool>()).prop_map(|(id, row, tabs)| Event::Command {
            name: "move_window_to".into(),
            arg: Some(json!({"id": id, "pin": true, "position": if tabs { "tabs" } else { "into" }, "row": row})),
        }),
        1 => (prop::collection::vec(id.clone(), 0..4), any::<bool>()).prop_map(|(ids, floating)| Event::Command {
            name: "set_floating".into(),
            arg: Some(json!({"ids": ids, "floating": floating})),
        }),
        1 => id.clone().prop_map(|id| Event::WindowMinimized { id }),
        1 => (id.clone(), 300.0f64..1400.0).prop_map(|(id, w)| Event::WindowRefused { id, frame: Rect { x: 0.0, y: 0.0, w, h: 500.0 } }),
        1 => (0..WIDTHS.len()).prop_map(|i| Event::Display { id: 1, frame: Rect { w: WIDTHS[i], ..DISPLAY } }),
        1 => (-1500.0f64..1500.0).prop_map(|dx| Event::ScrollBy { dx }),
        1 => (-3000.0f64..3000.0).prop_map(|v| Event::ScrollEnd { velocity: Some(v) }),
        1 => (id.clone(), -4000.0f64..8000.0).prop_map(|(id, x)| Event::ScrollTo { id, x }),
        1 => Just(Event::Query),
    ]
}

/// The shown window of every tabbed column (the pinned one included), sorted.
fn shown_tabs(p: &Plan) -> Vec<u32> {
    let mut v: Vec<u32> = p.tab_bars.iter().map(|b| b.active).collect();
    v.sort_unstable();
    v
}

fn width() -> impl Strategy<Value = f64> {
    (0..WIDTHS.len()).prop_map(|i| WIDTHS[i])
}

fn new_engine(w: f64) -> Engine {
    let mut e = Engine::new(Config::default());
    e.handle(Event::Display { id: 1, frame: Rect { w, ..DISPLAY } });
    e
}

fn run(w: f64, events: &[Event]) -> Vec<Plan> {
    let mut e = new_engine(w);
    events.iter().map(|ev| e.handle(ev.clone())).collect()
}

/// Each tiled window's column-mates (sorted) and whether they are tabbed, the pinned column included; the floating windows;
/// and every desktop's windows.
fn grouping(e: &Engine) -> (BTreeMap<u32, (Vec<u32>, bool)>, BTreeSet<u32>, Vec<BTreeSet<u32>>) {
    let mut groups = BTreeMap::new();
    for c in e.state().columns.iter().chain(e.pin().map(|p| &p.col)) {
        let mut mates = c.windows.clone();
        mates.sort_unstable();
        for id in &c.windows {
            groups.insert(*id, (mates.clone(), c.is_tabbed()));
        }
    }
    let desks = e.desktop_windows().into_iter().map(|d| d.into_iter().collect()).collect();
    (groups, e.state().floating.clone(), desks)
}

fn is_undoable(ev: &Event) -> bool {
    matches!(ev, Event::Command { name, .. } if !matches!(
        name.as_str(),
        "undo" | "redo" | "gather" | "bogus" | "focus_left" | "focus_right" | "focus_up" | "focus_down" | "focus_index" | "focus_window" | "focus_previous" | "center" | "switch_desktop" | "switch_desktop_back" | "focus_first" | "focus_last" | "next_tab" | "prev_tab"
    ))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(
        std::env::var("PROPTEST_CASES").ok().and_then(|v| v.parse().ok()).unwrap_or(300)
    ))]

    #[test]
    fn invariants_hold(w0 in width(), events in prop::collection::vec(event(), 0..60)) {
        let mut e = new_engine(w0);
        let mut known = BTreeSet::new();
        let mut prev: BTreeMap<u32, PlanFrame> = BTreeMap::new();
        let mut dw_px = w0 as i64;
        // Fingers on the trackpad: columns may slide under the pin until they lift.
        let mut swiping = false;
        for ev in events {
            match &ev {
                Event::WindowAdded { id, .. } => { known.insert(*id); }
                Event::WindowRemoved { id } | Event::WindowMinimized { id } => { known.remove(id); }
                // an unknown old window is ignored; a known one hands its place to `new` (which gives up its own slot if it had one)
                Event::WindowReplaced { old, new, .. } => {
                    let was_known = known.remove(old);
                    if was_known { known.insert(*new); }
                }
                Event::Display { frame, .. } => dw_px = frame.w as i64,
                Event::ScrollBy { .. } | Event::ScrollTo { .. } => swiping = true,
                Event::ScrollEnd { .. } => swiping = false,
                _ => {}
            }
            let resized = if let Event::WindowResized { id, .. } = &ev { Some(*id) } else { None };
            let is_gather = matches!(&ev, Event::Command { name, .. } if name == "gather");
            let p = e.handle(ev);

            // every window is on exactly one desktop; the map's counts and active flag agree
            let dw = e.desktop_windows();
            let mut all: Vec<u32> = dw.iter().flatten().copied().collect();
            all.sort_unstable();
            prop_assert_eq!(all, known.iter().copied().collect::<Vec<_>>());
            prop_assert_eq!(p.map.desktops.iter().map(|d| d.count).collect::<Vec<_>>(), dw.iter().map(Vec::len).collect::<Vec<_>>());
            prop_assert_eq!(p.map.desktops.iter().position(|d| d.active), Some(e.desktop() - 1));
            prop_assert_eq!(p.map.desktop, e.desktop());
            let active = &dw[e.desktop() - 1];
            // focus is on the active desktop, or null when it is empty
            match e.focused() {
                Some(f) => prop_assert!(active.contains(&f), "focus {f} not on desktop {}", e.desktop()),
                None => prop_assert!(active.is_empty()),
            }
            // windows of inactive desktops are never on screen (tiled: parked frame, floating: listed as parked)
            for f in p.frames.iter().filter(|f| !active.contains(&f.id)) {
                prop_assert!(!f.on_screen, "{f:?}");
            }
            prop_assert!(p.floating_parked.iter().all(|i| known.contains(i) && !active.contains(i)));
            let n_parked_tiled = p.frames.iter().filter(|f| !active.contains(&f.id)).count();
            let pin_cols: Vec<&ribbon_core::model::MapColumn> = p.map.pin.iter().map(|mp| &mp.column).collect();
            let n_pinned = pin_cols.iter().map(|c| c.windows.len()).sum::<usize>();
            prop_assert_eq!(p.frames.len(), p.map.columns.iter().map(|c| c.windows.len()).sum::<usize>() + n_pinned + n_parked_tiled);

            // the pin: frames flagged pinned are exactly its windows; it shows only on its desktop and only with room
            let pinned_ids: BTreeSet<u32> = p.frames.iter().filter(|f| f.pinned).map(|f| f.id).collect();
            match (e.pin(), &p.map.pin) {
                (Some(pin), Some(mp)) => {
                    prop_assert_eq!(pin.desk, e.desktop() - 1);
                    prop_assert_eq!(&mp.column.windows.iter().map(|w| w.id).collect::<Vec<_>>(), &pin.col.windows);
                    prop_assert!(mp.column.visible && !pin.col.windows.is_empty());
                    prop_assert!(dw_px >= 1728, "pin on a {dw_px} pt display");
                    prop_assert_eq!(mp.column.focused, e.focused().is_some_and(|f| pin.col.windows.contains(&f)));
                    if mp.column.focused { prop_assert_eq!(p.map.focused_index, None); }
                }
                (Some(pin), None) => prop_assert!(pin.desk != e.desktop() - 1 && !pin.every),
                (None, Some(_)) => prop_assert!(false, "map pin without a pin"),
                (None, None) => {}
            }
            prop_assert_eq!(pinned_ids, e.pin().map(|p| p.col.windows.iter().copied().collect()).unwrap_or_default());
            if !cfg!(feature = "plus") {
                // The open-source edition takes the pin commands above and does nothing with them: no pin, ever.
                prop_assert!(e.pin().is_none() && p.map.pin.is_none() && p.map.near_edge.is_none());
                prop_assert!(p.frames.iter().all(|f| !f.pinned) && p.tab_bars.iter().all(|b| !b.pinned));
            }
            for pf in p.frames.iter().filter(|f| f.pinned && f.on_screen) {
                // against its edge: 12 pt outer gap on the left, or the right
                prop_assert!(pf.x == 12 || pf.x + pf.w == dw_px - 12, "{pf:?}");
            }
            if !swiping {
                // At rest no ribbon window hides under the pin.
                for f in p.frames.iter().filter(|f| !f.pinned && f.on_screen) {
                    for q in p.frames.iter().filter(|f| f.pinned && f.on_screen) {
                        prop_assert!(f.x + f.w <= q.x || f.x >= q.x + q.w, "{f:?} under the pin {q:?}");
                    }
                }
            }

            // every tiled window of the active desktop: exactly one column (or the pin), exactly one frame
            let mut in_cols: Vec<u32> = p.map.columns.iter().chain(pin_cols.iter().copied()).flat_map(|c| c.windows.iter().map(|w| w.id)).collect();
            let mut in_frames: Vec<u32> = p.frames.iter().map(|f| f.id).filter(|i| active.contains(i)).collect();
            in_cols.sort();
            in_frames.sort();
            prop_assert_eq!(&in_cols, &in_frames);
            let mut all_frames: Vec<u32> = p.frames.iter().map(|f| f.id).collect();
            all_frames.sort();
            prop_assert!(all_frames.windows(2).all(|w| w[0] != w[1]), "window framed twice");
            prop_assert!(in_cols.windows(2).all(|w| w[0] != w[1]), "duplicate window");
            prop_assert!(in_cols.iter().all(|i| known.contains(i)));
            prop_assert!(p.map.columns.iter().all(|c| !c.windows.is_empty()));

            if let Some(f) = p.focus { prop_assert_eq!(Some(f), e.focused()); }
            prop_assert_eq!(e.window_count(), known.len());

            // on_screen consistent with geometry
            for f in &p.frames {
                let overlap = (f.x + f.w).min(dw_px) - f.x.max(0);
                if f.on_screen { prop_assert!(overlap > 0, "{f:?}"); } else { prop_assert!(overlap <= 1, "{f:?}"); }
                prop_assert!(f.w >= 1 && f.h >= 1);
                prop_assert!(f.y >= 25 && f.y + f.h <= 825);
            }

            // stacked windows: top to bottom, never overlapping, gaps within a pixel of exact, none vanishing
            for (ci, col) in p.map.columns.iter().chain(pin_cols.iter().copied()).enumerate() {
                let fr: Vec<&PlanFrame> = col.windows.iter().map(|w| p.frames.iter().find(|f| f.id == w.id).unwrap()).collect();
                if col.tabbed {
                    // tabs: 2+ windows, all the same size and top; only the active one may be on screen, the rest are parked
                    prop_assert!(col.windows.len() >= 2);
                    let a = col.active.expect("tabbed column has an active tab");
                    prop_assert!(a < col.windows.len());
                    prop_assert!(fr.iter().all(|f| f.y == fr[0].y && f.h == fr[0].h && f.w == fr[0].w));
                    for (i, f) in fr.iter().enumerate() { if i != a { prop_assert!(!f.on_screen, "{f:?}"); } }
                    if col.visible { prop_assert!(fr[a].on_screen); }
                    // the pinned column's bar is flagged and numbered one past the ribbon's columns
                    let pinned = ci == p.map.columns.len();
                    prop_assert!(p.tab_bars.iter().any(|b| b.column == ci && b.pinned == pinned));
                    continue;
                }
                prop_assert!(col.active.is_none());
                for pair in fr.windows(2) {
                    let gap = pair[1].y - (pair[0].y + pair[0].h);
                    prop_assert!((11..=13).contains(&gap), "gap {gap}: {pair:?}");
                }
                prop_assert!(fr.iter().all(|f| f.h >= 1));
            }

            prop_assert_eq!(p.tab_bars.len(), p.map.columns.iter().chain(pin_cols.iter().copied()).filter(|c| c.tabbed).count());
            prop_assert!(p.tab_bars.iter().filter(|b| b.pinned).count() <= 1);
            // changed == exactly the frames that differ from the previous plan
            let expect: Vec<u32> = p.frames.iter().filter(|f| prev.get(&f.id) != Some(f)).map(|f| f.id).collect();
            if is_gather {
                // `gather` re-emits everything
                prop_assert_eq!(&p.changed, &p.frames.iter().map(|f| f.id).collect::<Vec<_>>());
            } else if let Some(id) = resized {
                // a resized window may be added: the plan re-writes it when it keeps another size
                prop_assert!(expect.iter().all(|i| p.changed.contains(i)));
                prop_assert!(p.changed.iter().all(|i| *i == id || expect.contains(i)));
            } else {
                prop_assert_eq!(&p.changed, &expect);
            }
            prev = p.frames.iter().map(|f| (f.id, f.clone())).collect();
        }
    }

    #[test]
    fn undo_restores_previous_state(w0 in width(), prefix in prop::collection::vec(event(), 0..30), last in event()) {
        let mut e = new_engine(w0);
        for ev in prefix { e.handle(ev); }
        let before = e.state().clone();
        let pin = |e: &Engine| e.pin().map(|p| (p.col.windows.clone(), p.side, p.frac, p.every));
        let pin_before = pin(&e);
        let map_before = e.handle(Event::Query).map;
        let depth = e.undo_len();
        let undoable = is_undoable(&last);
        e.handle(last);
        if undoable && (e.state() != &before || pin(&e) != pin_before) {
            prop_assert!(e.undo_len() > depth || depth == 50, "state changed but nothing recorded");
            let p = e.handle(Event::Command { name: "undo".into(), arg: None });
            // Undo reveals the focused column, so the scroll offset (and what is visible) may differ.
            let layout = |s: &ribbon_core::engine::State| (s.columns.clone(), s.floating.clone(), s.focus);
            prop_assert_eq!(layout(e.state()), layout(&before));
            prop_assert_eq!(p.map.focused_index, map_before.focused_index);
            let widths = |m: &ribbon_core::model::Map| m.columns.iter().map(|c| (c.windows.clone(), c.width_frac)).collect::<Vec<_>>();
            prop_assert_eq!(widths(&p.map), widths(&map_before));
            prop_assert_eq!(pin(&e), pin_before);
        }
    }

    /// A snapshot restored into a fresh engine that knows the same windows reproduces every desktop's layout.
    #[test]
    fn snapshot_restore_roundtrip(w0 in width(), events in prop::collection::vec(event(), 0..50)) {
        let mut a = new_engine(w0);
        // The fresh engine sees the display the first one ended on.
        let last_w = events.iter().rev().find_map(|ev| if let Event::Display { frame, .. } = ev { Some(frame.w) } else { None }).unwrap_or(w0);
        for ev in events { a.handle(ev); }
        let snap = a.handle(Event::Snapshot).session.expect("snapshot answers with a session");
        let mut b = new_engine(last_w);
        for (id, pid, app, title, floating) in a.window_infos() {
            b.handle(Event::WindowAdded { id, pid, app, title, frame: DISPLAY, floating, width_hint: None, take_focus: true });
        }
        b.handle(Event::RestoreSession { active: snap.active, desktops: snap.desktops.clone(), pin: snap.pin.clone() });
        let again = b.handle(Event::Snapshot).session.unwrap();
        prop_assert_eq!(snap.active, again.active);
        // scroll may be clamped differently after the rebuild; layout, focus and floating must match
        let strip = |s: &ribbon_core::model::Session| s.desktops.iter().map(|d| (d.index, d.columns.clone(), d.floating.clone(), d.focus)).collect::<Vec<_>>();
        prop_assert_eq!(strip(&snap), strip(&again));
        // The pin comes back whole (a suspended one only remembers which windows to look for).
        let pin = |s: &ribbon_core::model::Session| s.pin.as_ref().filter(|p| !p.suspended).map(|p| (p.windows.clone(), p.side, p.fraction, p.desktop, p.every_desktop, p.home, p.home_desktop, p.tabbed, p.active, p.width));
        prop_assert_eq!(pin(&snap), pin(&again));
        prop_assert_eq!(snap.pin.as_ref().map(|p| p.suspended), again.pin.as_ref().map(|p| p.suspended));
    }

    /// A window an app in the background opens joins the ribbon but never takes focus, asks the OS for none, or changes a shown tab.
    #[test]
    fn background_add_leaves_focus_and_shown_tabs_alone(w0 in width(), events in prop::collection::vec(event(), 0..50), floating in any::<bool>()) {
        let mut e = new_engine(w0);
        for ev in events { e.handle(ev); }
        let (focus, shown) = (e.focused(), shown_tabs(&e.handle(Event::Query)));
        let p = e.handle(Event::WindowAdded { id: 99, pid: 1, app: "bg".into(), title: "t".into(), frame: DISPLAY, floating, width_hint: None, take_focus: false });
        prop_assert_eq!(p.focus, None);
        if focus.is_some() { prop_assert_eq!(e.focused(), focus); }
        prop_assert_eq!(shown_tabs(&p), shown);
    }

    #[test]
    fn a_settings_change_keeps_every_stack_tab_group_float_and_desktop(
        w0 in width(), events in prop::collection::vec(event(), 0..50), gap in 0.0f64..30.0, dw in 0usize..4, end in any::<bool>(), scroll in 0usize..3
    ) {
        let mut e = new_engine(w0);
        for ev in &events {
            e.handle(ev.clone());
        }
        let (before, undo, focus) = (grouping(&e), e.undo_len(), e.focused());
        let (width, new_window) = ([0.333, 0.5, 0.667, 1.0][dw], if end { "end" } else { "right_of_focused" });
        let scroll = ["keep_visible", "center", "center_on_overflow"][scroll];
        let arg = json!({"gap": gap, "outer_gap": gap, "default_width": width, "new_window": new_window, "scroll": scroll});
        let p = e.handle(Event::Command { name: "set_config".into(), arg: Some(arg) });
        prop_assert!(p.error.is_none());
        prop_assert_eq!(grouping(&e), before);
        prop_assert_eq!((e.undo_len(), e.focused()), (undo, focus));
    }

    #[test]
    fn deterministic(w0 in width(), events in prop::collection::vec(event(), 0..50)) {
        let a = serde_json::to_string(&run(w0, &events)).unwrap();
        let b = serde_json::to_string(&run(w0, &events)).unwrap();
        prop_assert_eq!(a, b);
    }
}
