//! The open-source edition's pin tests: no pin ever exists here, pin commands are silent no-ops, and a session a Plus build saved
//! with a pinned column comes back as an ordinary ribbon with every window in it. They run in builds without the `plus` feature.

use super::*;
use serde_json::json;

const R: Rect = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
/// An ultrawide, the display a pin is most at home on.
const WIDE: Rect = Rect { x: 0.0, y: 25.0, w: 3440.0, h: 1440.0 };

fn wide(n: u32) -> Engine {
    let mut e = Engine::new(Config::default());
    e.handle(Event::Display { id: 1, frame: WIDE });
    for id in 1..=n {
        e.handle(Event::WindowAdded { id, pid: id as i32, app: format!("App{id}"), title: format!("T{id}"), frame: R, floating: false, width_hint: None, take_focus: true });
    }
    e
}
fn cmd(e: &mut Engine, name: &str, arg: Option<Value>) -> Plan {
    e.handle(Event::Command { name: name.into(), arg })
}
fn ids(e: &Engine) -> Vec<Vec<u32>> {
    e.st.columns.iter().map(|c| c.windows.clone()).collect()
}

/// Everything an engine shows of a pin, which must stay empty: the pin itself, the map, the frames and the tab bars.
fn assert_no_pin(e: &Engine, p: &Plan) {
    assert!(e.pin().is_none() && e.pin_memo.is_none(), "an engine of this edition never pins");
    assert!(p.map.pin.is_none() && p.map.near_edge.is_none(), "the map shows no pin");
    assert!(p.frames.iter().all(|f| !f.pinned) && p.tab_bars.iter().all(|b| !b.pinned), "no frame or tab bar belongs to a pin");
    assert!(e.snapshot().pin.is_none(), "a snapshot saves no pin");
}

#[test]
fn pin_commands_are_silent_no_ops() {
    let mut e = wide(4);
    cmd(&mut e, "focus_index", Some(json!(2)));
    let at_rest = e.handle(Event::Query);
    let (state, undo, focus) = (e.st.clone(), e.undo_len(), e.focused());
    let args = [
        None,
        Some(json!("left")),
        Some(json!("right")),
        Some(json!("near")),
        Some(json!("far")),
        Some(json!(-1)),
        Some(json!({"side": "right"})),
        Some(json!(0.2)),
        Some(json!(4)),
        Some(json!({"fraction": 0.333})),
        Some(json!(true)),
        Some(json!("nonsense")),
        Some(json!(null)),
    ];
    for name in ["pin", "pin_other_side", "unpin", "pin_width", "pin_every_desktop"] {
        for arg in &args {
            let p = cmd(&mut e, name, arg.clone());
            let what = format!("{name} {arg:?}");
            assert!(p.error.is_none() && p.toast.is_none() && !p.show_map && p.focus.is_none(), "{what}: not silent: {p:?}");
            assert_eq!((p.frames.as_slice(), p.changed.as_slice()), (at_rest.frames.as_slice(), &[][..]), "{what}: moved something");
            assert_eq!((&e.st, e.undo_len(), e.focused()), (&state, undo, focus), "{what}: changed the layout");
            assert_no_pin(&e, &p);
        }
    }
    // Dropping a window "into the pin" is as silent, with or without a window named.
    for arg in [json!({"id": 3, "pin": true, "position": "into"}), json!({"pin": true}), json!({"id": 3, "pin": true, "position": "tabs", "row": 0})] {
        let p = cmd(&mut e, "move_window_to", Some(arg.clone()));
        assert!(p.error.is_none() && p.toast.is_none() && !p.show_map && p.focus.is_none(), "{arg}: {p:?}");
        assert_eq!((&e.st, e.undo_len()), (&state, undo), "{arg}");
        assert_no_pin(&e, &p);
    }
    // Undo has nothing to take back, and redo nothing to put back.
    assert_eq!(cmd(&mut e, "undo", None).toast.as_deref(), Some("Nothing to undo"));
    assert_eq!(cmd(&mut e, "redo", None).toast.as_deref(), Some("Nothing to redo"));
}

#[test]
fn pin_commands_are_silent_with_nothing_to_pin_too() {
    // No windows, no display, a floating window in focus: the same silence.
    let mut e = Engine::new(Config::default());
    for name in ["pin", "pin_other_side", "unpin", "pin_width", "pin_every_desktop"] {
        let p = cmd(&mut e, name, Some(json!("left")));
        assert!(p.error.is_none() && p.toast.is_none() && !p.show_map, "{name}: {p:?}");
        assert_no_pin(&e, &p);
    }
    let mut e = wide(2);
    e.handle(Event::WindowAdded { id: 9, pid: 9, app: "Float".into(), title: "f".into(), frame: R, floating: true, width_hint: None, take_focus: true });
    e.handle(Event::WindowFocused { id: 9 });
    assert!(e.st.floating.contains(&9) && e.focused() == Some(9));
    for name in ["pin", "pin_other_side", "unpin", "pin_width", "pin_every_desktop"] {
        let p = cmd(&mut e, name, None);
        assert!(p.error.is_none() && p.toast.is_none() && !p.show_map, "{name}: {p:?}");
        assert!(e.st.floating.contains(&9) && e.focused() == Some(9), "{name} took the floating window");
        assert_no_pin(&e, &p);
    }
}

#[test]
fn the_ribbon_plans_in_the_whole_display_and_rests_where_it_always_does() {
    let mut e = wide(4);
    cmd(&mut e, "focus_index", Some(json!(1)));
    cmd(&mut e, "pin", Some(json!("left")));
    let p = e.handle(Event::Query);
    // Half-width columns on 3440 pt: 1702 px, 12 pt outer gaps, the first at the display's edge.
    assert_eq!((p.frames[0].x, p.frames[0].w, p.frames[1].x), (12, 1702, 1726));
    assert_eq!((e.avail(), e.st.scroll), (3416.0, 0.0));
    // There is nothing past the ribbon's ends to step onto.
    for name in ["focus_left", "focus_left", "focus_right", "focus_right", "focus_right", "focus_right"] {
        cmd(&mut e, name, None);
        assert!(e.focused().is_some_and(|f| e.pos(f).is_some()), "{name}: focus left the ribbon");
    }
    assert_eq!(e.focused(), Some(4));
    let p = cmd(&mut e, "focus_right", None);
    assert_eq!((e.focused(), p.focus), (Some(4), None));
    assert_no_pin(&e, &p);
}

/// A session a Plus build saved with window 2 and 3 pinned to the left (a stack at the pin's ribbon width ⅔).
const PLUS_LIVE_PIN: &str = r#"{"active": 1, "desktops": [{"index": 1, "columns": [
    {"windows": [1], "width": {"kind": "frac", "value": 0.5}, "heights": null, "tabbed": false, "active": null},
    {"windows": [4], "width": {"kind": "frac", "value": 0.5}, "heights": null, "tabbed": false, "active": null}],
    "floating": [], "focus": 3, "scroll": 0.0}],
  "pin": {"windows": [2, 3], "heights": null, "tabbed": false, "active": null, "side": "left", "fraction": 0.2, "desktop": 1,
    "every_desktop": false, "home": 1, "home_desktop": 1, "width": {"kind": "frac", "value": 0.667}, "suspended": false, "need": 0.0}}"#;

/// A tab group of windows 2, 3 and 1 (tab 3 shown) pinned to the right on every desktop, saved while it shows.
const PLUS_TABBED_PIN: &str = r#"{"active": 1, "desktops": [{"index": 1, "columns": [
    {"windows": [4], "width": {"kind": "frac", "value": 0.5}, "heights": null, "tabbed": false, "active": null}],
    "floating": [], "focus": 3, "scroll": -1285.5}],
  "pin": {"windows": [2, 3, 1], "heights": null, "tabbed": true, "active": 1, "side": "right", "fraction": 0.25, "desktop": 1,
    "every_desktop": true, "home": 1, "home_desktop": 1, "width": {"kind": "frac", "value": 0.5}, "suspended": false, "need": 0.0}}"#;

/// The pin of the session above after the display got too narrow for it: its column is back in the ribbon, the pin is suspended.
const PLUS_SUSPENDED_PIN: &str = r#"{"active": 1, "desktops": [{"index": 1, "columns": [
    {"windows": [1], "width": {"kind": "frac", "value": 0.5}, "heights": null, "tabbed": false, "active": null},
    {"windows": [2, 3], "width": {"kind": "frac", "value": 0.5}, "heights": null, "tabbed": true, "active": 1},
    {"windows": [4], "width": {"kind": "frac", "value": 0.5}, "heights": null, "tabbed": false, "active": null}],
    "floating": [], "focus": 3, "scroll": 0.0}],
  "pin": {"windows": [2, 3], "heights": null, "tabbed": true, "active": 1, "side": "right", "fraction": 0.25, "desktop": 1,
    "every_desktop": true, "home": 1, "home_desktop": 1, "width": {"kind": "frac", "value": 0.5}, "suspended": true, "need": 345.0}}"#;

/// The `restore_session` event for a saved session (what the host sends after it re-added the windows).
fn restore(e: &mut Engine, session: &str) -> Plan {
    let mut v: Value = serde_json::from_str(session).expect("a session");
    v["type"] = json!("restore_session");
    e.handle_json(&v.to_string())
}

/// Every window is somewhere: in a ribbon column or floating, exactly once, and the plan frames each tiled one.
fn assert_all_placed(e: &Engine, p: &Plan, n: u32) {
    let mut all: Vec<u32> = e.desktop_windows().concat();
    all.sort_unstable();
    assert_eq!(all, (1..=n).collect::<Vec<_>>(), "a window was lost or doubled");
    let mut framed: Vec<u32> = p.frames.iter().map(|f| f.id).collect();
    framed.sort_unstable();
    let tiled: Vec<u32> = (1..=n).filter(|id| !(0..DESKTOPS).any(|d| e.desk_state(d).floating.contains(id))).collect();
    assert_eq!(framed, tiled, "a tiled window has no frame");
}

#[test]
fn a_session_saved_with_a_pin_puts_its_column_back_in_the_ribbon_at_its_slot_and_width() {
    let mut e = wide(4);
    let p = restore(&mut e, PLUS_LIVE_PIN);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert_eq!(ids(&e), [vec![1], vec![2, 3], vec![4]], "the pinned stack sits where it was pinned from");
    assert_eq!(e.st.columns[1].width, Width::Frac(0.667), "and has the width it had in the ribbon");
    assert!(!e.st.columns[1].is_tabbed());
    assert_all_placed(&e, &p, 4);
    assert_eq!((e.focused(), p.focus), (Some(3), Some(3)), "the focus the session had, which was on the pinned stack");
    assert_eq!(p.map.columns.len(), 3);
    assert_eq!(e.undo_len(), 0, "restoring is not an undoable edit");
    assert_no_pin(&e, &p);
    // The ribbon is the whole display's now: the window next to the stack is not squeezed beside a pin's band.
    assert_eq!(e.avail(), 3416.0);
    // Saving it again writes a plain ribbon, and that comes back the same.
    let snap = e.handle(Event::Snapshot).session.expect("a session");
    assert!(snap.pin.is_none());
    assert_eq!(snap.desktops[0].columns.iter().map(|c| c.windows.clone()).collect::<Vec<_>>(), [vec![1], vec![2, 3], vec![4]]);
    let mut again = wide(4);
    again.handle(Event::RestoreSession { active: snap.active, desktops: snap.desktops.clone(), pin: snap.pin.clone() });
    assert_eq!(again.st.columns, e.st.columns);
}

#[test]
fn a_tab_group_pinned_on_every_desktop_comes_back_as_a_tab_group() {
    let mut e = wide(4);
    let p = restore(&mut e, PLUS_TABBED_PIN);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert_eq!(ids(&e), [vec![4], vec![2, 3, 1]], "slot 1 of a ribbon of one column: after it");
    assert!(e.st.columns[1].is_tabbed() && e.st.columns[1].active == Some(3), "the tab it showed is shown");
    assert_eq!(e.st.columns[1].width, Width::Frac(0.5));
    assert_all_placed(&e, &p, 4);
    assert_eq!(e.focused(), Some(3));
    assert_eq!(p.tab_bars.len(), 1, "one tab bar, an ordinary one");
    assert_no_pin(&e, &p);
    // It lives on its desktop only now: another desktop does not get a pin along.
    cmd(&mut e, "switch_desktop", Some(json!(2)));
    assert!(e.desktop_windows()[1].is_empty());
    let p = e.handle(Event::Query);
    assert_all_placed(&e, &p, 4);
    assert_no_pin(&e, &p);
}

#[test]
fn a_suspended_pin_is_dropped_and_its_column_stays_where_the_ribbon_had_it() {
    let mut e = wide(4);
    let p = restore(&mut e, PLUS_SUSPENDED_PIN);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert_eq!(ids(&e), [vec![1], vec![2, 3], vec![4]]);
    assert!(e.st.columns[1].is_tabbed() && e.st.columns[1].active == Some(3));
    assert_all_placed(&e, &p, 4);
    assert_no_pin(&e, &p);
    // A wide display later does not bring the pin back: nothing remembers it.
    let p = e.handle(Event::Display { id: 1, frame: Rect { w: 5120.0, ..WIDE } });
    assert_all_placed(&e, &p, 4);
    assert_eq!(ids(&e), [vec![1], vec![2, 3], vec![4]]);
    assert_no_pin(&e, &p);
}

#[test]
fn a_saved_pin_loses_only_what_the_core_does_not_know() {
    // Window 99 is gone since the session was saved: the tab group of 2 and 3 cannot keep its tabs or its shares.
    let session = PLUS_TABBED_PIN.replace(r#""windows": [2, 3, 1]"#, r#""windows": [2, 99, 3, 1]"#).replace(r#""heights": null, "tabbed": true"#, r#""heights": [0.4, 0.2, 0.2, 0.2], "tabbed": true"#);
    let mut e = wide(4);
    let p = restore(&mut e, &session);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert_eq!(ids(&e), [vec![4], vec![2, 3, 1]]);
    assert!(!e.st.columns[1].is_tabbed() && e.st.columns[1].heights.is_none());
    assert_all_placed(&e, &p, 4);
    assert_no_pin(&e, &p);
    // A pin none of whose windows is around leaves the ribbon as the session had it.
    let session = PLUS_LIVE_PIN.replace(r#""windows": [2, 3]"#, r#""windows": [98, 99]"#);
    let mut e = wide(4);
    let p = restore(&mut e, &session);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert_eq!(ids(&e), [vec![1], vec![4], vec![2], vec![3]], "2 and 3, which the session never named, follow the saved columns");
    assert_all_placed(&e, &p, 4);
    assert_no_pin(&e, &p);
}

#[test]
fn a_pin_pinned_from_a_desktop_with_nothing_else_on_it_restores_there() {
    // The session names no columns for desktop 3: the pinned column was all that was on it.
    let session = PLUS_LIVE_PIN
        .replace(r#""desktop": 1,"#, r#""desktop": 3,"#)
        .replace(r#""home_desktop": 1,"#, r#""home_desktop": 3,"#)
        .replace(r#""home": 1,"#, r#""home": 0,"#);
    let mut e = wide(4);
    let p = restore(&mut e, &session);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert_eq!(e.desktop_windows()[2], vec![2, 3], "desktop 3 has its column back");
    assert_eq!(e.desktop_windows()[0], vec![1, 4]);
    assert_all_placed(&e, &p, 4);
    assert_no_pin(&e, &p);
    cmd(&mut e, "switch_desktop", Some(json!(3)));
    assert_eq!(ids(&e), [vec![2, 3]]);
    assert_eq!(e.st.columns[0].width, Width::Frac(0.667));
    assert_eq!(e.focused(), Some(2), "the first window of the column holds the focus when the session named none there");
}

#[test]
fn a_saved_pin_does_not_pull_a_floating_window_into_the_ribbon() {
    let mut e = wide(4);
    cmd(&mut e, "focus_index", Some(json!(2)));
    cmd(&mut e, "toggle_float", None);
    assert!(e.st.floating.contains(&2));
    let p = restore(&mut e, PLUS_LIVE_PIN);
    assert!(p.error.is_none(), "{:?}", p.error);
    assert!(e.st.floating.contains(&2), "a floating window stays floating");
    assert_eq!(ids(&e), [vec![1], vec![3], vec![4]]);
    assert_all_placed(&e, &p, 4);
    assert_no_pin(&e, &p);
}
