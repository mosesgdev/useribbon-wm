//! The open-source edition's pin: the functions the engine calls wherever a pin matters, answering "there is no pin". (The Plus
//! edition builds its own module of the same name and signatures in this one's place.) The engine never
//! creates a pin here (`pin` stays `None`, so does `pin_memo`), a pin command that still arrives is a silent no-op, and a
//! session saved by a Plus build with a pinned column restores with that column back in the ribbon.
//!
//! A child module of `engine`, like its twin, so it sees the engine's private fields.

use std::borrow::Cow;

use super::*;

#[cfg(test)]
mod pin_tests;

/// The pin commands of the Plus edition: here they do nothing, whatever the arg (an old saved shortcut, a stale event).
const PIN_COMMANDS: [&str; 5] = ["pin", "pin_other_side", "unpin", "pin_width", "pin_every_desktop"];

impl Engine {
    // ---- queries: nothing is pinned, so the ribbon plans in the whole display and scrolls as it always does ----

    pub(super) fn pin_inset(&self, _d: usize) -> Option<(f64, bool)> {
        None
    }
    pub(super) fn pin_rests(&self, _spans: &[(f64, f64)], _avail: f64) -> Option<Vec<f64>> {
        None
    }
    pub(super) fn pin_reveal(&self, _spans: &[(f64, f64)], _avail: f64, _idx: Option<usize>, _mode: ScrollMode) -> Option<f64> {
        None
    }
    pub(super) fn pin_scroll_end(&mut self, _spans: &[(f64, f64)], _avail: f64) -> bool {
        false
    }
    pub(super) fn near_edge(&self) -> Option<PinSide> {
        None
    }
    pub(super) fn step_onto_pin(&mut self, _toward: Option<&str>) {}

    // ---- events: there is no pin to keep up with them ----

    pub(super) fn fit_pin(&mut self) {}
    pub(super) fn unpin_inner(&mut self, _focus: bool) {}
    pub(super) fn resize_pinned(&mut self, _id: u32, _frame: Rect) -> bool {
        false
    }
    pub(super) fn refuse_pinned(&mut self, _id: u32, _frame: Rect) -> Option<Option<String>> {
        None
    }
    /// A shelved window comes back into a ribbon: no window is ever shelved from a pin here.
    pub(super) fn unshelve_into_pin(&mut self, _id: u32, s: &Shelved, _take_focus: bool) -> bool {
        debug_assert!(!s.pinned);
        false
    }
    pub(super) fn detach_from_pin(&mut self, _id: u32) -> Option<Option<u32>> {
        None
    }
    pub(super) fn pin_follow(&mut self) {}
    pub(super) fn send_pin_to_desktop(&mut self, _to: usize, _out: &mut Outcome) -> bool {
        false
    }

    // ---- commands ----

    /// A pin command does nothing, and says nothing: no toast, no error, no map, no focus request. That includes dropping a
    /// window "into the pin", which only the Plus edition's pin tile can send.
    pub(super) fn pin_command(&mut self, name: &str, arg: Option<&Value>, out: &mut Outcome) -> bool {
        let into_pin = name == "move_window_to" && arg.and_then(|a| a.get("pin")).and_then(Value::as_bool) == Some(true);
        let pin_command = into_pin || PIN_COMMANDS.contains(&name);
        if pin_command {
            out.show_map = false;
        }
        pin_command
    }
    pub(super) fn pin_inner_command(&mut self, _name: &str, _arg: Option<&Value>) -> Option<(Result<(), String>, Option<String>)> {
        None
    }
    pub(super) fn pin_toast(&self, _name: &str, _before: &State) -> Option<Option<String>> {
        None
    }
    pub(super) fn move_to_pin(&mut self, _o: &serde_json::Map<String, Value>) -> Option<Result<(), String>> {
        None
    }
    pub(super) fn leave_pin(&mut self, _id: u32) {}

    // ---- undo, session ----

    /// Undo entries carry no pin here: nothing to install, nothing to put back.
    pub(super) fn swap_pin(&mut self, _pin: Option<Option<Pin>>, _in_entry: &mut BTreeSet<u32>) -> (Option<Option<Pin>>, Vec<(u32, Width)>) {
        (None, vec![])
    }
    pub(super) fn snapshot_pin(&self) -> Option<SessionPin> {
        None
    }

    /// A session a Plus build saved with a pinned column: that column goes back into the ribbon of the desktop it was pinned
    /// from, at its saved slot and with its ribbon width, as a column like any other (tabs, stack shares, windows the core does
    /// not know are handled as for every saved column). A suspended pin is in a ribbon already: its saved column is among the
    /// desktops', and the pin itself is dropped.
    pub(super) fn take_saved_pin<'a>(
        &mut self,
        saved: &'a [SessionDesk],
        sp: Option<&SessionPin>,
        target: usize,
        _live_floating: &BTreeSet<u32>,
        _used: &mut BTreeSet<u32>,
    ) -> (Cow<'a, [SessionDesk]>, Option<Pin>) {
        let Some(sp) = sp.filter(|sp| !sp.suspended) else { return (Cow::Borrowed(saved), None) };
        let desk = sp.desktop.checked_sub(1).filter(|d| *d < DESKTOPS).unwrap_or(target);
        let home = sp.home_desktop.checked_sub(1).filter(|d| *d < DESKTOPS).unwrap_or(desk);
        let column = SessionColumn {
            windows: sp.windows.clone(),
            width: sp.width.unwrap_or(SessionWidth::Frac(self.cfg.default_width)),
            heights: sp.heights.clone(),
            tabbed: sp.tabbed,
            active: sp.active,
        };
        let mut desktops = saved.to_vec();
        let at = match desktops.iter().position(|d| d.index == home + 1) {
            Some(i) => i,
            None => {
                desktops.push(SessionDesk { index: home + 1, columns: vec![], floating: vec![], focus: None, scroll: 0.0 });
                desktops.len() - 1
            }
        };
        let columns = &mut desktops[at].columns;
        columns.insert(sp.home.min(columns.len()), column);
        (Cow::Owned(desktops), None)
    }
    pub(super) fn install_restored_pin(&mut self, _pin: Option<Pin>) {}

    // ---- plan ----

    pub(super) fn plan_pin(&self, _d: Rect, _edge: i64, _frames: &mut Vec<PlanFrame>, _tab_bars: &mut Vec<TabBar>) {}
    pub(super) fn map_pin(&self) -> Option<MapPin> {
        None
    }
}
