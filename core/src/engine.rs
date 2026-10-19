//! The state machine: events in, plan out. Deterministic, no clocks, no randomness.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use crate::layout::{self, Column, Width};
use crate::model::*;

// The pinned column. The Plus edition builds its own `pin` module; the open-source edition builds the twin in free/, which has
// the same functions doing nothing, so no pin ever comes into existence there. This file calls them wherever a pin matters and
// keeps only what carries or tolerates one: the data model (`Pin`, `Entry::pin`, ...) and the code that stays correct without one.
#[cfg(feature = "plus")]
compile_error!("the Plus edition is not part of the open-source repo: build without --features plus (see EDITIONS.md)");
#[path = "free/pin.rs"]
mod pin;

const UNDO_LIMIT: usize = 50;
const SNAP_PX: f64 = 24.0;
/// Resizes within this many px of the current width are echoes of our own frames.
const ECHO_PX: f64 = 2.0;
/// Height presets for `cycle_height` and drag snapping: share of the column's usable height.
const HEIGHT_PRESETS: [f64; 3] = [1.0 / 3.0, 0.5, 2.0 / 3.0];

/// How far (px) a trackpad scroll may stretch past either end of the ribbon, and how much of the push gets through.
const OVERSCROLL_PX: f64 = 60.0;
const OVERSCROLL_RESIST: f64 = 0.4;
/// Release velocity (px/s of the viewport) is projected this far ahead to pick the rest it settles on; capped.
const FLING_PROJECT_S: f64 = 0.12;
const MAX_FLING_PX_S: f64 = 6000.0;
/// A release still moving at least this fast (px/s) pages on to the next rest in its direction, and one at least
/// `COMMIT_MIN_PX` past the rest behind it: a flick moves a wide column as readily as a narrow one. Two rests closer than
/// `COMMIT_MIN_PX` are not told apart either (see `layout::free_rest_offsets`).
const COMMIT_PX_S: f64 = 400.0;
const COMMIT_MIN_PX: f64 = 32.0;
/// Two columns this close (px) to the middle of the band, by distance and by centre, are equally near it.
const TIE_PX: f64 = 1.0;
/// `grow_width` / `shrink_width` change a column's width by this much of the usable width; `grow_height` / `shrink_height`
/// change a stacked window's share of its column by the same.
const NUDGE: f64 = 0.05;

/// Where a release at viewport offset `s`, still moving at `v` px/s, comes to rest among the rest offsets `rest`: the one nearest where its
/// momentum would carry it. A flick (`COMMIT_PX_S`, from at least `COMMIT_MIN_PX` past the rest behind it) pages on to the
/// next rest in its direction at least, and further when the momentum reaches it.
fn settle_scroll(rest: &[f64], s: f64, v: f64) -> f64 {
    let proj = s + v * FLING_PROJECT_S;
    let nearest = rest.iter().copied().min_by(|a, b| (a - proj).abs().total_cmp(&(b - proj).abs())).unwrap_or(0.0);
    // Still moving at release: the next rest in that direction (or further, for a fling), whatever the column's width.
    // Halfway-to-commit made a wide window need a long swipe before it would move on.
    let (ahead, behind) = if v > 0.0 {
        (rest.iter().copied().filter(|r| *r > s + 0.5).fold(f64::INFINITY, f64::min), rest.iter().copied().filter(|r| *r <= s + 0.5).fold(f64::NEG_INFINITY, f64::max))
    } else {
        (rest.iter().copied().filter(|r| *r < s - 0.5).fold(f64::NEG_INFINITY, f64::max), rest.iter().copied().filter(|r| *r >= s - 0.5).fold(f64::INFINITY, f64::min))
    };
    let moved = if behind.is_finite() { (s - behind).abs() } else { f64::INFINITY };
    if v.abs() >= COMMIT_PX_S && ahead.is_finite() && moved >= COMMIT_MIN_PX {
        if v > 0.0 { ahead.max(nearest) } else { ahead.min(nearest) }
    } else {
        nearest
    }
}

/// The columns nearest the middle of the band at `scroll` among those wholly in view (all, when none is), ascending: the
/// nearest by distance to the column (0 inside it), then by its centre, and any within `tie_px` of it on both. A
/// `tie_px` of 0 leaves only exact ties.
fn nearest_columns(spans: &[(f64, f64)], target: f64, scroll: f64, avail: f64, tie_px: f64) -> Vec<usize> {
    let whole: Vec<usize> = (0..spans.len()).filter(|i| spans[*i].0 >= scroll - 0.5 && spans[*i].0 + spans[*i].1 <= scroll + avail + 0.5).collect();
    let cands = if whole.is_empty() { (0..spans.len()).collect() } else { whole };
    let key = |(l, w): (f64, f64)| ((l - target).max(target - (l + w)).max(0.0), (l + w / 2.0 - target).abs());
    let cmp = |a: (f64, f64), b: (f64, f64)| {
        if (a.0 - b.0).abs() > tie_px {
            a.0.total_cmp(&b.0)
        } else if (a.1 - b.1).abs() > tie_px {
            a.1.total_cmp(&b.1)
        } else {
            std::cmp::Ordering::Equal
        }
    };
    let best = cands.iter().copied().min_by(|a, b| cmp(key(spans[*a]), key(spans[*b]))).unwrap_or(0);
    cands.into_iter().filter(|i| cmp(key(spans[*i]), key(spans[best])).is_eq()).collect()
}

/// Everything undo/redo restores.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub columns: Vec<Column>,
    pub floating: BTreeSet<u32>,
    /// Column width a window had when it was floated, so re-tiling restores it. Only floating windows have entries.
    pub float_widths: BTreeMap<u32, Width>,
    pub scroll: f64,
    pub focus: Option<u32>,
}

impl State {
    fn holds(&self, id: u32) -> bool {
        self.floating.contains(&id) || self.columns.iter().any(|c| c.windows.contains(&id))
    }

    /// `new` takes over `old`'s place: column slot, tab choice, floating mode and width, focus (the pinned column's windows
    /// are not in a state, but a state can focus one). A state that holds both (a snapshot taken after `new` was added) drops
    /// `new` first; one without `old` is left alone.
    fn swap_id(&mut self, old: u32, new: u32) {
        if !self.holds(old) {
            self.focus = self.focus.map(|f| if f == old { new } else { f });
            return;
        }
        if self.holds(new) {
            for c in self.columns.iter_mut().filter(|c| c.windows.contains(&new)) {
                c.windows.retain(|w| *w != new);
                c.reset_heights();
                c.active = c.active.filter(|a| *a != new);
            }
            self.columns.retain(|c| !c.windows.is_empty());
            self.floating.remove(&new);
            self.float_widths.remove(&new);
            if self.focus == Some(new) {
                self.focus = Some(old);
            }
        }
        for c in &mut self.columns {
            c.windows.iter_mut().filter(|w| **w == old).for_each(|w| *w = new);
            c.active = c.active.map(|a| if a == old { new } else { a });
        }
        if self.floating.remove(&old) {
            self.floating.insert(new);
        }
        if let Some(w) = self.float_widths.remove(&old) {
            self.float_widths.insert(new, w);
        }
        self.focus = self.focus.map(|f| if f == old { new } else { f });
    }
}

impl Pin {
    /// `new` takes over `old`'s place in the pinned column (row, height share, tab). A `new` already in it is dropped first.
    fn swap_id(&mut self, old: u32, new: u32) {
        let col = &mut self.col;
        if !col.windows.contains(&old) {
            return;
        }
        if col.windows.contains(&new) {
            col.windows.retain(|w| *w != new);
            col.reset_heights();
        }
        col.windows.iter_mut().filter(|w| **w == old).for_each(|w| *w = new);
        col.active = col.active.map(|a| if a == old { new } else { a });
    }
}

struct WinInfo {
    pid: i32,
    app: String,
    title: String,
    /// Virtual desktop (0-based) this window lives on. Every known window is on exactly one.
    desk: usize,
}

/// A column pinned against one edge of the display, outside the ribbon (one per display). The ribbon of its desktop plans
/// in what is left (the display minus the pin's width and one gap). It sits on one desktop: the active one when it shows
/// on every desktop (it moves along with each switch), else the one it was pinned on.
#[derive(Clone, Debug, PartialEq)]
pub struct Pin {
    /// Its windows, tabs and stack heights; `width` is the width it had in the ribbon (it gets it back when unpinned).
    pub col: Column,
    pub side: PinSide,
    /// The chosen width, one of `PIN_FRACTIONS` (an app that refuses to get that narrow lifts it to the next one).
    pub frac: f64,
    pub desk: usize,
    pub every: bool,
    /// Desktop and column index it was pinned from: unpinning on that desktop puts it back in that slot.
    pub home: (usize, usize),
    /// Px it needed when a too-narrow display folded it back into the ribbon (0 while pinned): the memo pins again only
    /// once that fits, even after a relaunch has forgotten the app floors that made it that wide.
    pub need: f64,
}

/// A minimized or hidden window the core remembers so it can come back where it was.
struct Shelved {
    pid: i32,
    app: String,
    title: String,
    desk: usize,
    width: Option<Width>,
    floating: bool,
    hidden: bool,
    /// Shelving order (also the original left-to-right order within one hide).
    seq: u64,
    /// It was in the pinned column: it goes back there if the pin is still around.
    pinned: bool,
}

/// Everything one virtual desktop owns. The ACTIVE desktop's copy lives in the `Engine` fields themselves
/// (`st`, `undo`, `redo`, `last_tiled`, `history`); the others are parked in `Engine::others`.
#[derive(Default)]
struct Desk {
    st: State,
    undo: Vec<(Entry, &'static str)>,
    redo: Vec<(Entry, &'static str)>,
    last_tiled: Option<u32>,
    history: Vec<u32>,
}

/// One undo step: the state before the change of every desktop it touched (usually just one;
/// `move_to_desktop` touches the source and the target), and the pinned column before it if the step changed the pin.
#[derive(Default)]
struct Entry {
    desks: Vec<(usize, State)>,
    pin: Option<Option<Pin>>,
}

/// What an event asks of the plan beyond the frames themselves.
#[derive(Default)]
struct Outcome {
    show_map: bool,
    emit_focus: bool,
    regather: bool,
    error: Option<String>,
    toast: Option<String>,
    /// Apply the frames without animation (desktop switch).
    jump: bool,
    /// The focus may move in the core's books but the OS is left where it is (a window an app in the background opened).
    keep_os_focus: bool,
    /// The frame a user resize reported: the plan re-writes that window if its final frame differs.
    resized: Option<(u32, Rect)>,
}

pub struct Engine {
    cfg: Config,
    display: Option<Rect>,
    windows: BTreeMap<u32, WinInfo>,
    /// Minimized / hidden windows (not in `windows`, not in any layout).
    shelf: BTreeMap<u32, Shelved>,
    shelf_seq: u64,
    st: State,
    /// Snapshots paired with the label of the command that produced the change (for toasts). Per desktop.
    undo: Vec<(Entry, &'static str)>,
    redo: Vec<(Entry, &'static str)>,
    /// Active desktop (0-based) and the parked state of all the others (the active slot is an unused placeholder).
    desk: usize,
    others: Vec<Desk>,
    /// Desktop we came from, for `switch_desktop_back`.
    prev_desk: Option<usize>,
    /// Window whose resize drag owns the newest undo entry: more resize events for it join that entry.
    resizing: Option<u32>,
    last: BTreeMap<u32, PlanFrame>,
    /// Most recently focused tiled window: the anchor while a floating window has focus.
    last_tiled: Option<u32>,
    /// Focus history, most recent first (the current window is first). Feeds `focus_previous`.
    history: Vec<u32>,
    /// Minimum widths learned from refusals (the window stayed wider than planned). A stacked or tabbed column is at least
    /// as wide as the largest floor among its members. Forgotten when a window leaves a multi-window column.
    min_w: BTreeMap<u32, f64>,
    /// Heights apps refused to go below while stacked (a stack must give each at least this; forgotten with `min_w`).
    min_h: BTreeMap<u32, f64>,
    /// Consecutive too-tall refusals per window: a single one may be a stale reading mid-resize, a repeat is a floor.
    h_refusals: BTreeMap<u32, u8>,
    /// Windows that were in a multi-window column at the last sweep (to notice who left).
    in_multi: BTreeSet<u32>,
    /// The display's pinned column.
    pin: Option<Pin>,
    /// A pin waiting to come back: the display got too narrow for it, or its last window was minimized or hidden. It pins
    /// the column of the first of its windows that is back in a ribbon, once there is room.
    pin_memo: Option<Pin>,
    /// Width and every-desktop choice the next pin starts with (the last ones used). Only the Plus edition reads it.
    #[cfg_attr(not(feature = "plus"), allow(dead_code))]
    pin_pref: (f64, bool),
    /// What the newest add disturbed, for a replace that follows it at once (see `replace_window`). Any other event drops it.
    add_memo: Option<AddMemo>,
    /// Where the viewport was when the current trackpad gesture began: `scroll_end` tells a swipe that moved on from one that
    /// came back. Any event that is not part of a gesture drops it.
    swipe_from: Option<f64>,
}

/// The state a window's add changed besides adding it: what a native tab's replace gives back when its add came first.
struct AddMemo {
    id: u32,
    desk: usize,
    last_tiled: Option<u32>,
    scroll: f64,
    /// The tab group the add joined: its first window and its shown tab before the add.
    tab: Option<(u32, Option<u32>)>,
}

impl Engine {
    pub fn new(cfg: Config) -> Engine {
        Engine {
            cfg: cfg.sanitized(),
            display: None,
            windows: BTreeMap::new(),
            shelf: BTreeMap::new(),
            shelf_seq: 0,
            st: State::default(),
            undo: vec![],
            redo: vec![],
            desk: 0,
            others: (0..DESKTOPS).map(|_| Desk::default()).collect(),
            prev_desk: None,
            resizing: None,
            last: BTreeMap::new(),
            last_tiled: None,
            history: vec![],
            min_w: BTreeMap::new(),
            min_h: BTreeMap::new(),
            h_refusals: BTreeMap::new(),
            in_multi: BTreeSet::new(),
            pin: None,
            pin_memo: None,
            pin_pref: (0.25, true),
            add_memo: None,
            swipe_from: None,
        }
    }

    /// Parse one event JSON and handle it. Bad JSON yields an error plan, never a panic.
    pub fn handle_json(&mut self, json: &str) -> Plan {
        match serde_json::from_str::<Event>(json) {
            Ok(ev) => self.handle(ev),
            Err(e) => Plan::error(format!("bad event: {e}")),
        }
    }

    // ---- read-only accessors (tests, sim) ----
    pub fn state(&self) -> &State {
        &self.st
    }
    pub fn focused(&self) -> Option<u32> {
        self.st.focus
    }
    pub fn window_count(&self) -> usize {
        self.windows.len()
    }
    pub fn undo_len(&self) -> usize {
        self.undo.len()
    }
    pub fn pin(&self) -> Option<&Pin> {
        self.pin.as_ref()
    }
    /// Active desktop, 1-based.
    /// `(id, pid, app, title, floating)` of every known window (tests rebuild an engine from it).
    pub fn window_infos(&self) -> Vec<(u32, i32, String, String, bool)> {
        let floating: BTreeSet<u32> = (0..DESKTOPS).flat_map(|d| self.desk_state(d).floating.iter().copied().collect::<Vec<_>>()).collect();
        self.windows.iter().map(|(id, w)| (*id, w.pid, w.app.clone(), w.title.clone(), floating.contains(id))).collect()
    }

    pub fn desktop(&self) -> usize {
        self.desk + 1
    }
    /// Window ids (tiled, pinned and floating) per desktop, sorted, from the desktops' own layouts.
    pub fn desktop_windows(&self) -> Vec<Vec<u32>> {
        (0..DESKTOPS)
            .map(|d| {
                let mut v = self.desk_ids(d);
                v.sort_unstable();
                v
            })
            .collect()
    }

    /// Windows on desktop `d`: tiled in column order, then the pinned column if it is there, then floating (ascending).
    fn desk_ids(&self, d: usize) -> Vec<u32> {
        let st = self.desk_state(d);
        let pinned = self.pin.iter().filter(|p| p.desk == d).flat_map(|p| p.col.windows.iter().copied());
        st.columns.iter().flat_map(|c| c.windows.iter().copied()).chain(pinned).chain(st.floating.iter().copied()).collect()
    }

    pub fn handle(&mut self, ev: Event) -> Plan {
        let mut out = Outcome::default();
        let focus_before = self.st.focus;
        // A replace that follows its add undoes what the add did; anything else the window or the user does in between makes that stale.
        let memo_id = self.add_memo.as_ref().map(|m| m.id);
        if !matches!(&ev, Event::Query | Event::WindowAdded { .. } | Event::WindowReplaced { .. } | Event::WindowTitle { .. } | Event::WindowResized { .. })
            && !matches!(&ev, Event::WindowFocused { id } if Some(*id) == memo_id)
        {
            self.add_memo = None;
        }
        if !matches!(&ev, Event::ScrollBy { .. } | Event::ScrollTo { .. } | Event::ScrollEnd { .. } | Event::Query | Event::Snapshot) {
            self.swipe_from = None;
        }
        // The OS moves focus itself for these two (a replaced tab is already the key window); only our own changes ask for it.
        let os_focus = matches!(ev, Event::WindowFocused { .. } | Event::WindowReplaced { .. });
        let mut session = None;
        let tabs_before = self.active_tabs();
        let bands_before: Vec<Option<Rect>> = (0..DESKTOPS).map(|d| self.band_on(d)).collect();
        match ev {
            Event::Display { frame, .. } => {
                if self.display != Some(frame) {
                    self.display = Some(frame);
                    self.fit_pin();
                    self.reveal();
                    out.show_map = true;
                }
            }
            Event::WindowAdded { id, pid, app, title, floating, width_hint, take_focus, .. } => {
                out.keep_os_focus = !take_focus;
                if let Some(s) = self.shelf.get_mut(&id) {
                    (s.app, s.title) = (app, title);
                    self.unshelve(&[id], Some(id), take_focus, &mut out);
                } else {
                    self.add_window(id, WinInfo { pid, app, title, desk: self.desk }, floating, width_hint, take_focus);
                }
                // A window joining quietly has nothing to announce: the map would only flash over what the user is doing.
                out.show_map = take_focus;
            }
            Event::WindowRemoved { id } => {
                out.show_map = self.remove_window(id);
            }
            Event::WindowReplaced { old, new, pid, app, title } => {
                // The new tab is written in place: nothing glides, and the HUD has nothing to announce.
                out.jump = self.replace_window(old, new, pid, app, title);
            }
            Event::WindowMinimized { id } => {
                out.show_map = self.shelve(id, false);
            }
            Event::AppHidden { pid } => {
                out.show_map = self.hide_app(pid);
            }
            Event::AppShown { pid, front, take_focus } => {
                let mut ids: Vec<(u64, u32)> = self.shelf.iter().filter(|(_, s)| s.hidden && s.pid == pid).map(|(id, s)| (s.seq, *id)).collect();
                ids.sort_unstable();
                let ids: Vec<u32> = ids.into_iter().map(|(_, id)| id).collect();
                out.keep_os_focus = !take_focus;
                if !ids.is_empty() {
                    self.unshelve(&ids, front, take_focus, &mut out);
                }
            }
            Event::WindowFocused { id } => {
                if let Some(d) = self.windows.get(&id).map(|w| w.desk).filter(|d| *d != self.desk) {
                    // The OS focused a window on another desktop (⌘Tab, Dock): follow it.
                    self.go_to(d, &mut out);
                    self.st.focus = Some(id);
                    self.reveal();
                } else if self.windows.contains_key(&id) && self.st.focus != Some(id) {
                    self.st.focus = Some(id);
                    self.reveal();
                    out.show_map = true;
                }
            }
            Event::WindowTitle { id, title } => {
                if let Some(w) = self.windows.get_mut(&id) {
                    w.title = title;
                }
            }
            Event::WindowResized { id, frame } => {
                let before = self.st.clone();
                let pin_before = self.pin.clone();
                if !self.resize_pinned(id, frame) {
                    self.adopt_width(id, frame.w);
                    self.adopt_height(id, frame.h);
                }
                out.resized = Some((id, frame));
                // A drag streams many events: they all belong to one undo step.
                if (self.st != before || self.pin != pin_before) && self.resizing != Some(id) {
                    let pin = (self.pin != pin_before).then_some(pin_before);
                    self.push_undo_entry(Entry { desks: vec![(self.desk, before)], pin }, "resize");
                    self.redo.clear();
                    self.resizing = Some(id);
                }
            }
            Event::WindowRefused { id, frame } => {
                let toast = match self.refuse_pinned(id, frame) {
                    Some(toast) => toast,
                    None => self.adopt_refused(id, frame),
                };
                if let Some(t) = toast {
                    out.toast = Some(t);
                }
                out.show_map = false;
            }
            Event::Command { name, arg } => self.command(&name, arg.as_ref(), &mut out),
            Event::ScrollBy { dx } => {
                self.scroll_by(dx);
                out.show_map = true;
            }
            Event::ScrollTo { id, x } => self.scroll_window_to(id, x),
            Event::ScrollEnd { velocity } => {
                self.scroll_end(velocity.unwrap_or(0.0));
                out.show_map = true;
            }
            Event::Query => {}
            Event::Snapshot => session = Some(self.snapshot()),
            Event::RestoreSession { active, desktops, pin } => self.restore_session(active, &desktops, pin.as_ref(), &mut out),
        }
        self.fit_pin();
        // The pin came, went or changed width (or the display changed): every ribbon beside it settles into its new band. And
        // a column an app held wider than its own width takes that back once its band gives it as much, whatever brought the
        // two together: a band change, undo or redo, a pin folding away or taken over on the same side, a width toggled back.
        // Within the band it was held in, a hold never releases (the app refused more than ECHO_PX past its own width).
        for d in 0..DESKTOPS {
            let moved = self.band_on(d) != bands_before[d];
            let st = if d == self.desk { &self.st } else { &self.others[d].st };
            if moved || st.columns.iter().any(|c| c.held.is_some()) {
                self.on_desk(d, |e| {
                    if e.release_held() || moved {
                        e.reveal();
                    }
                });
            }
        }
        self.sane_focus();
        self.sync_tabs();
        self.enforce_floors();
        // A different tab became the shown one: swap the windows without gliding them across the screen.
        out.jump |= self.active_tabs() != tabs_before;
        // The OS already moved focus for window_focused; every other focus change is ours to ask for.
        out.emit_focus |= self.st.focus != focus_before && !os_focus && !out.keep_os_focus;
        if self.cursor().is_some() {
            self.last_tiled = self.st.focus;
        }
        if let Some(f) = self.st.focus.filter(|f| self.history.first() != Some(f)) {
            self.history.retain(|h| *h != f);
            self.history.insert(0, f);
        }
        let mut plan = self.plan(out);
        plan.session = session;
        plan
    }

    /// Keep `min_w` honest and make every multi-window column at least as wide as its widest member's floor.
    fn enforce_floors(&mut self) {
        if self.min_w.is_empty() && self.min_h.is_empty() && self.in_multi.is_empty() {
            return;
        }
        let multi: BTreeSet<u32> = self.st.columns.iter().filter(|c| c.windows.len() >= 2).flat_map(|c| c.windows.iter().copied()).collect();
        let tiled: BTreeSet<u32> = self.st.columns.iter().flat_map(|c| c.windows.iter().copied()).collect();
        for id in self.in_multi.iter().filter(|id| tiled.contains(id) && !multi.contains(id)) {
            self.min_w.remove(id);
            self.min_h.remove(id);
            self.h_refusals.remove(id);
        }
        self.min_w.retain(|id, _| self.windows.contains_key(id));
        self.min_h.retain(|id, _| self.windows.contains_key(id));
        self.h_refusals.retain(|id, _| self.windows.contains_key(id));
        self.in_multi = multi;
        let avail = self.avail();
        let mut changed = false;
        for c in 0..self.st.columns.len() {
            if self.st.columns[c].windows.len() < 2 {
                continue;
            }
            let floor = self.floor_of(c, None);
            let cur = layout::width_px(self.st.columns[c].width, &self.cfg, avail);
            if floor > cur + ECHO_PX {
                self.st.columns[c].hold_at(floor.min(avail).round());
                self.st.columns[c].restore = None;
                changed = true;
            }
        }
        if changed {
            self.reveal();
        }
    }

    /// Every column an app holds wider than its own width goes back to that width where the band now gives it as much.
    /// Returns whether one did.
    fn release_held(&mut self) -> bool {
        let avail = self.avail();
        let mut any = false;
        for col in &mut self.st.columns {
            let was = col.width;
            col.release(&self.cfg, avail);
            any |= col.width != was;
        }
        any
    }

    /// Largest learned floor in column `c`, leaving out `skip`.
    fn floor_of(&self, c: usize, skip: Option<u32>) -> f64 {
        self.st.columns[c].windows.iter().filter(|w| Some(**w) != skip).filter_map(|w| self.min_w.get(w)).fold(0.0, |a, b| a.max(*b))
    }

    // ---- tabs ----
    /// Keep tab state canonical: a column with fewer than two windows is never tabbed, and a tabbed column's active tab
    /// is the focused window when the focus is inside it (else the remembered one, else the first).
    fn sync_tabs(&mut self) {
        let focus = self.st.focus;
        let sync = |col: &mut Column| {
            if col.windows.len() < 2 {
                col.tabbed = false;
            }
            if !col.tabbed {
                col.active = None;
            } else if let Some(f) = focus.filter(|f| col.windows.contains(f)) {
                col.active = Some(f);
            } else if !col.active.is_some_and(|a| col.windows.contains(&a)) {
                col.active = Some(col.windows[0]);
            }
        };
        self.st.columns.iter_mut().for_each(sync);
        if let Some(p) = self.pin.as_mut() {
            sync(&mut p.col);
        }
    }

    /// The shown window of every tabbed column of the active desktop (the pinned one included).
    fn active_tabs(&self) -> Vec<u32> {
        let pinned = self.pin.iter().filter(|p| p.desk == self.desk).map(|p| &p.col);
        self.st.columns.iter().chain(pinned).filter(|c| c.is_tabbed()).map(|c| c.windows[c.active_index()]).collect()
    }

    // ---- helpers ----
    /// Usable width of the active desktop's ribbon (next to the pin, if it shows here).
    fn avail(&self) -> f64 {
        match (self.display, self.band_on(self.desk)) {
            (Some(d), Some(b)) => layout::band_width(&self.cfg, &d, &b),
            _ => 1.0,
        }
    }
    fn spans(&self) -> Vec<(f64, f64)> {
        layout::spans(&self.st.columns, &self.cfg, self.avail())
    }
    fn pos(&self, id: u32) -> Option<(usize, usize)> {
        self.st.columns.iter().enumerate().find_map(|(c, col)| {
            col.windows.iter().position(|w| *w == id).map(|r| (c, r))
        })
    }
    fn cursor(&self) -> Option<(usize, usize)> {
        self.st.focus.and_then(|f| self.pos(f))
    }

    /// The focused tiled position, or (while a floating window has focus) the last tiled one.
    fn anchor(&self) -> Option<(usize, usize)> {
        self.cursor().or_else(|| self.last_tiled.and_then(|id| self.pos(id)))
    }

    /// Scroll so the anchor column is shown per the scroll mode; always keeps scroll within the content. Next to a pin the
    /// ribbon only rests where a column edge meets the pin, and focusing the pin never scrolls it.
    fn reveal(&mut self) {
        if self.display.is_none() {
            return;
        }
        let (s, avail) = (self.spans(), self.avail());
        if let Some(scroll) = self.pin_reveal(&s, avail, self.anchor().map(|(c, _)| c), self.cfg.scroll) {
            self.st.scroll = scroll;
            return;
        }
        self.st.scroll = match self.anchor() {
            Some((c, _)) => layout::reveal(&s, c, self.st.scroll, self.cfg.scroll, avail),
            None => self.st.scroll.clamp(0.0, (layout::content_width(&s) - avail).max(0.0)),
        };
    }

    /// Trackpad scroll: move the viewport by `dx` px. Focus and undo are untouched. Inside the content the
    /// viewport follows 1:1; pushing past either end is resisted (rubber band, at most `OVERSCROLL_PX`).
    fn scroll_by(&mut self, dx: f64) {
        if self.display.is_none() || self.st.columns.is_empty() || !dx.is_finite() {
            return;
        }
        self.swipe_from.get_or_insert(self.st.scroll);
        let (lo, hi) = self.scroll_bounds();
        let (mut s, mut d) = (self.st.scroll, dx);
        // Full rate while moving through (or back into) the content; what is left past an end is resisted.
        let edge = if d > 0.0 { hi } else { lo };
        if (d > 0.0 && s < edge) || (d < 0.0 && s > edge) {
            let used = d.abs().min((edge - s).abs()) * d.signum();
            s += used;
            d -= used;
        }
        s += d * OVERSCROLL_RESIST;
        self.st.scroll = s.clamp(lo - OVERSCROLL_PX, hi + OVERSCROLL_PX);
    }

    /// The viewport at exactly `x` px: unresisted, but within the rubber band's reach like any scroll.
    fn set_scroll(&mut self, x: f64) {
        if self.display.is_none() || self.st.columns.is_empty() || !x.is_finite() {
            return;
        }
        self.swipe_from.get_or_insert(self.st.scroll);
        let (lo, hi) = self.scroll_bounds();
        self.st.scroll = x.clamp(lo - OVERSCROLL_PX, hi + OVERSCROLL_PX);
    }

    /// Scrolls so the tiled window `id` sits at logical x `x`, as a plan frame's `lx` reports it (the column's left edge, which
    /// the ribbon places at `band start + outer gap - scroll`, rounded, plus the column's rounded offset).
    fn scroll_window_to(&mut self, id: u32, x: f64) {
        let (Some((c, _)), Some(d), Some(band)) = (self.pos(id), self.display, self.band_on(self.desk)) else { return };
        let left = self.spans()[c].0.round();
        self.set_scroll(band.x + layout::outer_gap(&self.cfg, &d) - (x - left));
    }

    /// The offsets the viewport rests at when it settles: beside a pin where a column edge meets it; with `center`, with a
    /// column centred; otherwise at a column start, or where the content's end meets the band's end.
    fn rests(&self, spans: &[(f64, f64)], avail: f64) -> Vec<f64> {
        match self.pin_rests(spans, avail) {
            Some(rest) => rest,
            None if self.cfg.scroll == ScrollMode::Center => layout::center_rest_offsets(spans, avail),
            None => layout::free_rest_offsets(spans, avail, COMMIT_MIN_PX),
        }
    }

    /// The range the viewport may rest in: the content, or its first and last rest offsets next to a pin and with `center`
    /// (the first and last column centred, which reach past the content).
    fn scroll_bounds(&self) -> (f64, f64) {
        let (s, avail) = (self.spans(), self.avail());
        match self.pin_rests(&s, avail) {
            Some(r) => (r.iter().copied().fold(f64::INFINITY, f64::min), r.iter().copied().fold(f64::NEG_INFINITY, f64::max)),
            None if self.cfg.scroll == ScrollMode::Center && !s.is_empty() => (layout::center_scroll(&s, 0, avail), layout::center_scroll(&s, s.len() - 1, avail)),
            None => (0.0, (layout::content_width(&s) - avail).max(0.0)),
        }
    }

    /// Fingers lifted: the viewport settles on a rest and the column nearest the middle of what is whole in view gets focus.
    /// Slower than `COMMIT_PX_S`, or having moved under `COMMIT_MIN_PX` from the rest behind, it comes to rest nearest where its
    /// momentum (`FLING_PROJECT_S` ahead) would stop it; a flick pages on to the next rest in its direction at least, and
    /// further when the momentum reaches it. A pin that had focus keeps it.
    fn scroll_end(&mut self, velocity: f64) {
        if self.display.is_none() || self.st.columns.is_empty() {
            return;
        }
        let v = if velocity.is_finite() { velocity.clamp(-MAX_FLING_PX_S, MAX_FLING_PX_S) } else { 0.0 };
        let (spans, avail) = (self.spans(), self.avail());
        let (from, release) = (self.swipe_from.take(), self.st.scroll);
        let rest = self.rests(&spans, avail);
        self.st.scroll = settle_scroll(&rest, release, v);
        if self.pin_scroll_end(&spans, avail) {
            return;
        }
        let to = self.st.scroll;
        let c = match self.cfg.scroll {
            ScrollMode::Center => {
                let off = |i: usize| (layout::center_scroll(&spans, i, avail) - to).abs();
                (0..spans.len()).min_by(|a, b| off(*a).total_cmp(&off(*b))).unwrap_or(0)
            }
            _ => {
                let tied = nearest_columns(&spans, to + avail / 2.0, to, avail, TIE_PX);
                let at = |end: Option<f64>| end.is_some_and(|r| (r - to).abs() < 0.5);
                // Equally near (every pair of half-width columns is): a swipe that went somewhere focuses the side it went
                // towards; one that came back to where it began keeps its column, so a nudge never flips focus. Otherwise
                // the first column at the ribbon's start, the last at its end, else the side the release was heading to.
                let travel = from.map(|f| to - f).filter(|d| d.abs() > 0.5);
                let cursor = self.cursor().map(|(c, _)| c).filter(|c| tied.contains(c));
                match (travel, cursor) {
                    (Some(d), _) if d > 0.0 => tied[tied.len() - 1],
                    (Some(_), _) => tied[0],
                    (None, Some(c)) => c,
                    (None, None) if at(rest.iter().copied().reduce(f64::min)) => tied[0],
                    (None, None) if at(rest.iter().copied().reduce(f64::max)) => tied[tied.len() - 1],
                    (None, None) if to > release + 0.5 || (to > release - 0.5 && v > 0.0) => tied[tied.len() - 1],
                    (None, None) => tied[0],
                }
            }
        };
        let row = self.cursor().filter(|(cc, _)| *cc == c).map_or(0, |(_, r)| r);
        // The column is whole in view at the rest already: revealing it would only let the scroll mode move the ribbon off
        // the rest (`center_on_overflow` centres a column that exactly fills the display, by a rounding error's worth of overflow).
        self.focus_col_in_place(c, row);
    }

    fn focus_col(&mut self, c: usize, row: usize) {
        self.focus_col_in_place(c, row);
        self.reveal();
    }

    /// Focuses column `c` (row `row`, or its active tab when entering a tabbed column) without scrolling.
    fn focus_col_in_place(&mut self, c: usize, row: usize) {
        // Entering a tabbed column from elsewhere lands on its active tab, not on a row number.
        let row = if self.st.columns[c].is_tabbed() && self.cursor().map(|(cc, _)| cc) != Some(c) { self.st.columns[c].active_index() } else { row };
        let ws = &self.st.columns[c].windows;
        self.st.focus = Some(ws[row.min(ws.len() - 1)]);
    }

    /// Focus fallback when the focused window is gone: first visible column, else a floating window.
    fn fallback_focus(&self) -> Option<u32> {
        let s = self.spans();
        let avail = self.avail();
        let vis = s
            .iter()
            .position(|(l, w)| layout::span_visible(*l, *w, self.st.scroll, avail))
            .or((!s.is_empty()).then_some(0));
        vis.map(|c| self.st.columns[c].windows[0])
            .or_else(|| self.st.floating.iter().next().copied())
            .or_else(|| self.pin.as_ref().filter(|p| p.desk == self.desk).map(|p| p.col.windows[p.col.active_index()]))
    }

    /// Width for a new column: the app's hint (from the host, else config) snapped to the nearest preset.
    fn new_column_width(&self, app: &str, hint: Option<f64>) -> Width {
        let hint = hint.or_else(|| self.cfg.app_widths.get(app).copied()).filter(|f| *f > 0.0 && *f <= 1.0);
        let nearest = hint.and_then(|h| {
            self.cfg.width_presets.iter().copied().min_by(|a, b| (a - h).abs().total_cmp(&(b - h).abs()))
        });
        Width::Frac(nearest.unwrap_or(self.cfg.default_width))
    }

    /// Puts a new column right of the anchor (else at the end) and returns its index.
    fn insert_column(&mut self, col: Column) -> usize {
        let at = match (self.cfg.new_window, self.anchor()) {
            (NewWindow::RightOfFocused, Some((c, _))) => c + 1,
            _ => self.st.columns.len(),
        };
        self.st.columns.insert(at, col);
        at
    }

    /// A column went in at `at` without taking focus. One that landed left of the viewport (or at its edge) pushes the scroll
    /// along by its width, so the columns in view stay exactly where they are on screen; anywhere else the viewport is left
    /// alone. Beside a pin the ribbon may only rest on a column edge, so the scroll settles on the nearest one (a ribbon
    /// narrower than its band rests against the pin, so a column added at its end moves the others to make room).
    fn hold_view(&mut self, at: usize) {
        if self.display.is_none() {
            return;
        }
        let s = self.spans();
        if at + 1 < s.len() && s[at].0 <= self.st.scroll + 0.5 {
            self.st.scroll += s[at].1 + self.cfg.gap;
        }
        if let Some(scroll) = self.pin_reveal(&self.spans(), self.avail(), None, self.cfg.scroll) {
            self.st.scroll = scroll;
        }
    }

    // ---- window events ----
    /// `take_focus` false is a window an app in the background opened: it joins where it would go, but focus, the shown tab
    /// and the viewport stay as they are (see `hold_view`).
    fn add_window(&mut self, id: u32, info: WinInfo, floating: bool, hint: Option<f64>, take_focus: bool) {
        let width = self.new_column_width(&info.app, hint);
        if let Some(w) = self.windows.get_mut(&id) {
            (w.app, w.title) = (info.app, info.title); // duplicate add: just refresh metadata
            return;
        }
        let tab = self.anchor().filter(|_| self.cfg.new_window == NewWindow::RightOfFocused && !floating && !self.focus_pinned())
            .map(|(c, _)| &self.st.columns[c]).filter(|c| c.is_tabbed()).map(|c| (c.windows[0], c.active));
        self.add_memo = Some(AddMemo { id, desk: self.desk, last_tiled: self.last_tiled, scroll: self.st.scroll, tab });
        self.windows.insert(id, info);
        if floating {
            self.st.floating.insert(id);
            if take_focus {
                self.st.focus = self.st.focus.or(Some(id));
            }
        } else if let Some((c, r)) = self.anchor().filter(|(c, _)| self.cfg.new_window == NewWindow::RightOfFocused && self.st.columns[*c].is_tabbed() && !self.focus_pinned()) {
            // A window opened next to a tabbed column becomes its newest tab (right after the active one) and shows.
            let col = &mut self.st.columns[c];
            col.windows.insert(r + 1, id);
            col.reset_heights();
            if take_focus {
                col.active = Some(id);
                self.st.focus = Some(id);
                self.reveal();
            }
        } else {
            let at = self.insert_column(Column::new(id, width));
            if take_focus {
                self.st.focus = Some(id);
                self.reveal();
            } else {
                self.hold_view(at);
            }
        }
    }

    /// Returns whether anything was removed.
    fn remove_window(&mut self, id: u32) -> bool {
        let Some(w) = self.windows.remove(&id) else { return self.shelf.remove(&id).is_some() };
        self.on_desk(w.desk, |e| e.detach(id));
        true
    }

    /// A native tab switch: `new` takes over everything `old` had (slot, width, stack / tab-group membership, desktop, float
    /// mode, focus, focus history, undo entries, learned size floors). A `new` already in the core (its add came first) gives up
    /// its own slot, and the focus its add took goes back to whoever had it. Returns whether anything changed.
    fn replace_window(&mut self, old: u32, new: u32, pid: i32, app: String, title: String) -> bool {
        let Some(desk) = self.windows.get(&old).map(|w| w.desk) else { return false };
        if old == new {
            self.windows.insert(new, WinInfo { pid, app, title, desk });
            return false;
        }
        if let Some(dup) = self.windows.remove(&new) {
            let memo = self.add_memo.take().filter(|m| m.id == new && m.desk == dup.desk);
            self.on_desk(dup.desk, |e| {
                let was_focused = e.st.focus == Some(new);
                let before = e.history.iter().copied().find(|h| *h != new);
                // What its add disturbed besides the focus: the tab it took over in a tab group, the tiled anchor (a floating
                // window may have the focus) and the viewport.
                let tab_of = e.pos(new).map(|(c, _)| c).filter(|c| e.st.columns[*c].active == Some(new) && e.st.columns[*c].windows.len() > 1);
                let anchored = e.last_tiled == Some(new);
                e.detach(new);
                if let Some(c) = tab_of {
                    let col = &mut e.st.columns[c];
                    let shown = memo.as_ref().and_then(|m| m.tab).filter(|(first, _)| col.windows.first() == Some(first)).map(|(_, a)| a);
                    col.active = shown.unwrap_or_else(|| e.history.iter().copied().find(|h| col.windows.contains(h)));
                }
                if let Some(m) = memo.as_ref().filter(|_| anchored) {
                    e.last_tiled = m.last_tiled;
                }
                if let Some(b) = before.filter(|b| was_focused && e.st.focus != Some(*b) && (e.pos(*b).is_some() || e.st.floating.contains(b) || e.pinned(*b))) {
                    e.st.focus = Some(b);
                    e.reveal();
                }
                if let Some(m) = &memo {
                    e.st.scroll = m.scroll;
                }
            });
        }
        self.shelf.remove(&new);
        self.windows.remove(&old);
        self.windows.insert(new, WinInfo { pid, app, title, desk });
        self.on_desk(desk, |e| {
            e.st.swap_id(old, new);
            e.last_tiled = e.last_tiled.map(|t| if t == old { new } else { t });
            e.history.iter_mut().filter(|h| **h == old).for_each(|h| *h = new);
        });
        // The pinned column (or the memo of one that lost its last window) and the pins in undo / redo entries may hold it too.
        let mut pins = vec![self.pin.as_mut(), self.pin_memo.as_mut()];
        // Undo / redo entries of every desktop may name it (a sent window's entry holds two desktops).
        let stacks = self.undo.iter_mut().chain(self.redo.iter_mut()).chain(self.others.iter_mut().flat_map(|d| d.undo.iter_mut().chain(d.redo.iter_mut())));
        for (entry, _) in stacks {
            entry.desks.iter_mut().for_each(|(_, st)| st.swap_id(old, new));
            pins.push(entry.pin.as_mut().and_then(|p| p.as_mut()));
        }
        pins.into_iter().flatten().for_each(|p| p.swap_id(old, new));
        if self.resizing == Some(old) {
            self.resizing = Some(new);
        }
        for floors in [&mut self.min_w, &mut self.min_h] {
            if let Some(v) = floors.remove(&old) {
                floors.insert(new, v);
            }
        }
        if let Some(v) = self.h_refusals.remove(&old) {
            self.h_refusals.insert(new, v);
        }
        if self.in_multi.remove(&old) {
            self.in_multi.insert(new);
        }
        true
    }

    /// Takes a window out of the ribbon but remembers it (desktop, width, mode). Returns whether it was known.
    fn shelve(&mut self, id: u32, hidden: bool) -> bool {
        let pinned = self.pinned(id);
        let Some(w) = self.windows.remove(&id) else { return false };
        let (floating, width) = self.on_desk(w.desk, |e| e.detach(id));
        self.shelf_seq += 1;
        self.shelf.insert(id, Shelved { pid: w.pid, app: w.app, title: w.title, desk: w.desk, width, floating, hidden, seq: self.shelf_seq, pinned });
        true
    }

    /// Shelves every window of `pid`, left to right per desktop (tiled in column order, then floating).
    fn hide_app(&mut self, pid: i32) -> bool {
        let mut ids = vec![];
        for d in 0..DESKTOPS {
            ids.extend(self.desk_ids(d));
        }
        ids.retain(|id| self.windows.get(id).is_some_and(|w| w.pid == pid));
        let mut any = false;
        for id in ids {
            any |= self.shelve(id, true);
        }
        any
    }

    /// Puts shelved windows back, in the given order: each on its remembered desktop, with its remembered width,
    /// next to that desktop's focused column. Then focuses `front` (else the last one) and switches to its desktop.
    /// `take_focus` false (the app brought them back while the user is in another one): the same places, in the same order,
    /// but focus, the shown tabs, the desktop and the viewport stay as they are (see `hold_view`).
    fn unshelve(&mut self, ids: &[u32], front: Option<u32>, take_focus: bool, out: &mut Outcome) {
        let mut placed = vec![];
        for &id in ids {
            let Some(s) = self.shelf.remove(&id) else { continue };
            if self.unshelve_into_pin(id, &s, take_focus) {
                placed.push(id);
                continue;
            }
            // Focus does not move on a quiet return, so the anchor does not either: the next window goes right of the last one back.
            let cols = &self.desk_state(s.desk).columns;
            let after = placed.iter().rev().find_map(|p| cols.iter().position(|c| c.windows.contains(p)));
            self.windows.insert(id, WinInfo { pid: s.pid, app: s.app, title: s.title, desk: s.desk });
            self.on_desk(s.desk, |e| {
                if s.floating {
                    e.st.floating.insert(id);
                    if let Some(w) = s.width {
                        e.st.float_widths.insert(id, w);
                    }
                } else {
                    let w = s.width.unwrap_or(Width::Frac(e.cfg.default_width));
                    let col = Column::new(id, w);
                    let at = match after.filter(|_| !take_focus) {
                        Some(c) => {
                            e.st.columns.insert(c + 1, col);
                            c + 1
                        }
                        None => e.insert_column(col),
                    };
                    if !take_focus {
                        e.hold_view(at);
                    }
                }
                if take_focus {
                    e.st.focus = Some(id);
                    e.reveal();
                }
            });
            placed.push(id);
        }
        if !take_focus {
            return;
        }
        let Some(target) = front.filter(|f| placed.contains(f)).or(placed.last().copied()) else { return };
        let d = self.windows[&target].desk;
        if d != self.desk {
            self.go_to(d, out);
        }
        self.st.focus = Some(target);
        self.reveal();
        out.show_map = true;
    }

    /// `toggle_float` for any window of the active desktop, one way only and without touching focus: a tiled window floats
    /// (its width kept for later), a floating one tiles at the end of the ribbon. Anything else is left alone.
    fn set_floating(&mut self, id: u32, on: bool) {
        match self.pos(id) {
            Some((c, r)) if on => {
                self.st.float_widths.insert(id, self.st.columns[c].width);
                self.st.columns[c].windows.remove(r);
                self.st.columns[c].reset_heights();
                if self.st.columns[c].windows.is_empty() {
                    self.st.columns.remove(c);
                }
                self.st.floating.insert(id);
            }
            None if !on && self.st.floating.remove(&id) => {
                let width = match self.st.float_widths.remove(&id) {
                    Some(w) => w,
                    None => {
                        let app = self.windows.get(&id).map(|w| w.app.clone()).unwrap_or_default();
                        self.new_column_width(&app, None)
                    }
                };
                self.st.columns.push(Column::new(id, width));
            }
            _ => {}
        }
    }

    /// Takes a window out of the active desktop's layout (focus moves to its neighbour, history forgets it).
    /// Returns whether it was floating and the column width it had (tiled) or remembered (floating).
    fn detach(&mut self, id: u32) -> (bool, Option<Width>) {
        let floating = self.st.floating.remove(&id);
        let mut width = self.st.float_widths.remove(&id);
        self.history.retain(|h| *h != id);
        let mut next = None;
        if let Some((c, r)) = self.pos(id) {
            width = Some(self.st.columns[c].width);
            let cols = &mut self.st.columns;
            cols[c].windows.remove(r);
            cols[c].reset_heights();
            if cols[c].windows.is_empty() {
                // Left neighbor, else the column that slid into this slot.
                cols.remove(c);
                let pick = |k: &Column| k.windows[r.min(k.windows.len() - 1)];
                next = c.checked_sub(1).map(|l| pick(&cols[l])).or_else(|| cols.get(c).map(pick));
            } else {
                next = Some(cols[c].windows[r.saturating_sub(1)]); // above, else below
            }
        } else if let Some(pin_next) = self.detach_from_pin(id) {
            next = pin_next;
        }
        if self.last_tiled == Some(id) {
            self.last_tiled = next;
        }
        if self.st.focus == Some(id) {
            self.st.focus = next.or_else(|| self.fallback_focus());
        }
        self.reveal();
        (floating, width)
    }

    /// Puts a window (already known to the engine) on the active desktop in its own column right of the
    /// focused one, first if the desktop is empty. Floating windows stay floating.
    fn attach(&mut self, id: u32, floating: bool, width: Option<Width>) {
        if floating {
            self.st.floating.insert(id);
            if let Some(w) = width {
                self.st.float_widths.insert(id, w);
            }
        } else {
            let w = width.unwrap_or(Width::Frac(self.cfg.default_width));
            let at = self.anchor().map_or(self.st.columns.len(), |(c, _)| c + 1);
            self.st.columns.insert(at, Column::new(id, w));
        }
        self.st.focus = self.st.focus.or(Some(id));
        self.reveal();
    }

    // ---- desktops ----
    fn desk_state(&self, d: usize) -> &State {
        if d == self.desk { &self.st } else { &self.others[d].st }
    }

    fn desk_len(&self, d: usize) -> usize {
        self.windows.values().filter(|w| w.desk == d).count()
    }

    /// Make desktop `d` the active one: its state, undo history and focus memory swap into the engine fields.
    fn switch_to(&mut self, d: usize) {
        if d == self.desk {
            return;
        }
        let next = std::mem::take(&mut self.others[d]);
        let cur = Desk {
            st: std::mem::replace(&mut self.st, next.st),
            undo: std::mem::replace(&mut self.undo, next.undo),
            redo: std::mem::replace(&mut self.redo, next.redo),
            last_tiled: std::mem::replace(&mut self.last_tiled, next.last_tiled),
            history: std::mem::replace(&mut self.history, next.history),
        };
        self.others[self.desk] = cur;
        self.desk = d;
    }

    /// Run `f` with desktop `d` temporarily active (for edits to a desktop the user is not looking at).
    fn on_desk<R>(&mut self, d: usize, f: impl FnOnce(&mut Engine) -> R) -> R {
        let (back, resizing) = (self.desk, self.resizing);
        self.switch_to(d);
        let r = f(self);
        self.switch_to(back);
        self.resizing = resizing;
        r
    }

    /// User-visible switch: remember where we came from, settle the scroll, toast, and jump (no glide).
    fn go_to(&mut self, d: usize, out: &mut Outcome) {
        let empty = if self.desk_len(d) == 0 { " · empty" } else { "" };
        self.prev_desk = Some(self.desk);
        self.switch_to(d);
        self.pin_follow();
        self.resizing = None;
        self.reveal();
        out.jump = true;
        out.show_map = true;
        out.toast = Some(format!("Desktop {}{empty}", d + 1));
    }

    fn desktop_command(&mut self, name: &str, arg: Option<&Value>, out: &mut Outcome) {
        let target = || -> Result<usize, String> {
            match arg.and_then(num) {
                Some(n) if (1..=DESKTOPS as u64).contains(&n) => Ok(n as usize - 1),
                _ => Err(format!("{name} needs a desktop number 1-{DESKTOPS}")),
            }
        };
        let to = match name {
            "switch_desktop_back" => match self.prev_desk {
                Some(d) => Ok(d),
                None => {
                    out.toast = Some("No previous desktop".into());
                    return;
                }
            },
            _ => target(),
        };
        let to = match to {
            Ok(d) => d,
            Err(e) => {
                out.show_map = false;
                out.error = Some(e);
                return;
            }
        };
        if to == self.desk {
            out.toast = Some(format!("Already on Desktop {}", to + 1));
            return;
        }
        if name != "move_to_desktop" {
            self.go_to(to, out);
            out.emit_focus = self.st.focus.is_some();
            return;
        }
        let Some(id) = self.st.focus else {
            out.toast = Some("Nothing to send".into());
            return;
        };
        if self.send_pin_to_desktop(to, out) {
            return;
        }
        let entry = Entry { desks: vec![(self.desk, self.st.clone()), (to, self.others[to].st.clone())], pin: None };
        let (floating, width) = self.detach(id);
        if let Some(w) = self.windows.get_mut(&id) {
            w.desk = to;
        }
        self.on_desk(to, |e| e.attach(id, floating, width));
        self.push_undo_entry(entry, "move to desktop");
        self.redo.clear();
        out.emit_focus = true;
        out.toast = Some(format!("Sent to Desktop {}", to + 1));
    }

    /// Make a tab group of the focused window and its neighbour column (`dir` -1 left, 1 right): the window joins that column
    /// as the newest tab (leftmost if the neighbour is on the right) and shows. One undo step.
    fn tab_with(&mut self, dir: i32) -> Result<(), String> {
        let Some((c, _)) = self.cursor() else { return Ok(()) };
        let t = if dir < 0 { c.checked_sub(1) } else { Some(c + 1) }.filter(|t| *t < self.st.columns.len());
        let Some(t) = t else { return Err("Nothing on that side".into()) };
        let id = self.st.focus.unwrap_or_default();
        let mut arg = serde_json::Map::new();
        arg.insert("id".into(), serde_json::json!(id));
        arg.insert("column".into(), serde_json::json!(t + 1));
        arg.insert("position".into(), serde_json::json!("tabs"));
        if dir > 0 {
            arg.insert("row".into(), serde_json::json!(0));
        }
        self.move_window_to(Some(&Value::Object(arg)))
    }

    /// "Tab group: Safari + Notes" for the focused column. Windows of the same app go by their titles instead
    /// ("Tab group: Inbox + Drafts"), so the toast always tells them apart.
    fn tab_group_label(&self) -> Option<String> {
        let (c, _) = self.cursor()?;
        let names = self.distinct_names(&self.st.columns[c].windows);
        let more = names.len().saturating_sub(3);
        let mut s = format!("Tab group: {}", names.iter().take(3).cloned().collect::<Vec<_>>().join(" + "));
        if more > 0 {
            s.push_str(&format!(" + {more} more"));
        }
        Some(s)
    }

    /// Short names for `ids`: the app name, or the window title (shortened) where that app appears more than once.
    fn distinct_names(&self, ids: &[u32]) -> Vec<String> {
        let app = |id: &u32| self.windows.get(id).map(|i| i.app.trim_start_matches('\u{200e}').to_string()).unwrap_or_default();
        let apps: Vec<String> = ids.iter().map(app).collect();
        ids.iter().zip(&apps).map(|(id, a)| {
            if apps.iter().filter(|x| *x == a).count() < 2 {
                return a.clone();
            }
            let t = self.windows.get(id).map(|i| i.title.trim().to_string()).unwrap_or_default();
            if t.is_empty() { a.clone() } else if t.chars().count() > 24 { format!("{}…", t.chars().take(23).collect::<String>()) } else { t }
        }).collect()
    }

    /// Adopt a user-dragged width as absolute px, snapping to a preset within 24px.
    fn adopt_width(&mut self, id: u32, w: f64) {
        let Some((c, _)) = self.pos(id) else { return };
        if w < 1.0 {
            return;
        }
        if self.display.is_none() {
            // Display unknown: keep the raw px; layout clamps it once the display arrives.
            let col = &mut self.st.columns[c];
            col.width = Width::Px(w.round());
            col.restore = None;
            return;
        }
        let avail = self.avail();
        let cur = layout::width_px(self.st.columns[c].width, &self.cfg, avail);
        let w = w.clamp(layout::MIN_COL_PX.max(0.2 * avail).min(avail), avail);
        if (w - cur).abs() <= ECHO_PX {
            return;
        }
        let snap = self.cfg.width_presets.iter().copied().find(|p| {
            (layout::width_px(Width::Frac(*p), &self.cfg, avail) - w).abs() <= SNAP_PX
        });
        let col = &mut self.st.columns[c];
        col.width = snap.map_or(Width::Px(w.round()), Width::Frac);
        col.restore = None;
        self.reveal();
    }

    /// An app that cannot take our size settled on `frame`: keep exactly that width (and height in a stack).
    /// Returns a toast when the column had to change shape (apps that cannot share the height become tabs).
    fn adopt_refused(&mut self, id: u32, frame: Rect) -> Option<String> {
        let (Some((c, r)), Some(d)) = (self.pos(id), self.display) else { return None };
        let avail = self.avail();
        if frame.w >= 1.0 {
            let cur = layout::width_px(self.st.columns[c].width, &self.cfg, avail);
            // Refusing to shrink makes this window's width a floor for its column; accepting (or growing) lifts it.
            if frame.w > cur + ECHO_PX {
                self.min_w.insert(id, frame.w.min(avail));
            } else {
                self.min_w.remove(&id);
            }
            let w = frame.w.max(self.floor_of(c, Some(id))).clamp(1.0, avail);
            if (w - cur).abs() > ECHO_PX {
                let col = &mut self.st.columns[c];
                if w > cur {
                    // It would not go narrower: held there, the column keeps its own width for a band that gives it room.
                    col.hold_at(w.round());
                } else {
                    (col.width, col.held) = (Width::Fixed(w.round()), None);
                }
                self.reveal();
            }
        }
        let n = self.st.columns[c].windows.len();
        if n >= 2 && frame.h >= 1.0 && !self.st.columns[c].is_tabbed() {
            let usable = layout::stack_px(layout::avail_height(&self.cfg, &d), n, &self.cfg);
            let cur = self.st.columns[c].shares()[r] * usable;
            if frame.h > cur + ECHO_PX {
                let k = self.h_refusals.entry(id).or_insert(0);
                *k = k.saturating_add(1);
                if *k >= 2 {
                    self.min_h.insert(id, frame.h);
                }
            } else {
                self.h_refusals.remove(&id);
            }
            // Apps whose minimum heights add up to more than the screen can never share it: every answer we give
            // one of them is refused by another (a write loop). Show them as tabs instead, each at full height.
            let floors: f64 = self.st.columns[c].windows.iter().filter_map(|w| self.min_h.get(w)).sum();
            if floors > usable + ECHO_PX {
                let col = &mut self.st.columns[c];
                col.tabbed = true;
                col.active = Some(id);
                let names: Vec<String> = col.windows.iter().filter_map(|w| self.windows.get(w).map(|i| i.app.trim_start_matches('\u{200e}').to_string())).collect();
                self.reveal();
                return Some(format!("{} don't fit stacked · shown as tabs", names.join(" and ")));
            }
            if (frame.h - cur).abs() > ECHO_PX {
                self.set_share(c, r, (frame.h / usable).clamp(0.02, 1.0 - (n as f64 - 1.0) * 0.02));
                self.respect_height_floors(c, usable);
            }
        }
        None
    }

    /// Raise every window of stack `c` to its learned minimum height, taking the difference from windows with room to
    /// spare (in proportion to that room). Only called when the floors fit.
    fn respect_height_floors(&mut self, c: usize, usable: f64) {
        let col = &self.st.columns[c];
        let mut h: Vec<f64> = col.shares().iter().map(|s| s * usable).collect();
        let floor: Vec<f64> = col.windows.iter().map(|w| self.min_h.get(w).copied().unwrap_or(0.0)).collect();
        let deficit: f64 = h.iter().zip(&floor).map(|(a, f)| (f - a).max(0.0)).sum();
        if deficit <= 0.5 {
            return;
        }
        let room: f64 = h.iter().zip(&floor).map(|(a, f)| (a - f).max(0.0)).sum();
        if room <= deficit {
            return;
        }
        for i in 0..h.len() {
            if h[i] < floor[i] {
                h[i] = floor[i];
            } else {
                h[i] -= deficit * (h[i] - floor[i]) / room;
            }
        }
        let total: f64 = h.iter().sum();
        self.st.columns[c].heights = Some(h.iter().map(|x| x / total).collect());
    }

    /// Adopt a user-dragged height for a window in a stack: clamped, snapped to a preset within 24px.
    fn adopt_height(&mut self, id: u32, h: f64) {
        let (Some((c, r)), Some(d)) = (self.pos(id), self.display) else { return };
        let n = self.st.columns[c].windows.len();
        if n < 2 || h < 1.0 || self.st.columns[c].is_tabbed() {
            return;
        }
        let avail_h = layout::avail_height(&self.cfg, &d);
        let usable = layout::stack_px(avail_h, n, &self.cfg);
        let min = layout::min_share(avail_h, n, &self.cfg);
        let cur = self.st.columns[c].shares()[r] * usable;
        if (h - cur).abs() <= ECHO_PX {
            return;
        }
        let share = (h / usable).clamp(min, 1.0 - (n as f64 - 1.0) * min);
        let share = HEIGHT_PRESETS
            .into_iter()
            .find(|p| (p - share).abs() * usable <= SNAP_PX && *p >= min && *p <= 1.0 - (n as f64 - 1.0) * min)
            .unwrap_or(share);
        self.set_share(c, r, share);
    }

    /// Give window `r` of column `c` this share; the others split the remainder equally.
    fn set_share(&mut self, c: usize, r: usize, share: f64) {
        let col = &mut self.st.columns[c];
        let n = col.windows.len();
        let rest = (1.0 - share) / (n as f64 - 1.0);
        let shares: Vec<f64> = (0..n).map(|i| if i == r { share } else { rest }).collect();
        let equal = 1.0 / n as f64;
        col.heights = (!shares.iter().all(|s| (s - equal).abs() < 1e-6)).then_some(shares);
    }

    /// Next height preset after the focused window's current share (wrapping), skipping presets
    /// the minimum-height clamp would collapse onto the current share.
    fn cycle_height(&mut self, c: usize, r: usize) {
        let Some(d) = self.display else { return };
        let n = self.st.columns[c].windows.len();
        let avail_h = layout::avail_height(&self.cfg, &d);
        let min = layout::min_share(avail_h, n, &self.cfg);
        let max = 1.0 - (n as f64 - 1.0) * min;
        let cur = self.st.columns[c].shares()[r];
        let after = HEIGHT_PRESETS.into_iter().filter(|p| *p > cur + 1e-3);
        let before = HEIGHT_PRESETS.into_iter().filter(|p| *p <= cur + 1e-3);
        let next = after.chain(before).map(|p| p.clamp(min, max)).find(|p| (p - cur).abs() > 1e-3);
        if let Some(p) = next {
            self.set_share(c, r, p);
        }
    }

    /// The focused window's share of its stack a little larger (smaller), within the same limits as `cycle_height`.
    fn nudge_height(&mut self, c: usize, r: usize, grow: bool) {
        let Some(d) = self.display else { return };
        let n = self.st.columns[c].windows.len();
        let min = layout::min_share(layout::avail_height(&self.cfg, &d), n, &self.cfg);
        let max = 1.0 - (n as f64 - 1.0) * min;
        let cur = self.st.columns[c].shares()[r];
        let want = if grow { (cur + NUDGE).min(max).max(cur) } else { (cur - NUDGE).max(min).min(cur) };
        if (want - cur).abs() > 1e-3 {
            self.set_share(c, r, want);
        }
    }

    // ---- pin plumbing ----
    // What the shared engine carries and tolerates of a pin. Everything that creates, places, moves, resizes, suspends,
    // restores or steps onto one is in `pin` (the Plus module, or its twin where none of it ever happens).
    fn pinned(&self, id: u32) -> bool {
        self.pin.as_ref().is_some_and(|p| p.col.windows.contains(&id))
    }

    /// The focused window is in the pinned column.
    fn focus_pinned(&self) -> bool {
        self.st.focus.is_some_and(|f| self.pinned(f))
    }

    /// Where desktop `d`'s ribbon plans: the whole display, or what the pin leaves of it (its width and one gap).
    fn band_on(&self, d: usize) -> Option<Rect> {
        let disp = self.display?;
        Some(match self.pin_inset(d) {
            Some((inset, from_left)) => layout::band(&disp, inset, from_left),
            None => disp,
        })
    }

    /// The active desktop's focus is one of its own windows (else its last tiled window, else the fallback), and its
    /// history names only windows on it.
    fn sane_focus(&mut self) {
        let desk = self.desk;
        if !self.st.focus.is_some_and(|f| self.windows.get(&f).is_some_and(|w| w.desk == desk)) {
            self.st.focus = self.last_tiled.filter(|t| self.pos(*t).is_some()).or_else(|| self.fallback_focus());
            self.reveal();
        }
        self.history.retain(|h| self.windows.get(h).is_some_and(|w| w.desk == desk));
    }

    /// Some layout holds the window: a desktop's columns or floating set, or the pin.
    fn placed(&self, id: u32) -> bool {
        self.pinned(id)
            || (0..DESKTOPS).any(|d| {
                let st = self.desk_state(d);
                st.floating.contains(&id) || st.columns.iter().any(|c| c.windows.contains(&id))
            })
    }

    // ---- commands ----
    fn command(&mut self, name: &str, arg: Option<&Value>, out: &mut Outcome) {
        out.show_map = true;
        match name {
            "undo" | "redo" => {
                out.toast = Some(self.undo_redo(name == "undo", out));
                out.emit_focus = true;
                return;
            }
            "set_width_presets" => {
                // Settings changed the width steps: take them live (no layout change, no undo step).
                let list: Vec<f64> = arg.and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_f64).collect()).unwrap_or_default();
                if list.is_empty() {
                    out.error = Some("set_width_presets needs a list of fractions".into());
                } else {
                    self.cfg = Config { width_presets: list, ..self.cfg.clone() }.sanitized();
                }
                out.show_map = false;
                return;
            }
            "set_scroll" => {
                // Focus mode switches to "center" (and back to the Settings choice) live: the focused column is
                // revealed under the new mode right away, so entering focus mode pulls the window to the middle.
                match arg.cloned().map(serde_json::from_value::<ScrollMode>) {
                    Some(Ok(mode)) => {
                        self.cfg = Config { scroll: mode, ..self.cfg.clone() }.sanitized();
                        self.reveal();
                    }
                    _ => out.error = Some("set_scroll needs \"keep_visible\", \"center\" or \"center_on_overflow\"".into()),
                }
                out.show_map = false;
                return;
            }
            "set_config" => {
                // Settings changed the gap, default width, placement or scroll mode: take them live over the layout as it is.
                // Stacks, tabs, widths, floating windows and the pin all stay; only what the new values move moves. Keys the
                // host leaves out keep their current values. No undo step: undo never brings back an old setting.
                let merged = match (serde_json::to_value(&self.cfg), arg) {
                    (Ok(Value::Object(mut cur)), Some(Value::Object(new))) => {
                        cur.extend(new.iter().map(|(k, v)| (k.clone(), v.clone())));
                        serde_json::from_value::<Config>(Value::Object(cur)).ok()
                    }
                    _ => None,
                };
                match merged {
                    Some(cfg) => {
                        self.cfg = cfg.sanitized();
                        for d in 0..DESKTOPS {
                            self.on_desk(d, |e| e.reveal());
                        }
                    }
                    None => out.error = Some("set_config needs a config object".into()),
                }
                out.show_map = false;
                return;
            }
            "set_floating" => {
                // An app was put in or out of the ribbon ("Always float"): every listed window floats, or tiles at the end of its
                // ribbon, on whichever desktop it is. Focus and the pin stay as they are; windows already that way are left alone,
                // and a minimized one comes back that way. One undo step for the lot.
                let parsed = arg.and_then(|a| {
                    let ids: Vec<u32> = a.get("ids")?.as_array()?.iter().filter_map(num).filter_map(|v| u32::try_from(v).ok()).collect();
                    Some((ids, a.get("floating")?.as_bool()?))
                });
                let Some((ids, on)) = parsed else {
                    out.error = Some("set_floating needs {ids, floating}".into());
                    out.show_map = false;
                    return;
                };
                for id in &ids {
                    if let Some(s) = self.shelf.get_mut(id) {
                        s.floating = on;
                    }
                }
                let mut desks = Vec::new();
                for d in 0..DESKTOPS {
                    let mine: Vec<u32> = ids.iter().copied().filter(|id| self.windows.get(id).is_some_and(|w| w.desk == d)).collect();
                    if mine.is_empty() {
                        continue;
                    }
                    let before = self.desk_state(d).clone();
                    self.on_desk(d, |e| {
                        mine.iter().for_each(|id| e.set_floating(*id, on));
                        e.reveal();
                    });
                    if *self.desk_state(d) != before {
                        desks.push((d, before));
                    }
                }
                if !desks.is_empty() {
                    self.push_undo_entry(Entry { desks, pin: None }, "float");
                    self.redo.clear();
                }
                out.show_map = false;
                return;
            }
            "gather" => {
                self.reveal();
                out.regather = true;
                out.emit_focus = true;
                return;
            }
            "switch_desktop" | "switch_desktop_back" | "move_to_desktop" => {
                self.desktop_command(name, arg, out);
                return;
            }
            "focus_window" => {
                // A window on another desktop: switch there, then focus it.
                let other = arg.and_then(num).and_then(|v| u32::try_from(v).ok()).and_then(|id| {
                    self.windows.get(&id).filter(|w| w.desk != self.desk).map(|w| (id, w.desk))
                });
                if let Some((id, d)) = other {
                    self.go_to(d, out);
                    self.st.focus = Some(id);
                    self.reveal();
                    out.emit_focus = true;
                    return;
                }
            }
            _ => {}
        }
        // The pin's own commands, and what the others mean while it has focus.
        if self.pin_command(name, arg, out) {
            return;
        }
        let before = self.st.clone();
        let pin_before = self.pin.clone();
        let (result, inner_toast) = match self.pin_inner_command(name, arg) {
            Some((r, t)) => (r, Some(t)),
            None => (self.apply_command(name, arg), None),
        };
        match result {
            Ok(()) => {}
            Err(e) => {
                out.show_map = false;
                out.error = Some(e);
            }
        }
        out.emit_focus |= matches!(name, "focus_window" | "move_to_index" | "move_window_to");
        if matches!(name, "focus_window" | "focus_previous" | "move_to_index") && self.st == before {
            out.show_map = false; // unknown or already-focused window: nothing to show
        }
        // Focus/scroll-only commands are navigation, not edits: undo covers layout changes only.
        let navigation = matches!(
            name,
            "focus_left" | "focus_right" | "focus_up" | "focus_down" | "focus_index" | "focus_window" | "focus_previous" | "center"
                | "focus_first" | "focus_last" | "next_tab" | "prev_tab"
        );
        out.toast = inner_toast.unwrap_or_else(|| self.toast_for(name, &before));
        if !navigation && (self.st != before || self.pin != pin_before) {
            let pin = (self.pin != pin_before).then_some(pin_before);
            self.push_undo_entry(Entry { desks: vec![(self.desk, before)], pin }, undo_label(name));
            self.redo.clear();
        }
    }

    /// " · Safari" for the focused window, for tab toasts.
    fn app_suffix(&self) -> String {
        self.st.focus.and_then(|f| self.windows.get(&f)).map(|w| format!(" · {}", w.app)).unwrap_or_default()
    }

    /// Short human feedback for a command that just ran (`before` is the state ahead of it).
    fn toast_for(&self, name: &str, before: &State) -> Option<String> {
        if matches!(name, "set_width" | "grow_width" | "shrink_width") {
            // Always confirms, even when the column already had that width; a step that cannot go on says so.
            return self.cursor().map(|(c, _)| {
                let f = layout::width_frac(self.st.columns[c].width, &self.cfg, self.avail());
                match (name, self.st == *before) {
                    ("grow_width", true) => "As wide as it gets".into(),
                    ("shrink_width", true) => "As narrow as it gets".into(),
                    _ => format!("Width {}", percent(f)),
                }
            });
        }
        if matches!(name, "grow_height" | "shrink_height") {
            return self.cursor().map(|(c, r)| {
                let col = &self.st.columns[c];
                match (col.windows.len() < 2, col.is_tabbed(), self.st == *before) {
                    (true, ..) => "Stack windows first".into(),
                    (_, true, _) => "Tabs fill the column".into(),
                    (.., true) => if name == "grow_height" { "As tall as it gets" } else { "As short as it gets" }.into(),
                    _ => format!("Height {}", percent(col.shares()[r])),
                }
            });
        }
        if let Some(toast) = self.pin_toast(name, before) {
            return toast;
        }
        if name == "cycle_height" && self.cursor().is_some_and(|(c, _)| self.st.columns[c].windows.len() < 2) {
            return Some("Stack windows first".into());
        }
        if name == "move_window_to" && self.st != *before {
            // A window dropped onto a column's title bar / added as a tab: a new tab group says so.
            if let Some((c, _)) = self.cursor().filter(|(c, _)| self.st.columns[*c].is_tabbed()) {
                let other = self.st.columns[c].windows.iter().find(|w| Some(**w) != self.st.focus);
                let was_tabbed = other.and_then(|o| before.columns.iter().find(|bc| bc.windows.contains(o))).is_some_and(|bc| bc.is_tabbed());
                if !was_tabbed {
                    return self.tab_group_label();
                }
            }
        }
        if name == "tab_with" {
            return if self.st != *before { self.tab_group_label() } else { None };
        }
        if name == "toggle_tabs" {
            let was_lone = before.focus.and_then(|f| before.columns.iter().find(|c| c.windows.contains(&f))).is_some_and(|c| c.windows.len() == 1);
            if was_lone && self.st != *before {
                return self.tab_group_label();
            }
            let cur = self.cursor().map(|(c, _)| &self.st.columns[c]);
            return match cur {
                Some(c) if c.windows.len() < 2 => Some("Nothing to tab with".into()),
                Some(c) if c.is_tabbed() => Some("Tabs".into()),
                Some(_) => Some("Shown as a stack".into()),
                None => None,
            };
        }
        if matches!(name, "next_tab" | "prev_tab") {
            return match self.cursor().map(|(c, r)| (self.st.columns[c].windows.len(), r)) {
                Some((n, _)) if n < 2 => Some("No tabs here".into()),
                Some((n, r)) => Some(format!("Tab {} of {n}{}", r + 1, self.app_suffix())),
                None => None,
            };
        }
        if matches!(name, "focus_up" | "focus_down") && self.st != *before {
            if let Some((c, r)) = self.cursor().filter(|(c, _)| self.st.columns[*c].is_tabbed()) {
                return Some(format!("Tab {} of {}{}", r + 1, self.st.columns[c].windows.len(), self.app_suffix()));
            }
        }
        if name == "equalize_heights" {
            let stacked = self.cursor().is_some_and(|(c, _)| self.st.columns[c].windows.len() > 1);
            return match (self.st == *before, stacked) {
                (false, _) => Some("Heights evened out".into()),
                (true, true) => Some("Already even".into()),
                (true, false) => Some("Stack windows first".into()),
            };
        }
        if self.st == *before {
            let edge = matches!(
                name,
                "focus_left" | "focus_right" | "focus_up" | "focus_down" | "move_left" | "move_right" | "focus_first" | "focus_last"
                    | "move_first" | "move_last" | "move_up" | "move_down" | "stack" | "stack_right"
            );
            let on_ribbon = before.focus.is_some_and(|f| before.columns.iter().any(|c| c.windows.contains(&f)));
            let stacked = self.cursor().is_some_and(|(c, _)| self.st.columns[c].windows.len() > 1);
            let tabbed = self.cursor().is_some_and(|(c, _)| self.st.columns[c].is_tabbed());
            let msg = match (name, stacked) {
                ("move_up", true) if tabbed => "Already the first tab",
                ("move_down", true) if tabbed => "Already the last tab",
                ("focus_up" | "move_up", true) => "Top of the stack",
                ("focus_down" | "move_down", true) => "Bottom of the stack",
                ("focus_up" | "focus_down" | "move_up" | "move_down", false) => "No stack here",
                ("move_first", _) => "Already first",
                ("move_last", _) => "Already last",
                ("stack", _) => "No more windows on the left",
                (_, _) if name.ends_with("left") || name == "focus_first" => "No more windows on the left",
                (_, _) if name.ends_with("right") || name == "focus_last" => "No more windows on the right",
                _ => "No more windows that way",
            };
            return (edge && on_ribbon).then(|| msg.into());
        }
        // Every width and height toast says the size it left, the same way whichever command set it: "Width 66 %".
        let width = self.cursor().map(|(c, _)| (self.st.columns[c].width, layout::width_frac(self.st.columns[c].width, &self.cfg, self.avail())));
        match name {
            "cycle_width" | "cycle_width_back" => width.map(|(_, f)| format!("Width {}", percent(f))),
            "toggle_full" => width.map(|(w, f)| if w == Width::Frac(1.0) { "Full width".into() } else { format!("Back to {}", percent(f)) }),
            "toggle_float" => Some(if self.cursor().is_some() { "Back in the ribbon" } else { "Out of the ribbon" }.into()),
            "cycle_height" => self.cursor().map(|(c, r)| format!("Height {}", percent(self.st.columns[c].shares()[r]))),
            "move_left" | "move_right" => Some("Moved".into()),
            "move_first" => Some("Moved to the start".into()),
            "move_last" => Some("Moved to the end".into()),
            "move_up" | "move_down" => self.cursor().map(|(c, r)| {
                let n = self.st.columns[c].windows.len();
                if self.st.columns[c].is_tabbed() { format!("Moved to tab {} of {n}{}", r + 1, self.app_suffix()) } else { format!("Moved {}", &name[5..]) }
            }),
            "focus_first" => Some("First window".into()),
            "focus_last" => Some("Last window".into()),
            "move_window_to" => Some(if self.cursor().is_some_and(|(c, _)| self.st.columns[c].windows.len() > 1) { "Stacked" } else { "Moved" }.into()),
            "ungroup_tabs" => Some("Tabs split into columns".into()),
            "stack" | "stack_right" => Some("Stacked".into()),
            "unstack" => Some("Moved to its own column".into()),
            _ => None,
        }
    }

    /// A direct width never goes below the drag floor (`MIN_COL_PX` / 20 %), except that every configured preset stays
    /// reachable (25 % is below the floor on a 1440pt display, and cycling already lands on it).
    fn clamp_set_width(&self, f: f64, avail: f64) -> f64 {
        let floor_px = layout::MIN_COL_PX.max(0.2 * avail).min(avail);
        let floor = (floor_px + self.cfg.gap) / (avail + self.cfg.gap);
        let smallest = self.cfg.width_presets.first().copied().unwrap_or(floor);
        f.clamp(floor.min(smallest), 1.0)
    }

    fn apply_command(&mut self, name: &str, arg: Option<&Value>) -> Result<(), String> {
        let n = self.st.columns.len();
        let cur = self.cursor();
        let avail = self.avail();
        match name {
            "focus_left" | "focus_right" | "focus_up" | "focus_down" => match cur.or(self.anchor()) {
                // From a floating window every direction re-enters the ribbon where it was left.
                Some((c, r)) if cur.is_none() => self.focus_col(c, r),
                Some((c, r)) => match name {
                    // A tabbed column cycles its tabs (wrapping), so up/down never dead-ends there.
                    "focus_up" | "focus_down" if self.st.columns[c].is_tabbed() => {
                        let len = self.st.columns[c].windows.len();
                        self.focus_col(c, if name == "focus_up" { (r + len - 1) % len } else { (r + 1) % len });
                    }
                    "focus_left" if c > 0 => self.focus_col(c - 1, r),
                    "focus_right" if c + 1 < n => self.focus_col(c + 1, r),
                    "focus_up" if r > 0 => self.focus_col(c, r - 1),
                    "focus_down" if r + 1 < self.st.columns[c].windows.len() => self.focus_col(c, r + 1),
                    // One step past the end of the ribbon on the pin's side lands on the pin.
                    _ => self.step_onto_pin(Some(name)),
                },
                // Floating focus without any tiled anchor: enter the ribbon at the first visible column.
                None if n > 0 => {
                    let s = self.spans();
                    let v = s.iter().position(|(l, w)| layout::span_visible(*l, *w, self.st.scroll, avail));
                    self.focus_col(v.unwrap_or(0), 0);
                }
                None => self.step_onto_pin(None),
            },
            "toggle_tabs" => {
                if let Some((c, r)) = cur.filter(|(c, _)| self.st.columns[*c].windows.len() > 1) {
                    let col = &mut self.st.columns[c];
                    col.tabbed = !col.tabbed;
                    col.active = col.tabbed.then(|| col.windows[r]);
                } else if let Some((c, _)) = cur {
                    // A lone window: one step to a tab group with the column on its left (the right one, if it is the first).
                    if n > 1 {
                        self.tab_with(if c > 0 { -1 } else { 1 })?;
                    }
                }
            }
            "tab_with" => {
                let dir = arg.and_then(|a| a.as_i64().or_else(|| a.get("direction").and_then(Value::as_i64)).or_else(|| match a.as_str().or_else(|| a.get("direction").and_then(Value::as_str)) {
                    Some("left") => Some(-1),
                    Some("right") => Some(1),
                    _ => None,
                }));
                let Some(dir) = dir.filter(|d| *d == -1 || *d == 1) else { return Err("tab_with needs a direction: left or right".into()) };
                self.tab_with(dir as i32)?;
            }
            "ungroup_tabs" => {
                // Close the tab group: every window of the focused tabbed column gets its own column, in place.
                if let Some((c, _)) = cur.filter(|(c, _)| self.st.columns[*c].is_tabbed()) {
                    let col = self.st.columns.remove(c);
                    for (i, id) in col.windows.iter().enumerate() {
                        self.st.columns.insert(c + i, Column::new(*id, col.width));
                    }
                    self.reveal();
                }
            }
            "next_tab" | "prev_tab" => {
                // Cycles the windows of the focused column (wrapping), tabbed or stacked.
                if let Some((c, r)) = cur.filter(|(c, _)| self.st.columns[*c].windows.len() > 1) {
                    let len = self.st.columns[c].windows.len();
                    self.focus_col(c, if name == "next_tab" { (r + 1) % len } else { (r + len - 1) % len });
                }
            }
            "move_window_to" => self.move_window_to(arg)?,
            "focus_first" | "focus_last" => {
                // Home / end of the ribbon: the first (last) column, top window; floating focus re-enters there too.
                if n > 0 {
                    self.focus_col(if name == "focus_first" { 0 } else { n - 1 }, 0);
                }
            }
            "equalize_heights" => {
                if let Some((c, _)) = cur.filter(|(c, _)| self.st.columns[*c].windows.len() > 1 && !self.st.columns[*c].is_tabbed()) {
                    self.st.columns[c].reset_heights();
                }
            }
            "move_left" | "move_right" => {
                if let Some((c, _)) = cur {
                    let t = if name == "move_left" { c.checked_sub(1) } else { Some(c + 1) };
                    if let Some(t) = t.filter(|t| *t < n) {
                        self.st.columns.swap(c, t);
                        self.reveal();
                    }
                }
            }
            "move_first" | "move_last" => {
                // The focused column (all of its windows) to the start / end of the ribbon.
                if let Some((c, _)) = cur {
                    let to = if name == "move_first" { 0 } else { n - 1 };
                    if c != to {
                        let col = self.st.columns.remove(c);
                        self.st.columns.insert(to, col);
                        self.reveal();
                    }
                }
            }
            "move_up" | "move_down" => {
                // Reorder inside the focused stack (a tabbed column moves the tab): the window swaps places with its
                // neighbour, taking its height along.
                if let Some((c, r)) = cur {
                    let col = &mut self.st.columns[c];
                    let t = if name == "move_up" { r.checked_sub(1) } else { Some(r + 1) };
                    if let Some(t) = t.filter(|t| *t < col.windows.len()) {
                        col.windows.swap(r, t);
                        if let Some(h) = col.heights.as_mut().filter(|h| h.len() == col.windows.len()) {
                            h.swap(r, t);
                        }
                    }
                }
            }
            "cycle_width" | "cycle_width_back" => {
                if let Some((c, _)) = cur {
                    let f = layout::width_frac(self.st.columns[c].width, &self.cfg, avail);
                    let p = &self.cfg.width_presets;
                    let next = if name == "cycle_width" {
                        p.iter().find(|x| **x > f + 1e-3).or(p.first())
                    } else {
                        p.iter().rev().find(|x| **x < f - 1e-3).or(p.last())
                    };
                    let col = &mut self.st.columns[c];
                    col.width = Width::Frac(*next.unwrap_or(&f));
                    col.restore = None;
                    self.reveal();
                }
            }
            "grow_width" | "shrink_width" => {
                // A small step (`NUDGE` of the usable width) from wherever the column is, preset or not, within the same
                // limits as `set_width`. A column that cannot go on keeps its restore memory.
                if let Some((c, _)) = cur {
                    let f = layout::width_frac(self.st.columns[c].width, &self.cfg, avail);
                    let want = self.clamp_set_width(f + if name == "grow_width" { NUDGE } else { -NUDGE }, avail);
                    let want = (want * 1e4).round() / 1e4;
                    // A column already below the floor (the width steps changed since) is never widened by a shrink.
                    let want = if name == "grow_width" { want.max(f) } else { want.min(f) };
                    if (want - f).abs() > 1e-6 {
                        let col = &mut self.st.columns[c];
                        col.width = Width::Frac(want);
                        col.restore = None;
                        self.reveal();
                    }
                }
            }
            "set_width" => {
                // Direct width: arg is a fraction (0.66) or {"fraction": 0.66}. Anything outside (0, 1] is an error.
                let f = arg.and_then(|a| a.as_f64().or_else(|| a.get("fraction").and_then(Value::as_f64)));
                let Some(f) = f.filter(|f| f.is_finite() && *f > 0.0 && *f <= 1.0) else {
                    return Err("set_width needs a fraction in (0, 1]".into());
                };
                if let Some((c, _)) = cur {
                    let f = self.clamp_set_width(f, avail);
                    let col = &mut self.st.columns[c];
                    col.width = Width::Frac(f);
                    col.restore = None;
                    self.reveal();
                }
            }
            "cycle_height" => {
                if let Some((c, r)) = cur.filter(|(c, _)| self.st.columns[*c].windows.len() > 1 && !self.st.columns[*c].is_tabbed()) {
                    self.cycle_height(c, r);
                }
            }
            "grow_height" | "shrink_height" => {
                if let Some((c, r)) = cur.filter(|(c, _)| self.st.columns[*c].windows.len() > 1 && !self.st.columns[*c].is_tabbed()) {
                    self.nudge_height(c, r, name == "grow_height");
                }
            }
            "toggle_full" => {
                if let Some((c, _)) = cur {
                    let default = Width::Frac(self.cfg.default_width);
                    let col = &mut self.st.columns[c];
                    if let Some(prev) = col.restore.take() {
                        col.width = prev;
                    } else if col.width == Width::Frac(1.0) {
                        col.width = default; // already full with nothing to restore
                    } else {
                        col.restore = Some(col.width);
                        col.width = Width::Frac(1.0);
                    }
                    self.reveal();
                }
            }
            "stack" => {
                if let Some((c, r)) = cur.filter(|(c, _)| *c > 0) {
                    let id = self.st.columns[c].windows.remove(r);
                    self.st.columns[c].reset_heights();
                    if self.st.columns[c].windows.is_empty() {
                        self.st.columns.remove(c);
                    }
                    let target = &mut self.st.columns[c - 1];
                    target.windows.push(id);
                    target.reset_heights();
                    self.reveal();
                }
            }
            "stack_right" => {
                // Mirror of `stack`: the window joins the column on its right, as that column's first window.
                if let Some((c, r)) = cur.filter(|(c, _)| c + 1 < n) {
                    let id = self.st.columns[c].windows.remove(r);
                    self.st.columns[c].reset_heights();
                    let to = if self.st.columns[c].windows.is_empty() {
                        self.st.columns.remove(c);
                        c
                    } else {
                        c + 1
                    };
                    let target = &mut self.st.columns[to];
                    target.windows.insert(0, id);
                    target.reset_heights();
                    self.reveal();
                }
            }
            "unstack" => {
                if let Some((c, r)) = cur.filter(|(c, _)| self.st.columns[*c].windows.len() > 1) {
                    let id = self.st.columns[c].windows.remove(r);
                    self.st.columns[c].reset_heights();
                    let width = self.st.columns[c].width;
                    self.st.columns.insert(c + 1, Column::new(id, width));
                    self.reveal();
                }
            }
            "center" => {
                if let (Some((c, _)), Some(_)) = (cur, self.display) {
                    // Next to a pin it centres as near as a rest offset allows, so no window slides under the pin.
                    self.st.scroll = match self.pin_reveal(&self.spans(), avail, Some(c), ScrollMode::Center) {
                        Some(scroll) => scroll,
                        None => layout::center_scroll(&self.spans(), c, avail),
                    };
                }
            }
            "focus_index" => {
                let k = arg.and_then(num).ok_or("focus_index needs a numeric arg")?;
                if n > 0 && k >= 1 {
                    self.focus_col((k as usize - 1).min(n - 1), 0);
                }
            }
            "move_to_index" => {
                // arg: target column (1-based) for the focused window, or {"id": window, "index": column}.
                let (id, k) = match arg {
                    Some(Value::Object(o)) => (o.get("id").and_then(num).map(|v| u32::try_from(v).ok()), o.get("index").and_then(num)),
                    a => (self.st.focus.map(Some), a.and_then(num)),
                };
                let (id, k) = id.zip(k).filter(|(_, k)| *k >= 1).ok_or("move_to_index needs a column index")?;
                // An id beyond u32 cannot name a window: ignore it rather than truncate.
                if let Some((id, (c, r))) = id.and_then(|id| Some((id, self.pos(id)?))) {
                    let cols = &mut self.st.columns;
                    let width = cols[c].width;
                    cols[c].windows.remove(r);
                    cols[c].reset_heights();
                    if cols[c].windows.is_empty() {
                        cols.remove(c);
                    }
                    let at = (k as usize - 1).min(cols.len());
                    cols.insert(at, Column::new(id, width));
                    self.st.focus = Some(id);
                    self.reveal();
                }
            }
            "focus_previous" => {
                // history[0] is the current window; closed windows were already pruned.
                if let Some(id) = self.history.iter().copied().find(|h| Some(*h) != self.st.focus) {
                    self.st.focus = Some(id);
                    self.reveal();
                }
            }
            "focus_window" => {
                let id = arg.and_then(num).ok_or("focus_window needs a window id")?;
                if let Some(id) = u32::try_from(id).ok().filter(|id| self.windows.contains_key(id)) {
                    self.st.focus = Some(id);
                    self.reveal();
                }
            }
            "toggle_float" => {
                if let Some(id) = self.st.focus {
                    if let Some((c, r)) = cur {
                        self.st.float_widths.insert(id, self.st.columns[c].width);
                        self.st.columns[c].windows.remove(r);
                        self.st.columns[c].reset_heights();
                        let mut near = c; // the surviving stack, else the left neighbour (else the new first column)
                        if self.st.columns[c].windows.is_empty() {
                            self.st.columns.remove(c);
                            near = c.saturating_sub(1);
                        }
                        self.st.floating.insert(id);
                        // Anchor on a neighbour so re-tiling lands in (almost) the same place.
                        self.last_tiled = self.st.columns.get(near).map(|k| k.windows[0]);
                        self.reveal(); // the ribbon got shorter: settle the scroll now, not on the next focus
                    } else {
                        self.st.floating.remove(&id);
                        let width = match self.st.float_widths.remove(&id) {
                            Some(w) => w,
                            None => {
                                let app = self.windows.get(&id).map(|w| w.app.clone()).unwrap_or_default();
                                self.new_column_width(&app, None)
                            }
                        };
                        self.insert_column(Column::new(id, width));
                        self.reveal();
                    }
                }
            }
            _ => return Err(format!("unknown command: {name}")),
        }
        Ok(())
    }

    /// `move_window_to` `{id, column, position, row?}`: drop a window at a column of the ribbon (drag to reorder).
    /// `column` is 1-based as the map shows it *before* the move; `position` is `before` / `after` (its own new column
    /// next to it) or `into` (joins that column as a stack, or as the newest tab of a tabbed one); `row` (into only) is
    /// the insertion index among the column's other windows, default the end. Keeps the window's width, focuses it.
    /// Unknown windows are ignored, a bad column or position is an error. Dropping a lone window on its own column is a no-op.
    fn move_window_to(&mut self, arg: Option<&Value>) -> Result<(), String> {
        let Some(Value::Object(o)) = arg else { return Err("move_window_to needs {id, column, position}".into()) };
        if let Some(moved) = self.move_to_pin(o) {
            return moved;
        }
        let col = o.get("column").and_then(num).filter(|k| *k >= 1).ok_or("move_window_to needs a column")? as usize - 1;
        let pos = o.get("position").and_then(Value::as_str).unwrap_or("");
        if !matches!(pos, "before" | "after" | "into" | "tabs") {
            return Err("move_window_to position must be before, after, into or tabs".into());
        }
        let id = match o.get("id") {
            Some(v) => num(v).and_then(|v| u32::try_from(v).ok()),
            None => self.st.focus,
        };
        let (Some(id), n) = (id, self.st.columns.len()) else { return Ok(()) };
        if col >= n {
            return Err("move_window_to: no such column".into());
        }
        self.leave_pin(id);
        let Some((sc, sr)) = self.pos(id) else { return Ok(()) };
        // The target column is remembered by one of its other windows: indices shift when the source column vanishes.
        let Some(anchor) = self.st.columns[col].windows.iter().copied().find(|w| *w != id) else { return Ok(()) };
        let row = o.get("row").and_then(num).map(|r| r as usize);
        let cols = &mut self.st.columns;
        let width = cols[sc].width;
        cols[sc].windows.remove(sr);
        cols[sc].reset_heights();
        if cols[sc].windows.is_empty() {
            cols.remove(sc);
        }
        let t = cols.iter().position(|c| c.windows.contains(&anchor)).unwrap_or(0);
        match pos {
            "before" => cols.insert(t, Column::new(id, width)),
            "after" => cols.insert(t + 1, Column::new(id, width)),
            _ => {
                let c = &mut cols[t];
                c.windows.insert(row.unwrap_or(usize::MAX).min(c.windows.len()), id);
                c.reset_heights();
                if pos == "tabs" {
                    c.tabbed = true; // `tabs`: like `into`, but the column becomes a tab group with this window showing
                }
                if c.tabbed {
                    c.active = Some(id);
                }
            }
        }
        self.st.focus = Some(id);
        self.reveal();
        Ok(())
    }

    fn push_undo_entry(&mut self, entry: Entry, label: &'static str) {
        self.resizing = None;
        self.undo.push((entry, label));
        if self.undo.len() > UNDO_LIMIT {
            self.undo.remove(0);
        }
    }

    /// Returns the toast: what was undone/redone, or that there was nothing to do.
    fn undo_redo(&mut self, undo: bool, out: &mut Outcome) -> String {
        let popped = if undo { self.undo.pop() } else { self.redo.pop() };
        let Some((entry, label)) = popped else {
            return format!("Nothing to {}", if undo { "undo" } else { "redo" });
        };
        self.resizing = None;
        out.jump |= entry.desks.len() > 1;
        let now = self.swap_entry(entry);
        if undo {
            self.redo.push((now, label));
        } else {
            self.push_undo_entry(now, label);
        }
        self.reveal(); // the restored scroll may hide the focused column (e.g. after a display change)
        format!("{}: {label}", if undo { "Undid" } else { "Redid" })
    }

    /// Install an undo entry's snapshots; returns the states they replaced (the opposite stack's entry).
    fn swap_entry(&mut self, entry: Entry) -> Entry {
        let Entry { desks, pin } = entry;
        let descs: BTreeSet<usize> = desks.iter().map(|(d, _)| *d).collect();
        let mut in_entry: BTreeSet<u32> = desks
            .iter()
            .flat_map(|(_, s)| s.columns.iter().flat_map(|c| c.windows.iter().copied()).chain(s.floating.iter().copied()))
            .collect();
        // What the entry replaces, taken before anything changes: the opposite stack's entry.
        let now: Vec<(usize, State)> = desks.iter().map(|(d, _)| (*d, self.desk_state(*d).clone())).collect();
        // The entry's pin, if it carries one, replaces the engine's; `loose` is what the replaced pin held.
        let (now_pin, loose) = self.swap_pin(pin, &mut in_entry);
        // A snapshot taken in a narrower band can hold a column wider than its own width: `handle` gives it its own width back
        // once the pin has settled, where the band then gives it as much.
        for (d, snap) in desks {
            self.on_desk(d, |e| e.restore(snap, &descs, &in_entry));
        }
        // Windows follow the restored layouts (a sent window returns, or leaves again on redo).
        for &d in &descs {
            for id in self.desk_ids(d) {
                if let Some(w) = self.windows.get_mut(&id) {
                    w.desk = d;
                }
            }
        }
        // Windows of the pin this replaced that no restored layout holds go back into their desktop's ribbon.
        for (id, width) in loose {
            if self.windows.contains_key(&id) && !self.placed(id) {
                let d = self.windows[&id].desk;
                self.on_desk(d, |e| e.attach(id, false, Some(width)));
            }
        }
        Entry { desks: now, pin: now_pin }
    }

    /// Install a snapshot, reconciling it with windows that came or went since it was taken.
    /// `descs`: desktops of the entry (a window on any other desktop is not ours to restore);
    /// `moved`: windows the entry places, so they are not mistaken for newcomers on the desktop they left.
    fn restore(&mut self, mut snap: State, descs: &BTreeSet<usize>, moved: &BTreeSet<u32>) {
        // The pin holds its windows whatever the snapshot says.
        let pinned: BTreeSet<u32> = self.pin.iter().flat_map(|p| p.col.windows.iter().copied()).collect();
        let pin_here = self.pin.as_ref().is_some_and(|p| p.desk == self.desk);
        let known = |id: &u32| !pinned.contains(id) && self.windows.get(id).is_some_and(|w| descs.contains(&w.desk));
        for c in &mut snap.columns {
            let len = c.windows.len();
            c.windows.retain(known);
            if c.windows.len() != len {
                c.reset_heights();
            }
        }
        snap.columns.retain(|c| !c.windows.is_empty());
        snap.floating.retain(known);
        let seen: BTreeSet<u32> = snap
            .columns
            .iter()
            .flat_map(|c| c.windows.iter().copied())
            .chain(snap.floating.iter().copied())
            .collect();
        // Windows the snapshot never saw keep their current mode. Tiled ones go right after the
        // nearest window to their left in the current ribbon (first if none, end if that one is gone).
        let current: Vec<u32> = self.st.columns.iter().flat_map(|c| c.windows.iter().copied()).collect();
        for (i, id) in current.iter().enumerate().filter(|(_, id)| !seen.contains(id) && !moved.contains(id) && !pinned.contains(id)) {
            let left = current[..i].iter().rev().find_map(|w| snap.columns.iter().position(|c| c.windows.contains(w)));
            let at = left.map_or(if i == 0 { 0 } else { snap.columns.len() }, |l| l + 1);
            snap.columns.insert(at, Column::new(*id, Width::Frac(self.cfg.default_width)));
        }
        for id in self.st.floating.iter().filter(|id| !seen.contains(id) && !moved.contains(id) && !pinned.contains(id)) {
            snap.floating.insert(*id);
            if let Some(w) = self.st.float_widths.get(id) {
                snap.float_widths.insert(*id, *w);
            }
        }
        let floating = snap.floating.clone();
        snap.float_widths.retain(|id, _| floating.contains(id));
        if !snap.focus.as_ref().is_some_and(|f| known(f) || (pin_here && pinned.contains(f))) {
            snap.focus = None;
        }
        let old = std::mem::replace(&mut self.st, snap);
        if self.st.focus.is_none() {
            self.st.focus = self.fallback_focus();
        }
        // The floating-focus anchor and focus history must only name windows that still exist / are tiled.
        self.history.retain(|h| self.windows.contains_key(h));
        if self.last_tiled.is_some_and(|id| self.pos(id).is_none()) {
            let ordered: Vec<u32> = old.columns.iter().flat_map(|c| c.windows.iter().copied()).collect();
            let at = ordered.iter().position(|w| Some(*w) == self.last_tiled);
            let tiled = |w: &&u32| self.pos(**w).is_some();
            self.last_tiled = at.and_then(|i| {
                ordered[..i].iter().rev().find(tiled).or_else(|| ordered[i..].iter().find(tiled)).copied()
            });
        }
    }

    // ---- session ----
    /// The layout of every non-empty desktop, for the host to persist.
    fn snapshot(&self) -> Session {
        let desktops = (0..DESKTOPS)
            .filter_map(|d| {
                let st = self.desk_state(d);
                if st.columns.is_empty() && st.floating.is_empty() {
                    return None;
                }
                let columns = st
                    .columns
                    .iter()
                    .map(|c| SessionColumn {
                        windows: c.windows.clone(),
                        width: session_width(c.own_width()),
                        heights: c.heights.clone().filter(|h| h.len() == c.windows.len()),
                        tabbed: c.is_tabbed(),
                        active: c.is_tabbed().then(|| c.active_index()),
                    })
                    .collect();
                // The focus must be one of this desktop's windows, or the pin while it shows here (it may have left
                // since, folded into another desktop's ribbon); else what a restore would pick.
                let here = |f: &u32| {
                    st.columns.iter().any(|c| c.windows.contains(f))
                        || st.floating.contains(f)
                        || (self.pinned(*f) && self.pin.as_ref().is_some_and(|p| p.every || p.desk == d))
                };
                let focus = st.focus.filter(here);
                let focus = focus.or_else(|| st.columns.first().map(|c| c.windows[0]).or_else(|| st.floating.iter().next().copied()));
                Some(SessionDesk { index: d + 1, columns, floating: st.floating.iter().copied().collect(), focus, scroll: st.scroll })
            })
            .collect();
        Session { active: self.desk + 1, desktops, pin: self.snapshot_pin() }
    }

    /// Rebuild desktops from a saved session. Only windows the core knows are placed; the rest stay where they are
    /// (after the restored columns of their desktop). Windows that are floating now stay floating. Not undoable.
    fn restore_session(&mut self, active: usize, saved: &[SessionDesk], saved_pin: Option<&SessionPin>, out: &mut Outcome) {
        // A live pin's column goes back into its ribbon first, so it is reconciled like every other column.
        self.unpin_inner(false);
        self.pin_memo = None;
        let target = active.checked_sub(1).filter(|d| *d < DESKTOPS).unwrap_or(self.desk);
        let old: Vec<State> = (0..DESKTOPS).map(|d| self.desk_state(d).clone()).collect();
        let live_floating: BTreeSet<u32> = old.iter().flat_map(|s| s.floating.iter().copied()).collect();
        let mut news: Vec<State> = (0..DESKTOPS).map(|_| State::default()).collect();
        let mut used: BTreeSet<u32> = BTreeSet::new();
        // A saved pin claims its windows before any desktop does (`take_saved_pin`: what becomes of it depends on the edition).
        let (saved, new_pin) = self.take_saved_pin(saved, saved_pin, target, &live_floating, &mut used);
        let pin_ok = |d: usize, f: u32| new_pin.as_ref().is_some_and(|p: &Pin| p.col.windows.contains(&f) && (p.every || p.desk == d));
        for sd in saved.iter() {
            let Some(d) = sd.index.checked_sub(1).filter(|d| *d < DESKTOPS) else { continue };
            for sc in &sd.columns {
                let ids: Vec<u32> = sc.windows.iter().copied().filter(|id| self.windows.contains_key(id) && used.insert(*id)).collect();
                let (tiled, floats): (Vec<u32>, Vec<u32>) = ids.iter().partition(|id| !live_floating.contains(id));
                news[d].floating.extend(floats);
                if tiled.is_empty() {
                    continue;
                }
                let width = width_from(sc.width, self.cfg.default_width);
                let mut col = Column { windows: tiled, width, restore: None, heights: None, tabbed: false, active: None, held: None };
                // Tabs survive only for a whole column that is still a stack; a bad active index falls back to the first tab.
                if sc.tabbed && col.windows.len() >= 2 && ids.len() == sc.windows.len() {
                    col.tabbed = true;
                    col.active = Some(col.windows[sc.active.filter(|a| *a < col.windows.len()).unwrap_or(0)]);
                }
                // Shares only survive when every window of the stack is back and they are sane.
                col.heights = sc.heights.clone().filter(|h| {
                    h.len() == col.windows.len() && ids.len() == sc.windows.len() && h.iter().all(|x| x.is_finite() && *x > 0.0)
                        && (h.iter().sum::<f64>() - 1.0).abs() < 1e-3
                });
                news[d].columns.push(col);
            }
            for id in sd.floating.iter().copied().filter(|id| self.windows.contains_key(id) && used.insert(*id)) {
                news[d].floating.insert(id);
            }
            news[d].focus = sd.focus.filter(|f| used.contains(f));
            news[d].scroll = if sd.scroll.is_finite() { sd.scroll } else { 0.0 };
        }
        for (d, st) in old.into_iter().enumerate() {
            for col in st.columns {
                let rest: Vec<u32> = col.windows.iter().copied().filter(|id| !used.contains(id)).collect();
                if !rest.is_empty() {
                    let kept = rest.len() == col.windows.len();
                    news[d].columns.push(Column { windows: rest, width: col.width, restore: col.restore, heights: col.heights.filter(|_| kept), tabbed: col.tabbed && kept, active: col.active.filter(|_| kept), held: col.held });
                }
            }
            for id in st.floating.iter().filter(|id| !used.contains(id)) {
                news[d].floating.insert(*id);
                if let Some(w) = st.float_widths.get(id) {
                    news[d].float_widths.insert(*id, *w);
                }
            }
            if news[d].focus.is_none() {
                news[d].focus = st.focus.filter(|f| !used.contains(f));
            }
        }
        // Windows follow their desktop; every desktop starts without undo history.
        for (d, st) in news.iter_mut().enumerate() {
            let tiled: Vec<u32> = st.columns.iter().flat_map(|c| c.windows.iter().copied()).collect();
            for id in tiled.iter().chain(st.floating.iter()) {
                if let Some(w) = self.windows.get_mut(id) {
                    w.desk = d;
                }
            }
            if !st.focus.is_some_and(|f| tiled.contains(&f) || st.floating.contains(&f) || pin_ok(d, f)) {
                st.focus = st.columns.first().map(|c| c.windows[0]).or_else(|| st.floating.iter().next().copied());
            }
        }
        self.install_restored_pin(new_pin);
        for (d, st) in news.into_iter().enumerate() {
            let tiled_focus = st.focus.filter(|f| st.columns.iter().any(|c| c.windows.contains(f)));
            let desk = Desk { history: st.focus.into_iter().collect(), last_tiled: tiled_focus, st, ..Desk::default() };
            if d == self.desk {
                (self.st, self.undo, self.redo, self.last_tiled, self.history) = (desk.st, vec![], vec![], desk.last_tiled, desk.history);
            } else {
                self.others[d] = desk;
            }
        }
        self.resizing = None;
        self.prev_desk = None;
        self.switch_to(target);
        for d in 0..DESKTOPS {
            self.on_desk(d, |e| e.reveal()); // clamps each saved scroll; keeps the focused column in view
        }
        out.jump = true;
        out.emit_focus = self.st.focus.is_some();
    }

    // ---- plan assembly ----
    /// The tab bar of `col` (a tabbed column), laid out at `b`; `column` is its index in the map.
    fn tab_bar(&self, col: &Column, b: &layout::BarRect, column: usize, focused: bool, pinned: bool) -> TabBar {
        let tabs = col
            .windows
            .iter()
            .map(|id| {
                let info = &self.windows[id];
                TabItem { id: *id, app: info.app.clone(), title: info.title.clone() }
            })
            .collect();
        TabBar { column, x: b.x, y: b.y, w: b.w, h: b.h, on_screen: b.on_screen, active: col.windows[col.active_index()], focused, tabs, pinned }
    }

    fn plan(&mut self, out: Outcome) -> Plan {
        let (mut frames, bars) = match (self.display, self.band_on(self.desk)) {
            (Some(d), Some(b)) => layout::frames_and_bars_in(&self.st.columns, &self.cfg, &d, &b, self.st.scroll),
            _ => Default::default(),
        };
        let focus_col = self.cursor().map(|(c, _)| c);
        let mut tab_bars: Vec<TabBar> = bars.iter().map(|b| self.tab_bar(&self.st.columns[b.column], b, b.column, focus_col == Some(b.column), false)).collect();
        if let Some(d) = self.display {
            // Windows of inactive desktops stay parked: a 1pt sliver at the right edge keeps macOS from reclaiming them.
            // They keep the widths of their own band, so switching does not resize them.
            let edge = (d.x + d.w).round() as i64 - 1;
            for (i, desk) in self.others.iter().enumerate().filter(|(i, _)| *i != self.desk) {
                let band = self.band_on(i).unwrap_or(d);
                for mut f in layout::frames_and_bars_in(&desk.st.columns, &self.cfg, &d, &band, desk.st.scroll).0 {
                    (f.x, f.on_screen, f.lx) = (edge, false, i64::MIN);
                    frames.push(f);
                }
            }
            self.plan_pin(d, edge, &mut frames, &mut tab_bars);
        }
        let floating_parked: Vec<u32> = {
            let mut v: Vec<u32> = self
                .others
                .iter()
                .enumerate()
                .filter(|(i, _)| *i != self.desk)
                .flat_map(|(_, d)| d.st.floating.iter().copied())
                .collect();
            v.sort_unstable();
            v
        };
        if out.regather {
            self.last.clear();
        }
        let mut shelf: Vec<(u64, ShelfItem)> = self
            .shelf
            .iter()
            .map(|(id, s)| (s.seq, ShelfItem { id: *id, app: s.app.clone(), title: s.title.clone(), desk: s.desk + 1, hidden: s.hidden }))
            .collect();
        shelf.sort_by(|a, b| b.0.cmp(&a.0));
        let mut changed: Vec<u32> = frames.iter().filter(|f| self.last.get(&f.id) != Some(f)).map(|f| f.id).collect();
        // The user left the window at a size the plan did not keep (clamp, snap): write it back.
        if let Some((id, r)) = out.resized {
            let off = |f: &PlanFrame| f.on_screen && ((f.w as f64 - r.w).abs() > ECHO_PX || (f.h as f64 - r.h).abs() > ECHO_PX);
            if !changed.contains(&id) && frames.iter().any(|f| f.id == id && off(f)) {
                changed.push(id);
                changed.sort_unstable();
            }
        }
        self.last = frames.iter().map(|f| (f.id, f.clone())).collect();
        Plan {
            frames,
            focus: if out.emit_focus { self.st.focus } else { None },
            changed,
            map: self.map(),
            show_map: out.show_map,
            error: out.error,
            toast: out.toast,
            jump: out.jump,
            floating_parked,
            shelf: shelf.into_iter().map(|(_, s)| s).collect(),
            session: None,
            tab_bars,
        }
    }

    /// The map's entries for `ids` (windows of the core).
    fn map_windows(&self, ids: &[u32]) -> Vec<MapWindow> {
        ids.iter()
            .map(|id| {
                let info = &self.windows[id];
                MapWindow { id: *id, app: info.app.clone(), title: info.title.clone() }
            })
            .collect()
    }

    fn map(&self) -> Map {
        let avail = self.avail();
        let spans = self.spans();
        let total = layout::content_width(&spans);
        let focus_col = self.cursor().map(|(c, _)| c);
        let columns = self.st.columns.iter().zip(&spans).enumerate().map(|(i, (col, (l, w)))| MapColumn {
            windows: self.map_windows(&col.windows),
            width_frac: r4(layout::width_frac(col.width, &self.cfg, avail)),
            focused: focus_col == Some(i),
            visible: layout::span_visible(*l, *w, self.st.scroll, avail),
            tabbed: col.is_tabbed(),
            active: col.is_tabbed().then(|| col.active_index()),
        });
        let viewport = if total > 0.0 {
            Viewport {
                start: r4((self.st.scroll / total).clamp(0.0, 1.0)),
                end: r4(((self.st.scroll + avail) / total).clamp(0.0, 1.0)),
            }
        } else {
            Viewport { start: 0.0, end: 1.0 }
        };
        let desktops = (0..DESKTOPS)
            .map(|d| {
                let windows = self.desk_ids(d);
                DesktopInfo { index: d + 1, count: windows.len(), active: d == self.desk, windows }
            })
            .collect();
        Map { columns: columns.collect(), viewport, focused_index: focus_col, desktop: self.desk + 1, desktops, pin: self.map_pin(), near_edge: self.near_edge() }
    }
}

/// A column's width or a window's height in the toasts: whole percent, rounded down so ⅔ reads "66 %" as in Settings and the
/// command bar. The no-break space keeps the % beside its number.
fn percent(share: f64) -> String {
    format!("{}\u{a0}%", (share * 100.0 + 1e-6).floor() as u32)
}

/// Four decimals, for the map's fractions.
fn r4(v: f64) -> f64 {
    (v * 1e4).round() / 1e4
}

/// What a snapshot's command did, in the words of the undo/redo toast.
fn undo_label(name: &str) -> &'static str {
    match name {
        "toggle_full" => "full width",
        "move_left" | "move_right" | "move_first" | "move_last" | "move_up" | "move_down" | "move_to_index" | "move_window_to" => "move",
        "toggle_tabs" | "ungroup_tabs" | "tab_with" => "tabs",
        "cycle_width" | "cycle_width_back" | "set_width" | "grow_width" | "shrink_width" => "width",
        "cycle_height" | "grow_height" | "shrink_height" => "height",
        "equalize_heights" => "heights",
        "stack" | "stack_right" => "stack",
        "unstack" => "unstack",
        "toggle_float" => "float",
        "move_to_desktop" => "move to desktop",
        _ => "change",
    }
}

fn session_width(w: Width) -> SessionWidth {
    match w {
        Width::Frac(f) => SessionWidth::Frac(f),
        Width::Px(p) => SessionWidth::Px(p),
        Width::Fixed(p) => SessionWidth::Fixed(p),
    }
}

/// A saved width, or the default when it is not sane.
fn width_from(w: SessionWidth, default: f64) -> Width {
    match w {
        SessionWidth::Frac(f) if f > 0.0 && f <= 1.0 => Width::Frac(f),
        SessionWidth::Px(p) if p.is_finite() && p > 0.0 => Width::Px(p),
        SessionWidth::Fixed(p) if p.is_finite() && p > 0.0 => Width::Fixed(p),
        _ => Width::Frac(default),
    }
}

/// Numeric command arg: accepts `3`, `3.0` or `"3"`.
fn num(v: &Value) -> Option<u64> {
    v.as_u64().or_else(|| v.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64)).or_else(|| v.as_str()?.parse().ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const R: Rect = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };

    fn eng() -> Engine {
        let mut e = Engine::new(Config::default());
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        e
    }
    fn add_to(e: &mut Engine, id: u32, floating: bool) -> Plan {
        e.handle(Event::WindowAdded { id, pid: 1, app: format!("App{id}"), title: format!("T{id}"), frame: R, floating, width_hint: None, take_focus: true })
    }
    /// A window an app in the background opened: the host says it does not take focus.
    fn add_quiet(e: &mut Engine, id: u32, floating: bool) -> Plan {
        e.handle(Event::WindowAdded { id, pid: 1, app: format!("App{id}"), title: format!("T{id}"), frame: R, floating, width_hint: None, take_focus: false })
    }
    fn with(n: u32) -> Engine {
        let mut e = eng();
        (1..=n).for_each(|i| {
            add_to(&mut e, i, false);
        });
        e
    }
    fn cmd(e: &mut Engine, name: &str) -> Plan {
        e.handle(Event::Command { name: name.into(), arg: None })
    }
    fn cmd_arg(e: &mut Engine, name: &str, arg: Value) -> Plan {
        e.handle(Event::Command { name: name.into(), arg: Some(arg) })
    }
    fn ids(e: &Engine) -> Vec<Vec<u32>> {
        e.st.columns.iter().map(|c| c.windows.clone()).collect()
    }
    fn frame(p: &Plan, id: u32) -> &PlanFrame {
        p.frames.iter().find(|f| f.id == id).unwrap()
    }

    #[test]
    fn empty_engine() {
        let mut e = eng();
        let p = e.handle(Event::Query);
        assert!(p.frames.is_empty() && p.focus.is_none() && !p.show_map && p.map.focused_index.is_none());
        for c in ["focus_left", "move_right", "cycle_width", "toggle_full", "stack", "unstack", "center", "toggle_float", "undo", "redo", "gather"] {
            assert!(cmd(&mut e, c).error.is_none(), "{c}");
        }
        assert_eq!(e.undo_len(), 0);
    }

    #[test]
    fn no_display_means_no_frames_but_state_tracks() {
        let mut e = Engine::new(Config::default());
        let p = add_to(&mut e, 1, false);
        assert!(p.frames.is_empty() && p.map.columns.len() == 1);
        let p = e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 1000.0, h: 800.0 } });
        assert_eq!(p.changed, vec![1]);
    }

    #[test]
    fn single_window_add() {
        let mut e = eng();
        let p = add_to(&mut e, 5, false);
        assert_eq!(p.focus, Some(5));
        assert!(p.show_map && p.changed == vec![5]);
        assert_eq!((frame(&p, 5).x, frame(&p, 5).w), (12, 482));
        assert_eq!(p.map.focused_index, Some(0));
        let p = cmd(&mut e, "focus_left");
        assert_eq!(p.focus, None); // nothing changed
        let p = cmd(&mut e, "focus_right");
        assert!(p.show_map && p.changed.is_empty());
    }

    #[test]
    fn add_inserts_right_of_focused_and_focuses() {
        let mut e = with(3);
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_left");
        add_to(&mut e, 9, false);
        assert_eq!(ids(&e), [vec![1], vec![9], vec![2], vec![3]]);
        assert_eq!(e.focused(), Some(9));
    }

    #[test]
    fn new_window_end_config() {
        let mut e = Engine::new(Config { new_window: NewWindow::End, ..Config::default() });
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 1000.0, h: 800.0 } });
        (1..=3).for_each(|i| {
            add_to(&mut e, i, false);
        });
        cmd_arg(&mut e, "focus_index", json!(1));
        add_to(&mut e, 4, false);
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3], vec![4]]);
    }

    #[test]
    fn background_add_joins_in_place_but_keeps_focus_and_scroll() {
        let mut e = with(4);
        cmd_arg(&mut e, "focus_window", json!(2));
        let (focus, scroll) = (e.focused(), e.state().scroll);
        let before = e.handle(Event::Query);
        let p = add_quiet(&mut e, 9, false);
        // Same placement as a foreground window (right of the focused column) ...
        assert_eq!(ids(&e), [vec![1], vec![2], vec![9], vec![3], vec![4]]);
        // ... but focus, the focus request and the viewport stay exactly where they were.
        assert_eq!((e.focused(), p.focus, e.state().scroll), (focus, None, scroll));
        assert_eq!(p.map.focused_index, Some(1));
        assert!(!p.show_map && p.changed.contains(&9), "nothing for the map to announce: it would flash over what the user is doing");
        assert_eq!(frame(&p, 2).x, frame(&before, 2).x);
        assert_eq!(e.undo_len(), 0);
    }

    #[test]
    fn foreground_add_focuses_and_reveals() {
        let mut e = with(5);
        cmd_arg(&mut e, "focus_window", json!(1));
        by(&mut e, 700.0);
        assert!(e.state().scroll > 600.0);
        let p = add_to(&mut e, 9, false);
        assert_eq!((e.focused(), p.focus), (Some(9), Some(9)));
        assert_eq!(ids(&e)[1], [9]);
        // Column 1 starts at 494 (482 + gap): the scroll went back to it so the new window shows.
        assert_eq!(e.state().scroll, 494.0);
        assert!(frame(&p, 9).on_screen);
    }

    #[test]
    fn background_add_left_of_the_viewport_leaves_what_is_in_view_in_place() {
        let mut e = with(5);
        cmd_arg(&mut e, "focus_window", json!(1));
        by(&mut e, 700.0);
        let before = e.handle(Event::Query);
        let scroll = e.state().scroll;
        let p = add_quiet(&mut e, 9, false);
        assert_eq!(ids(&e), [vec![1], vec![9], vec![2], vec![3], vec![4], vec![5]]);
        assert_eq!((e.focused(), p.focus), (Some(1), None));
        // The new column (482 wide + 12 gap) went in left of the viewport: the scroll moved by exactly that.
        assert_eq!(e.state().scroll, scroll + 494.0);
        for f in before.frames.iter().filter(|f| f.on_screen) {
            assert_eq!((frame(&p, f.id).x, frame(&p, f.id).w, frame(&p, f.id).on_screen), (f.x, f.w, true), "window {}", f.id);
        }
        assert!(!frame(&p, 9).on_screen);
        // Windows on screen did not need a write; only the new one is new.
        assert!(!p.changed.iter().any(|id| before.frames.iter().any(|f| f.id == *id && f.on_screen)), "{:?}", p.changed);
    }

    #[test]
    fn background_add_at_the_viewport_edge_does_not_push_what_is_in_view() {
        let mut e = with(4);
        cmd_arg(&mut e, "focus_window", json!(1));
        by(&mut e, 494.0); // the viewport starts exactly where column 1 does, which is where the new column goes
        assert_eq!(e.state().scroll, 494.0);
        let before = e.handle(Event::Query);
        let p = add_quiet(&mut e, 9, false);
        assert_eq!(e.state().scroll, 988.0);
        for f in before.frames.iter().filter(|f| f.on_screen) {
            assert_eq!(frame(&p, f.id).x, f.x, "window {}", f.id);
        }
    }

    #[test]
    fn background_add_at_the_end_never_moves_the_viewport() {
        let mut e = Engine::new(Config { new_window: NewWindow::End, ..Config::default() });
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        (1..=3).for_each(|i| {
            add_to(&mut e, i, false);
        });
        cmd_arg(&mut e, "focus_window", json!(1));
        let scroll = e.state().scroll;
        let p = add_quiet(&mut e, 4, false);
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3], vec![4]]);
        assert_eq!((e.focused(), p.focus, e.state().scroll), (Some(1), None, scroll));
    }

    #[test]
    fn background_add_to_a_tabbed_column_keeps_the_shown_tab_and_focus() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_window", json!(2));
        cmd(&mut e, "toggle_tabs"); // window 2 joins its left neighbour: [1, 2] tabbed, 2 shown
        assert_eq!(ids(&e), [vec![1, 2], vec![3]]);
        let before = e.handle(Event::Query);
        let p = add_quiet(&mut e, 9, false);
        // It is a tab right after the active one, like a foreground window, but it is not shown and nothing else changes.
        assert_eq!(ids(&e), [vec![1, 2, 9], vec![3]]);
        assert_eq!((e.focused(), p.focus), (Some(2), None));
        assert_eq!(p.map.columns[0].active, Some(1));
        assert!(!frame(&p, 9).on_screen && frame(&p, 2).on_screen);
        assert!(!p.jump && p.tab_bars[0].active == 2 && p.tab_bars[0].tabs.len() == 3);
        assert_eq!((frame(&p, 2).x, frame(&p, 3).x), (frame(&before, 2).x, frame(&before, 3).x));
        // The same window in the foreground becomes the shown tab and takes focus.
        let mut f = with(3);
        cmd_arg(&mut f, "focus_window", json!(2));
        cmd(&mut f, "toggle_tabs");
        let p = add_to(&mut f, 9, false);
        assert_eq!((f.focused(), p.focus, p.map.columns[0].active), (Some(9), Some(9), Some(2)));
    }

    #[test]
    fn background_floating_add_does_not_take_focus() {
        let mut e = with(2);
        let p = add_quiet(&mut e, 9, true);
        assert_eq!((e.focused(), p.focus), (Some(2), None));
        assert!(e.state().floating.contains(&9));
        // A tiled window keeps focus the same way, and a foreground floater is unchanged (it never took focus from a window).
        add_quiet(&mut e, 8, false);
        assert_eq!(e.focused(), Some(2));
        let p = add_to(&mut e, 7, true);
        assert_eq!((e.focused(), p.focus), (Some(2), None));
    }

    #[test]
    fn background_add_to_an_empty_desktop_is_known_but_asks_the_os_for_nothing() {
        let mut e = eng();
        let p = add_quiet(&mut e, 5, false);
        // The core always has a focus when it has a window, but nothing here has the user's attention to move.
        assert_eq!((e.focused(), p.focus), (Some(5), None));
        assert_eq!(p.map.columns.len(), 1);
        let p = add_quiet(&mut eng(), 6, true);
        assert_eq!(p.focus, None);
    }

    #[test]
    fn take_focus_is_optional_on_the_wire_and_defaults_to_today() {
        let json = |id: u32, extra: &str| format!(r#"{{"type":"window_added","id":{id},"pid":1,"app":"x","title":"","frame":{{"x":0,"y":0,"w":1,"h":1}}{extra}}}"#);
        let mut e = with(2);
        let p = e.handle_json(&json(9, ""));
        assert_eq!((e.focused(), p.focus), (Some(9), Some(9)));
        let p = e.handle_json(&json(10, r#","take_focus":false"#));
        assert_eq!((e.focused(), p.focus, e.window_count()), (Some(9), None, 4));
        let ev: Event = serde_json::from_str(&json(11, r#","take_focus":false"#)).unwrap();
        assert!(matches!(ev, Event::WindowAdded { take_focus: false, .. }));
    }

    #[test]
    fn a_fresh_apps_window_seen_before_the_app_is_active_is_focused_once_it_is() {
        let mut e = with(4);
        cmd_arg(&mut e, "focus_window", json!(1));
        by(&mut e, 900.0);
        add_quiet(&mut e, 9, false);
        assert_eq!(e.focused(), Some(1));
        // The OS reports the app's window as focused when the app comes to the front: the usual follow-the-OS path.
        let p = e.handle(Event::WindowFocused { id: 9 });
        assert_eq!((e.focused(), p.focus), (Some(9), None));
        assert!(frame(&p, 9).on_screen && p.map.focused_index == Some(1));
    }

    #[test]
    fn a_window_unminimized_while_the_user_is_elsewhere_returns_quietly() {
        let mut e = with(4);
        cmd(&mut e, "focus_left"); // 3
        cmd(&mut e, "cycle_width");
        let w3 = frame(&e.handle(Event::Query), 3).w;
        e.handle(Event::WindowMinimized { id: 3 });
        cmd_arg(&mut e, "focus_window", json!(1));
        let (before, s0) = (e.handle(Event::Query), e.st.scroll);
        let p = add_quiet(&mut e, 3, false);
        assert_eq!((e.focused(), p.focus, p.map.focused_index), (Some(1), None, Some(0)));
        assert!(!p.show_map && p.shelf.is_empty() && p.error.is_none(), "no map over what the user is doing");
        assert_eq!(ids(&e), [vec![1], vec![3], vec![2], vec![4]], "back right of the focused column, like a foreground return");
        assert_eq!(frame(&p, 3).w, w3, "with its remembered width");
        assert_eq!((frame(&p, 1).x, e.st.scroll), (frame(&before, 1).x, s0), "the view stays put");
        // The user going there afterwards (the app came to the front) focuses it as usual.
        let p = e.handle(Event::WindowFocused { id: 3 });
        assert!(e.focused() == Some(3) && frame(&p, 3).on_screen);
        // A foreground return still takes focus.
        e.handle(Event::WindowMinimized { id: 2 });
        let p = add_to(&mut e, 2, false);
        assert_eq!((e.focused(), p.focus), (Some(2), Some(2)));
        assert!(p.show_map);
    }

    #[test]
    fn a_quiet_return_to_another_desktop_does_not_switch_there() {
        let mut e = with(2);
        sw(&mut e, 2);
        add_to(&mut e, 20, false);
        add_to(&mut e, 21, false);
        e.handle(Event::WindowMinimized { id: 21 });
        sw(&mut e, 1);
        let p = add_quiet(&mut e, 21, false);
        assert_eq!((e.desktop(), p.focus, e.focused()), (1, None, Some(2)));
        assert!(!p.jump && !p.show_map && p.toast.is_none());
        assert_eq!((on_desk(&e, 1), on_desk(&e, 2)), (vec![1, 2], vec![20, 21]));
        assert!(!frame(&p, 21).on_screen);
        assert_eq!(sw(&mut e, 2).focus, Some(20), "its desktop keeps the focus it had");
    }

    #[test]
    fn a_quiet_return_that_lands_left_of_the_view_keeps_the_view() {
        let mut e = with(4);
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_left"); // 1, at the left edge
        e.handle(Event::WindowMinimized { id: 1 });
        cmd_arg(&mut e, "focus_window", json!(4));
        e.handle(Event::WindowFocused { id: 2 });
        by(&mut e, 900.0); // 2 still has the focus but has scrolled out of view
        let before = e.handle(Event::Query);
        let p = add_quiet(&mut e, 1, false);
        assert_eq!(ids(&e), [vec![2], vec![1], vec![3], vec![4]]);
        for id in [3, 4] {
            assert_eq!((frame(&p, id).x, frame(&p, id).on_screen), (frame(&before, id).x, frame(&before, id).on_screen), "{id} stays where it is on screen");
        }
    }

    #[test]
    fn duplicate_add_is_metadata_refresh() {
        let mut e = with(2);
        add_to(&mut e, 1, false);
        assert_eq!(ids(&e), [vec![1], vec![2]]);
    }

    #[test]
    fn focus_left_right_and_scroll_keep_visible() {
        let mut e = with(4); // lefts 0,494,988,1482; avail 976
        assert_eq!(e.st.scroll, 1482.0 + 482.0 - 976.0);
        let p = cmd(&mut e, "focus_left");
        assert_eq!(p.focus, Some(3));
        assert_eq!(e.st.scroll, 988.0); // aligned to the new focus's left edge: minimal move
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_left");
        assert_eq!(e.st.scroll, 0.0);
        let p = cmd(&mut e, "focus_right");
        assert_eq!(p.focus, Some(2));
        assert!(frame(&p, 2).on_screen);
    }

    #[test]
    fn center_mode_scroll() {
        let mut e = Engine::new(Config { scroll: ScrollMode::Center, ..Config::default() });
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 1000.0, h: 800.0 } });
        (1..=4).for_each(|i| {
            add_to(&mut e, i, false);
        });
        assert_eq!(e.st.scroll, 1482.0 + 241.0 - 488.0);
        cmd(&mut e, "focus_left");
        assert_eq!(e.st.scroll, 988.0 + 241.0 - 488.0);
    }

    #[test]
    fn set_scroll_center_pulls_the_focused_column_to_the_middle_and_keeps_following() {
        let mut e = eng();
        (1..=4).for_each(|i| {
            add_to(&mut e, i, false);
        });
        cmd(&mut e, "focus_left");
        let p = cmd_arg(&mut e, "set_scroll", json!("center"));
        assert!(p.error.is_none() && !p.show_map);
        let f = frame(&p, 3);
        assert_eq!(f.x + f.w / 2, 500, "focused column centered on the 1000pt display");
        let p = cmd(&mut e, "focus_left");
        let f = frame(&p, 2);
        assert_eq!(f.x + f.w / 2, 500, "focus moves stay centered while the mode is on");
        assert!(cmd_arg(&mut e, "set_scroll", json!("keep_visible")).error.is_none());
        assert_eq!(e.cfg.scroll, ScrollMode::KeepVisible);
        assert!(cmd_arg(&mut e, "set_scroll", json!("sideways")).error.is_some());
    }

    #[test]
    fn center_command_in_keep_visible() {
        let mut e = with(4);
        cmd_arg(&mut e, "focus_index", json!(2));
        let p = cmd(&mut e, "center");
        assert_eq!(e.st.scroll, 494.0 + 241.0 - 488.0);
        let f = frame(&p, 2);
        assert_eq!(f.x + f.w / 2, 500); // centered on the 1000pt display
    }

    #[test]
    fn focus_up_down_in_stack() {
        let mut e = with(3);
        cmd(&mut e, "stack"); // 3 into 2
        assert_eq!(ids(&e), [vec![1], vec![2, 3]]);
        assert_eq!(cmd(&mut e, "focus_down").focus, None); // already bottom
        assert_eq!(cmd(&mut e, "focus_up").focus, Some(2));
        assert_eq!(cmd(&mut e, "focus_up").focus, None);
        assert_eq!(cmd(&mut e, "focus_down").focus, Some(3));
        // moving left keeps the row
        cmd(&mut e, "focus_up");
        assert_eq!(cmd(&mut e, "focus_left").focus, Some(1));
        assert_eq!(cmd(&mut e, "focus_right").focus, Some(2));
    }

    /// 6 tiled windows, focus on the last, then a floating dialog (10) takes focus.
    fn with_dialog() -> Engine {
        let mut e = with(6);
        cmd_arg(&mut e, "focus_index", json!(6));
        add_to(&mut e, 10, true);
        e.handle(Event::WindowFocused { id: 10 });
        e
    }
    fn visible_cols(p: &Plan) -> usize {
        p.map.columns.iter().filter(|c| c.visible).count()
    }

    #[test]
    fn floating_focus_display_shrink_keeps_ribbon_visible() {
        let mut e = with_dialog();
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 600.0, h: 800.0 } });
        let p = cmd(&mut e, "gather");
        assert!(visible_cols(&p) > 0);
        assert!(p.map.viewport.start < 1.0 && p.map.columns.last().unwrap().visible);
    }

    #[test]
    fn floating_focus_close_columns_keeps_ribbon_visible() {
        let mut e = with_dialog();
        e.handle(Event::WindowRemoved { id: 5 });
        let p = e.handle(Event::WindowRemoved { id: 6 });
        assert!(visible_cols(&p) > 0);
        assert!(p.frames.iter().any(|f| f.on_screen));
    }

    #[test]
    fn focus_direction_from_floating_is_relative_to_last_tiled() {
        let mut e = with(4);
        cmd_arg(&mut e, "focus_index", json!(3));
        add_to(&mut e, 10, true);
        e.handle(Event::WindowFocused { id: 10 });
        assert_eq!(cmd(&mut e, "focus_left").focus, Some(3)); // re-enter at the anchor
        e.handle(Event::WindowFocused { id: 10 });
        assert_eq!(cmd(&mut e, "focus_right").focus, Some(3));
    }

    #[test]
    fn floating_focus_at_the_ends_never_noops() {
        let mut e = with_dialog(); // anchor is the last column
        assert_eq!(cmd(&mut e, "focus_right").focus, Some(6));
        e.handle(Event::WindowFocused { id: 10 });
        assert_eq!(cmd(&mut e, "focus_left").focus, Some(6));
    }

    #[test]
    fn retiling_a_floated_window_returns_next_to_its_old_place() {
        for focus in 1..=4u32 {
            let mut e = with(4);
            cmd_arg(&mut e, "focus_index", json!(focus));
            cmd(&mut e, "toggle_float");
            cmd(&mut e, "toggle_float");
            let mut expect: Vec<u32> = (1..=4).filter(|i| *i != focus).collect();
            expect.insert(if focus == 1 { 1 } else { focus as usize - 1 }, focus);
            let got: Vec<u32> = ids(&e).concat();
            assert_eq!(got, expect, "focus {focus}");
        }
    }

    #[test]
    fn move_to_index_moves_and_focuses() {
        let mut e = with(4);
        let p = cmd_arg(&mut e, "move_to_index", json!({"id": 4, "index": 1}));
        assert_eq!(ids(&e), [vec![4], vec![1], vec![2], vec![3]]);
        assert_eq!(p.focus, Some(4));
        cmd_arg(&mut e, "move_to_index", json!(3)); // focused window
        assert_eq!(ids(&e), [vec![1], vec![2], vec![4], vec![3]]);
        cmd_arg(&mut e, "move_to_index", json!(99)); // clamps to the end
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3], vec![4]]);
        cmd(&mut e, "undo");
        assert_eq!(ids(&e), [vec![1], vec![2], vec![4], vec![3]]);
        assert!(cmd(&mut e, "move_to_index").error.is_some());
    }

    #[test]
    fn move_to_index_pulls_a_window_out_of_a_stack() {
        let mut e = with(3);
        cmd(&mut e, "stack"); // 3 into 2's column
        cmd_arg(&mut e, "move_to_index", json!(1));
        assert_eq!(ids(&e), [vec![3], vec![1], vec![2]]);
    }

    #[test]
    fn untiling_a_float_inserts_right_of_last_tiled() {
        let mut e = with(5);
        cmd_arg(&mut e, "focus_index", json!(2));
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        cmd(&mut e, "toggle_float");
        assert_eq!(ids(&e), [vec![1], vec![2], vec![9], vec![3], vec![4], vec![5]]);
    }

    #[test]
    fn focus_window_unknown_id_is_a_silent_noop() {
        let mut e = with(2);
        let n = e.undo_len();
        let p = cmd_arg(&mut e, "focus_window", json!(77));
        assert!(!p.show_map && p.error.is_none());
        assert_eq!((e.focused(), e.undo_len()), (Some(2), n));
    }

    #[test]
    fn focus_commands_are_not_undoable() {
        let mut e = with(3);
        cmd(&mut e, "move_left");
        let n = e.undo_len();
        let s = e.st.clone();
        for c in ["focus_left", "focus_right", "center"] {
            cmd(&mut e, c);
        }
        cmd_arg(&mut e, "focus_index", json!(1));
        cmd_arg(&mut e, "focus_window", json!(3));
        assert_eq!(e.undo_len(), n);
        cmd(&mut e, "undo"); // undoes the move, not the navigation
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]);
        assert_ne!(e.st, s);
    }

    #[test]
    fn move_left_right() {
        let mut e = with(3);
        cmd(&mut e, "move_left");
        assert_eq!(ids(&e), [vec![1], vec![3], vec![2]]);
        cmd(&mut e, "move_right");
        cmd(&mut e, "move_right"); // at end: no-op
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]);
        assert_eq!(e.undo_len(), 2); // the no-op was not recorded
    }

    #[test]
    fn cycle_width_wraps_both_ways() {
        let mut e = with(1);
        let w = |e: &Engine| e.st.columns[0].width;
        for want in [0.667, 0.75, 1.0, 0.25 /* wrap */, 0.333, 0.5] {
            cmd(&mut e, "cycle_width");
            assert_eq!(w(&e), Width::Frac(want));
        }
        for want in [0.333, 0.25, 1.0 /* wrap back */, 0.75, 0.667] {
            cmd(&mut e, "cycle_width_back");
            assert_eq!(w(&e), Width::Frac(want));
        }
    }

    #[test]
    fn set_width_sets_the_focused_column_directly_and_toasts() {
        let mut e = with(2);
        let w = |e: &Engine| e.st.columns[1].width;
        for (f, want, label) in [(0.667, 0.667, "Width 66\u{a0}%"), (0.25, 0.25, "Width 25\u{a0}%"), (0.333, 0.333, "Width 33\u{a0}%"), (0.5, 0.5, "Width 50\u{a0}%"), (0.75, 0.75, "Width 75\u{a0}%")] {
            let p = cmd_arg(&mut e, "set_width", json!(f));
            assert!(p.error.is_none());
            assert_eq!(w(&e), Width::Frac(want));
            assert_eq!(toast(p).as_deref(), Some(label));
        }
        assert_eq!(toast(cmd_arg(&mut e, "set_width", json!({"fraction": 1.0}))).as_deref(), Some("Width 100\u{a0}%"));
        assert_eq!(w(&e), Width::Frac(1.0));
        assert_eq!(e.st.columns[0].width, Width::Frac(0.5), "other columns untouched");
        // Same width again: no change, still confirmed, no undo step.
        let n = e.undo_len();
        assert_eq!(toast(cmd_arg(&mut e, "set_width", json!(1.0))).as_deref(), Some("Width 100\u{a0}%"));
        assert_eq!(e.undo_len(), n);
    }

    #[test]
    fn set_width_is_undoable_and_forgets_the_full_width_restore() {
        let mut e = with(1);
        cmd(&mut e, "toggle_full");
        cmd_arg(&mut e, "set_width", json!(0.333));
        assert_eq!(e.st.columns[0].width, Width::Frac(0.333));
        assert!(e.st.columns[0].restore.is_none());
        let p = cmd(&mut e, "undo");
        assert_eq!(e.st.columns[0].width, Width::Frac(1.0));
        assert_eq!(toast(p).as_deref(), Some("Undid: width"));
        cmd(&mut e, "redo");
        assert_eq!(e.st.columns[0].width, Width::Frac(0.333));
    }

    #[test]
    fn set_width_rejects_bad_fractions_and_respects_the_floor() {
        let mut e = with(1);
        for bad in [json!(0.0), json!(-0.5), json!(1.5), json!("wide"), json!(null)] {
            let before = e.st.clone();
            assert!(cmd_arg(&mut e, "set_width", bad).error.is_some());
            assert_eq!(e.st, before);
        }
        // Arbitrary tiny widths are lifted to the floor (360px on a 1000px display = ~0.37)...
        cmd_arg(&mut e, "set_width", json!(0.05));
        let avail = e.avail();
        let px = layout::width_px(e.st.columns[0].width, &e.cfg, avail);
        assert!(px >= layout::MIN_COL_PX - 1.0 || e.st.columns[0].width == Width::Frac(0.25), "{px}");
        assert!(matches!(e.st.columns[0].width, Width::Frac(f) if f >= 0.25 - 1e-9), "never below the smallest preset");
        // ...but every configured preset stays reachable, like cycling (25 % is under the floor on a narrow display).
        cmd_arg(&mut e, "set_width", json!(0.25));
        assert_eq!(e.st.columns[0].width, Width::Frac(0.25));
    }

    #[test]
    fn set_width_with_no_focused_column_is_harmless() {
        let mut e = eng();
        let p = cmd_arg(&mut e, "set_width", json!(0.5));
        assert!(p.error.is_none());
        assert!(e.st.columns.is_empty());
    }

    #[test]
    fn set_width_presets_takes_effect_live_without_touching_the_layout() {
        let mut e = with(2);
        let before = e.state().clone();
        let p = cmd_arg(&mut e, "set_width_presets", json!([0.333, 0.5, 0.667, 1.0]));
        assert!(p.error.is_none() && !p.show_map && e.state() == &before && e.undo_len() == 0);
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 66\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 100\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 33\u{a0}%"), "no ¾ or ¼ in the simple list");
        assert!(cmd_arg(&mut e, "set_width_presets", json!([])).error.is_some());
    }

    #[test]
    fn set_config_takes_settings_live_and_keeps_the_layout_as_it_is() {
        // Changing the gap in Settings used to rebuild the ribbon from scratch: stacks and tabs came apart, widths reset.
        let mut e = with(5);
        cmd_arg(&mut e, "focus_window", json!(2));
        cmd(&mut e, "stack"); // [1 2] [3] [4] [5]
        cmd_arg(&mut e, "focus_window", json!(1));
        cmd(&mut e, "toggle_tabs");
        cmd_arg(&mut e, "focus_window", json!(3));
        cmd_arg(&mut e, "set_width", json!(0.75));
        cmd_arg(&mut e, "focus_window", json!(5));
        cmd_arg(&mut e, "move_to_desktop", json!(2));
        add_to(&mut e, 6, true);
        cmd_arg(&mut e, "focus_window", json!(1));
        let (cols, floating, desks, undo) = (e.st.columns.clone(), e.st.floating.clone(), e.desktop_windows(), e.undo_len());
        assert_eq!(ids(&e), vec![vec![1, 2], vec![3], vec![4]]);
        let p = cmd_arg(
            &mut e,
            "set_config",
            json!({"gap": 20.0, "outer_gap": 20.0, "default_width": 0.333, "new_window": "end", "scroll": "keep_visible", "width_presets": [0.333, 0.5, 0.667, 1.0]}),
        );
        assert!(p.error.is_none() && !p.show_map);
        assert_eq!((&e.st.columns, &e.st.floating, e.desktop_windows(), e.undo_len()), (&cols, &floating, desks, undo));
        assert_eq!(frame(&p, 3).x - (frame(&p, 1).x + frame(&p, 1).w), 20, "the new gap is live");
        assert_eq!(frame(&p, 1).x, 20, "and so is the outer gap");
        // Placement and default width are live too: a new window goes to the end at ⅓.
        add_to(&mut e, 7, false);
        cmd_arg(&mut e, "focus_window", json!(1));
        add_to(&mut e, 8, false);
        assert_eq!(ids(&e), vec![vec![1, 2], vec![3], vec![4], vec![7], vec![8]]);
        assert_eq!(e.st.columns[4].width, Width::Frac(0.333));
        // Keys left out keep their values; nonsense is refused and changes nothing.
        cmd_arg(&mut e, "set_config", json!({"gap": 8.0}));
        assert_eq!((e.cfg.gap, e.cfg.outer_gap, e.cfg.new_window), (8.0, 20.0, NewWindow::End));
        let cfg = e.cfg.clone();
        for bad in [json!(5), json!({"gap": "wide"}), json!(null)] {
            assert!(cmd_arg(&mut e, "set_config", bad).error.is_some());
            assert_eq!(e.cfg, cfg);
        }
        assert!(cmd(&mut e, "set_config").error.is_some());
    }

    #[test]
    fn set_floating_puts_an_apps_windows_out_of_and_back_into_the_ribbon_in_one_step() {
        // "Keep Finder out of the ribbon" used to float only the focused Finder window; the others stayed in their columns.
        let mut e = with(5);
        cmd_arg(&mut e, "focus_window", json!(2));
        cmd(&mut e, "stack"); // [1 2] [3] [4] [5]
        cmd_arg(&mut e, "focus_window", json!(4));
        cmd_arg(&mut e, "set_width", json!(0.75));
        cmd_arg(&mut e, "focus_window", json!(5));
        cmd_arg(&mut e, "move_to_desktop", json!(2));
        cmd_arg(&mut e, "focus_window", json!(3));
        let (before, undo) = (e.st.clone(), e.undo_len());
        let p = cmd_arg(&mut e, "set_floating", json!({"ids": [2, 4, 5, 99], "floating": true}));
        assert!(p.error.is_none() && p.frames.iter().all(|f| ![2, 4, 5].contains(&f.id)));
        assert_eq!((ids(&e), e.focused(), e.undo_len()), (vec![vec![1], vec![3]], Some(3), undo + 1));
        assert_eq!(e.st.floating, [2, 4].into());
        assert!(e.desktop_windows()[1].contains(&5) && !e.others[1].st.columns.iter().any(|c| c.windows.contains(&5)));
        // Again: nothing to do, nothing recorded.
        cmd_arg(&mut e, "set_floating", json!({"ids": [2, 4, 5], "floating": true}));
        assert_eq!(e.undo_len(), undo + 1);
        // Back in: at the end of the ribbon, with the width each had; focus stays.
        cmd_arg(&mut e, "set_floating", json!({"ids": [4, 2], "floating": false}));
        assert_eq!((ids(&e), e.focused()), (vec![vec![1], vec![3], vec![4], vec![2]], Some(3)));
        assert_eq!(e.st.columns[2].width, before.columns[2].width);
        // One undo per step, across desktops: two undos bring back the stack, the width and window 5's column on desktop 2.
        cmd(&mut e, "undo");
        cmd(&mut e, "undo");
        assert_eq!((&e.st.columns, &e.st.floating), (&before.columns, &before.floating));
        assert!(e.others[1].st.columns.iter().any(|c| c.windows == [5]));
        assert!(cmd_arg(&mut e, "set_floating", json!([2])).error.is_some());
        assert!(cmd_arg(&mut e, "set_floating", json!({"ids": [2]})).error.is_some());
    }

    #[test]
    fn set_floating_reaches_a_minimized_window_when_it_comes_back() {
        let mut e = with(3);
        e.handle(Event::WindowMinimized { id: 2 });
        cmd_arg(&mut e, "set_floating", json!({"ids": [2], "floating": true}));
        add_to(&mut e, 2, false);
        assert!(e.st.floating.contains(&2) && ids(&e) == vec![vec![1], vec![3]]);
    }

    #[test]
    fn simple_presets_keep_the_old_cycle() {
        let cfg = Config { width_presets: Config::PRESETS_SIMPLE.to_vec(), ..Config::default() };
        let mut e = Engine::new(cfg);
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        add_to(&mut e, 1, false);
        let w = |e: &Engine| e.st.columns[0].width;
        for want in [0.667, 1.0, 0.333, 0.5] {
            cmd(&mut e, "cycle_width");
            assert_eq!(w(&e), Width::Frac(want));
        }
    }

    #[test]
    fn default_presets_are_the_rich_list_and_labelled() {
        assert_eq!(Config::default().width_presets, vec![0.25, 0.333, 0.5, 0.667, 0.75, 1.0]);
        let mut e = with(1);
        let labels: Vec<String> = (0..6).filter_map(|_| toast(cmd(&mut e, "cycle_width"))).collect();
        assert_eq!(labels, ["Width 66\u{a0}%", "Width 75\u{a0}%", "Width 100\u{a0}%", "Width 25\u{a0}%", "Width 33\u{a0}%", "Width 50\u{a0}%"]);
    }

    #[test]
    fn every_preset_lays_out_inside_the_display_and_survives_its_own_echo() {
        // 1440pt wide: ¼ is 345px, below the 360px drag floor; the cycle still gets there and an echoed resize keeps it.
        let mut e = Engine::new(Config::default());
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1440.0, h: 900.0 } });
        add_to(&mut e, 1, false);
        add_to(&mut e, 2, false);
        for _ in 0..6 {
            let p = cmd(&mut e, "cycle_width");
            let f = frame(&p, 2).clone();
            let frac = e.state().columns[1].width;
            assert!(f.w >= 1 && f.x + f.w <= 1440 - 12 + 1 || !f.on_screen, "{f:?}");
            // the app reports exactly the frame we wrote: no change to the column
            e.handle(Event::WindowResized { id: 2, frame: Rect { x: f.x as f64, y: f.y as f64, w: f.w as f64, h: f.h as f64 } });
            assert_eq!(e.state().columns[1].width, frac, "echo changed {frac:?}");
        }
        let quarter = layout::width_px(Width::Frac(0.25), &Config::default(), 1416.0);
        assert!(quarter < layout::MIN_COL_PX, "documented: the smallest preset is below the drag floor ({quarter})");
    }

    #[test]
    fn cycle_from_px_width_uses_nearest_greater() {
        let mut e = with(1);
        e.st.columns[0].width = Width::Px(600.0); // frac ~0.62
        cmd(&mut e, "cycle_width");
        assert_eq!(e.st.columns[0].width, Width::Frac(0.667));
        e.st.columns[0].width = Width::Px(600.0);
        cmd(&mut e, "cycle_width_back");
        assert_eq!(e.st.columns[0].width, Width::Frac(0.5));
    }

    #[test]
    fn toggle_full_restores_and_cycle_clears_restore() {
        let mut e = with(2);
        cmd(&mut e, "cycle_width"); // 0.667
        let p = cmd(&mut e, "toggle_full");
        assert_eq!(frame(&p, 2).w, 976);
        let p = cmd(&mut e, "toggle_full");
        assert_eq!(e.st.columns[1].width, Width::Frac(0.667));
        assert!(frame(&p, 2).w < 976);
        cmd(&mut e, "toggle_full");
        cmd(&mut e, "cycle_width");
        assert_eq!(e.st.columns[1].restore, None);
        // already full (via a preset) with nothing to restore -> default width
        (0..5).for_each(|_| {
            cmd(&mut e, "cycle_width");
        });
        assert_eq!(e.st.columns[1].width, Width::Frac(1.0));
        cmd(&mut e, "toggle_full");
        assert_eq!(e.st.columns[1].width, Width::Frac(0.5));
    }

    #[test]
    fn stack_at_index_zero_is_noop_and_unrecorded() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_index", json!(1));
        let n = e.undo_len();
        let p = cmd(&mut e, "stack");
        assert!(p.show_map && ids(&e) == [vec![1], vec![2], vec![3]]);
        assert_eq!(e.undo_len(), n);
    }

    #[test]
    fn stack_merges_only_focused_window_and_drops_empty_column() {
        let mut e = with(3);
        cmd(&mut e, "stack");
        assert_eq!(ids(&e), [vec![1], vec![2, 3]]);
        cmd(&mut e, "focus_up");
        cmd(&mut e, "stack"); // 2 -> into 1
        assert_eq!(ids(&e), [vec![1, 2], vec![3]]);
        let p = cmd(&mut e, "unstack");
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]);
        assert_eq!(e.focused(), Some(2));
        assert_eq!(p.map.focused_index, Some(1));
        assert_eq!(cmd(&mut e, "unstack").changed.len(), 0); // single window: no-op
    }

    #[test]
    fn stacked_frames_share_x_and_split_height() {
        let mut e = with(2);
        let p = cmd(&mut e, "stack");
        let (a, b) = (frame(&p, 1), frame(&p, 2));
        assert_eq!((a.x, a.w), (b.x, b.w));
        assert_eq!(a.y, 37);
        assert_eq!(b.y + b.h, 813);
        assert_eq!(p.map.columns.len(), 1);
    }

    #[test]
    fn focus_index_clamps_and_validates() {
        let mut e = with(3);
        assert_eq!(cmd_arg(&mut e, "focus_index", json!(1)).focus, Some(1));
        assert_eq!(cmd_arg(&mut e, "focus_index", json!("2")).focus, Some(2));
        assert_eq!(cmd_arg(&mut e, "focus_index", json!(9)).focus, Some(3));
        assert_eq!(cmd_arg(&mut e, "focus_index", json!(0)).focus, None);
        assert!(cmd(&mut e, "focus_index").error.is_some());
    }

    #[test]
    fn focus_window_command_always_emits_focus() {
        let mut e = with(3);
        assert_eq!(cmd_arg(&mut e, "focus_window", json!(1)).focus, Some(1));
        assert_eq!(cmd_arg(&mut e, "focus_window", json!(1)).focus, Some(1));
        assert_eq!(cmd_arg(&mut e, "focus_window", json!(99)).focus, Some(1));
        assert!(cmd(&mut e, "focus_window").error.is_some());
    }

    #[test]
    fn os_focus_scrolls_but_does_not_request_focus() {
        let mut e = with(4);
        let p = e.handle(Event::WindowFocused { id: 1 });
        assert_eq!(p.focus, None);
        assert!(p.show_map && e.st.scroll == 0.0 && frame(&p, 1).on_screen);
        let p = e.handle(Event::WindowFocused { id: 1 });
        assert!(!p.show_map);
        assert!(!e.handle(Event::WindowFocused { id: 77 }).show_map);
        assert_eq!(e.focused(), Some(1));
    }

    #[test]
    fn remove_focused_prefers_left_then_right() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_index", json!(2));
        let p = e.handle(Event::WindowRemoved { id: 2 });
        assert_eq!((p.focus, e.focused()), (Some(1), Some(1)));
        assert!(p.show_map);
        let p = e.handle(Event::WindowRemoved { id: 1 });
        assert_eq!(p.focus, Some(3)); // no left neighbor -> right
        let p = e.handle(Event::WindowRemoved { id: 3 });
        assert_eq!((p.focus, e.focused()), (None, None));
        assert!(p.frames.is_empty() && p.map.columns.is_empty());
    }

    #[test]
    fn remove_in_stack_focuses_mate_and_unfocused_removal_keeps_focus() {
        let mut e = with(3);
        cmd(&mut e, "stack");
        e.handle(Event::WindowRemoved { id: 3 });
        assert_eq!((e.focused(), ids(&e)), (Some(2), vec![vec![1], vec![2]]));
        e.handle(Event::WindowRemoved { id: 1 });
        assert_eq!(e.focused(), Some(2));
        assert!(!e.handle(Event::WindowRemoved { id: 1 }).show_map); // unknown
    }

    #[test]
    fn remove_scrolls_back_into_content() {
        let mut e = with(4);
        e.handle(Event::WindowRemoved { id: 4 });
        e.handle(Event::WindowRemoved { id: 3 });
        assert_eq!(e.st.scroll, 0.0); // 2 columns fit: no stale blank space
    }

    #[test]
    fn floating_windows_are_known_but_not_tiled() {
        let mut e = with(2);
        let p = add_to(&mut e, 10, true);
        assert!(p.frames.iter().all(|f| f.id != 10) && p.changed.is_empty());
        assert_eq!(e.window_count(), 3);
        assert_eq!(e.focused(), Some(2)); // floating add does not steal focus
        assert_eq!(ids(&e), [vec![1], vec![2]]);
        // OS focuses it; it is the focus but no column is focused
        let p = e.handle(Event::WindowFocused { id: 10 });
        assert_eq!(p.map.focused_index, None);
        assert!(p.map.columns.iter().all(|c| !c.focused));
        // navigation re-enters the ribbon at the anchor
        assert_eq!(cmd(&mut e, "focus_left").focus, Some(2));
    }

    #[test]
    fn toggle_float_roundtrip() {
        let mut e = with(3);
        cmd(&mut e, "focus_left");
        let p = cmd(&mut e, "toggle_float");
        assert_eq!(ids(&e), [vec![1], vec![3]]);
        assert!(p.frames.iter().all(|f| f.id != 2));
        assert_eq!(e.focused(), Some(2));
        assert_eq!(window_ids(&p), [1, 3]);
        let p = cmd(&mut e, "toggle_float");
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]); // back next to where it was
        assert!(p.frames.iter().any(|f| f.id == 2));
        cmd(&mut e, "undo");
        assert_eq!(ids(&e), [vec![1], vec![3]]);
        assert!(e.st.floating.contains(&2));
    }

    fn float_roundtrip(e: &mut Engine) {
        cmd(e, "toggle_float");
        assert!(e.st.floating.contains(&2));
        cmd(e, "toggle_float");
        assert!(e.st.float_widths.is_empty());
    }

    #[test]
    fn refloating_restores_the_column_width() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_index", json!(2));
        cmd(&mut e, "cycle_width");
        let w = e.st.columns[1].width;
        assert_ne!(w, Width::Frac(0.5));
        float_roundtrip(&mut e);
        assert_eq!(e.st.columns[1].windows, [2]);
        assert_eq!(e.st.columns[1].width, w);
        // undo of the re-tile floats it again and keeps the memory; redo restores the width.
        cmd(&mut e, "undo");
        assert_eq!(e.st.float_widths.get(&2), Some(&w));
        cmd(&mut e, "redo");
        assert_eq!(e.st.columns[1].width, w);
    }

    #[test]
    fn refloating_restores_a_dragged_px_width() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_index", json!(2));
        e.st.columns[1].width = Width::Px(700.0);
        float_roundtrip(&mut e);
        assert_eq!(e.st.columns[1].width, Width::Px(700.0));
    }

    #[test]
    fn window_floated_from_the_start_tiles_at_the_default_width() {
        let mut e = with(2);
        add_to(&mut e, 3, true);
        cmd_arg(&mut e, "focus_window", json!(3));
        cmd(&mut e, "toggle_float");
        let c = e.st.columns.iter().find(|c| c.windows == [3]).unwrap();
        assert_eq!(c.width, Width::Frac(e.cfg.default_width));
    }

    #[test]
    fn removing_a_floating_window_forgets_its_width() {
        let mut e = with(2);
        cmd(&mut e, "toggle_float");
        assert_eq!(e.st.float_widths.len(), 1);
        let id = e.focused().unwrap();
        e.handle(Event::WindowRemoved { id });
        assert!(e.st.float_widths.is_empty());
    }

    fn window_ids(p: &Plan) -> Vec<u32> {
        p.frames.iter().map(|f| f.id).collect()
    }

    #[test]
    fn removing_floating_focus_falls_back() {
        let mut e = with(2);
        add_to(&mut e, 10, true);
        e.handle(Event::WindowFocused { id: 10 });
        let p = e.handle(Event::WindowRemoved { id: 10 });
        assert!(p.focus.is_some() && e.focused().is_some());
    }

    #[test]
    fn focus_previous_toggles_and_skips_closed() {
        let mut e = with(3); // focus order: 1,2,3
        assert_eq!(cmd(&mut e, "focus_previous").focus, Some(2));
        assert_eq!(cmd(&mut e, "focus_previous").focus, Some(3)); // twice = toggle
        assert_eq!(cmd(&mut e, "focus_previous").focus, Some(2));
        e.handle(Event::WindowFocused { id: 1 }); // history: 1,2,3
        e.handle(Event::WindowRemoved { id: 2 });
        assert_eq!(cmd(&mut e, "focus_previous").focus, Some(3)); // 2 is gone
        assert_eq!(e.undo_len(), 0); // navigation: not undoable
    }

    #[test]
    fn focus_previous_with_no_history_is_a_noop() {
        let mut e = with(1);
        let p = cmd(&mut e, "focus_previous");
        assert!(p.error.is_none() && !p.show_map);
        assert_eq!(e.focused(), Some(1));
        assert_eq!(e.undo_len(), 0);
    }

    #[test]
    fn stack_edge_toasts_only_inside_a_stack() {
        let mut e = with(3);
        assert_eq!(toast(cmd(&mut e, "focus_up")).as_deref(), Some("No stack here"));
        cmd(&mut e, "stack");
        assert_eq!(toast(cmd(&mut e, "focus_down")).as_deref(), Some("Bottom of the stack"));
        assert_eq!(toast(cmd(&mut e, "focus_up")), None);
        assert_eq!(toast(cmd(&mut e, "focus_up")).as_deref(), Some("Top of the stack"));
    }

    fn drag(e: &mut Engine, id: u32, w: f64, h: f64) -> Plan {
        e.handle(Event::WindowResized { id, frame: Rect { x: 0.0, y: 0.0, w, h } })
    }

    #[test]
    fn clamped_resize_rewrites_the_window() {
        let mut e = with(2);
        // Drag steps down to the 360px floor, then below it: the plan keeps 360 but the window is at 344.
        for w in [500.0, 400.0, 361.0] {
            drag(&mut e, 2, w, 774.0);
        }
        let p = drag(&mut e, 2, 344.0, 774.0);
        assert_eq!(frame(&p, 2).w, 361);
        assert!(p.changed.contains(&2), "window must be re-written to the plan frame");
        // A normal drag that the plan keeps as-is does not ask for a write-back.
        let p = drag(&mut e, 2, 420.0, 774.0);
        assert_eq!(frame(&p, 2).w, 420);
        assert!(p.changed.contains(&2)); // width changed, so it is in the diff anyway
        let p = drag(&mut e, 2, 420.0, 774.0);
        assert!(p.changed.is_empty());
    }

    #[test]
    fn resize_drag_is_one_undo_step() {
        let mut e = with(2);
        let w0 = frame(&e.handle(Event::Query), 2).w;
        let n0 = e.undo_len();
        for w in [480.0, 450.0, 430.0, 415.0] {
            drag(&mut e, 2, w, 774.0);
        }
        assert_eq!(e.undo_len(), n0 + 1);
        drag(&mut e, 2, 415.0, 774.0); // echo: no new step
        assert_eq!(e.undo_len(), n0 + 1);
        assert_eq!(frame(&e.handle(Event::Query), 2).w, 415);
        let p = cmd(&mut e, "undo");
        assert_eq!(p.toast.as_deref(), Some("Undid: resize"));
        assert_eq!(frame(&p, 2).w, w0);
        let p = cmd(&mut e, "redo");
        assert_eq!(p.toast.as_deref(), Some("Redid: resize"));
        assert_eq!(frame(&p, 2).w, 415);
    }

    #[test]
    fn resize_steps_join_only_without_other_edits_between() {
        let mut e = with(2);
        let n0 = e.undo_len();
        drag(&mut e, 2, 430.0, 774.0);
        cmd(&mut e, "cycle_width");
        drag(&mut e, 2, 420.0, 774.0);
        drag(&mut e, 1, 400.0, 774.0); // another window: its own step
        assert_eq!(e.undo_len(), n0 + 4);
    }

    #[test]
    fn stack_height_drag_undoes_to_old_height() {
        let mut e = with(2);
        cmd(&mut e, "stack");
        let h0 = frame(&e.handle(Event::Query), 2).h;
        for h in [400.0, 430.0, 460.0] {
            drag(&mut e, 2, 500.0, h);
        }
        let p = cmd(&mut e, "undo");
        assert_eq!(frame(&p, 2).h, h0);
    }

    #[test]
    fn width_hint_beats_config_beats_default_and_snaps() {
        let mut cfg = Config::default();
        cfg.app_widths.insert("App2".into(), 0.333);
        let mut e = Engine::new(cfg);
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        let add = |e: &mut Engine, id: u32, hint: Option<f64>| {
            e.handle(Event::WindowAdded { id, pid: 1, app: format!("App{id}"), title: String::new(), frame: R, floating: false, width_hint: hint, take_focus: true });
        };
        add(&mut e, 1, None);
        add(&mut e, 2, None);
        add(&mut e, 3, Some(0.66));
        add(&mut e, 4, Some(7.0)); // nonsense hint falls back
        let w = |e: &Engine, c: usize| e.st.columns[c].width;
        assert_eq!(w(&e, 0), Width::Frac(0.5));
        assert_eq!(w(&e, 1), Width::Frac(0.333));
        assert_eq!(w(&e, 2), Width::Frac(0.667));
        assert_eq!(w(&e, 3), Width::Frac(0.5));
        let ev: Event = serde_json::from_str(r#"{"type":"window_added","id":9,"pid":1,"app":"x","title":"","frame":{"x":0,"y":0,"w":1,"h":1},"width_hint":0.333}"#).unwrap();
        assert!(matches!(ev, Event::WindowAdded { width_hint: Some(_), .. }));
    }

    #[test]
    fn resize_adopts_px_and_snaps_to_preset() {
        let mut e = with(2);
        let rs = |e: &mut Engine, w: f64| e.handle(Event::WindowResized { id: 2, frame: Rect { x: 0.0, y: 0.0, w, h: 774.0 } });
        let p = rs(&mut e, 700.0);
        assert_eq!(e.st.columns[1].width, Width::Px(700.0));
        assert_eq!(frame(&p, 2).w, 700);
        assert!(!p.show_map);
        // preset 0.667 = 0.667*988-12 = 647.0; within 24px snaps
        rs(&mut e, 660.0);
        assert_eq!(e.st.columns[1].width, Width::Frac(0.667));
        // an echo of our own frame is ignored
        let p = rs(&mut e, 647.0);
        assert!(p.changed.is_empty());
        assert_eq!(e.st.columns[1].width, Width::Frac(0.667));
        // unknown / floating windows ignored
        e.handle(Event::WindowResized { id: 42, frame: Rect { x: 0.0, y: 0.0, w: 10.0, h: 10.0 } });
    }

    #[test]
    fn title_updates_map_only() {
        let mut e = with(1);
        let p = e.handle(Event::WindowTitle { id: 1, title: "new".into() });
        assert_eq!(p.map.columns[0].windows[0].title, "new");
        assert!(!p.show_map && p.changed.is_empty());
    }

    #[test]
    fn changed_is_diff_against_previous_plan() {
        let mut e = with(3);
        let p = e.handle(Event::Query);
        assert!(p.changed.is_empty() && !p.show_map && p.focus.is_none());
        let p = cmd(&mut e, "focus_left");
        // scroll moved? only if needed; col 2 was visible
        assert!(p.changed.is_empty());
        let p = cmd(&mut e, "cycle_width");
        assert_eq!(p.changed, vec![2, 3]); // 2 resized, 3 shifted
        let p = cmd(&mut e, "gather");
        assert_eq!(p.changed, vec![1, 2, 3]);
        assert_eq!(p.focus, Some(2));
    }

    #[test]
    fn off_screen_frames_for_far_columns() {
        let e = with(5);
        let p = &mut { e };
        let pl = p.handle(Event::Query);
        assert!(pl.frames.iter().filter(|f| !f.on_screen).count() >= 2);
        assert!(pl.map.columns.iter().filter(|c| !c.visible).count() >= 2);
        assert!(pl.map.viewport.end > 0.99 && pl.map.viewport.start > 0.4);
    }

    #[test]
    fn undo_redo_restores_exact_state() {
        let mut e = with(3);
        let s0 = e.st.clone();
        cmd(&mut e, "move_left");
        cmd(&mut e, "cycle_width");
        let s2 = e.st.clone();
        let p = cmd(&mut e, "undo");
        assert_eq!(p.focus, e.focused());
        cmd(&mut e, "undo");
        assert_eq!(e.st, s0);
        cmd(&mut e, "undo"); // nothing left: harmless
        assert_eq!(e.st, s0);
        cmd(&mut e, "redo");
        cmd(&mut e, "redo");
        assert_eq!(e.st, s2);
        cmd(&mut e, "undo");
        cmd(&mut e, "toggle_full"); // new command clears redo
        cmd(&mut e, "redo");
        assert!(e.st.columns[1].restore.is_some());
    }

    #[test]
    fn undo_limit_is_fifty() {
        let mut e = with(2);
        for _ in 0..80 {
            cmd(&mut e, "cycle_width");
        }
        assert_eq!(e.undo_len(), 50);
    }

    #[test]
    fn undo_reconciles_with_removed_and_added_windows() {
        let mut e = with(3);
        cmd(&mut e, "move_left"); // [1,3,2]
        e.handle(Event::WindowRemoved { id: 3 });
        add_to(&mut e, 4, false);
        cmd(&mut e, "undo");
        let flat: Vec<u32> = ids(&e).concat();
        let mut sorted = flat.clone();
        sorted.sort();
        assert_eq!(sorted, [1, 2, 4]);
        assert!(e.focused().is_some_and(|f| flat.contains(&f)));
    }

    #[test]
    fn unknown_command_reports_error_without_map() {
        let mut e = with(1);
        let p = cmd(&mut e, "bogus");
        assert!(p.error.is_some() && !p.show_map);
        assert_eq!(p.frames.len(), 1);
    }

    #[test]
    fn bad_json_gives_error_plan() {
        let mut e = with(1);
        let p = e.handle_json(r#"{"type":"nope"}"#);
        assert!(p.error.is_some() && p.frames.is_empty());
        let p = e.handle_json(r#"{"type":"query"}"#);
        assert!(p.error.is_none() && p.frames.len() == 1);
    }

    #[test]
    fn config_sanitized_and_event_json_shapes() {
        let c: Config = serde_json::from_str(r#"{"gap": -5, "width_presets": [], "default_width": 7}"#).unwrap();
        let c = c.sanitized();
        assert_eq!((c.gap, c.default_width), (0.0, 0.5));
        assert_eq!(c.width_presets.len(), 6);
        let ev: Event = serde_json::from_str(r#"{"type":"command","name":"focus_index","arg":3}"#).unwrap();
        assert!(matches!(ev, Event::Command { arg: Some(_), .. }));
        let ev: Event = serde_json::from_str(r#"{"type":"window_added","id":1,"pid":2,"app":"a","title":"t","frame":{"x":0,"y":0,"w":1,"h":1}}"#).unwrap();
        assert!(matches!(ev, Event::WindowAdded { floating: false, .. }));
    }

    #[test]
    fn display_change_relayouts() {
        let mut e = with(2);
        let p = e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 2000.0, h: 1000.0 } });
        assert!(p.show_map);
        assert_eq!(p.changed, vec![1, 2]);
        let p = e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 2000.0, h: 1000.0 } });
        assert!(!p.show_map && p.changed.is_empty());
    }

    // ---- UX-simulation regressions (qa/ux-sim) ----

    fn replay(json: &str, upto: Option<usize>) -> (Engine, Vec<Plan>) {
        let events: Vec<Event> = serde_json::from_str(json).unwrap();
        let mut e = Engine::new(Config::default());
        let n = upto.unwrap_or(events.len());
        let plans = events.into_iter().take(n).map(|ev| e.handle(ev)).collect();
        (e, plans)
    }
    fn fully_on_screen(p: &Plan, id: u32, d: Rect) -> bool {
        let f = frame(p, id);
        f.on_screen && f.x as f64 >= d.x && (f.x + f.w) as f64 <= d.x + d.w
    }

    #[test]
    fn undo_reveals_focused_column() {
        let d = Rect { x: 0.0, y: 33.0, w: 1512.0, h: 949.0 };
        let (e, plans) = replay(include_str!("../../qa/ux-sim/repro_undo_offscreen_focus.json"), None);
        assert_eq!(e.focused(), Some(26));
        assert!(fully_on_screen(plans.last().unwrap(), 26, d));
    }

    #[test]
    fn undo_after_display_swap_reveals_focused_column() {
        let d = Rect { x: 0.0, y: 33.0, w: 1512.0, h: 949.0 };
        let (e, plans) = replay(include_str!("../../qa/ux-sim/repro_undo_after_display_swap.json"), None);
        assert_eq!(e.focused(), Some(5));
        assert!(fully_on_screen(plans.last().unwrap(), 5, d));
    }

    #[test]
    fn undo_after_close_reverts_older_change_and_says_so() {
        let (e, plans) = replay(include_str!("../../qa/ux-sim/repro_undo_skips_close.json"), None);
        assert_eq!(plans.last().unwrap().toast.as_deref(), Some("Undid: full width"));
        assert_eq!(e.window_count(), 2); // the closed window stays closed
    }

    #[test]
    fn focusing_from_floating_does_not_scroll_a_visible_anchor() {
        // f_chaos #80: floating the last column shortens the ribbon; the next focus_left must not scroll.
        let (_, plans) = replay(include_str!("../../qa/ux-sim/f_chaos.json"), Some(82));
        let (float, focus) = (&plans[80], &plans[81]);
        assert_eq!(focus.focus, Some(8));
        assert_eq!(frame(float, 8), frame(focus, 8));
        assert_eq!(frame(float, 2), frame(focus, 2));
    }

    #[test]
    fn dragged_width_has_a_floor_and_a_ceiling() {
        let (e, _) = replay(include_str!("../../qa/ux-sim/repro_drag_tiny_column_3840.json"), None);
        let avail = 3840.0 - 24.0;
        let w = layout::width_px(e.st.columns[1].width, &e.cfg, avail);
        assert!(w >= 0.2 * avail - 1.0, "{w}");
        let mut e = with(2);
        let resize = |e: &mut Engine, w: f64| e.handle(Event::WindowResized { id: 2, frame: Rect { x: 0.0, y: 0.0, w, h: 500.0 } });
        resize(&mut e, 100.0); // avail 976: floor is max(360, 195)
        assert_eq!(e.st.columns[1].width, Width::Px(360.0));
        resize(&mut e, 5000.0);
        assert_eq!(e.st.columns[1].width, Width::Frac(1.0)); // clamped to avail, snaps to full
    }

    #[test]
    fn adding_a_window_keeps_every_existing_column_width() {
        let mut e = with(3);
        cmd(&mut e, "focus_first");
        cmd(&mut e, "cycle_width");
        cmd(&mut e, "focus_last");
        cmd(&mut e, "cycle_width");
        cmd(&mut e, "cycle_width");
        for (n, focus) in ["focus_first", "focus_last", "focus_left"].into_iter().enumerate() {
            cmd(&mut e, focus);
            let new_id = 100 + n as u32;
            let before: Vec<Width> = e.st.columns.iter().map(|c| c.width).collect();
            let ids_before = ids(&e);
            add_to(&mut e, new_id, false);
            let others = |e: &Engine| -> Vec<(Vec<u32>, Width)> {
                e.st.columns.iter().filter(|c| !c.windows.contains(&new_id)).map(|c| (c.windows.clone(), c.width)).collect()
            };
            let (got_ids, got_w): (Vec<_>, Vec<_>) = others(&e).into_iter().unzip();
            assert_eq!(before, got_w, "widths changed when adding after {focus}");
            assert_eq!(ids_before, got_ids);
            assert_eq!(e.st.columns.len(), before.len() + 1);
        }
    }

    #[test]
    fn refused_width_is_kept_exactly_with_a_12px_gap() {
        let mut e = with(2);
        let undo = e.undo_len();
        let refused = |e: &mut Engine, w: f64| e.handle(Event::WindowRefused { id: 1, frame: Rect { x: 0.0, y: 0.0, w, h: 500.0 } });
        let p = refused(&mut e, 200.0); // below the 360 drag floor: kept
        assert_eq!(e.st.columns[0].width, Width::Fixed(200.0));
        assert_eq!(frame(&p, 1).w, 200);
        assert_eq!(frame(&p, 2).x - (frame(&p, 1).x + frame(&p, 1).w), 12);
        assert_eq!(e.undo_len(), undo, "no undo step");
        assert!(!p.changed.is_empty() && p.changed.contains(&2));
        // Same refusal again is an echo: nothing changes, nothing is rewritten.
        let p = refused(&mut e, 200.0);
        assert!(p.changed.is_empty());
    }

    #[test]
    fn refusal_after_cycle_width_does_not_loop() {
        let mut e = with(2);
        cmd(&mut e, "focus_left");
        refuse(&mut e, 1, 200.0);
        cmd(&mut e, "cycle_width"); // user asks for a preset: the app may try again
        assert!(matches!(e.st.columns[0].width, Width::Frac(_)));
        let p = refuse(&mut e, 1, 200.0); // refused once more: re-adopted, then stable
        assert_eq!(e.st.columns[0].width, Width::Fixed(200.0));
        assert_eq!(frame(&p, 1).w, 200);
        assert!(refuse(&mut e, 1, 200.0).changed.is_empty());
    }

    #[test]
    fn a_column_its_app_held_wider_gets_its_own_width_back_when_the_band_gives_it_room() {
        // 1000 pt: a half is 482 px. An app that will not go below 600 holds its column there, and one that settled narrower
        // than asked keeps exactly that. On a 1728 pt display a half is 846 px: the first column is a half again.
        let mut e = with(3);
        refuse(&mut e, 1, 600.0);
        refuse(&mut e, 2, 300.0);
        assert_eq!((e.st.columns[0].width, e.st.columns[1].width), (Width::Fixed(600.0), Width::Fixed(300.0)));
        assert_eq!(e.snapshot().desktops[0].columns[0].width, SessionWidth::Frac(0.5), "a session saves the column's own width");
        let wide = |w: f64| Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w, h: 800.0 } };
        e.handle(wide(1728.0));
        assert_eq!((e.st.columns[0].width, e.st.columns[1].width), (Width::Frac(0.5), Width::Fixed(300.0)));
        // Back on the narrow display the half is asked for again (the app refuses once more if it still must).
        e.handle(wide(1000.0));
        assert_eq!(e.st.columns[0].width, Width::Frac(0.5));
        refuse(&mut e, 1, 600.0);
        assert_eq!(e.st.columns[0].width, Width::Fixed(600.0));
        // A width the user picks replaces its own width: a later band change does not bring the old one back.
        cmd(&mut e, "focus_first");
        cmd_arg(&mut e, "set_width", serde_json::json!(0.75));
        refuse(&mut e, 1, 900.0);
        e.handle(wide(1728.0));
        assert_eq!(e.st.columns[0].width, Width::Frac(0.75));
    }

    #[test]
    fn undo_brings_a_held_column_back_at_its_own_width_where_the_band_now_gives_it_room() {
        // The move is undone on a wider display than it was made on: the snapshot holds the first column at the 600 px its
        // app would not go below, and a 1728 pt display gives its half 846 px.
        let mut e = with(3);
        refuse(&mut e, 1, 600.0);
        cmd(&mut e, "focus_last");
        cmd(&mut e, "move_left");
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1728.0, h: 800.0 } });
        assert_eq!((e.st.columns[0].width, e.st.columns[0].held), (Width::Frac(0.5), None));
        cmd(&mut e, "undo");
        assert_eq!(ids(&e), vec![vec![1], vec![2], vec![3]]);
        assert_eq!((e.st.columns[0].width, e.st.columns[0].held), (Width::Frac(0.5), None));
        cmd(&mut e, "redo");
        assert_eq!(ids(&e), vec![vec![1], vec![3], vec![2]]);
        assert_eq!((e.st.columns[0].width, e.st.columns[0].held), (Width::Frac(0.5), None));
        // Undone in the band it was made in, the hold stays: the half is still narrower than the app allows.
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        refuse(&mut e, 1, 600.0);
        cmd(&mut e, "move_right");
        cmd(&mut e, "undo");
        assert_eq!((e.st.columns[0].width, e.st.columns[0].held), (Width::Fixed(600.0), Some(Width::Frac(0.5))));
    }

    #[test]
    fn full_width_and_back_gives_a_held_column_its_own_width_where_the_band_now_gives_it_room() {
        // Held at 600 px on a 1000 pt display, taken to full width, then back after a switch to 1728 pt: its half is 846 px.
        let mut e = with(3);
        refuse(&mut e, 1, 600.0);
        cmd(&mut e, "focus_first");
        cmd(&mut e, "toggle_full");
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1728.0, h: 800.0 } });
        cmd(&mut e, "toggle_full");
        assert_eq!((e.st.columns[0].width, e.st.columns[0].held), (Width::Frac(0.5), None));
    }

    #[test]
    fn adjacent_visible_frames_always_sit_one_gap_apart() {
        let mut e = with(4);
        for (id, w) in [(1, 200.0), (2, 515.0), (3, 641.0), (4, 977.0)] {
            let p = refuse(&mut e, id, w);
            let mut f: Vec<_> = p.frames.iter().filter(|f| f.on_screen).collect();
            f.sort_by_key(|f| f.x);
            for pair in f.windows(2) {
                assert_eq!(pair[1].x - (pair[0].x + pair[0].w), 12, "after refusing {id}={w}");
            }
        }
        // a user drag that snaps/clamps, then the app settles elsewhere (terminal cells): the settled width wins
        drag(&mut e, 2, 480.0, 500.0);
        let p = refuse(&mut e, 2, 463.0);
        assert_eq!(frame(&p, 2).w, 463);
        let (a, b) = (frame(&p, 2), frame(&p, 3));
        if b.on_screen {
            assert_eq!(b.x - (a.x + a.w), 12);
        }
    }

    fn refuse(e: &mut Engine, id: u32, w: f64) -> Plan {
        e.handle(Event::WindowRefused { id, frame: Rect { x: 0.0, y: 0.0, w, h: 500.0 } })
    }

    fn toast(p: Plan) -> Option<String> {
        p.toast
    }

    #[test]
    fn toasts_for_undo_redo() {
        let mut e = with(3);
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Nothing to undo"));
        assert_eq!(toast(cmd(&mut e, "redo")).as_deref(), Some("Nothing to redo"));
        cmd(&mut e, "toggle_full");
        cmd(&mut e, "move_left");
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: move"));
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: full width"));
        assert_eq!(toast(cmd(&mut e, "redo")).as_deref(), Some("Redid: full width"));
        cmd(&mut e, "cycle_width");
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: width"));
        assert!(cmd(&mut e, "undo").show_map);
    }

    #[test]
    fn toasts_for_edges_and_layout_commands() {
        let mut e = with(3);
        let p = cmd(&mut e, "focus_right");
        assert_eq!(p.toast.as_deref(), Some("No more windows on the right"));
        assert!(p.show_map);
        assert_eq!(toast(cmd(&mut e, "move_right")).as_deref(), Some("No more windows on the right"));
        assert_eq!(toast(cmd(&mut e, "focus_up")).as_deref(), Some("No stack here"));
        assert_eq!(toast(cmd(&mut e, "focus_down")).as_deref(), Some("No stack here"));
        assert_eq!(toast(cmd(&mut e, "move_left")).as_deref(), Some("Moved"));
        assert_eq!(toast(cmd(&mut e, "move_right")).as_deref(), Some("Moved"));
        assert_eq!(toast(cmd(&mut e, "focus_left")), None);
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 66\u{a0}%")); // ½ -> ⅔
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 75\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 100\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 25\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "toggle_full")).as_deref(), Some("Full width"));
        assert_eq!(toast(cmd(&mut e, "toggle_full")).as_deref(), Some("Back to 25\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "stack")).as_deref(), Some("Stacked"));
        assert_eq!(toast(cmd(&mut e, "unstack")).as_deref(), Some("Moved to its own column"));
        assert_eq!(toast(cmd(&mut e, "toggle_float")).as_deref(), Some("Out of the ribbon"));
        assert_eq!(toast(cmd(&mut e, "toggle_float")).as_deref(), Some("Back in the ribbon"));
        assert_eq!(toast(cmd(&mut e, "center")), None);
        assert_eq!(toast(add_to(&mut e, 9, false)), None);
        e.handle(Event::WindowResized { id: 9, frame: Rect { x: 0.0, y: 0.0, w: 600.0, h: 500.0 } });
        assert_eq!(toast(cmd(&mut e, "cycle_width")).as_deref(), Some("Width 66\u{a0}%"));
    }

    #[test]
    fn width_toasts_say_the_same_whichever_command_set_the_width() {
        // ⅓ by cycling (½ ⅔ ¾ full ¼ ⅓), by a width key, by typing it in the bar and by a nudge that lands there: one wording.
        let mut e = with(1);
        let cycled = (0..5).filter_map(|_| toast(cmd(&mut e, "cycle_width"))).last();
        assert_eq!(cycled.as_deref(), Some("Width 33\u{a0}%"));
        assert_eq!(toast(cmd_arg(&mut e, "set_width", json!(0.333))).as_deref(), Some("Width 33\u{a0}%"));
        assert_eq!(toast(cmd_arg(&mut e, "set_width", json!({"fraction": 0.33}))).as_deref(), Some("Width 33\u{a0}%"));
        cmd_arg(&mut e, "set_width", json!(0.383));
        assert_eq!(toast(cmd(&mut e, "shrink_width")).as_deref(), Some("Width 33\u{a0}%"));
        assert_eq!(toast(cmd(&mut e, "cycle_width_back")).as_deref(), Some("Width 25\u{a0}%"));
        // A dragged width in points says its percent too, and leaving full width names it the same way.
        e.handle(Event::WindowResized { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 600.0, h: 500.0 } });
        let w = e.st.columns[0].width;
        assert!(matches!(w, Width::Px(_)), "{w:?}");
        let dragged = percent(layout::width_frac(w, &e.cfg, e.avail()));
        assert_eq!(toast(cmd(&mut e, "toggle_full")).as_deref(), Some("Full width"));
        assert_eq!(toast(cmd(&mut e, "toggle_full")), Some(format!("Back to {dragged}")));
        assert_eq!(toast(cmd(&mut e, "grow_width")), Some(format!("Width {}", percent(layout::width_frac(w, &e.cfg, e.avail()) + 0.05))));
    }

    // ---- core-review regressions ----
    #[test]
    fn undo_keeps_new_window_next_to_its_neighbour() {
        let mut e = with(2);
        cmd_arg(&mut e, "focus_index", json!(1));
        cmd(&mut e, "cycle_width"); // snapshot [1][2]
        add_to(&mut e, 3, false); // [1][3][2]
        cmd(&mut e, "undo");
        assert_eq!(ids(&e), [vec![1], vec![3], vec![2]]);
        cmd(&mut e, "redo");
        assert_eq!(ids(&e), [vec![1], vec![3], vec![2]]);
    }

    #[test]
    fn undo_reconciles_anchor_and_history() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_index", json!(2));
        cmd(&mut e, "toggle_float");
        cmd(&mut e, "toggle_float");
        cmd(&mut e, "undo"); // 2 floats again and is focused; the stale anchor must not be 2
        assert!(e.st.floating.contains(&2) && e.focused() == Some(2));
        assert_eq!(e.last_tiled, Some(1));
        add_to(&mut e, 9, false);
        assert_eq!(ids(&e), [vec![1], vec![9], vec![3]]);
        // anchor with nothing tiled left after restore
        let mut e = with(1);
        cmd(&mut e, "toggle_float");
        cmd(&mut e, "toggle_float");
        cmd(&mut e, "undo");
        assert_eq!(e.last_tiled, None);
        assert!(e.history.iter().all(|h| e.windows.contains_key(h)));
    }

    #[test]
    fn oversized_ids_are_rejected_not_truncated() {
        let mut e = with(2);
        let big = json!(4_294_967_297u64); // 2^32 + 1 would truncate to window 1
        cmd_arg(&mut e, "focus_index", json!(2));
        let p = cmd_arg(&mut e, "focus_window", big.clone());
        assert!(p.focus != Some(1) && !p.show_map && e.focused() == Some(2));
        let p = cmd_arg(&mut e, "move_to_index", json!({"id": big, "index": 1}));
        assert!(!p.show_map);
        assert_eq!(ids(&e), [vec![1], vec![2]]);
    }

    #[test]
    fn resize_before_display_keeps_px_then_clamps() {
        let mut e = Engine::new(Config::default());
        add_to(&mut e, 1, false);
        add_to(&mut e, 2, false);
        let wide = Rect { x: 0.0, y: 0.0, w: 700.0, h: 500.0 };
        e.handle(Event::WindowResized { id: 2, frame: wide });
        assert_eq!(e.st.columns[1].width, Width::Px(700.0));
        let p = e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        assert_eq!(frame(&p, 2).w, 700);
        // a smaller display clamps the stored px at layout time
        let p = e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 600.0, h: 800.0 } });
        assert_eq!(frame(&p, 2).w, 576);
    }

    // ---- heights ----
    fn stack_of(n: u32) -> Engine {
        let mut e = with(n);
        for k in 2..=n {
            e.handle(Event::WindowFocused { id: k });
            cmd(&mut e, "stack");
        }
        assert_eq!(ids(&e), vec![(1..=n).collect::<Vec<_>>()]);
        e
    }
    fn hs(p: &Plan, ids: &[u32]) -> Vec<i64> {
        ids.iter().map(|i| frame(p, *i).h).collect()
    }
    fn no_overlap(p: &Plan, ids: &[u32]) {
        for w in ids.windows(2) {
            let (a, b) = (frame(p, w[0]), frame(p, w[1]));
            assert_eq!(b.y - (a.y + a.h), 12, "gap exact: {p:?}");
        }
        let (f, l) = (frame(p, ids[0]), frame(p, *ids.last().unwrap()));
        assert_eq!((f.y, l.y + l.h), (37, 813));
    }

    #[test]
    fn cycle_height_two_stack() {
        let mut e = stack_of(2);
        e.handle(Event::WindowFocused { id: 1 });
        let p = cmd(&mut e, "cycle_height");
        assert_eq!(p.toast.as_deref(), Some("Height 66\u{a0}%"));
        // usable 764 -> 509 / 255
        assert_eq!(hs(&p, &[1, 2]), vec![509, 255]);
        no_overlap(&p, &[1, 2]);
        assert_eq!(cmd(&mut e, "cycle_height").toast.as_deref(), Some("Height 33\u{a0}%"));
        assert_eq!(cmd(&mut e, "cycle_height").toast.as_deref(), Some("Height 50\u{a0}%"));
        assert!(e.st.columns[0].heights.is_none(), "equal split is stored as unset");
        // the lower window cycles its own share
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd(&mut e, "cycle_height");
        assert_eq!(hs(&p, &[1, 2]), vec![255, 509]);
    }

    #[test]
    fn cycle_height_three_stack_shares_remainder() {
        let mut e = stack_of(3);
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd(&mut e, "cycle_height"); // equal is 1/3 -> next is 1/2
        assert_eq!(p.toast.as_deref(), Some("Height 50\u{a0}%"));
        // usable 752 -> 376 / 188 / 188
        assert_eq!(hs(&p, &[1, 2, 3]), vec![188, 376, 188]);
        no_overlap(&p, &[1, 2, 3]);
        let p = cmd(&mut e, "cycle_height");
        assert_eq!(p.toast.as_deref(), Some("Height 66\u{a0}%"));
        assert_eq!(hs(&p, &[1, 2, 3]), vec![125, 502, 125]);
        no_overlap(&p, &[1, 2, 3]);
        assert_eq!(cmd(&mut e, "cycle_height").toast.as_deref(), Some("Height 33\u{a0}%"));
        assert!(e.st.columns[0].heights.is_none());
    }

    #[test]
    fn cycle_height_respects_minimum_in_tall_stacks() {
        let mut e = stack_of(5);
        e.handle(Event::WindowFocused { id: 1 });
        for _ in 0..6 {
            let p = cmd(&mut e, "cycle_height");
            assert!(p.frames.iter().all(|f| f.h >= 116), "{:?}", hs(&p, &[1, 2, 3, 4, 5]));
            no_overlap(&p, &[1, 2, 3, 4, 5]);
        }
    }

    #[test]
    fn cycle_height_on_single_window_is_noop_with_hint() {
        let mut e = with(2);
        let p = cmd(&mut e, "cycle_height");
        assert_eq!(p.toast.as_deref(), Some("Stack windows first"));
        assert!(p.error.is_none() && e.undo_len() == 0);
    }

    #[test]
    fn cycle_height_undo_redo() {
        let mut e = stack_of(2);
        e.handle(Event::WindowFocused { id: 1 });
        let depth = e.undo_len();
        cmd(&mut e, "cycle_height");
        assert_eq!(e.undo_len(), depth + 1);
        let p = cmd(&mut e, "undo");
        assert_eq!(p.toast.as_deref(), Some("Undid: height"));
        assert_eq!(hs(&p, &[1, 2]), vec![382, 382]);
        let p = cmd(&mut e, "redo");
        assert_eq!(p.toast.as_deref(), Some("Redid: height"));
        assert_eq!(hs(&p, &[1, 2]), vec![509, 255]);
    }

    fn drag_h(e: &mut Engine, id: u32, h: f64) -> Plan {
        let w = frame(&e.handle(Event::Query), id).w as f64;
        e.handle(Event::WindowResized { id, frame: Rect { x: 0.0, y: 0.0, w, h } })
    }

    #[test]
    fn height_drag_adopts_snaps_and_clamps() {
        let mut e = stack_of(2);
        e.handle(Event::WindowFocused { id: 1 });
        // 600px of 764: custom share, other takes the rest
        let p = drag_h(&mut e, 1, 600.0);
        assert_eq!(hs(&p, &[1, 2]), vec![600, 164]);
        no_overlap(&p, &[1, 2]);
        assert_eq!(cmd(&mut e, "cycle_height").toast.as_deref(), Some("Height 33\u{a0}%")); // from custom 0.785
        // within 24px of 1/2 (382): snaps
        let p = drag_h(&mut e, 1, 395.0);
        assert_eq!(hs(&p, &[1, 2]), vec![382, 382]);
        assert!(e.st.columns[0].heights.is_none());
        // clamp: min = max(120, 0.15*776=116.4) = 120
        let p = drag_h(&mut e, 1, 700.0);
        assert_eq!(hs(&p, &[1, 2]), vec![644, 120]);
        let p = drag_h(&mut e, 1, 10.0);
        assert_eq!(hs(&p, &[1, 2]), vec![120, 644]);
        no_overlap(&p, &[1, 2]);
        // echo of our own frame is ignored
        let before = e.st.clone();
        drag_h(&mut e, 1, 121.0);
        assert_eq!(e.st, before);
    }

    #[test]
    fn height_drag_ignored_for_single_window_and_width_still_adopted() {
        let mut e = with(1);
        let before = e.st.clone();
        e.handle(Event::WindowResized { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 482.0, h: 300.0 } });
        assert_eq!(e.st, before);
        let mut e = stack_of(2);
        e.handle(Event::WindowFocused { id: 1 });
        let p = e.handle(Event::WindowResized { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 700.0, h: 600.0 } });
        assert_eq!(frame(&p, 1).w, 700);
        assert_eq!(hs(&p, &[1, 2]), vec![600, 164]);
    }

    #[test]
    fn heights_reset_when_the_stack_changes() {
        // unstack
        let mut e = stack_of(3);
        e.handle(Event::WindowFocused { id: 1 });
        cmd(&mut e, "cycle_height");
        assert!(e.st.columns[0].heights.is_some());
        e.handle(Event::WindowFocused { id: 3 });
        cmd(&mut e, "unstack");
        assert!(e.st.columns.iter().all(|c| c.heights.is_none()));
        let p = e.handle(Event::Query);
        assert_eq!(hs(&p, &[1, 2]), vec![382, 382]);
        // stack onto a customised column
        e.handle(Event::WindowFocused { id: 1 });
        cmd(&mut e, "cycle_height");
        e.handle(Event::WindowFocused { id: 3 });
        cmd(&mut e, "stack");
        assert!(e.st.columns.iter().all(|c| c.heights.is_none()));
        // remove
        e.handle(Event::WindowFocused { id: 1 });
        cmd(&mut e, "cycle_height");
        e.handle(Event::WindowRemoved { id: 3 });
        assert!(e.st.columns.iter().all(|c| c.heights.is_none()));
        // undo of a unstack onto a customised snapshot after a removal keeps shares consistent
        cmd(&mut e, "cycle_height");
        e.handle(Event::WindowRemoved { id: 2 });
        let p = cmd(&mut e, "undo");
        assert!(p.error.is_none());
        for c in &e.st.columns {
            assert_eq!(c.shares().len(), c.windows.len());
        }
    }

    // ---- trackpad scroll ----

    fn by(e: &mut Engine, dx: f64) -> Plan {
        e.handle(Event::ScrollBy { dx })
    }
    fn end(e: &mut Engine, v: Option<f64>) -> Plan {
        e.handle(Event::ScrollEnd { velocity: v })
    }
    /// Content 5 * 482 + 4 * 12 = 2458, viewport 976 -> scroll range 0..=1482.
    fn five() -> Engine {
        let mut e = with(5);
        cmd_arg(&mut e, "focus_index", json!(1));
        assert_eq!(e.state().scroll, 0.0);
        e
    }

    #[test]
    fn scroll_by_moves_continuously_without_touching_focus_or_undo() {
        let mut e = five();
        let undo = e.undo_len();
        let p = by(&mut e, 100.0);
        assert_eq!(e.state().scroll, 100.0);
        assert_eq!(e.focused(), Some(1));
        assert_eq!(p.focus, None);
        assert!(p.show_map && p.error.is_none());
        assert_eq!(frame(&p, 1).x, 12 - 100);
        assert!(p.changed.contains(&1) && p.changed.contains(&2));
        by(&mut e, -30.0);
        assert_eq!(e.state().scroll, 70.0);
        assert_eq!((e.focused(), e.undo_len()), (Some(1), undo));
    }

    #[test]
    fn scroll_by_rubber_bands_at_both_ends_and_returns_one_to_one() {
        let mut e = five();
        by(&mut e, -100.0); // 100px past the left end, resisted and capped
        assert!((0.0 - e.state().scroll - 40.0).abs() < 1e-9);
        by(&mut e, -1000.0);
        assert_eq!(e.state().scroll, -60.0);
        by(&mut e, 30.0); // coming back is 1:1
        assert_eq!(e.state().scroll, -30.0);
        by(&mut e, 5000.0);
        assert_eq!(e.state().scroll, 1482.0 + 60.0);
        by(&mut e, -42.0);
        assert_eq!(e.state().scroll, 1482.0 + 18.0);
        let p = by(&mut e, f64::NAN); // nonsense is ignored
        assert_eq!(e.state().scroll, 1500.0);
        assert!(p.error.is_none());
    }

    #[test]
    fn scroll_by_crossing_an_edge_splits_full_and_resisted() {
        let mut e = five();
        by(&mut e, 1482.0 + 10.0);
        assert!((e.state().scroll - (1482.0 + 4.0)).abs() < 1e-9);
    }

    #[test]
    fn scroll_by_without_display_or_windows_is_inert() {
        let mut e = Engine::new(Config::default());
        by(&mut e, 50.0);
        assert_eq!(e.state().scroll, 0.0);
        let mut e = eng();
        by(&mut e, 50.0);
        end(&mut e, None);
        assert_eq!(e.state().scroll, 0.0);
    }

    /// Where `five()` rests: the column starts 0, 494 and 988, and 1482 where the content's end meets the display's.
    const FIVE_RESTS: [f64; 4] = [0.0, 494.0, 988.0, 1482.0];
    const DISPLAY: Rect = Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 };

    /// `n` columns of the same width fraction on the 1000 px test display.
    fn with_width(n: u32, cfg: Config, frac: f64) -> Engine {
        on_display(DISPLAY.w, n, cfg, frac)
    }
    fn on_display(width: f64, n: u32, cfg: Config, frac: f64) -> Engine {
        let mut e = Engine::new(cfg);
        e.handle(Event::Display { id: 1, frame: Rect { w: width, ..DISPLAY } });
        for id in 1..=n {
            e.handle(Event::WindowAdded { id, pid: 1, app: format!("App{id}"), title: format!("T{id}"), frame: R, floating: false, width_hint: Some(frac), take_focus: true });
        }
        e
    }
    fn swipe(e: &mut Engine, dx: f64, v: f64) -> f64 {
        by(e, dx);
        end(e, Some(v));
        e.state().scroll
    }
    fn rests_of(e: &Engine) -> Vec<f64> {
        e.rests(&e.spans(), e.avail())
    }

    #[test]
    fn scroll_end_rests_on_a_column_start_and_focuses_the_side_it_went_to() {
        let mut e = five();
        by(&mut e, 700.0); // nearer the second column's start (494) than the third's (988)
        let p = end(&mut e, None);
        assert_eq!(e.state().scroll, 494.0);
        assert_eq!((e.focused(), p.focus), (Some(3), Some(3))); // columns 2 and 3 are equally near the middle: the one it went towards
        assert!(fully_on_screen(&p, 2, DISPLAY) && fully_on_screen(&p, 3, DISPLAY));
        assert_eq!(frame(&p, 2).x, 12);
        assert!(p.show_map);
        assert_eq!(e.undo_len(), 0);
        // And back: the side it went towards is now the left one.
        cmd_arg(&mut e, "focus_index", json!(4));
        assert_eq!(e.state().scroll, 988.0);
        swipe(&mut e, -300.0, 0.0);
        assert_eq!((e.state().scroll, e.focused()), (494.0, Some(2)));
    }

    #[test]
    fn scroll_end_without_velocity_settles_on_the_nearest_rest() {
        let mut e = five();
        assert_eq!(swipe(&mut e, 200.0, 0.0), 0.0); // not yet halfway: back where it was
        assert_eq!(e.focused(), Some(1));
        assert_eq!(swipe(&mut e, 300.0, 0.0), 494.0);
        assert_eq!(swipe(&mut e, 900.0, 0.0), 1482.0); // 494 + 900 is nearer the end than 988
        assert_eq!(swipe(&mut e, -2000.0, 0.0), 0.0);
        assert_eq!(swipe(&mut e, 300.0, f64::NAN), 494.0); // garbage velocity is no velocity
        assert_eq!(e.undo_len(), 0);
    }

    #[test]
    fn a_flick_pages_on_by_one_column_and_a_hard_fling_by_more() {
        let mut e = five();
        assert_eq!(swipe(&mut e, 150.0, 900.0), 494.0, "still moving: on to the next column");
        assert_eq!(swipe(&mut e, 150.0, 900.0), 988.0);
        assert_eq!(swipe(&mut e, -150.0, -900.0), 494.0, "and back the same way");
        assert_eq!(swipe(&mut e, 150.0, -900.0), 494.0, "a flick back cancels the swipe");
        assert_eq!(swipe(&mut e, 10.0, 900.0), 494.0, "a twitch is not a swipe");
        assert_eq!(swipe(&mut e, 300.0, 2000.0), 988.0, "a 300 px flick: on one column");
        assert_eq!(swipe(&mut e, -2000.0, 0.0), 0.0);
        assert_eq!(swipe(&mut e, 300.0, 6000.0), 988.0, "a hard fling carries on past the next column: 300 + 720 projected");
    }

    #[test]
    fn a_flick_from_a_rest_advances_exactly_one_column_however_short_the_swipe() {
        // A 1512 pt MacBook: half columns of 738 px, one every 750.
        let mut e = on_display(1512.0, 6, Config::default(), 0.5);
        cmd_arg(&mut e, "focus_index", json!(1));
        assert_eq!(rests_of(&e), vec![0.0, 750.0, 1500.0, 2250.0, 3000.0]);
        for v in [400.0, 450.0, 700.0, 1500.0] {
            for dx in (32..=300).step_by(17) {
                assert_eq!(swipe(&mut e, dx as f64, v), 750.0, "dx={dx} v={v}");
                assert_eq!(swipe(&mut e, -(dx as f64), -v), 0.0, "back: dx={dx} v={v}");
            }
        }
        // Below the flick speed or the twitch distance it settles where it stopped.
        assert_eq!(swipe(&mut e, 200.0, 390.0), 0.0);
        assert_eq!(swipe(&mut e, 31.0, 1500.0), 0.0);
        assert_eq!(swipe(&mut e, 400.0, 300.0), 750.0);
    }

    #[test]
    fn a_release_always_rests_on_a_column_start_or_the_end_and_focuses_a_column_in_view() {
        let configs = [
            (ScrollMode::KeepVisible, 0.5),
            (ScrollMode::KeepVisible, 0.25),
            (ScrollMode::KeepVisible, 0.333),
            (ScrollMode::KeepVisible, 0.667),
            (ScrollMode::KeepVisible, 0.75),
            (ScrollMode::KeepVisible, 1.0),
            (ScrollMode::CenterOnOverflow, 0.5),
            (ScrollMode::Center, 0.5),
        ];
        for (mode, frac) in configs {
            for n in [1, 2, 3, 5, 8] {
                for dx in (-1300..=1700).step_by(137) {
                    for v in [-6000.0, -1500.0, -420.0, -100.0, 0.0, 100.0, 420.0, 1500.0, 6000.0] {
                        let mut e = with_width(n, Config { scroll: mode, ..Config::default() }, frac);
                        cmd_arg(&mut e, "focus_index", json!(n.div_ceil(2)));
                        by(&mut e, dx as f64);
                        let p = end(&mut e, Some(v));
                        let (rests, scroll) = (rests_of(&e), e.state().scroll);
                        let tag = format!("{mode:?} {frac} n={n} dx={dx} v={v}: scroll {scroll}, rests {rests:?}");
                        assert!(rests.iter().any(|r| (r - scroll).abs() < 1e-6), "{tag}");
                        let hi = (layout::content_width(&e.spans()) - e.avail()).max(0.0);
                        if mode != ScrollMode::Center {
                            assert!((-1e-9..=hi + 1e-9).contains(&scroll), "never past the content: {tag}");
                        }
                        let id = e.focused().unwrap();
                        assert!(fully_on_screen(&p, id, DISPLAY), "{tag}: focus {id}");
                    }
                }
            }
        }
    }

    #[test]
    fn a_nudge_never_moves_the_ribbon_or_flips_focus() {
        for start in 1..=5 {
            for dx in [3.0, -3.0, 1.0, -1.0] {
                for v in [0.0, 40.0, -40.0] {
                    let mut e = five();
                    cmd_arg(&mut e, "focus_index", json!(start));
                    let before = (e.state().scroll, e.focused());
                    swipe(&mut e, dx, v);
                    assert_eq!((e.state().scroll, e.focused()), before, "focus {start} dx={dx} v={v}");
                }
            }
        }
        // Standing at the end with the second-to-last column focused, too.
        let mut e = five();
        cmd_arg(&mut e, "focus_index", json!(5));
        cmd(&mut e, "focus_left");
        assert_eq!((e.state().scroll, e.focused()), (1482.0, Some(4)));
        swipe(&mut e, -3.0, 0.0);
        swipe(&mut e, 40.0, 0.0); // rubber band at the end, released
        assert_eq!((e.state().scroll, e.focused()), (1482.0, Some(4)));
    }

    #[test]
    fn wide_columns_never_rest_past_the_end_of_the_content() {
        for frac in [0.667, 0.75] {
            let mut e = with_width(4, Config::default(), frac);
            let (hi, last) = ((layout::content_width(&e.spans()) - e.avail()).max(0.0), e.spans().len() - 1);
            assert!(hi > 0.0 && !rests_of(&e).iter().any(|r| *r > hi + 1e-9), "{frac}: {:?}", rests_of(&e));
            for dx in (-2500..=3500).step_by(97) {
                for v in [-3000.0, -600.0, 0.0, 600.0, 3000.0] {
                    swipe(&mut e, dx as f64, v);
                    assert!(e.state().scroll <= hi + 1e-9, "{frac} dx={dx} v={v}: {} > {hi}", e.state().scroll);
                }
            }
            // The end of the ribbon sits flush with the display's edge: no blank gap, the last column is the focus.
            let p = swipe_plan(&mut e, 5000.0, 0.0);
            assert_eq!(e.state().scroll, hi);
            let f = frame(&p, last as u32 + 1);
            assert_eq!(f.x + f.w, 1000 - 12, "{frac}");
            assert_eq!(e.focused(), Some(last as u32 + 1));
        }
    }
    fn swipe_plan(e: &mut Engine, dx: f64, v: f64) -> Plan {
        by(e, dx);
        end(e, Some(v))
    }

    #[test]
    fn the_far_end_of_five_half_columns_focuses_the_fifth() {
        let mut e = five();
        swipe(&mut e, 5000.0, 0.0);
        assert_eq!((e.focused(), e.state().scroll), (Some(5), 1482.0));
        // The same by a flick, one page at a time, and by the keyboard's route back.
        let mut e = five();
        for _ in 0..3 {
            swipe(&mut e, 150.0, 900.0);
        }
        assert_eq!((e.focused(), e.state().scroll), (Some(5), 1482.0));
        for (rest, win) in [(988.0, 3), (494.0, 2), (0.0, 1)] {
            swipe(&mut e, -150.0, -900.0);
            assert_eq!((e.state().scroll, e.focused()), (rest, Some(win)));
        }
    }

    #[test]
    fn scroll_end_from_rubber_band_returns_to_the_edge() {
        let mut e = five();
        by(&mut e, -500.0);
        assert!(e.state().scroll < 0.0);
        let p = end(&mut e, None);
        assert_eq!((e.focused(), e.state().scroll), (Some(1), 0.0));
        assert_eq!(frame(&p, 1).x, 12);
        by(&mut e, 5000.0);
        assert!(e.state().scroll > 1482.0);
        end(&mut e, None);
        assert_eq!((e.focused(), e.state().scroll), (Some(5), 1482.0));
        // A fling into the band comes back to the same rest, not past it.
        by(&mut e, 500.0);
        end(&mut e, Some(4000.0));
        assert_eq!((e.focused(), e.state().scroll), (Some(5), 1482.0));
        by(&mut e, -5000.0);
        end(&mut e, Some(-4000.0));
        assert_eq!((e.focused(), e.state().scroll), (Some(1), 0.0));
    }

    #[test]
    fn a_ribbon_that_fits_rests_at_its_start_and_a_start_near_the_end_gives_way_to_it() {
        let mut e = with(2);
        assert_eq!(swipe(&mut e, 80.0, 900.0), 0.0);
        assert_eq!(e.state().scroll, 0.0);
        let spans = [(0.0, 500.0), (512.0, 500.0), (1024.0, 500.0)]; // content 1524
        assert_eq!(layout::free_rest_offsets(&spans, 976.0, 32.0), vec![0.0, 512.0, 548.0]);
        assert_eq!(layout::free_rest_offsets(&spans, 990.0, 32.0), vec![0.0, 534.0], "512 is 22 px from the end: one stop");
        assert_eq!(layout::free_rest_offsets(&spans, 1524.0, 32.0), vec![0.0]);
        assert_eq!(layout::free_rest_offsets(&spans[..1], 976.0, 32.0), vec![0.0]);
        // Barely longer than the display: the first stop is kept, so the ribbon can always return to its beginning.
        assert_eq!(layout::free_rest_offsets(&spans, 1510.0, 32.0), vec![0.0, 14.0]);
    }

    #[test]
    fn center_rests_with_a_column_in_the_middle_and_the_rubber_band_starts_at_the_ends() {
        let cfg = Config { scroll: ScrollMode::Center, ..Config::default() };
        let mut e = with_width(5, cfg, 0.5);
        cmd_arg(&mut e, "focus_index", json!(1));
        let first = e.state().scroll;
        assert_eq!(first, 241.0 - 488.0, "the first column is centred too");
        assert_eq!(rests_of(&e), vec![-247.0, 247.0, 741.0, 1235.0, 1729.0]);
        // Pushing further left from there is the rubber band, not a jump to its edge.
        by(&mut e, -30.0);
        assert!((e.state().scroll - (first - 12.0)).abs() < 1e-9, "{}", e.state().scroll);
        end(&mut e, None);
        assert_eq!((e.state().scroll, e.focused()), (first, Some(1)));
        assert_eq!(swipe(&mut e, 200.0, 0.0), first, "less than half a page: back");
        assert_eq!(swipe(&mut e, 300.0, 0.0), 247.0);
        assert_eq!(e.focused(), Some(2));
        assert_eq!(swipe(&mut e, 150.0, 900.0), 741.0, "a flick moves one column on");
        assert_eq!(e.focused(), Some(3));
        assert_eq!(swipe(&mut e, 4000.0, 0.0), 1729.0);
        assert_eq!(e.focused(), Some(5));
    }

    #[test]
    fn a_swipe_with_a_floating_window_focused_still_rests_on_a_column_and_focuses_it() {
        let mut e = five();
        add_to(&mut e, 99, true);
        e.handle(Event::WindowFocused { id: 99 });
        assert_eq!(e.focused(), Some(99));
        let scroll = swipe(&mut e, 700.0, 0.0);
        assert_eq!((scroll, e.focused()), (494.0, Some(3)));
        e.handle(Event::WindowFocused { id: 99 });
        assert_eq!(swipe(&mut e, -3000.0, 0.0), 0.0);
        assert_eq!(e.focused(), Some(1), "the start of the ribbon focuses its first column");
    }

    #[test]
    fn center_on_overflow_rests_like_keep_visible() {
        let cfg = Config { scroll: ScrollMode::CenterOnOverflow, ..Config::default() };
        let mut e = with_width(5, cfg, 0.5);
        cmd_arg(&mut e, "focus_index", json!(1));
        assert_eq!(swipe(&mut e, 300.0, 0.0), 494.0);
        assert_eq!(swipe(&mut e, 150.0, 900.0), 988.0);
        assert_eq!(rests_of(&e), FIVE_RESTS.to_vec());
        assert_eq!(e.focused(), Some(4));
    }

    #[test]
    fn a_release_rests_on_the_grid_and_flush_with_the_end_on_displays_of_any_width() {
        for dw in [1000.0, 1512.0, 1728.0, 2560.0, 3840.0] {
            let d = Rect { w: dw, ..DISPLAY };
            for mode in [ScrollMode::KeepVisible, ScrollMode::CenterOnOverflow, ScrollMode::Center] {
                for frac in [0.25, 0.333, 0.5, 0.667, 1.0] {
                    for n in [2u32, 5, 9] {
                        for start in [1, n] {
                            for dx in (-1700..=2300).step_by(400) {
                                for v in [-3000.0, -450.0, 0.0, 450.0, 3000.0] {
                                    let mut e = on_display(dw, n, Config { scroll: mode, ..Config::default() }, frac);
                                    cmd_arg(&mut e, "focus_index", json!(start));
                                    let p = swipe_plan(&mut e, dx as f64, v);
                                    let (rests, scroll) = (rests_of(&e), e.state().scroll);
                                    let tag = format!("{mode:?} dw={dw} frac={frac} n={n} start={start} dx={dx} v={v}: scroll {scroll}, rests {rests:?}");
                                    assert!(rests.iter().any(|r| (r - scroll).abs() < 1e-6), "off the grid: {tag}");
                                    let id = e.focused().unwrap();
                                    assert!(fully_on_screen(&p, id, d), "focus {id} not in view: {tag}");
                                    let hi = (layout::content_width(&e.spans()) - e.avail()).max(0.0);
                                    if mode != ScrollMode::Center && hi > 0.0 && (scroll - hi).abs() < 1e-6 {
                                        let last = frame(&p, n);
                                        assert_eq!(last.x + last.w, dw as i64 - 12, "the end is not flush: {tag}");
                                    }
                                    if mode != ScrollMode::Center && scroll < hi - 1e-6 {
                                        assert!(p.frames.iter().any(|f| f.on_screen && f.x == 12), "no window against the left gap: {tag}");
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn a_release_rests_on_the_grid_after_windows_came_and_went_and_the_tiles_were_caught() {
        let mut seed: u64 = 987654321;
        let mut rnd = move |n: u64| {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) % n
        };
        for sc in 0..600 {
            let w = [1000.0, 1512.0, 1728.0, 3840.0][rnd(4) as usize];
            let mode = [ScrollMode::KeepVisible, ScrollMode::CenterOnOverflow, ScrollMode::Center][rnd(3) as usize];
            let mut e = on_display(w, 0, Config { scroll: mode, ..Config::default() }, 0.5);
            let (mut next_id, mut log) = (1u32, vec![]);
            for step in 0..60 {
                let r = rnd(100);
                let tiled: Vec<u32> = e.state().columns.iter().flat_map(|c| c.windows.clone()).collect();
                let ev = if r < 14 || tiled.is_empty() {
                    let (id, hint) = (next_id, [0.25, 0.333, 0.5, 0.667, 1.0][rnd(5) as usize]);
                    next_id += 1;
                    log.push(format!("add {id} {hint}"));
                    Event::WindowAdded { id, pid: 1, app: format!("A{id}"), title: format!("T{id}"), frame: R, floating: rnd(10) == 0, width_hint: Some(hint), take_focus: rnd(4) != 0 }
                } else if r < 22 {
                    let id = tiled[rnd(tiled.len() as u64) as usize];
                    log.push(format!("remove {id}"));
                    Event::WindowRemoved { id }
                } else if r < 50 {
                    let dx = rnd(2400) as f64 - 1000.0;
                    log.push(format!("by {dx}"));
                    Event::ScrollBy { dx }
                } else if r < 58 {
                    let (id, x) = (tiled[rnd(tiled.len() as u64) as usize], rnd(3000) as f64 - 800.0);
                    log.push(format!("to {id} {x}"));
                    Event::ScrollTo { id, x }
                } else if r < 85 {
                    let v = [0.0, 100.0, -100.0, 450.0, -450.0, 2500.0, -2500.0, 9000.0][rnd(8) as usize];
                    log.push(format!("end {v}"));
                    Event::ScrollEnd { velocity: Some(v) }
                } else {
                    let name = ["focus_left", "focus_right", "cycle_width", "toggle_float", "stack", "unstack", "move_left", "toggle_full", "focus_first", "focus_last", "toggle_tabs"][rnd(11) as usize];
                    log.push(name.to_string());
                    Event::Command { name: name.to_string(), arg: None }
                };
                let released = matches!(ev, Event::ScrollEnd { .. });
                let p = e.handle(ev);
                if released && !e.state().columns.is_empty() {
                    let (rests, scroll) = (rests_of(&e), e.state().scroll);
                    let tag = format!("scenario {sc} {mode:?} w={w} step {step}: scroll {scroll}, rests {rests:?}, last events {:?}", &log[log.len().saturating_sub(8)..]);
                    assert!(rests.iter().any(|r| (r - scroll).abs() < 1e-6), "off the grid: {tag}");
                    if let Some(id) = e.focused().filter(|id| e.pos(*id).is_some()) {
                        assert!(fully_on_screen(&p, id, Rect { w, ..DISPLAY }), "focus {id} not in view: {tag}");
                    }
                }
            }
        }
    }

    #[test]
    fn a_release_leaves_the_ribbon_on_its_rest_whatever_the_scroll_mode_would_reveal() {
        // A third and two thirds fill the display up to a rounding error: `center_on_overflow` takes that for overflow when it
        // reveals the wide column, and would centre it, off the rest the release settled on.
        let cfg = Config { scroll: ScrollMode::CenterOnOverflow, ..Config::default() };
        let mut e = on_display(3840.0, 3, cfg, 0.333);
        for (i, f) in [(2, 0.667), (3, 0.667)] {
            cmd_arg(&mut e, "focus_index", json!(i));
            cmd_arg(&mut e, "set_width", json!(f));
        }
        cmd_arg(&mut e, "focus_index", json!(1));
        assert_eq!(e.state().scroll, 0.0);
        assert_eq!(swipe(&mut e, 50.0, 0.0), 0.0);
        assert_eq!(e.focused(), Some(2), "the wide column holds the middle of the display");
        assert_eq!(rests_of(&e).iter().map(|r| *r as i64).collect::<Vec<_>>(), vec![0, 1274, 2553]);
        assert_eq!(swipe(&mut e, 2000.0, 0.0), 2553.2760000000007, "and the end of the ribbon is flush too");
        assert_eq!(e.focused(), Some(3));
    }

    #[test]
    fn scroll_to_sets_the_viewport_unresisted_and_a_swipe_goes_on_from_there() {
        let mut e = five();
        by(&mut e, -100.0); // resisted: 40 px past the start
        let p = e.handle(Event::Query);
        assert_eq!(e.state().scroll, -40.0);
        // The tiles of a swipe that was caught while it settled sit at x = 52: the core joins them there, not 60% of the way.
        let want = frame(&p, 1).lx as f64;
        by(&mut e, 300.0);
        assert_ne!(e.state().scroll, -40.0);
        let p = e.handle(Event::ScrollTo { id: 1, x: want });
        assert_eq!(e.state().scroll, -40.0);
        assert_eq!(frame(&p, 1).lx, 52);
        assert!(!p.show_map && p.error.is_none());
        assert_eq!((e.focused(), e.undo_len()), (Some(1), 0));
        by(&mut e, -10.0); // still beyond the start: resisted from there
        assert!((e.state().scroll - (-44.0)).abs() < 1e-9);
        by(&mut e, 30.0); // and back in 1:1
        assert!((e.state().scroll - -14.0).abs() < 1e-9);
        // Absolute whatever the resistance: any place within the rubber band's reach, nothing beyond it.
        for (id, x, scroll) in [(3, 600.0, 400.0), (3, 1000.0, 0.0), (1, 73.0, -60.0), (1, -1588.0, 1482.0 + 60.0)] {
            e.handle(Event::ScrollTo { id, x });
            assert_eq!(e.state().scroll, scroll, "id {id} x {x}");
        }
        e.handle(Event::ScrollTo { id: 9, x: 0.0 }); // not a tiled window: ignored
        e.handle(Event::ScrollTo { id: 1, x: f64::NAN });
        assert!(e.state().scroll >= -60.0 && e.state().scroll <= 1542.0);
        // The round trip: a plan's own lx brings the viewport back to within the rounding of the plan.
        for s in [0.0, 123.4, 777.7, 1482.0] {
            e.st.scroll = s;
            let p = e.handle(Event::Query);
            e.st.scroll = 0.0;
            e.handle(Event::ScrollTo { id: 4, x: frame(&p, 4).lx as f64 });
            assert!((e.state().scroll - s).abs() <= 0.5, "{s} -> {}", e.state().scroll);
        }
    }

    #[test]
    fn scroll_to_is_the_set_scroll_path_of_a_caught_swipe() {
        let mut e = five();
        e.set_scroll(-40.0);
        assert_eq!(e.state().scroll, -40.0);
        e.set_scroll(-400.0);
        assert_eq!(e.state().scroll, -60.0);
        e.set_scroll(1482.0 + 1000.0);
        assert_eq!(e.state().scroll, 1482.0 + 60.0);
        e.set_scroll(f64::INFINITY);
        assert_eq!(e.state().scroll, 1482.0 + 60.0);
    }

    #[test]
    fn a_swipe_that_came_back_keeps_its_focus_and_one_that_went_on_follows_it() {
        let mut e = five();
        cmd_arg(&mut e, "focus_index", json!(3)); // scroll 494, columns 2 and 3 in view, 3 focused
        assert_eq!((e.state().scroll, e.focused()), (494.0, Some(3)));
        assert_eq!(swipe(&mut e, 120.0, 0.0), 494.0);
        assert_eq!(e.focused(), Some(3), "it came back: the right-hand column keeps focus");
        assert_eq!(swipe(&mut e, -120.0, 0.0), 494.0);
        assert_eq!(e.focused(), Some(3));
        assert_eq!(swipe(&mut e, -300.0, 0.0), 0.0);
        assert_eq!(e.focused(), Some(1), "it went left: the left-hand column of the pair");
        // Another command in the middle of a gesture drops where it began.
        by(&mut e, 300.0);
        cmd_arg(&mut e, "focus_index", json!(4));
        end(&mut e, None);
        assert_eq!((e.state().scroll, e.focused()), (988.0, Some(4)));
    }

    #[test]
    fn scroll_end_keeps_the_row_in_a_stack_and_is_not_undoable() {
        let mut e = with(3);
        cmd(&mut e, "focus_left");
        cmd(&mut e, "stack"); // 2 -> stacked onto 1
        cmd(&mut e, "focus_down");
        let focused = e.focused();
        let undo = e.undo_len();
        by(&mut e, -5.0);
        end(&mut e, None);
        assert_eq!(e.focused(), focused);
        assert_eq!(e.undo_len(), undo);
    }

    #[test]
    fn scroll_is_deterministic_and_json_shaped() {
        let run = || {
            let mut e = five();
            let mut plans = vec![];
            for dx in [40.0, 55.5, -12.0, 300.0, 700.0] {
                plans.push(e.handle_json(&format!(r#"{{"type":"scroll_by","dx":{dx}}}"#)));
            }
            plans.push(e.handle_json(r#"{"type":"scroll_end","velocity":850.5}"#));
            plans.push(e.handle_json(r#"{"type":"scroll_end"}"#));
            plans
        };
        assert_eq!(run(), run());
        assert!(run().iter().all(|p| p.error.is_none()));
    }

    // ---- virtual desktops ----

    fn sw(e: &mut Engine, n: u32) -> Plan {
        cmd_arg(e, "switch_desktop", json!(n))
    }
    fn mv(e: &mut Engine, n: u32) -> Plan {
        cmd_arg(e, "move_to_desktop", json!(n))
    }
    fn on_desk(e: &Engine, d: usize) -> Vec<u32> {
        e.desktop_windows()[d - 1].clone()
    }

    #[test]
    fn switching_to_an_empty_desktop_parks_everything() {
        let mut e = with(3);
        let p = sw(&mut e, 3);
        assert_eq!(toast(p.clone()).as_deref(), Some("Desktop 3 · empty"));
        assert_eq!(p.map.desktop, 3);
        assert!(p.map.columns.is_empty() && p.focus.is_none() && p.jump && p.show_map);
        assert_eq!(p.frames.len(), 3);
        assert!(p.frames.iter().all(|f| !f.on_screen && f.x == 999));
        assert_eq!(p.map.desktops.iter().map(|d| d.count).collect::<Vec<_>>(), vec![3, 0, 0, 0, 0, 0, 0, 0, 0]);
        assert!(p.map.desktops[2].active && !p.map.desktops[0].active);
        assert_eq!(p.changed, vec![1, 2, 3]);
    }

    #[test]
    fn switching_back_restores_layout_scroll_and_focus() {
        let mut e = with(4);
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_left");
        let before = e.handle(Event::Query);
        sw(&mut e, 2);
        let p = sw(&mut e, 1);
        assert_eq!(toast(p.clone()).as_deref(), Some("Desktop 1"));
        assert_eq!(p.focus, Some(2));
        assert_eq!(p.frames, before.frames);
        assert_eq!(p.map.viewport, before.map.viewport);
        assert!(p.frames.iter().filter(|f| f.on_screen).count() >= 1);
    }

    #[test]
    fn new_windows_go_to_the_active_desktop_and_each_desktop_is_its_own_ribbon() {
        let mut e = with(2);
        sw(&mut e, 2);
        let p = add_to(&mut e, 10, false);
        assert_eq!(on_desk(&e, 2), vec![10]);
        assert_eq!(on_desk(&e, 1), vec![1, 2]);
        assert_eq!(p.map.columns.len(), 1);
        assert_eq!(p.focus, Some(10));
        assert_eq!(e.focused(), Some(10));
        assert!(frame(&p, 10).on_screen && !frame(&p, 1).on_screen);
        cmd(&mut e, "cycle_width"); // desktop 2 only
        sw(&mut e, 1);
        assert_eq!(e.focused(), Some(2));
        assert_eq!(ids(&e), vec![vec![1], vec![2]]);
    }

    #[test]
    fn switch_to_current_desktop_says_so_and_bad_numbers_error() {
        let mut e = with(1);
        let p = sw(&mut e, 1);
        assert_eq!(toast(p).as_deref(), Some("Already on Desktop 1"));
        for bad in [json!(0), json!(10), json!("x")] {
            let p = cmd_arg(&mut e, "switch_desktop", bad);
            assert!(p.error.is_some() && !p.show_map);
        }
        let p = cmd(&mut e, "switch_desktop");
        assert!(p.error.is_some());
        assert_eq!(e.desktop(), 1);
        assert_eq!(toast(sw(&mut e, 9)).as_deref(), Some("Desktop 9 · empty"));
    }

    #[test]
    fn switch_desktop_back_toggles() {
        let mut e = with(1);
        assert_eq!(toast(cmd(&mut e, "switch_desktop_back")).as_deref(), Some("No previous desktop"));
        sw(&mut e, 4);
        assert_eq!(toast(cmd(&mut e, "switch_desktop_back")).as_deref(), Some("Desktop 1"));
        assert_eq!(toast(cmd(&mut e, "switch_desktop_back")).as_deref(), Some("Desktop 4 · empty"));
        assert_eq!(e.desktop(), 4);
        sw(&mut e, 2);
        cmd(&mut e, "switch_desktop_back");
        assert_eq!(e.desktop(), 4);
    }

    #[test]
    fn move_to_desktop_sends_the_window_and_stays_put() {
        let mut e = with(3); // focus 3
        let p = mv(&mut e, 2);
        assert_eq!(toast(p.clone()).as_deref(), Some("Sent to Desktop 2"));
        assert_eq!(e.desktop(), 1);
        assert_eq!(on_desk(&e, 2), vec![3]);
        assert_eq!(ids(&e), vec![vec![1], vec![2]]);
        assert_eq!((e.focused(), p.focus), (Some(2), Some(2)));
        assert!(!frame(&p, 3).on_screen && frame(&p, 2).on_screen);
        assert_eq!(p.map.desktops[1].count, 1);
        // The target takes it right of its focused column.
        sw(&mut e, 2);
        add_to(&mut e, 20, false);
        add_to(&mut e, 21, false);
        cmd(&mut e, "focus_left"); // 20 focused: [3, 20, 21]
        sw(&mut e, 1);
        mv(&mut e, 2);
        sw(&mut e, 2);
        assert_eq!(ids(&e), vec![vec![3], vec![20], vec![2], vec![21]]);
        assert_eq!(e.focused(), Some(20), "target keeps its own focus");
    }

    #[test]
    fn move_to_desktop_edge_cases() {
        let mut e = eng();
        assert_eq!(toast(mv(&mut e, 2)).as_deref(), Some("Nothing to send"));
        add_to(&mut e, 1, false);
        assert_eq!(toast(mv(&mut e, 1)).as_deref(), Some("Already on Desktop 1"));
        assert!(cmd_arg(&mut e, "move_to_desktop", json!(10)).error.is_some());
        let p = mv(&mut e, 5); // last window leaves: desktop is empty, focus none
        assert!(p.focus.is_none() && p.map.columns.is_empty() && e.focused().is_none());
        sw(&mut e, 5);
        assert_eq!(e.focused(), Some(1));
        assert_eq!(e.undo_len(), 0, "the undo entry lives on the source desktop");
    }

    #[test]
    fn move_to_desktop_undo_brings_it_back_and_redo_sends_it_again() {
        let mut e = with(3);
        cmd(&mut e, "focus_left"); // focus 2
        mv(&mut e, 3);
        assert_eq!(ids(&e), vec![vec![1], vec![3]]);
        let p = cmd(&mut e, "undo");
        assert_eq!(toast(p.clone()).as_deref(), Some("Undid: move to desktop"));
        assert_eq!(ids(&e), vec![vec![1], vec![2], vec![3]]);
        assert_eq!((e.focused(), p.focus), (Some(2), Some(2)));
        assert!(on_desk(&e, 3).is_empty());
        assert!(frame(&p, 2).on_screen && p.jump);
        let p = cmd(&mut e, "redo");
        assert_eq!(toast(p).as_deref(), Some("Redid: move to desktop"));
        assert_eq!(ids(&e), vec![vec![1], vec![3]]);
        assert_eq!(on_desk(&e, 3), vec![2]);
        assert_eq!(e.desktop_windows().iter().map(Vec::len).sum::<usize>(), 3);
    }

    #[test]
    fn undo_is_per_desktop_and_switching_is_not_undoable() {
        let mut e = with(2);
        cmd(&mut e, "toggle_full"); // desktop 1 change
        sw(&mut e, 2);
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Nothing to undo"));
        add_to(&mut e, 10, false);
        add_to(&mut e, 11, false);
        cmd(&mut e, "move_left");
        sw(&mut e, 1);
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: full width"));
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Nothing to undo"));
        sw(&mut e, 2);
        assert_eq!(ids(&e), vec![vec![10], vec![11]].into_iter().rev().collect::<Vec<_>>());
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: move"));
        assert_eq!(ids(&e), vec![vec![10], vec![11]]);
    }

    #[test]
    fn os_focus_on_another_desktop_switches_without_stealing_focus() {
        let mut e = with(2);
        mv(&mut e, 2); // window 2 on desktop 2
        let p = e.handle(Event::WindowFocused { id: 2 });
        assert_eq!(e.desktop(), 2);
        assert_eq!(toast(p.clone()).as_deref(), Some("Desktop 2"));
        assert!(p.focus.is_none() && p.show_map && p.jump);
        assert!(frame(&p, 2).on_screen && !frame(&p, 1).on_screen);
        assert_eq!(e.focused(), Some(2));
        // and back through the command bar's focus_window
        let p = cmd_arg(&mut e, "focus_window", json!(1));
        assert_eq!((e.desktop(), p.focus), (1, Some(1)));
        assert_eq!(toast(p).as_deref(), Some("Desktop 1"));
        assert_eq!(e.undo_len(), 1, "the earlier move is still the only undo entry");
    }

    #[test]
    fn floating_windows_belong_to_their_desktop() {
        let mut e = with(1);
        add_to(&mut e, 5, true);
        assert_eq!(on_desk(&e, 1), vec![1, 5]);
        let p = sw(&mut e, 2);
        assert_eq!(p.floating_parked, vec![5]);
        sw(&mut e, 1);
        assert!(e.handle(Event::Query).floating_parked.is_empty());
        // focus the float, send it away: it stays floating and remembers its width
        cmd_arg(&mut e, "focus_window", json!(5));
        let p = mv(&mut e, 4);
        assert_eq!(p.floating_parked, vec![5]);
        assert_eq!(e.focused(), Some(1));
        sw(&mut e, 4);
        assert_eq!(e.focused(), Some(5));
        let p = cmd(&mut e, "toggle_float");
        assert_eq!(ids(&e), vec![vec![5]]);
        assert!(frame(&p, 5).on_screen);
    }

    #[test]
    fn sent_floating_window_keeps_its_tile_width() {
        let mut e = with(1);
        add_to(&mut e, 2, false);
        cmd(&mut e, "cycle_width"); // window 2 wider
        let w = e.st.columns[1].width;
        cmd(&mut e, "toggle_float");
        mv(&mut e, 2);
        sw(&mut e, 2);
        cmd(&mut e, "toggle_float");
        assert_eq!(e.st.columns[0].width, w);
    }

    #[test]
    fn closing_a_window_on_an_inactive_desktop_cleans_up_there() {
        let mut e = with(2);
        mv(&mut e, 2); // 2 -> desktop 2; focus 1
        sw(&mut e, 2);
        add_to(&mut e, 9, false); // [2, 9], focus 9
        sw(&mut e, 1);
        let p = e.handle(Event::WindowRemoved { id: 9 });
        assert_eq!((e.desktop(), e.focused()), (1, Some(1)));
        assert!(p.frames.iter().all(|f| f.id != 9));
        assert_eq!(on_desk(&e, 2), vec![2]);
        sw(&mut e, 2);
        assert_eq!(e.focused(), Some(2), "its focus fell back to the neighbour");
        e.handle(Event::WindowRemoved { id: 2 });
        assert_eq!(toast(sw(&mut e, 1)).as_deref(), Some("Desktop 1"));
        assert_eq!(toast(sw(&mut e, 2)).as_deref(), Some("Desktop 2 · empty"));
    }

    #[test]
    fn resize_undo_on_a_second_desktop_still_coalesces() {
        let mut e = with(1);
        sw(&mut e, 2);
        add_to(&mut e, 10, false);
        let start = e.st.columns[0].width;
        drag(&mut e, 10, 500.0, 700.0);
        drag(&mut e, 10, 520.0, 700.0);
        assert_eq!(e.undo_len(), 1);
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: resize"));
        assert_eq!(e.st.columns[0].width, start);
    }

    #[test]
    fn display_change_and_gather_keep_parked_desktops_parked() {
        let mut e = with(2);
        mv(&mut e, 2);
        let p = cmd(&mut e, "gather");
        assert_eq!(p.frames.len(), 2);
        assert!(!frame(&p, 2).on_screen);
        let p = e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1200.0, h: 800.0 } });
        assert_eq!(frame(&p, 2).x, 1199);
        assert!(!frame(&p, 2).on_screen);
    }

    #[test]
    fn focus_previous_is_per_desktop() {
        let mut e = with(3);
        cmd(&mut e, "focus_left");
        sw(&mut e, 2);
        add_to(&mut e, 10, false);
        cmd(&mut e, "focus_previous"); // nothing earlier on desktop 2
        assert_eq!(e.focused(), Some(10));
        sw(&mut e, 1);
        cmd(&mut e, "focus_previous");
        assert_eq!(e.focused(), Some(3));
    }

    // ---- minimize / hide shelf ----
    fn minimize(e: &mut Engine, id: u32) -> Plan {
        e.handle(Event::WindowMinimized { id })
    }
    fn add_app(e: &mut Engine, id: u32, pid: i32) -> Plan {
        e.handle(Event::WindowAdded { id, pid, app: format!("P{pid}"), title: format!("T{id}"), frame: R, floating: false, width_hint: None, take_focus: true })
    }

    #[test]
    fn minimize_closes_the_gap_with_12px() {
        let mut e = with(3);
        let p = minimize(&mut e, 2);
        assert_eq!(p.frames.len(), 2);
        let (a, b) = (frame(&p, 1), frame(&p, 3));
        assert_eq!(b.x - (a.x + a.w), 12, "no gap left");
        assert_eq!(ids(&e), vec![vec![1], vec![3]]);
        assert_eq!(p.shelf.len(), 1);
        assert_eq!((p.shelf[0].id, p.shelf[0].hidden, p.shelf[0].desk), (2, false, 1));
    }

    #[test]
    fn minimize_then_restore_keeps_width_and_focuses() {
        let mut e = with(3);
        cmd(&mut e, "focus_left"); // 2
        cmd(&mut e, "cycle_width");
        let w2 = frame(&e.handle(Event::Query), 2).w;
        minimize(&mut e, 2);
        e.handle(Event::WindowFocused { id: 3 });
        let p = add_to(&mut e, 2, false); // deminiaturize: same id again
        assert_eq!(frame(&p, 2).w, w2, "remembered width");
        assert_eq!(e.focused(), Some(2));
        assert_eq!(p.focus, Some(2));
        assert!(p.shelf.is_empty());
        // right of the focused column (3)
        let cols: Vec<u32> = e.state().columns.iter().map(|c| c.windows[0]).collect();
        assert_eq!(cols, vec![1, 3, 2]);
    }

    #[test]
    fn restore_returns_to_the_desktop_it_left() {
        let mut e = with(2);
        sw(&mut e, 2);
        add_to(&mut e, 20, false);
        add_to(&mut e, 21, false);
        cmd(&mut e, "cycle_width");
        let w = frame(&e.handle(Event::Query), 21).w;
        minimize(&mut e, 21);
        sw(&mut e, 1);
        let p = add_to(&mut e, 21, false);
        assert_eq!(e.desktop(), 2, "switched to where it was");
        assert!(p.jump);
        assert_eq!(on_desk(&e, 1), vec![1, 2]);
        assert_eq!(on_desk(&e, 2), vec![20, 21]);
        assert_eq!((e.focused(), p.focus), (Some(21), Some(21)));
        assert_eq!(frame(&p, 21).w, w);
    }

    #[test]
    fn destroy_while_minimized_drops_the_shelf_entry() {
        let mut e = with(2);
        minimize(&mut e, 2);
        assert_eq!(e.handle(Event::Query).shelf.len(), 1);
        let p = e.handle(Event::WindowRemoved { id: 2 });
        assert!(p.shelf.is_empty());
        // A fresh window with that id is a new window, not a restore.
        let p = add_to(&mut e, 2, false);
        assert!(p.shelf.is_empty() && e.window_count() == 2);
    }

    #[test]
    fn hide_app_shelves_all_its_windows_and_unhide_restores_order_and_widths() {
        let mut e = eng();
        add_app(&mut e, 1, 100);
        add_app(&mut e, 2, 200);
        add_app(&mut e, 3, 100);
        add_app(&mut e, 4, 300);
        add_app(&mut e, 5, 100);
        // distinct widths for 1 and 3
        e.handle(Event::WindowFocused { id: 3 });
        cmd(&mut e, "cycle_width");
        let before = e.handle(Event::Query);
        let (w1, w3) = (frame(&before, 1).w, frame(&before, 3).w);
        let p = e.handle(Event::AppHidden { pid: 100 });
        assert_eq!(p.frames.len(), 2);
        assert_eq!(e.window_count(), 2);
        assert!(p.shelf.iter().all(|s| s.hidden) && p.shelf.len() == 3);
        let (a, b) = (frame(&p, 2), frame(&p, 4));
        assert_eq!(b.x - (a.x + a.w), 12);
        e.handle(Event::WindowFocused { id: 4 });
        let p = e.handle(Event::AppShown { pid: 100, front: Some(3), take_focus: true });
        let order: Vec<u32> = e.state().columns.iter().map(|c| c.windows[0]).collect();
        assert_eq!(order, vec![2, 4, 1, 3, 5], "next to focus, original relative order");
        assert_eq!(frame(&p, 1).w, w1);
        assert_eq!(frame(&p, 3).w, w3);
        assert_eq!((e.focused(), p.focus), (Some(3), Some(3)));
        assert!(p.shelf.is_empty());
    }

    #[test]
    fn unhide_leaves_minimized_windows_shelved() {
        let mut e = eng();
        add_app(&mut e, 1, 100);
        add_app(&mut e, 2, 100);
        minimize(&mut e, 1);
        e.handle(Event::AppHidden { pid: 100 });
        let p = e.handle(Event::AppShown { pid: 100, front: None, take_focus: true });
        assert_eq!(e.window_count(), 1);
        assert_eq!(p.shelf.len(), 1);
        assert!(!p.shelf[0].hidden);
    }

    #[test]
    fn an_app_unhidden_while_the_user_is_elsewhere_comes_back_quietly_in_order() {
        let mut e = eng();
        for (id, pid) in [(1, 100), (2, 200), (3, 100), (4, 300), (5, 100)] {
            add_app(&mut e, id, pid);
        }
        e.handle(Event::AppHidden { pid: 100 });
        e.handle(Event::WindowFocused { id: 2 });
        let (before, s0) = (e.handle(Event::Query), e.st.scroll);
        let p = e.handle(Event::AppShown { pid: 100, front: Some(3), take_focus: false });
        let order: Vec<u32> = e.state().columns.iter().map(|c| c.windows[0]).collect();
        assert_eq!(order, vec![2, 1, 3, 5, 4], "right of the focused column, in their old order");
        assert_eq!((e.focused(), p.focus, p.map.focused_index), (Some(2), None, Some(0)));
        assert!(!p.show_map && p.shelf.is_empty() && p.error.is_none());
        assert_eq!((frame(&p, 2).x, e.st.scroll), (frame(&before, 2).x, s0), "the view stays put");
        // The user ⌘Tabs there afterwards: the OS reports the app's front window and the ribbon goes to it.
        let p = e.handle(Event::WindowFocused { id: 3 });
        assert!(e.focused() == Some(3) && frame(&p, 3).on_screen);
    }

    #[test]
    fn hide_and_unhide_json_shapes() {
        let mut e = eng();
        add_app(&mut e, 1, 100);
        let p = e.handle_json(r#"{"type":"app_hidden","pid":100}"#);
        assert!(p.error.is_none() && p.frames.is_empty());
        let p = e.handle_json(r#"{"type":"app_shown","pid":100}"#);
        assert!(p.error.is_none() && p.frames.len() == 1 && p.focus == Some(1), "take_focus is optional and defaults to yes");
        e.handle_json(r#"{"type":"app_hidden","pid":100}"#);
        let p = e.handle_json(r#"{"type":"app_shown","pid":100,"take_focus":false}"#);
        assert!(p.error.is_none() && p.frames.len() == 1 && p.focus.is_none());
        let p = e.handle_json(r#"{"type":"window_minimized","id":1}"#);
        assert!(p.error.is_none() && p.shelf.len() == 1);
    }

    // ---- first / last, equalize, center on overflow, session ----
    #[test]
    fn focus_first_and_last_jump_and_toast_only_when_moved() {
        let mut e = with(5);
        let p = cmd(&mut e, "focus_first");
        assert_eq!((p.focus, p.toast.as_deref()), (Some(1), Some("First window")));
        assert_eq!(e.st.scroll, 0.0);
        let p = cmd(&mut e, "focus_first");
        assert_eq!((p.focus, p.toast.as_deref()), (None, Some("No more windows on the left")));
        let p = cmd(&mut e, "focus_last");
        assert_eq!((p.focus, p.toast.as_deref()), (Some(5), Some("Last window")));
        let p = cmd(&mut e, "focus_last");
        assert_eq!(p.toast.as_deref(), Some("No more windows on the right"));
        assert_eq!(e.undo_len(), 0, "navigation is not undoable");
    }

    #[test]
    fn focus_first_and_last_land_on_the_top_of_a_stack_and_leave_floats() {
        let mut e = with(3);
        cmd(&mut e, "stack"); // columns [1] [2,3], focus 3 (bottom)
        let p = cmd(&mut e, "focus_last");
        assert_eq!((e.focused(), p.toast.as_deref()), (Some(2), Some("Last window")));
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        let p = cmd(&mut e, "focus_first");
        assert_eq!((p.focus, p.toast.as_deref()), (Some(1), Some("First window")));
        e.handle(Event::WindowFocused { id: 9 });
        assert_eq!(cmd(&mut e, "focus_last").focus, Some(2), "from a float it re-enters the ribbon at the end");
    }

    #[test]
    fn focus_first_last_on_empty_ribbon_is_quiet() {
        let mut e = eng();
        let p = cmd(&mut e, "focus_first");
        assert!(p.error.is_none() && p.focus.is_none() && p.toast.is_none());
        let p = cmd(&mut e, "focus_last");
        assert!(p.error.is_none() && p.toast.is_none());
    }

    #[test]
    fn equalize_heights_resets_the_focused_stack_and_undoes() {
        let mut e = with(3);
        cmd(&mut e, "stack"); // 2,3
        cmd(&mut e, "focus_up"); // 2
        cmd(&mut e, "cycle_height");
        assert!(e.st.columns[1].heights.is_some());
        let uneven = e.st.columns[1].heights.clone();
        let p = cmd(&mut e, "equalize_heights");
        assert!(e.st.columns[1].heights.is_none());
        assert_eq!(p.toast.as_deref(), Some("Heights evened out"));
        let (a, b) = (frame(&p, 2).h, frame(&p, 3).h);
        assert!((a - b).abs() <= 1, "{a} vs {b}");
        let p = cmd(&mut e, "undo");
        assert_eq!(e.st.columns[1].heights, uneven);
        assert_eq!(p.toast.as_deref(), Some("Undid: heights"));
    }

    #[test]
    fn equalize_heights_when_already_even_or_not_stacked_changes_nothing() {
        let mut e = with(3);
        let p = cmd(&mut e, "equalize_heights");
        assert_eq!(p.toast.as_deref(), Some("Stack windows first"));
        assert_eq!(e.undo_len(), 0);
        cmd(&mut e, "stack");
        let depth = e.undo_len();
        let p = cmd(&mut e, "equalize_heights");
        assert_eq!(p.toast.as_deref(), Some("Already even"));
        assert_eq!(e.undo_len(), depth, "no undo entry for a no-op");
        assert!(p.changed.is_empty());
    }

    #[test]
    fn equalize_only_touches_the_focused_stack() {
        let mut e = with(4);
        cmd(&mut e, "stack"); // 3,4
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_left"); // 2
        cmd(&mut e, "stack"); // [1,2]? 2 joins column 1
        cmd(&mut e, "cycle_height");
        let other = e.st.columns.iter().position(|c| c.windows.contains(&4)).unwrap();
        e.st.columns[other].heights = Some(vec![0.25, 0.75]);
        cmd(&mut e, "equalize_heights");
        assert_eq!(e.st.columns[other].heights, Some(vec![0.25, 0.75]));
    }

    // ---- go to window n, first / last place, nudges, stack right, reorder in a stack ----
    #[test]
    fn go_to_window_n_lands_on_the_nth_column_without_an_undo_step() {
        let mut e = with(5);
        cmd(&mut e, "focus_first");
        cmd(&mut e, "stack_right"); // [1,2] [3] [4] [5], focus 1
        for (k, want) in [(2, 3), (3, 4), (4, 5), (1, 1)] {
            let p = cmd_arg(&mut e, "focus_index", json!(k));
            assert_eq!((p.focus, p.map.focused_index), (Some(want), Some(k as usize - 1)), "window {k}");
            assert!(frame(&p, want).on_screen, "window {k} is revealed");
        }
        assert_eq!(cmd_arg(&mut e, "focus_index", json!(9)).focus, Some(5), "past the end it clamps to the last column");
        assert_eq!(e.undo_len(), 1, "only the stack_right is an edit");
        // A tabbed column lands on its shown tab, and a float gives way to the column.
        let mut e = with(3);
        mv_to(&mut e, 1, 2, "tabs"); // [2,1 tabs] [3], 1 shown
        cmd_arg(&mut e, "focus_index", json!(2));
        assert_eq!(cmd_arg(&mut e, "focus_index", json!(1)).focus, Some(1), "the tab that was shown");
        add_to(&mut e, 8, true);
        e.handle(Event::WindowFocused { id: 8 });
        assert_eq!(cmd_arg(&mut e, "focus_index", json!(2)).focus, Some(3));
    }

    #[test]
    fn move_first_and_last_carry_the_whole_column_and_keep_focus() {
        let mut e = with(4);
        cmd_arg(&mut e, "focus_index", json!(3));
        let p = cmd(&mut e, "move_first");
        assert_eq!((ids(&e), e.focused(), p.toast.as_deref()), (vec![vec![3], vec![1], vec![2], vec![4]], Some(3), Some("Moved to the start")));
        assert_eq!((p.map.focused_index, e.st.scroll), (Some(0), 0.0), "the column is revealed where it landed");
        let p = cmd(&mut e, "move_last");
        assert_eq!((ids(&e), e.focused(), p.toast.as_deref()), (vec![vec![1], vec![2], vec![4], vec![3]], Some(3), Some("Moved to the end")));
        assert_eq!(p.map.focused_index, Some(3));
        assert!(frame(&p, 3).on_screen);
        assert_eq!(e.undo_len(), 2);
        assert_eq!(cmd(&mut e, "undo").toast.as_deref(), Some("Undid: move"));
        assert_eq!(ids(&e), vec![vec![3], vec![1], vec![2], vec![4]]);
        assert_eq!(cmd(&mut e, "redo").toast.as_deref(), Some("Redid: move"));
        assert_eq!(ids(&e), vec![vec![1], vec![2], vec![4], vec![3]]);
        // A stack travels as one column, and the focused window stays focused.
        let mut e = with(3);
        cmd(&mut e, "stack"); // [1] [2,3], focus 3
        cmd(&mut e, "move_first");
        assert_eq!((ids(&e), e.focused()), (vec![vec![2, 3], vec![1]], Some(3)));
    }

    #[test]
    fn move_first_and_last_at_the_ends_are_quiet_no_ops() {
        let mut e = with(3);
        let p = cmd(&mut e, "move_last");
        assert_eq!((p.toast.as_deref(), e.undo_len()), (Some("Already last"), 0));
        cmd(&mut e, "focus_first");
        let p = cmd(&mut e, "move_first");
        assert_eq!((p.toast.as_deref(), e.undo_len(), ids(&e)), (Some("Already first"), 0, vec![vec![1], vec![2], vec![3]]));
        assert!(p.error.is_none() && p.changed.is_empty());
        let mut e = with(1);
        assert_eq!(cmd(&mut e, "move_first").toast.as_deref(), Some("Already first"));
        // A float has no place in the ribbon to move; an empty ribbon has nothing.
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        let p = cmd(&mut e, "move_last");
        assert!(p.toast.is_none() && p.error.is_none() && e.undo_len() == 0);
        let mut e = eng();
        assert!(cmd(&mut e, "move_first").error.is_none() && cmd(&mut e, "move_last").error.is_none());
    }

    #[test]
    fn grow_and_shrink_width_step_five_percent_from_any_width() {
        let mut e = with(2); // two halves
        let w = |e: &Engine| e.st.columns[1].width;
        let p = cmd(&mut e, "grow_width");
        assert_eq!((w(&e), p.toast.as_deref()), (Width::Frac(0.55), Some("Width 55\u{a0}%")));
        assert_eq!(p.map.columns[1].width_frac, 0.55);
        assert!(frame(&p, 2).w > frame(&p, 1).w);
        for want in [0.6, 0.65, 0.7] {
            cmd(&mut e, "grow_width");
            assert_eq!(w(&e), Width::Frac(want));
        }
        for want in [0.65, 0.6, 0.55, 0.5] {
            cmd(&mut e, "shrink_width");
            assert_eq!(w(&e), Width::Frac(want));
        }
        assert_eq!(e.undo_len(), 8, "one undo step per tap");
        assert_eq!(cmd(&mut e, "undo").toast.as_deref(), Some("Undid: width"));
        assert_eq!(w(&e), Width::Frac(0.55));
        // From a dragged width the step is taken from the equivalent fraction.
        e.handle(Event::WindowResized { id: 2, frame: Rect { x: 0.0, y: 0.0, w: 600.0, h: 500.0 } });
        let f = layout::width_frac(w(&e), &e.cfg, e.avail());
        assert!(matches!(w(&e), Width::Px(_)));
        let p = cmd(&mut e, "shrink_width");
        assert!(matches!(w(&e), Width::Frac(x) if (x - (f - 0.05)).abs() < 1e-3), "{:?} from {f}", w(&e));
        assert_eq!(p.toast.as_deref(), Some(format!("Width {}", percent(f - 0.05)).as_str()));
    }

    #[test]
    fn grow_and_shrink_width_stop_at_full_and_at_the_drag_floor() {
        let mut e = with(1);
        cmd_arg(&mut e, "set_width", json!(0.97));
        assert_eq!(cmd(&mut e, "grow_width").toast.as_deref(), Some("Width 100\u{a0}%"));
        let depth = e.undo_len();
        let p = cmd(&mut e, "grow_width");
        assert_eq!((p.toast.as_deref(), e.undo_len(), e.st.columns[0].width), (Some("As wide as it gets"), depth, Width::Frac(1.0)));
        assert!(p.changed.is_empty());
        // 976 px usable: the smallest preset (25 %) is the floor, as for a direct width.
        cmd_arg(&mut e, "set_width", json!(0.28));
        assert_eq!(cmd(&mut e, "shrink_width").toast.as_deref(), Some("Width 25\u{a0}%"));
        let depth = e.undo_len();
        let p = cmd(&mut e, "shrink_width");
        assert_eq!((p.toast.as_deref(), e.undo_len(), e.st.columns[0].width), (Some("As narrow as it gets"), depth, Width::Frac(0.25)));
    }

    #[test]
    fn shrink_width_never_widens_a_column_below_a_raised_floor() {
        let mut e = with(1);
        cmd_arg(&mut e, "set_width", json!(0.3));
        cmd_arg(&mut e, "set_width_presets", json!([0.5, 1.0])); // the floor rises to the drag floor, above 30 %
        let depth = e.undo_len();
        let p = cmd(&mut e, "shrink_width");
        assert_eq!((p.toast.as_deref(), e.undo_len(), e.st.columns[0].width), (Some("As narrow as it gets"), depth, Width::Frac(0.3)));
        cmd(&mut e, "grow_width");
        assert!(matches!(e.st.columns[0].width, Width::Frac(f) if f > 0.35), "a grow goes on from there, up to at least the floor");
    }

    #[test]
    fn a_width_nudge_that_cannot_go_on_keeps_the_full_width_restore() {
        let mut e = with(2);
        cmd(&mut e, "toggle_full");
        assert!(e.st.columns[1].restore.is_some());
        cmd(&mut e, "grow_width");
        assert_eq!(e.st.columns[1].restore, Some(Width::Frac(0.5)), "nothing changed, so full width still toggles back");
        cmd(&mut e, "shrink_width");
        assert_eq!((e.st.columns[1].width, e.st.columns[1].restore), (Width::Frac(0.95), None), "a real change forgets it, like any width");
    }

    #[test]
    fn width_nudges_apply_to_a_stacked_column_and_ignore_floats() {
        let mut e = with(3);
        cmd(&mut e, "stack");
        let p = cmd(&mut e, "grow_width");
        assert_eq!(e.st.columns[1].width, Width::Frac(0.55));
        assert!(frame(&p, 2).w == frame(&p, 3).w && frame(&p, 2).w > frame(&p, 1).w);
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        let (before, depth) = (e.state().clone(), e.undo_len());
        let p = cmd(&mut e, "shrink_width");
        assert!(p.toast.is_none() && p.error.is_none() && e.state() == &before && e.undo_len() == depth);
    }

    #[test]
    fn grow_and_shrink_height_step_the_share_of_a_stacked_window() {
        let mut e = stack_of(2);
        e.handle(Event::WindowFocused { id: 1 });
        let p = cmd(&mut e, "grow_height");
        assert_eq!(p.toast.as_deref(), Some("Height 55\u{a0}%"));
        let h = e.st.columns[0].shares();
        assert!((h[0] - 0.55).abs() < 1e-9 && (h[1] - 0.45).abs() < 1e-9, "{h:?}");
        no_overlap(&p, &[1, 2]);
        assert!(frame(&p, 1).h > frame(&p, 2).h);
        let p = cmd(&mut e, "shrink_height");
        assert_eq!(p.toast.as_deref(), Some("Height 50\u{a0}%"));
        assert!(e.st.columns[0].heights.is_none(), "back to an equal split is stored as unset");
        // The others share what is left equally, as for the height presets.
        let mut e = stack_of(3);
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd(&mut e, "grow_height");
        let h = e.st.columns[0].shares();
        assert!((h[1] - (1.0 / 3.0 + 0.05)).abs() < 1e-9 && (h[0] - h[2]).abs() < 1e-9 && (h.iter().sum::<f64>() - 1.0).abs() < 1e-9, "{h:?}");
        assert_eq!(p.toast.as_deref(), Some("Height 38\u{a0}%"));
        no_overlap(&p, &[1, 2, 3]);
        // The window below takes its own share.
        e.handle(Event::WindowFocused { id: 3 });
        cmd(&mut e, "shrink_height");
        assert!(e.st.columns[0].shares()[2] < e.st.columns[0].shares()[0]);
        assert_eq!(cmd(&mut e, "undo").toast.as_deref(), Some("Undid: height"));
    }

    #[test]
    fn height_nudges_stop_at_the_minimum_and_never_squeeze_a_neighbour() {
        let mut e = stack_of(3);
        e.handle(Event::WindowFocused { id: 1 });
        let mut last = None;
        for _ in 0..12 {
            let p = cmd(&mut e, "grow_height");
            assert!(p.frames.iter().all(|f| f.h >= 116), "{:?}", hs(&p, &[1, 2, 3]));
            no_overlap(&p, &[1, 2, 3]);
            last = p.toast;
        }
        assert_eq!(last.as_deref(), Some("As tall as it gets"));
        let depth = e.undo_len();
        cmd(&mut e, "grow_height");
        assert_eq!(e.undo_len(), depth, "the nudge that goes nowhere is not an undo step");
        for _ in 0..12 {
            let p = cmd(&mut e, "shrink_height");
            assert!(p.frames.iter().all(|f| f.h >= 116), "{:?}", hs(&p, &[1, 2, 3]));
            last = p.toast;
        }
        assert_eq!(last.as_deref(), Some("As short as it gets"));
    }

    #[test]
    fn height_nudges_need_a_stack_and_leave_tabs_alone() {
        let mut e = with(2);
        for c in ["grow_height", "shrink_height"] {
            let p = cmd(&mut e, c);
            assert_eq!(p.toast.as_deref(), Some("Stack windows first"), "{c}");
            assert!(p.error.is_none() && e.undo_len() == 0);
        }
        let mut e = tabbed3();
        let (before, depth) = (e.state().clone(), e.undo_len());
        let p = cmd(&mut e, "grow_height");
        assert_eq!((p.toast.as_deref(), e.state() == &before, e.undo_len()), (Some("Tabs fill the column"), true, depth));
        assert!(cmd(&mut eng(), "grow_height").error.is_none());
    }

    #[test]
    fn stack_right_and_height_nudges_leave_a_focused_float_alone() {
        let mut e = stack_of(2);
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        let (before, depth) = (e.state().clone(), e.undo_len());
        for c in ["stack_right", "grow_height", "shrink_height"] {
            let p = cmd(&mut e, c);
            assert!(p.toast.is_none() && p.error.is_none(), "{c}: {:?}", p.toast);
            assert!(e.state() == &before && e.undo_len() == depth, "{c} changed nothing");
        }
    }

    #[test]
    fn stack_right_mirrors_stack() {
        let mut e = with(3);
        cmd_arg(&mut e, "focus_index", json!(1));
        let p = cmd(&mut e, "stack_right");
        assert_eq!((ids(&e), e.focused(), p.toast.as_deref()), (vec![vec![1, 2], vec![3]], Some(1), Some("Stacked")));
        assert_eq!(p.map.focused_index, Some(0));
        let (a, b) = (frame(&p, 1), frame(&p, 2));
        assert_eq!((a.x, a.w), (b.x, b.w));
        assert!(a.y < b.y, "it joins at the top of the column on its right");
        assert_eq!(cmd(&mut e, "undo").toast.as_deref(), Some("Undid: stack"));
        assert_eq!(ids(&e), vec![vec![1], vec![2], vec![3]]);
        assert_eq!(cmd(&mut e, "redo").toast.as_deref(), Some("Redid: stack"));
        // Into a stack: the lone window's column is gone and it heads the column on its right.
        let mut e = with(3);
        cmd(&mut e, "stack"); // [1] [2,3]
        e.handle(Event::WindowFocused { id: 1 });
        cmd(&mut e, "stack_right");
        assert_eq!(ids(&e), vec![vec![1, 2, 3]]);
        // Out of a stack: the column it leaves stays.
        let mut e = with(4);
        cmd_arg(&mut e, "focus_index", json!(3));
        cmd(&mut e, "stack"); // 3 into 2: [1] [2,3] [4]
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "stack_right"); // 2 leaves the pair and heads the next column, 3 stays
        assert_eq!(ids(&e), vec![vec![1], vec![3], vec![2, 4]]);
        assert_eq!(e.focused(), Some(2));
    }

    #[test]
    fn stack_right_at_the_last_column_is_a_quiet_no_op_and_resets_heights() {
        let mut e = with(3);
        let p = cmd(&mut e, "stack_right");
        assert_eq!((p.toast.as_deref(), e.undo_len(), ids(&e)), (Some("No more windows on the right"), 0, vec![vec![1], vec![2], vec![3]]));
        assert!(p.error.is_none() && p.changed.is_empty());
        let mut e = with(2);
        cmd(&mut e, "stack"); // [1,2]
        cmd(&mut e, "cycle_height");
        assert!(e.st.columns[0].heights.is_some());
        add_to(&mut e, 3, false);
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "stack_right");
        assert_eq!(ids(&e), vec![vec![1], vec![2, 3]]);
        assert!(e.st.columns.iter().all(|c| c.heights.is_none()), "both columns change shape: equal heights");
        assert_eq!(cmd(&mut e, "stack").toast.as_deref(), Some("Stacked"));
        cmd(&mut e, "focus_first");
        assert_eq!(cmd(&mut e, "stack").toast.as_deref(), Some("No more windows on the left"), "the mirror says so too");
    }

    #[test]
    fn stack_right_into_tabs_makes_the_window_the_first_shown_tab() {
        let mut e = with(3);
        mv_to(&mut e, 2, 3, "tabs"); // [1] [3,2 tabs]
        cmd(&mut e, "focus_first");
        let p = cmd(&mut e, "stack_right");
        assert_eq!(ids(&e), vec![vec![1, 3, 2]]);
        assert!(e.st.columns[0].tabbed && e.st.columns[0].active == Some(1) && e.focused() == Some(1));
        assert_eq!((p.tab_bars[0].active, p.tab_bars[0].tabs.len()), (1, 3));
    }

    #[test]
    fn move_up_and_down_reorder_a_stack_and_keep_heights_with_their_windows() {
        let mut e = stack_of(3);
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd(&mut e, "move_up");
        assert_eq!((ids(&e), e.focused(), p.toast.as_deref()), (vec![vec![2, 1, 3]], Some(2), Some("Moved up")));
        assert!(frame(&p, 2).y < frame(&p, 1).y);
        let depth = e.undo_len();
        let p = cmd(&mut e, "move_up");
        assert_eq!((ids(&e), p.toast.as_deref(), e.undo_len()), (vec![vec![2, 1, 3]], Some("Top of the stack"), depth));
        for want in [vec![vec![1, 2, 3]], vec![vec![1, 3, 2]]] {
            cmd(&mut e, "move_down");
            assert_eq!(ids(&e), want);
        }
        let depth = e.undo_len();
        let p = cmd(&mut e, "move_down");
        assert_eq!((p.toast.as_deref(), e.undo_len()), (Some("Bottom of the stack"), depth));
        assert_eq!(cmd(&mut e, "undo").toast.as_deref(), Some("Undid: move"));
        assert_eq!(ids(&e), vec![vec![1, 2, 3]]);
        // The height travels with the window.
        let mut e = stack_of(2);
        e.handle(Event::WindowFocused { id: 1 });
        let tall = frame(&cmd(&mut e, "cycle_height"), 1).h;
        let p = cmd(&mut e, "move_down");
        assert_eq!(ids(&e), vec![vec![2, 1]]);
        assert!((frame(&p, 1).h - tall).abs() <= 1, "{} vs {tall}", frame(&p, 1).h);
        no_overlap(&p, &[2, 1]);
        assert_eq!(e.st.columns[0].shares()[1], 2.0 / 3.0);
    }

    #[test]
    fn move_up_and_down_need_a_stack_and_leave_floats_alone() {
        let mut e = with(2);
        for c in ["move_up", "move_down"] {
            let p = cmd(&mut e, c);
            assert_eq!(p.toast.as_deref(), Some("No stack here"), "{c}");
            assert!(p.error.is_none() && e.undo_len() == 0 && ids(&e) == [vec![1], vec![2]]);
        }
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        let p = cmd(&mut e, "move_up");
        assert!(p.toast.is_none() && p.error.is_none() && e.undo_len() == 0);
        assert!(cmd(&mut eng(), "move_down").error.is_none());
    }

    #[test]
    fn move_up_and_down_move_the_tab_in_a_tabbed_column() {
        let mut e = tabbed3(); // [1,2,3], 1 shown
        let depth = e.undo_len();
        let p = cmd(&mut e, "move_up");
        assert_eq!((ids(&e), p.toast.as_deref(), e.undo_len()), (vec![vec![1, 2, 3]], Some("Already the first tab"), depth));
        let p = cmd(&mut e, "move_down");
        assert_eq!((ids(&e), e.focused(), p.toast.as_deref()), (vec![vec![2, 1, 3]], Some(1), Some("Moved to tab 2 of 3 · App1")));
        assert!(e.st.columns[0].tabbed && e.st.columns[0].active == Some(1));
        assert_eq!(p.tab_bars[0].tabs.iter().map(|t| t.id).collect::<Vec<_>>(), vec![2, 1, 3]);
        assert_eq!(p.tab_bars[0].active, 1);
        cmd(&mut e, "move_down");
        assert_eq!(cmd(&mut e, "move_down").toast.as_deref(), Some("Already the last tab"));
        assert_eq!(ids(&e), vec![vec![2, 3, 1]]);
        assert_eq!(cmd(&mut e, "undo").toast.as_deref(), Some("Undid: move"));
        assert_eq!(ids(&e), vec![vec![2, 1, 3]]);
    }

    fn center_engine(n: u32) -> Engine {
        let mut e = Engine::new(Config { scroll: ScrollMode::CenterOnOverflow, ..Config::default() });
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 1000.0, h: 800.0 } });
        (1..=n).for_each(|i| {
            add_to(&mut e, i, false);
        });
        e
    }

    #[test]
    fn center_on_overflow_centers_only_when_the_column_does_not_fit() {
        let mut e = center_engine(4); // lefts 0,494,988,1482 width 482, avail 976
        // the newest column hangs off the right edge: centered, then clamped to the content end
        assert_eq!(e.st.scroll, 1964.0 - 976.0);
        cmd(&mut e, "focus_left"); // 3rd column [988,1470] is inside [988,1964]: no move
        assert_eq!(e.st.scroll, 988.0);
        cmd(&mut e, "focus_left"); // 2nd [494,976] starts left of the view: centered (494+241-488=247)
        assert_eq!(e.st.scroll, 247.0);
        cmd(&mut e, "focus_right"); // 3rd [988,1470] vs view [247,1223]: overflows right, centered at 741
        assert_eq!(e.st.scroll, 741.0);
        cmd(&mut e, "focus_left"); // 2nd [494,976] fully in [741,..]? no (494<741): centered again
        assert_eq!(e.st.scroll, 247.0);
        cmd(&mut e, "focus_first");
        assert_eq!(e.st.scroll, 0.0, "centering never leaves a gap before the first column");
    }

    #[test]
    fn center_on_overflow_leaves_a_fitting_column_alone() {
        let mut e = center_engine(2);
        assert_eq!(e.st.scroll, 0.0);
        cmd(&mut e, "focus_left");
        assert_eq!(e.st.scroll, 0.0);
        let mut k = with(4);
        assert_ne!(k.st.scroll, 247.0, "keep_visible aligns edges");
        cmd(&mut k, "focus_left");
        cmd(&mut k, "focus_left");
        assert_eq!(k.st.scroll, 494.0);
    }

    #[test]
    fn center_on_overflow_parses_from_config() {
        let mut e = Engine::new(Config { scroll: ScrollMode::CenterOnOverflow, ..Config::default() });
        let p = e.handle_json(r#"{"type":"display","id":1,"frame":{"x":0,"y":0,"w":1000,"h":800}}"#);
        assert!(p.error.is_none());
        let v: serde_json::Value = serde_json::to_value(ScrollMode::CenterOnOverflow).unwrap();
        assert_eq!(v, json!("center_on_overflow"));
    }

    fn session_json(v: Value) -> Event {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn snapshot_reports_columns_widths_heights_floating_focus_and_scroll() {
        let mut e = with(4);
        add_to(&mut e, 9, true);
        cmd(&mut e, "focus_left"); // 3
        cmd(&mut e, "stack"); // 3 into 2's column
        cmd(&mut e, "cycle_height");
        let p = e.handle(Event::Snapshot);
        let s = p.session.expect("session");
        assert_eq!(s.active, 1);
        assert_eq!(s.desktops.len(), 1);
        let d = &s.desktops[0];
        assert_eq!((d.index, d.floating.clone(), d.focus), (1, vec![9], Some(3)));
        assert_eq!(d.columns.iter().map(|c| c.windows.clone()).collect::<Vec<_>>(), [vec![1], vec![2, 3], vec![4]]);
        assert_eq!(d.columns[0].width, SessionWidth::Frac(0.5));
        assert!(d.columns[1].heights.is_some() && d.columns[0].heights.is_none());
        assert_eq!(d.scroll, e.st.scroll);
        assert!(e.handle(Event::Query).session.is_none(), "only snapshot answers with a session");
    }

    #[test]
    fn restore_session_rebuilds_order_widths_stacks_and_focus() {
        let mut e = with(4); // fresh: 1 2 3 4, all half width
        let p = e.handle(session_json(json!({
            "type": "restore_session", "active": 1,
            "desktops": [{"index": 1, "focus": 3, "scroll": 0.0, "columns": [
                {"windows": [4], "width": {"kind": "frac", "value": 0.333}},
                {"windows": [2, 1], "width": {"kind": "frac", "value": 0.667}, "heights": [0.25, 0.75]},
                {"windows": [3], "width": {"kind": "px", "value": 700.0}}
            ]}]
        })));
        assert!(p.error.is_none(), "{:?}", p.error);
        assert_eq!(ids(&e), [vec![4], vec![2, 1], vec![3]]);
        assert_eq!(e.st.columns[0].width, Width::Frac(0.333));
        assert_eq!(e.st.columns[1].heights, Some(vec![0.25, 0.75]));
        assert_eq!(e.st.columns[2].width, Width::Px(700.0));
        assert_eq!((e.focused(), p.focus), (Some(3), Some(3)));
        assert!(p.jump);
        assert_eq!(e.undo_len(), 0, "restoring is not an undoable edit");
        assert_eq!(p.map.columns.iter().map(|c| c.windows[0].id).collect::<Vec<_>>(), [4, 2, 3]);
        assert!(frame(&p, 1).h > frame(&p, 2).h);
    }

    #[test]
    fn restore_session_appends_unmatched_windows_and_ignores_unknown_ids() {
        let mut e = with(4);
        e.handle(session_json(json!({
            "type": "restore_session", "active": 1,
            "desktops": [{"index": 1, "focus": 99, "columns": [
                {"windows": [3, 77], "width": {"kind": "frac", "value": 0.5}, "heights": [0.5, 0.5]},
                {"windows": [1], "width": {"kind": "frac", "value": 0.5}}
            ]}]
        })));
        // 3 and 1 first (77 is not a window), then the unnamed 2 and 4 in their old order
        assert_eq!(ids(&e), [vec![3], vec![1], vec![2], vec![4]]);
        assert!(e.st.columns[0].heights.is_none(), "heights of a stack that lost a window are dropped");
        assert_eq!(e.focused(), Some(4), "an unknown saved focus keeps the live one");
    }

    #[test]
    fn restore_session_spreads_windows_over_desktops_and_switches_to_the_active_one() {
        let mut e = with(5);
        let p = e.handle(session_json(json!({
            "type": "restore_session", "active": 2,
            "desktops": [
                {"index": 1, "focus": 1, "columns": [{"windows": [1, 2], "width": {"kind": "frac", "value": 0.5}}]},
                {"index": 2, "focus": 4, "scroll": 0.0, "columns": [{"windows": [3], "width": {"kind": "frac", "value": 0.333}},
                                                    {"windows": [4], "width": {"kind": "frac", "value": 0.5}}], "floating": [5]}
            ]
        })));
        assert_eq!(e.desktop(), 2);
        assert_eq!(p.map.desktop, 2);
        assert_eq!(e.desktop_windows()[0], vec![1, 2]);
        assert_eq!(e.desktop_windows()[1], vec![3, 4, 5]);
        assert_eq!(e.focused(), Some(4));
        assert!(p.floating_parked.is_empty());
        assert!(p.frames.iter().filter(|f| f.id == 1 || f.id == 2).all(|f| !f.on_screen), "desktop 1 is parked");
        cmd_arg(&mut e, "switch_desktop", json!(1));
        assert_eq!(e.focused(), Some(1));
        assert_eq!(ids(&e), [vec![1, 2]]);
    }

    #[test]
    fn restore_session_keeps_live_floating_windows_floating_and_survives_garbage() {
        let mut e = with(2);
        add_to(&mut e, 7, true);
        let p = e.handle(session_json(json!({
            "type": "restore_session", "active": 42,
            "desktops": [{"index": 1, "focus": 7, "scroll": 1e9, "columns": [
                {"windows": [7, 1], "width": {"kind": "frac", "value": -3.0}, "heights": [0.9, 0.9]},
                {"windows": [2], "width": {"kind": "fixed", "value": 0.0}}]},
                {"index": 0, "columns": []}, {"index": 99, "columns": []}]
        })));
        assert!(p.error.is_none());
        assert_eq!(ids(&e), [vec![1], vec![2]]);
        assert_eq!(e.st.columns[0].width, Width::Frac(0.5), "bad width falls back to the default");
        assert!(e.st.columns[0].heights.is_none());
        assert!(e.st.floating.contains(&7) && e.focused() == Some(7));
        assert_eq!(e.desktop(), 1, "an invalid active desktop keeps the current one");
        assert!(e.st.scroll <= 976.0 + 1.0, "scroll is clamped into the content");
    }

    #[test]
    fn restore_session_is_idempotent_with_a_snapshot_of_itself() {
        let mut e = with(4);
        cmd(&mut e, "stack");
        cmd(&mut e, "cycle_width");
        cmd(&mut e, "move_to_desktop"); // arg missing: error, nothing moves
        cmd_arg(&mut e, "move_to_desktop", json!(3));
        let snap = e.handle(Event::Snapshot).session.unwrap();
        let before = e.st.clone();
        let p = e.handle(Event::RestoreSession { active: snap.active, desktops: snap.desktops.clone(), pin: snap.pin.clone() });
        assert!(p.error.is_none());
        assert_eq!(e.st.columns, before.columns);
        assert_eq!(e.handle(Event::Snapshot).session.unwrap().desktops, snap.desktops);
    }

    #[test]
    fn restore_and_snapshot_json_shapes() {
        let mut e = with(2);
        let p = e.handle_json(r#"{"type":"snapshot"}"#);
        assert!(p.error.is_none());
        let text = serde_json::to_string(&p.session).unwrap();
        assert!(text.contains(r#""kind":"frac""#), "{text}");
        let p = e.handle_json(r#"{"type":"restore_session","desktops":[]}"#);
        assert!(p.error.is_none(), "an empty session changes nothing");
        assert_eq!(ids(&e), [vec![1], vec![2]]);
        let p = e.handle_json(r#"{"type":"restore_session"}"#);
        assert!(p.error.is_some(), "desktops are required");
    }

    // ---- tabbed columns ----
    fn tabbed3() -> Engine {
        let mut e = stack_of(3);
        e.handle(Event::WindowFocused { id: 1 });
        cmd(&mut e, "toggle_tabs");
        e
    }
    fn mv_to(e: &mut Engine, id: u32, column: u32, position: &str) -> Plan {
        cmd_arg(e, "move_window_to", json!({"id": id, "column": column, "position": position}))
    }

    #[test]
    fn tab_group_toast_names_same_app_windows_by_title() {
        let mut e = eng();
        for (id, title) in [(1, "Inbox"), (2, "Drafts")] {
            e.handle(Event::WindowAdded { id, pid: 7, app: "Mail".into(), title: title.into(), frame: R, floating: false, width_hint: None, take_focus: true });
        }
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd(&mut e, "toggle_tabs");
        assert_eq!(p.toast.as_deref(), Some("Tab group: Inbox + Drafts"));
    }

    #[test]
    fn stack_of_apps_too_tall_to_share_becomes_tabs_instead_of_looping() {
        // WhatsApp refuses to go below 600, Buzz below 650; together they need more than the screen's usable height.
        let mut e = stack_of(2);
        let usable = { let d = e.display.unwrap(); layout::stack_px(layout::avail_height(&e.cfg, &d), 2, &e.cfg) };
        assert!(600.0 + 650.0 > usable, "test setup: floors must not fit ({usable})");
        let refuse = |e: &mut Engine, id: u32, h: f64| e.handle(Event::WindowRefused { id, frame: Rect { x: 0.0, y: 0.0, w: 482.0, h } });
        let p = refuse(&mut e, 1, 600.0);
        assert!(!p.map.columns[0].tabbed);
        let p = refuse(&mut e, 2, 650.0);
        assert!(!p.map.columns[0].tabbed, "one reading is not a floor (could be stale mid-resize)");
        refuse(&mut e, 1, 600.0);
        let p = refuse(&mut e, 2, 650.0);
        assert!(p.map.columns[0].tabbed, "infeasible stack turns into tabs");
        assert!(p.toast.as_deref().is_some_and(|t| t.contains("shown as tabs")), "{:?}", p.toast);
        // further echoes change nothing: no loop
        let p = refuse(&mut e, 1, 600.0);
        assert!(p.changed.is_empty() || p.map.columns[0].tabbed);
    }

    #[test]
    fn stack_floors_that_fit_are_all_respected() {
        let mut e = stack_of(2);
        let usable = { let d = e.display.unwrap(); layout::stack_px(layout::avail_height(&e.cfg, &d), 2, &e.cfg) };
        let refuse = |e: &mut Engine, id: u32, h: f64| e.handle(Event::WindowRefused { id, frame: Rect { x: 0.0, y: 0.0, w: 482.0, h } });
        let a = (usable * 0.45).round();
        let b = (usable * 0.5).round();
        for _ in 0..2 {
            refuse(&mut e, 1, a);
            refuse(&mut e, 2, b);
        }
        let p = refuse(&mut e, 2, b);
        let (h1, h2) = (frame(&p, 1).h as f64, frame(&p, 2).h as f64);
        assert!(h1 + 1.5 >= a && h2 + 1.5 >= b, "both floors kept: {h1} >= {a}, {h2} >= {b}");
        assert!(!p.map.columns[0].tabbed);
    }

    #[test]
    fn toggle_tabs_puts_one_window_below_a_bar_and_parks_the_rest() {
        let mut e = stack_of(3);
        let p = cmd(&mut e, "toggle_tabs");
        assert_eq!(p.toast.as_deref(), Some("Tabs"));
        assert!(p.map.columns[0].tabbed && p.map.columns[0].active == Some(2), "stack_of leaves window 3 focused");
        let bar = &p.tab_bars[0];
        assert_eq!((bar.x, bar.y, bar.w, bar.h, bar.active), (12, 37, 482, 32, 3));
        assert!(bar.on_screen && bar.focused && bar.tabs.len() == 3 && bar.tabs[1].app == "App2");
        // the shown window sits below the bar and fills the rest of the column; the others share its size, parked
        let shown = frame(&p, 3);
        assert_eq!((shown.x, shown.y, shown.w, shown.on_screen), (12, 37 + 32 + 8, 482, true));
        assert_eq!(shown.y + shown.h, 25 + 800 - 12);
        for id in [1, 2] {
            let f = frame(&p, id);
            assert!(!f.on_screen && f.x == 999 && (f.y, f.w, f.h) == (shown.y, shown.w, shown.h), "{f:?}");
        }
        assert!(p.jump, "swapping tabs must not glide windows across the screen");
        // toggling back restores the stack split
        let p = cmd(&mut e, "toggle_tabs");
        assert_eq!(p.toast.as_deref(), Some("Shown as a stack"));
        assert!(p.tab_bars.is_empty() && !p.map.columns[0].tabbed);
        assert!([1, 2, 3].iter().all(|i| frame(&p, *i).on_screen));
    }

    #[test]
    fn ungroup_tabs_gives_every_window_its_own_column_and_undoes() {
        let mut e = tabbed3();
        let p = cmd(&mut e, "ungroup_tabs");
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]);
        assert!(p.tab_bars.is_empty() && p.toast.as_deref() == Some("Tabs split into columns"));
        let p = cmd(&mut e, "undo");
        assert_eq!(p.toast.as_deref(), Some("Undid: tabs"));
        assert!(p.map.columns[0].tabbed && ids(&e) == [vec![1, 2, 3]]);
        assert!(cmd(&mut with(2), "ungroup_tabs").tab_bars.is_empty());
    }

    #[test]
    fn toggle_tabs_on_a_lone_window_makes_a_tab_group_with_its_left_neighbour() {
        let mut e = with(3); // focus: window 3, last column
        let p = cmd(&mut e, "toggle_tabs");
        assert_eq!(ids(&e), [vec![1], vec![2, 3]]);
        assert!(e.st.columns[1].tabbed && e.st.columns[1].active == Some(3), "the focused window shows");
        assert_eq!(e.st.focus, Some(3));
        assert_eq!(p.toast.as_deref(), Some("Tab group: App2 + App3"));
        assert_eq!(p.tab_bars.len(), 1);
        // one undo step brings the three columns back
        assert_eq!(toast(cmd(&mut e, "undo")).as_deref(), Some("Undid: tabs"));
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]);
        assert!(e.st.columns.iter().all(|c| !c.tabbed));
        cmd(&mut e, "redo");
        assert_eq!(ids(&e), [vec![1], vec![2, 3]]);
    }

    #[test]
    fn toggle_tabs_on_the_first_lone_column_uses_the_right_neighbour() {
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 1 });
        let p = cmd(&mut e, "toggle_tabs");
        assert_eq!(ids(&e), [vec![1, 2], vec![3]], "the focused window goes first, the neighbour keeps its place after it");
        assert!(e.st.columns[0].tabbed && e.st.columns[0].active == Some(1));
        assert_eq!(p.toast.as_deref(), Some("Tab group: App1 + App2"));
        // on a tabbed column it goes back to a stack, on a stack it tabs, as before
        assert_eq!(toast(cmd(&mut e, "toggle_tabs")).as_deref(), Some("Shown as a stack"));
        assert!(!e.st.columns[0].tabbed);
    }

    #[test]
    fn tab_with_picks_the_side_and_joins_stacks_and_tab_groups() {
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd_arg(&mut e, "tab_with", json!("right"));
        assert_eq!(ids(&e), [vec![1], vec![2, 3]]);
        assert!(e.st.columns[1].tabbed && e.st.columns[1].active == Some(2) && p.toast.as_deref() == Some("Tab group: App2 + App3"));
        // joining an existing tab group adds the newest tab and shows it
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        cmd_arg(&mut e, "tab_with", json!({"direction": "left"}));
        assert_eq!(ids(&e), [vec![1, 2], vec![3]]);
        e.handle(Event::WindowFocused { id: 3 });
        let p = cmd_arg(&mut e, "tab_with", json!(-1));
        assert_eq!(ids(&e), [vec![1, 2, 3]]);
        assert!(e.st.columns[0].tabbed && e.st.columns[0].active == Some(3));
        assert_eq!(p.toast.as_deref(), Some("Tab group: App1 + App2 + App3"));
        // the whole thing was three separate undo steps, each exact
        cmd(&mut e, "undo");
        assert_eq!(ids(&e), [vec![1, 2], vec![3]]);
    }

    #[test]
    fn tab_with_errors_without_a_neighbour_and_for_bad_directions() {
        let mut e = with(2);
        e.handle(Event::WindowFocused { id: 1 });
        let before = e.st.clone();
        assert!(cmd_arg(&mut e, "tab_with", json!("left")).error.is_some());
        assert!(cmd_arg(&mut e, "tab_with", json!("up")).error.is_some());
        assert!(cmd(&mut e, "tab_with").error.is_some());
        assert_eq!(e.st, before);
        assert_eq!(e.undo_len(), 0);
    }

    #[test]
    fn move_window_to_tabs_makes_the_target_a_tab_group() {
        let mut e = with(3);
        let p = mv_to(&mut e, 1, 3, "tabs");
        assert!(p.error.is_none());
        assert_eq!(ids(&e), [vec![2], vec![3, 1]]);
        assert!(e.st.columns[1].tabbed && e.st.columns[1].active == Some(1) && e.st.focus == Some(1));
        assert_eq!(e.undo_len(), 1);
        // a stacked target becomes tabs too
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 3 });
        cmd(&mut e, "stack");
        mv_to(&mut e, 1, 2, "tabs");
        assert!(e.st.columns[0].tabbed && ids(&e) == [vec![2, 3, 1]]);
    }

    #[test]
    fn tabs_need_two_windows() {
        let mut e = with(1);
        let p = cmd(&mut e, "toggle_tabs");
        assert_eq!(p.toast.as_deref(), Some("Nothing to tab with"));
        assert!(p.tab_bars.is_empty() && e.undo_len() == 0);
    }

    #[test]
    fn cycling_tabs_with_next_prev_and_up_down_wraps_and_moves_the_shown_window() {
        let mut e = tabbed3();
        let shown = |p: &Plan| p.tab_bars[0].active;
        let undo = e.undo_len();
        let p = cmd(&mut e, "next_tab");
        assert_eq!((shown(&p), p.toast.as_deref(), p.focus), (2, Some("Tab 2 of 3 · App2"), Some(2)));
        assert!(frame(&p, 2).on_screen && !frame(&p, 1).on_screen && p.jump);
        assert_eq!(shown(&cmd(&mut e, "next_tab")), 3);
        assert_eq!(shown(&cmd(&mut e, "next_tab")), 1); // wraps
        assert_eq!(shown(&cmd(&mut e, "prev_tab")), 3);
        assert_eq!(shown(&cmd(&mut e, "focus_down")), 1);
        assert_eq!(shown(&cmd(&mut e, "focus_up")), 3);
        let p = cmd(&mut e, "focus_up");
        assert_eq!((shown(&p), p.toast.as_deref()), (2, Some("Tab 2 of 3 · App2")));
        assert_eq!(e.undo_len(), undo, "switching tabs is navigation, never an undo step");
    }

    #[test]
    fn entering_a_tabbed_column_lands_on_its_active_tab() {
        let mut e = with(4);
        e.handle(Event::WindowFocused { id: 3 });
        cmd(&mut e, "stack"); // [1][2,3][4]
        cmd(&mut e, "toggle_tabs");
        cmd(&mut e, "prev_tab");
        assert_eq!(e.focused(), Some(2));
        cmd(&mut e, "focus_right");
        assert_eq!(e.focused(), Some(4));
        cmd(&mut e, "focus_left");
        assert_eq!(e.focused(), Some(2));
        cmd(&mut e, "focus_left");
        cmd(&mut e, "focus_right");
        assert_eq!(e.focused(), Some(2), "the column remembers its tab while you are elsewhere");
    }

    #[test]
    fn clicking_or_alt_tabbing_to_a_parked_tab_shows_it() {
        let mut e = tabbed3();
        let p = e.handle(Event::WindowFocused { id: 3 });
        assert_eq!(p.tab_bars[0].active, 3);
        assert!(frame(&p, 3).on_screen && !frame(&p, 1).on_screen);
        let p = cmd_arg(&mut e, "focus_window", json!(2));
        assert_eq!(p.tab_bars[0].active, 2);
        assert_eq!(p.focus, Some(2));
    }

    #[test]
    fn tab_mode_undoes_and_redoes() {
        let mut e = stack_of(2);
        let n = e.undo_len();
        cmd(&mut e, "toggle_tabs");
        assert_eq!(e.undo_len(), n + 1);
        let p = cmd(&mut e, "undo");
        assert_eq!(p.toast.as_deref(), Some("Undid: tabs"));
        assert!(!p.map.columns[0].tabbed && p.tab_bars.is_empty());
        assert!(frame(&p, 1).on_screen && frame(&p, 2).on_screen);
        let p = cmd(&mut e, "redo");
        assert!(p.map.columns[0].tabbed && p.tab_bars.len() == 1);
    }

    #[test]
    fn a_column_that_drops_below_two_windows_stops_being_tabbed() {
        let mut e = stack_of(2);
        cmd(&mut e, "toggle_tabs");
        let p = e.handle(Event::WindowRemoved { id: 2 });
        assert!(!p.map.columns[0].tabbed && p.tab_bars.is_empty());
        assert!(frame(&p, 1).on_screen);
        // unstack out of a tabbed pair also ends the mode
        let mut e = stack_of(2);
        cmd(&mut e, "toggle_tabs");
        let p = cmd(&mut e, "unstack");
        assert!(p.map.columns.iter().all(|c| !c.tabbed) && p.tab_bars.is_empty());
    }

    #[test]
    fn closing_the_active_tab_activates_a_neighbour_and_closing_another_keeps_the_active_one() {
        let mut e = tabbed3();
        e.handle(Event::WindowFocused { id: 2 });
        let p = e.handle(Event::WindowRemoved { id: 1 }); // not active
        assert_eq!(p.tab_bars[0].active, 2);
        let p = e.handle(Event::WindowRemoved { id: 2 }); // active, leaving one window
        assert!(!p.map.columns[0].tabbed && e.focused() == Some(3));
        assert!(frame(&p, 3).on_screen);
    }

    #[test]
    fn a_new_window_opened_in_a_tabbed_column_becomes_the_active_tab() {
        let mut e = tabbed3();
        e.handle(Event::WindowFocused { id: 2 });
        let p = add_to(&mut e, 7, false);
        assert_eq!(ids(&e), [vec![1, 2, 7, 3]], "right after the active tab");
        assert_eq!((p.tab_bars[0].active, e.focused()), (7, Some(7)));
        assert!(frame(&p, 7).on_screen && !frame(&p, 2).on_screen && p.map.columns[0].tabbed);
        // outside a tabbed column a new window still gets its own column
        let mut e = with(2);
        add_to(&mut e, 3, false);
        assert_eq!(ids(&e), [vec![1], vec![2], vec![3]]);
    }

    #[test]
    fn tabbed_columns_ignore_height_commands_and_height_drags() {
        let mut e = tabbed3();
        let before = e.state().clone();
        cmd(&mut e, "cycle_height");
        cmd(&mut e, "equalize_heights");
        assert_eq!(e.state(), &before);
        e.handle(Event::WindowResized { id: 1, frame: Rect { x: 0.0, y: 0.0, w: 976.0, h: 300.0 } });
        assert!(e.state().columns[0].heights.is_none());
    }

    #[test]
    fn tabs_survive_a_session_round_trip_and_stale_data_is_harmless() {
        let mut e = tabbed3();
        e.handle(Event::WindowFocused { id: 3 });
        let snap = e.handle(Event::Snapshot).session.unwrap();
        let col = &snap.desktops[0].columns[0];
        assert!(col.tabbed && col.active == Some(2));
        let text = serde_json::to_string(&snap).unwrap();
        assert!(text.contains(r#""tabbed":true"#) && text.contains(r#""active":2"#), "{text}");
        let mut b = with(3);
        b.handle(Event::RestoreSession { active: snap.active, desktops: snap.desktops.clone(), pin: snap.pin.clone() });
        let p = cmd(&mut b, "gather");
        assert!(p.map.columns[0].tabbed && p.tab_bars[0].active == 3 && ids(&b) == [vec![1, 2, 3]]);
        // old files have no tab fields; a bad active index falls back to the first tab; a missing window drops the mode
        let old: SessionColumn = serde_json::from_str(r#"{"windows":[1,2],"width":{"kind":"frac","value":0.5}}"#).unwrap();
        assert!(!old.tabbed && old.active.is_none());
        let mut c = with(2);
        let desk = SessionDesk {
            index: 1,
            columns: vec![SessionColumn { windows: vec![1, 2], width: SessionWidth::Frac(0.5), heights: None, tabbed: true, active: Some(9) }],
            floating: vec![],
            focus: None,
            scroll: 0.0,
        };
        c.handle(Event::RestoreSession { active: 1, desktops: vec![desk.clone()], pin: None });
        assert!(c.state().columns[0].tabbed);
        let mut d = with(1);
        d.handle(Event::RestoreSession { active: 1, desktops: vec![desk], pin: None });
        assert!(!d.state().columns[0].tabbed);
    }

    #[test]
    fn stacking_into_a_tabbed_column_adds_a_tab() {
        let mut e = tabbed3();
        add_to(&mut e, 4, false); // joins the tabs
        assert_eq!(ids(&e), [vec![1, 4, 2, 3]]);
        cmd(&mut e, "unstack");
        assert_eq!(ids(&e), [vec![1, 2, 3], vec![4]]);
        let p = cmd(&mut e, "stack");
        assert!(p.map.columns[0].tabbed && p.tab_bars[0].active == 4);
    }

    // ---- width floors learned from refusals ----
    fn col_w(e: &Engine, c: usize) -> f64 {
        layout::width_px(e.st.columns[c].width, &e.cfg, e.avail())
    }

    #[test]
    fn stacked_refusal_sets_a_floor_and_a_stale_narrow_echo_cannot_undo_it() {
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "stack"); // [1,2][3]
        refuse(&mut e, 1, 795.0);
        assert_eq!(col_w(&e, 0), 795.0);
        let p = refuse(&mut e, 2, 890.0); // 2 will not shrink
        assert_eq!(col_w(&e, 0), 890.0);
        assert_eq!((frame(&p, 1).w, frame(&p, 2).w), (890, 890));
        let p = refuse(&mut e, 1, 795.0); // stale echo of the narrow member
        assert_eq!(col_w(&e, 0), 890.0);
        assert_eq!((frame(&p, 1).w, frame(&p, 2).w), (890, 890));
        assert_eq!(frame(&p, 3).x - (frame(&p, 1).x + frame(&p, 1).w), 12, "neighbour clears the wide column");
        cmd(&mut e, "unstack");
        assert!(e.min_w.is_empty(), "floor is forgotten when the stack dissolves");
        let w = col_w(&e, 0);
        assert_eq!(w, 890.0, "the width itself stays; only the floor is gone");
        e.handle(Event::WindowFocused { id: 1 });
        cmd(&mut e, "cycle_width");
        assert_ne!(col_w(&e, 0), 890.0);
    }

    #[test]
    fn tabbed_column_floor_is_the_max_over_the_tabs() {
        let mut e = tabbed3();
        refuse(&mut e, 2, 850.0);
        refuse(&mut e, 3, 900.0);
        refuse(&mut e, 1, 700.0);
        assert_eq!(col_w(&e, 0), 900.0);
        let p = cmd(&mut e, "cycle_width");
        assert!(col_w(&e, 0) >= 900.0);
        assert!(frame(&p, 1).w >= 900 || frame(&p, 2).w >= 900 || frame(&p, 3).w >= 900);
    }

    #[test]
    fn joining_a_column_applies_a_known_floor() {
        let mut e = with(3);
        refuse(&mut e, 3, 900.0); // alone: its own column grows to 900
        assert_eq!(col_w(&e, 2), 900.0);
        // move it into column 1 (width ~ default): the column widens
        let p = cmd_arg(&mut e, "move_window_to", json!({"id": 3, "column": 1, "position": "into"}));
        assert_eq!(ids(&e), [vec![1, 3], vec![2]]);
        assert_eq!(col_w(&e, 0), 900.0);
        assert_eq!((frame(&p, 1).w, frame(&p, 3).w), (900, 900));
        // joining by `stack` too
        let mut e = with(2);
        refuse(&mut e, 1, 900.0);
        e.handle(Event::WindowFocused { id: 2 });
        let p = cmd(&mut e, "stack");
        assert_eq!(col_w(&e, 0), 900.0);
        assert_eq!((frame(&p, 1).w, frame(&p, 2).w), (900, 900));
    }

    // ---- move_window_to ----
    #[test]
    fn move_window_to_before_and_after_make_a_column_next_to_the_target() {
        let mut e = with(4); // [1][2][3][4]
        let p = mv_to(&mut e, 4, 1, "before");
        assert_eq!(ids(&e), [vec![4], vec![1], vec![2], vec![3]]);
        assert_eq!((p.toast.as_deref(), p.focus), (Some("Moved"), Some(4)));
        mv_to(&mut e, 4, 3, "after"); // column 3 is [2]
        assert_eq!(ids(&e), [vec![1], vec![2], vec![4], vec![3]]);
        assert_eq!(e.undo_len(), 2);
        let p = cmd(&mut e, "undo");
        assert_eq!(p.toast.as_deref(), Some("Undid: move"));
        assert_eq!(ids(&e), [vec![4], vec![1], vec![2], vec![3]]);
    }

    #[test]
    fn move_window_to_into_stacks_at_a_row_and_resets_heights() {
        let mut e = with(3); // [1][2][3]
        let p = cmd_arg(&mut e, "move_window_to", json!({"id": 3, "column": 1, "position": "into"}));
        assert_eq!(ids(&e), [vec![1, 3], vec![2]]);
        assert_eq!(p.toast.as_deref(), Some("Stacked"));
        cmd_arg(&mut e, "move_window_to", json!({"id": 2, "column": 1, "position": "into", "row": 1}));
        assert_eq!(ids(&e), [vec![1, 2, 3]], "row counts the column's other windows");
        // reorder inside the stack: window 1 dropped into its own column below 3
        cmd_arg(&mut e, "move_window_to", json!({"id": 1, "column": 1, "position": "into", "row": 9}));
        assert_eq!(ids(&e), [vec![2, 3, 1]]);
        assert!(e.state().columns[0].heights.is_none());
    }

    #[test]
    fn move_window_to_a_tabbed_column_becomes_its_active_tab() {
        let mut e = tabbed3();
        add_to(&mut e, 5, false); // joins the tabs; take it out first
        cmd(&mut e, "unstack");
        let p = cmd_arg(&mut e, "move_window_to", json!({"id": 5, "column": 1, "position": "into", "row": 0}));
        assert_eq!(ids(&e), [vec![5, 1, 2, 3]]);
        assert!(p.map.columns[0].tabbed && p.tab_bars[0].active == 5);
    }

    #[test]
    fn move_window_to_pulls_out_of_a_stack_keeps_width_and_handles_edges() {
        let mut e = with(3);
        cmd(&mut e, "cycle_width"); // focused 3 -> 0.667
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "stack"); // [1,2][3]
        let w3 = e.state().columns[1].width;
        mv_to(&mut e, 3, 1, "before");
        assert_eq!(ids(&e), [vec![3], vec![1, 2]]);
        assert_eq!(e.state().columns[0].width, w3);
        // popping a window out of a stack to the side of its own column
        mv_to(&mut e, 2, 2, "after");
        assert_eq!(ids(&e), [vec![3], vec![1], vec![2]]);
        // lone window on its own column: nothing to do, nothing recorded
        let depth = e.undo_len();
        let p = mv_to(&mut e, 2, 3, "before");
        assert_eq!(ids(&e), [vec![3], vec![1], vec![2]]);
        assert!(p.error.is_none() && e.undo_len() == depth);
        // unknown window: ignored; bad column or position: an error, no change
        assert!(mv_to(&mut e, 99, 1, "after").error.is_none());
        assert!(mv_to(&mut e, 1, 9, "after").error.is_some());
        assert!(mv_to(&mut e, 1, 1, "sideways").error.is_some());
        assert!(cmd_arg(&mut e, "move_window_to", json!(3)).error.is_some());
        assert_eq!(ids(&e), [vec![3], vec![1], vec![2]]);
    }

    #[test]
    fn move_window_to_defaults_to_the_focused_window_and_scrolls_it_into_view() {
        let mut e = with(5);
        e.handle(Event::WindowFocused { id: 2 });
        cmd_arg(&mut e, "move_window_to", json!({"column": 5, "position": "after"}));
        assert_eq!(ids(&e), [vec![1], vec![3], vec![4], vec![5], vec![2]]);
        assert_eq!(e.focused(), Some(2));
        let p = cmd(&mut e, "gather");
        assert!(frame(&p, 2).on_screen);
    }

    // ---- native tab groups: a replaced window keeps everything its predecessor had ----
    fn replace(e: &mut Engine, old: u32, new: u32) -> Plan {
        e.handle(Event::WindowReplaced { old, new, pid: 1, app: "Tabs".into(), title: format!("Tab {new}") })
    }
    fn known(e: &Engine) -> Vec<u32> {
        e.window_infos().iter().map(|w| w.0).collect()
    }

    #[test]
    fn replacing_a_window_keeps_its_column_width_and_frame_and_never_glides() {
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "cycle_width"); // 0.667
        let before = e.handle(Event::Query);
        let old = frame(&before, 2).clone();
        let p = replace(&mut e, 2, 20);
        assert_eq!(ids(&e), [vec![1], vec![20], vec![3]]);
        let f = frame(&p, 20);
        assert_eq!((f.x, f.y, f.w, f.h, f.on_screen, f.lx), (old.x, old.y, old.w, old.h, old.on_screen, old.lx));
        assert!(p.frames.iter().all(|f| f.id != 2));
        assert_eq!(p.changed, vec![20], "only the new window is written");
        assert!(p.jump && !p.show_map && p.error.is_none());
        assert_eq!(p.focus, None, "the OS already focused the new tab; nothing to ask for");
        assert_eq!(e.focused(), Some(20));
        assert_eq!(p.map.columns[1].width_frac, before.map.columns[1].width_frac);
        assert_eq!((p.map.columns[1].windows[0].id, p.map.columns[1].windows[0].title.as_str()), (20, "Tab 20"));
        assert_eq!(known(&e), [1, 3, 20]);
        assert!(p.map.desktops[0].windows.contains(&20) && !p.map.desktops[0].windows.contains(&2));
        // and the layout is the same one the old window would have produced: nothing else moved
        assert_eq!(cmd(&mut e, "gather").frames.iter().map(|f| (f.x, f.w)).collect::<Vec<_>>(), before.frames.iter().map(|f| (f.x, f.w)).collect::<Vec<_>>());
    }

    #[test]
    fn replacing_an_unfocused_window_leaves_the_focus_alone() {
        let mut e = with(3); // focus 3
        let p = replace(&mut e, 1, 10);
        assert_eq!((ids(&e), e.focused()), (vec![vec![10], vec![2], vec![3]], Some(3)));
        assert!(p.jump && p.focus.is_none() && p.changed == vec![10]);
        assert_eq!(p.map.focused_index, Some(2));
    }

    #[test]
    fn replacing_a_stacked_window_keeps_its_row_and_height_share() {
        let mut e = stack_of(3); // [1,2,3], focus 3
        cmd(&mut e, "cycle_height");
        let before = e.handle(Event::Query);
        assert!(frame(&before, 3).h != frame(&before, 1).h, "test setup: uneven shares");
        let p = replace(&mut e, 2, 20); // the middle row, not focused
        assert_eq!(ids(&e), [vec![1, 20, 3]]);
        let (a, b) = (frame(&before, 2), frame(&p, 20));
        assert_eq!((b.x, b.y, b.w, b.h), (a.x, a.y, a.w, a.h));
        assert_eq!(p.changed, vec![20]);
        assert_eq!(e.focused(), Some(3));
        let p = replace(&mut e, 3, 30); // the focused row
        assert_eq!((ids(&e), e.focused()), (vec![vec![1, 20, 30]], Some(30)));
        assert_eq!(frame(&p, 30).h, frame(&before, 3).h);
    }

    #[test]
    fn replacing_a_member_of_a_ribbon_tab_group_keeps_the_group_and_its_active_tab() {
        let mut e = tabbed3(); // focus and active tab: 1
        let p = replace(&mut e, 1, 10);
        assert_eq!(ids(&e), [vec![10, 2, 3]]);
        assert!(p.map.columns[0].tabbed && p.map.columns[0].active == Some(0));
        assert_eq!((p.tab_bars[0].active, e.focused()), (10, Some(10)));
        assert_eq!(p.tab_bars[0].tabs.iter().map(|t| (t.id, t.title.as_str())).collect::<Vec<_>>(), [(10, "Tab 10"), (2, "T2"), (3, "T3")]);
        assert!(frame(&p, 10).on_screen && !frame(&p, 2).on_screen && !frame(&p, 3).on_screen);
        assert!(p.jump);
        // a parked tab changes: the active one stays, the new one is parked like the old one was
        let (parked, shown) = (frame(&p, 3).clone(), frame(&p, 10).clone());
        let p = replace(&mut e, 3, 30);
        assert_eq!(ids(&e), [vec![10, 2, 30]]);
        assert_eq!((p.tab_bars[0].active, e.focused()), (10, Some(10)));
        let f = frame(&p, 30);
        assert_eq!((f.x, f.y, f.w, f.h, f.on_screen), (parked.x, parked.y, parked.w, parked.h, false));
        assert_eq!(frame(&p, 10), &shown);
        assert_eq!(p.changed, vec![30]);
    }

    #[test]
    fn replacing_a_floating_window_keeps_it_floating_on_its_desktop() {
        let mut e = with(2);
        add_to(&mut e, 9, true);
        let p = replace(&mut e, 9, 90);
        assert_eq!((ids(&e), e.st.floating.iter().copied().collect::<Vec<_>>()), (vec![vec![1], vec![2]], vec![90]));
        assert_eq!(known(&e), [1, 2, 90]);
        assert!(p.error.is_none() && p.changed.is_empty(), "floating windows have no frame in the plan");
        // the float remembers its tile width and its desktop
        let mut e = with(2);
        add_to(&mut e, 9, false);
        cmd(&mut e, "cycle_width");
        cmd(&mut e, "toggle_float");
        assert!(e.st.float_widths.contains_key(&9));
        replace(&mut e, 9, 90);
        assert!(e.st.float_widths.contains_key(&90) && !e.st.float_widths.contains_key(&9));
        cmd(&mut e, "toggle_float");
        assert_eq!(ids(&e).iter().flatten().filter(|i| **i == 90).count(), 1);
        assert_eq!(e.st.columns.iter().find(|c| c.windows == [90]).map(|c| c.width), Some(Width::Frac(0.667)), "re-tiling restores the width");
        // on another desktop it stays parked
        let mut e = with(1);
        add_to(&mut e, 9, true);
        e.handle(Event::WindowFocused { id: 9 });
        mv(&mut e, 2);
        let p = replace(&mut e, 9, 90);
        assert_eq!((on_desk(&e, 2), p.floating_parked), (vec![90], vec![90]));
    }

    #[test]
    fn replacing_unknown_windows_is_a_silent_noop() {
        let mut e = with(2);
        let before = e.state().clone();
        let p = replace(&mut e, 77, 78);
        assert!(p.error.is_none() && p.changed.is_empty() && !p.jump && !p.show_map && p.focus.is_none());
        assert_eq!((e.state(), known(&e)), (&before, vec![1, 2]), "an unknown old window does not add the new one");
        // a minimized window is not replaced either: it comes back under its own id
        minimize(&mut e, 2);
        replace(&mut e, 2, 20);
        assert_eq!(known(&e), [1]);
        assert_eq!(e.handle(Event::Query).shelf.iter().map(|s| s.id).collect::<Vec<_>>(), [2]);
        // replacing a window with itself only refreshes the metadata
        let p = replace(&mut e, 1, 1);
        assert!(!p.jump && p.changed.is_empty());
        assert_eq!(p.map.columns[0].windows[0].title, "Tab 1");
    }

    #[test]
    fn a_new_window_the_core_already_has_gives_up_its_slot_for_the_old_ones() {
        // The add arrived before the replace: right of the focused column, focused.
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "cycle_width");
        let want = frame(&e.handle(Event::Query), 2).clone();
        add_to(&mut e, 9, false);
        assert_eq!(ids(&e), [vec![1], vec![2], vec![9], vec![3]]);
        let p = replace(&mut e, 2, 9);
        assert_eq!(ids(&e), [vec![1], vec![9], vec![3]]);
        let f = frame(&p, 9);
        assert_eq!((f.x, f.w, f.h), (want.x, want.w, want.h));
        assert!(p.changed.contains(&9) && p.frames.iter().all(|f| f.id != 2));
        assert_eq!((e.focused(), known(&e)), (Some(9), vec![1, 3, 9]));
        // The old window was not focused: whoever had the focus before the add gets it back.
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 1 });
        add_to(&mut e, 9, false);
        replace(&mut e, 3, 9);
        assert_eq!((ids(&e), e.focused()), (vec![vec![1], vec![2], vec![9]], Some(1)));
        // ...also when the add went to the end of the ribbon.
        let mut e = Engine::new(Config { new_window: NewWindow::End, ..Config::default() });
        e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
        (1..=3).for_each(|i| {
            add_to(&mut e, i, false);
        });
        e.handle(Event::WindowFocused { id: 1 });
        add_to(&mut e, 9, false);
        replace(&mut e, 3, 9);
        assert_eq!((ids(&e), e.focused()), (vec![vec![1], vec![2], vec![9]], Some(1)));
        // Opened as a tab of a Ribbon tab group (it became the newest tab): it replaces the tab it came from.
        let mut e = tabbed3();
        e.handle(Event::WindowFocused { id: 2 });
        add_to(&mut e, 7, false);
        assert_eq!(ids(&e), [vec![1, 2, 7, 3]]);
        let p = replace(&mut e, 2, 7);
        assert_eq!((ids(&e), e.focused(), p.tab_bars[0].active), (vec![vec![1, 7, 3]], Some(7), 7));
    }

    #[test]
    fn an_add_first_replace_restores_the_tab_and_the_tiled_anchor_the_add_disturbed() {
        // The add joined a Ribbon tab group as its active tab; the tab it replaces was an inactive one: the shown tab stays shown.
        let mut e = tabbed3(); // [1,2,3], focus and active tab 1
        add_to(&mut e, 9, true);
        cmd_arg(&mut e, "focus_window", json!(9));
        add_to(&mut e, 7, false);
        assert_eq!(ids(&e), [vec![1, 7, 2, 3]]);
        let p = replace(&mut e, 3, 7);
        assert_eq!(ids(&e), [vec![1, 2, 7]]);
        assert_eq!((p.tab_bars[0].active, e.focused()), (1, Some(9)));
        // A floating window has the focus and the add went to the end: the tiled anchor goes back to what it was, so closing the
        // float focuses the same window as it would had the add never happened.
        let setup = || {
            let mut e = Engine::new(Config { new_window: NewWindow::End, ..Config::default() });
            e.handle(Event::Display { id: 1, frame: Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 } });
            (1..=3).for_each(|i| {
                add_to(&mut e, i, false);
            });
            e.handle(Event::WindowFocused { id: 1 });
            add_to(&mut e, 9, true);
            cmd_arg(&mut e, "focus_window", json!(9));
            e
        };
        let mut plain = setup();
        replace(&mut plain, 2, 20);
        let mut first = setup();
        add_to(&mut first, 20, false);
        replace(&mut first, 2, 20);
        assert_eq!((first.last_tiled, first.focused()), (plain.last_tiled, plain.focused()));
        for e in [&mut plain, &mut first] {
            e.handle(Event::WindowRemoved { id: 9 });
        }
        assert_eq!((first.focused(), ids(&first)), (plain.focused(), ids(&plain)));
        assert_eq!(first.focused(), Some(1));
    }

    #[test]
    fn an_add_first_replace_gives_back_the_shown_tab_the_anchor_and_the_viewport() {
        // The shown tab was not the first one and a floating window has the focus when the add joins the group.
        let mut plain = tabbed3();
        cmd_arg(&mut plain, "focus_window", json!(2));
        add_to(&mut plain, 9, true);
        cmd_arg(&mut plain, "focus_window", json!(9));
        let mut first = tabbed3();
        cmd_arg(&mut first, "focus_window", json!(2));
        add_to(&mut first, 9, true);
        cmd_arg(&mut first, "focus_window", json!(9));
        add_to(&mut first, 7, true);
        let p = replace(&mut first, 3, 7);
        let q = replace(&mut plain, 3, 7);
        assert_eq!((ids(&first), p.tab_bars[0].active), (ids(&plain), q.tab_bars[0].active));
        assert_eq!(p.tab_bars[0].active, 2);
        // The default mode, a float focused after toggle_float: the tiled anchor is what it was, so the next window opens in the same place.
        let setup = || {
            let mut e = with(4);
            cmd_arg(&mut e, "focus_window", json!(3));
            cmd(&mut e, "toggle_float");
            e
        };
        let mut plain = setup();
        replace(&mut plain, 4, 99);
        let mut first = setup();
        add_to(&mut first, 99, false);
        replace(&mut first, 4, 99);
        assert_eq!((first.last_tiled, first.focused()), (plain.last_tiled, plain.focused()));
        for e in [&mut plain, &mut first] {
            add_to(e, 50, false);
        }
        assert_eq!(ids(&first), ids(&plain));
        // The viewport stays where the user left it, even when it was scrolled away from the focus and the add was in the background.
        let setup = || {
            let mut e = with(6);
            cmd_arg(&mut e, "focus_window", json!(1));
            e.st.scroll = 1482.0;
            e
        };
        let mut plain = setup();
        replace(&mut plain, 5, 7);
        let mut first = setup();
        add_to(&mut first, 7, false);
        replace(&mut first, 5, 7);
        assert_eq!((first.st.scroll, ids(&first)), (plain.st.scroll, ids(&plain)));
        // Anything in between makes the record stale: the replace then settles for what the focus history says.
        let mut e = tabbed3();
        cmd_arg(&mut e, "focus_window", json!(2));
        add_to(&mut e, 7, false);
        add_to(&mut e, 8, false);
        replace(&mut e, 3, 7);
        assert_eq!(ids(&e), [vec![1, 2, 8, 7]]);
    }

    #[test]
    fn undo_and_redo_follow_a_replaced_window() {
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "cycle_width");
        let wide = frame(&e.handle(Event::Query), 2).w;
        replace(&mut e, 2, 20);
        let p = cmd(&mut e, "undo");
        assert_eq!(p.toast.as_deref(), Some("Undid: width"));
        assert_eq!((ids(&e), e.focused()), (vec![vec![1], vec![20], vec![3]], Some(20)));
        assert!(frame(&p, 20).w < wide && p.frames.iter().all(|f| f.id != 2));
        let p = cmd(&mut e, "redo");
        assert_eq!((frame(&p, 20).w, ids(&e)), (wide, vec![vec![1], vec![20], vec![3]]));
        // a stack made before the replace comes apart for the new window too
        let mut e = with(2);
        cmd(&mut e, "focus_left");
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "stack");
        replace(&mut e, 2, 20);
        cmd(&mut e, "undo");
        assert_eq!(ids(&e), [vec![1], vec![20]]);
        // snapshots taken after the new window was added hold both ids: no window may appear twice
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        add_to(&mut e, 9, false);
        cmd(&mut e, "cycle_width"); // its snapshot has [1][2][9][3]
        replace(&mut e, 2, 9);
        let p = cmd(&mut e, "undo");
        assert_eq!(ids(&e), [vec![1], vec![9], vec![3]]);
        assert_eq!(p.frames.iter().filter(|f| f.id == 9).count(), 1);
    }

    #[test]
    fn replacing_a_window_that_was_sent_to_another_desktop_fixes_the_cross_desktop_undo_entry_too() {
        let mut e = with(2);
        mv(&mut e, 2); // window 2 (focused) goes to desktop 2; the entry holds both desktops
        let p = replace(&mut e, 2, 20);
        assert_eq!((on_desk(&e, 1), on_desk(&e, 2)), (vec![1], vec![20]));
        let f = frame(&p, 20);
        assert!(!f.on_screen && p.changed == vec![20] && p.frames.iter().all(|f| f.id != 2));
        cmd(&mut e, "undo"); // 20 returns to desktop 1
        assert_eq!((on_desk(&e, 1), on_desk(&e, 2)), (vec![1, 20], vec![]));
        assert_eq!(ids(&e), [vec![1], vec![20]]);
    }

    #[test]
    fn focus_history_floating_anchor_and_size_floors_follow_the_replaced_window() {
        let mut e = with(3); // history 3, 2, 1
        replace(&mut e, 2, 20);
        assert_eq!(e.history, [3, 20, 1]);
        assert_eq!(cmd(&mut e, "focus_previous").focus, Some(20));
        add_to(&mut e, 9, true);
        cmd_arg(&mut e, "focus_window", json!(9));
        replace(&mut e, 20, 21);
        assert_eq!((e.last_tiled, e.history.contains(&20)), (Some(21), false));
        // a stack's learned minimum width stays with the column
        let mut e = with(3);
        e.handle(Event::WindowFocused { id: 2 });
        cmd(&mut e, "stack"); // [1,2][3]
        refuse(&mut e, 1, 795.0);
        replace(&mut e, 1, 10);
        assert_eq!(col_w(&e, 0), 795.0);
        assert_eq!(e.min_w.keys().copied().collect::<Vec<_>>(), [10]);
        cmd(&mut e, "unstack");
        assert!(e.min_w.is_empty(), "the floor is forgotten when the stack dissolves, under the new id too");
    }

    #[test]
    fn a_replace_is_part_of_the_json_protocol_and_the_session() {
        let mut e = with(2);
        let p = e.handle_json(r#"{"type":"window_replaced","old":1,"new":5,"pid":3,"app":"Notes","title":"Groceries"}"#);
        assert!(p.error.is_none() && p.jump && p.changed == vec![5]);
        assert_eq!((p.map.columns[0].windows[0].app.as_str(), p.map.columns[0].windows[0].title.as_str()), ("Notes", "Groceries"));
        assert_eq!(e.window_infos()[0], (2, 1, "App2".into(), "T2".into(), false));
        assert!(e.window_infos().contains(&(5, 3, "Notes".into(), "Groceries".into(), false)));
        let snap = e.handle(Event::Snapshot).session.unwrap();
        assert_eq!(snap.desktops[0].columns.iter().flat_map(|c| c.windows.clone()).collect::<Vec<_>>(), [5, 2]);
        assert!(e.handle_json(r#"{"type":"window_replaced","old":1}"#).error.is_some(), "missing fields are a bad event");
    }
}
