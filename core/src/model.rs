//! Serde types for the JSON contract (Config / Event / Plan).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize, Serialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ScrollMode {
    KeepVisible,
    Center,
    /// Like `keep_visible`, but a column that is not fully in view is centered instead of edge-aligned.
    CenterOnOverflow,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NewWindow {
    RightOfFocused,
    End,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Config {
    pub gap: f64,
    pub outer_gap: f64,
    pub default_width: f64,
    pub width_presets: Vec<f64>,
    pub new_window: NewWindow,
    pub scroll: ScrollMode,
    /// Per-app width fractions keyed by app name, used when the host sends no hint.
    pub app_widths: BTreeMap<String, f64>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            gap: 12.0,
            outer_gap: 12.0,
            default_width: 0.5,
            width_presets: Config::PRESETS_RICH.to_vec(),
            new_window: NewWindow::RightOfFocused,
            scroll: ScrollMode::KeepVisible,
            app_widths: BTreeMap::new(),
        }
    }
}

impl Config {
    /// Default width cycle: 25 / 33 / 50 / 66 / 75 / 100 %.
    pub const PRESETS_RICH: [f64; 6] = [0.25, 0.333, 0.5, 0.667, 0.75, 1.0];
    /// The older, calmer cycle (Settings: "Simple"): ⅓ ½ ⅔ full.
    pub const PRESETS_SIMPLE: [f64; 4] = [0.333, 0.5, 0.667, 1.0];

    /// Clamp nonsense values so layout math can never divide by zero or go negative.
    pub fn sanitized(mut self) -> Config {
        let d = Config::default();
        self.gap = self.gap.clamp(0.0, 200.0);
        self.outer_gap = self.outer_gap.clamp(0.0, 200.0);
        self.width_presets.retain(|p| *p > 0.0 && *p <= 1.0);
        self.width_presets.sort_by(f64::total_cmp);
        self.width_presets.dedup();
        if self.width_presets.is_empty() {
            self.width_presets = d.width_presets;
        }
        if !(self.default_width > 0.0 && self.default_width <= 1.0) {
            self.default_width = d.default_width;
        }
        self
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Display {
        id: u32,
        frame: Rect,
    },
    WindowAdded {
        id: u32,
        pid: i32,
        app: String,
        title: String,
        frame: Rect,
        #[serde(default)]
        floating: bool,
        /// Preferred width fraction for the new column (host knows the app); snapped to a preset.
        #[serde(default)]
        width_hint: Option<f64>,
        /// The window takes focus and the viewport reveals it. The host says no for a window an app in the background opened:
        /// it joins the ribbon where it would go, but focus and viewport stay put.
        #[serde(default = "yes")]
        take_focus: bool,
    },
    WindowRemoved {
        id: u32,
    },
    /// A native macOS tab group showed another of its windows (tab click, new tab, closed tab): `new` takes `old`'s place
    /// in the layout (column slot and width, stack or tab-group membership, desktop, float mode, focus, undo history) and
    /// is written without gliding. Title and app come from `new`. An unknown `old` is ignored; a `new` the core already
    /// has (its `window_added` arrived first) gives up its own slot for `old`'s.
    WindowReplaced {
        old: u32,
        new: u32,
        pid: i32,
        app: String,
        title: String,
    },
    /// The window was minimized (yellow button): it leaves the ribbon but the core shelves its desktop, width and
    /// floating mode. A later `window_added` with the same id puts it back where it was.
    WindowMinimized {
        id: u32,
    },
    /// ⌘H: every managed window of the app is shelved like a minimize (neighbours close the gap).
    AppHidden {
        pid: i32,
    },
    /// The app was unhidden: its hidden windows return in their old relative order, next to focus (each on its own
    /// desktop); `front` (the app's front window, if known) gets the focus.
    AppShown {
        pid: i32,
        #[serde(default)]
        front: Option<u32>,
        /// As for `window_added`: the host says no when the app was unhidden while the user is in another app. The windows
        /// return to their places, but focus, desktop and viewport stay put.
        #[serde(default = "yes")]
        take_focus: bool,
    },
    WindowFocused {
        id: u32,
    },
    WindowTitle {
        id: u32,
        title: String,
    },
    WindowResized {
        id: u32,
        frame: Rect,
    },
    /// The app refused our size and settled on `frame`: a hard constraint, adopted exactly (no min clamp, no preset snap,
    /// no undo step, no write-back).
    WindowRefused {
        id: u32,
        frame: Rect,
    },
    Command {
        name: String,
        #[serde(default)]
        arg: Option<Value>,
    },
    /// Continuous trackpad scroll: move the viewport offset by `dx` px (positive = towards later columns).
    ScrollBy {
        dx: f64,
    },
    /// Put the tiled window `id` at logical x `x` (a frame's `lx`) by moving the viewport there: absolute and unresisted, within
    /// the rubber band's reach. The host lines the core up with tiles that are still gliding when a new swipe catches them.
    ScrollTo {
        id: u32,
        x: f64,
    },
    /// Fingers lifted: snap to a column. `velocity` is the viewport's px/s at release (same sign as `dx`).
    ScrollEnd {
        #[serde(default)]
        velocity: Option<f64>,
    },
    Query,
    /// Ask for the layout of every desktop (`Plan.session`), for the host to persist.
    Snapshot,
    /// Rebuild the layout from a saved session. The host has already re-added the windows (and mapped saved window
    /// identities to the current ids); ids the core does not know are ignored, windows the session does not name stay
    /// where they are (appended after the restored columns of their desktop).
    RestoreSession {
        #[serde(default)]
        active: usize,
        desktops: Vec<SessionDesk>,
        /// The display's pinned column, if it had one.
        #[serde(default)]
        pin: Option<SessionPin>,
    },
}

/// Which display edge a pinned column sits against.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PinSide {
    #[default]
    Left,
    Right,
}

impl PinSide {
    pub fn other(self) -> PinSide {
        match self {
            PinSide::Left => PinSide::Right,
            PinSide::Right => PinSide::Left,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            PinSide::Left => "left",
            PinSide::Right => "right",
        }
    }
}

/// Widths a pinned column can have, as fractions of the display's usable width (⅕, ¼, ⅓).
pub const PIN_FRACTIONS: [f64; 3] = [0.2, 0.25, 1.0 / 3.0];

/// The pinned column as saved (one per display).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct SessionPin {
    /// Top to bottom (tab order for a tab group).
    pub windows: Vec<u32>,
    #[serde(default)]
    pub heights: Option<Vec<f64>>,
    #[serde(default)]
    pub tabbed: bool,
    #[serde(default)]
    pub active: Option<usize>,
    #[serde(default)]
    pub side: PinSide,
    /// One of `PIN_FRACTIONS`.
    pub fraction: f64,
    /// Desktop it belongs to, 1-based (the active one when it shows on every desktop).
    pub desktop: usize,
    #[serde(default = "yes")]
    pub every_desktop: bool,
    /// Column index it was pinned from (0-based), so unpinning puts it back.
    #[serde(default)]
    pub home: usize,
    /// Desktop of that column index, 1-based (0: the same as `desktop`).
    #[serde(default)]
    pub home_desktop: usize,
    /// The width the column had in the ribbon (it gets it back when unpinned).
    #[serde(default)]
    pub width: Option<SessionWidth>,
    /// The display was too narrow: the column is in the ribbon and pins itself again on a wide display.
    #[serde(default)]
    pub suspended: bool,
    /// Px a suspended pin needs before it pins again.
    #[serde(default)]
    pub need: f64,
}

fn yes() -> bool {
    true
}

/// A column width as saved: a fraction of the usable width, dragged px, or an app's fixed px.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum SessionWidth {
    Frac(f64),
    Px(f64),
    Fixed(f64),
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct SessionColumn {
    /// Top to bottom.
    pub windows: Vec<u32>,
    pub width: SessionWidth,
    /// Height shares of the stack (same length as `windows`); absent = equal.
    #[serde(default)]
    pub heights: Option<Vec<f64>>,
    /// The column shows one window at a time with a tab bar (only meaningful with 2+ windows).
    #[serde(default)]
    pub tabbed: bool,
    /// Index into `windows` of the active tab.
    #[serde(default)]
    pub active: Option<usize>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct SessionDesk {
    /// 1-based desktop.
    pub index: usize,
    #[serde(default)]
    pub columns: Vec<SessionColumn>,
    #[serde(default)]
    pub floating: Vec<u32>,
    #[serde(default)]
    pub focus: Option<u32>,
    /// Viewport offset in px.
    #[serde(default)]
    pub scroll: f64,
}

/// The layout of every non-empty desktop (what `restore_session` takes back).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct Session {
    /// Active desktop, 1-based.
    pub active: usize,
    pub desktops: Vec<SessionDesk>,
    #[serde(default)]
    pub pin: Option<SessionPin>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct PlanFrame {
    pub id: u32,
    pub x: i64,
    pub y: i64,
    pub w: i64,
    pub h: i64,
    pub on_screen: bool,
    /// Where the window sits in the ribbon, ignoring parking (equals `x` while on screen; `i64::MIN` for windows of inactive desktops). The swipe overlay slides snapshots by it.
    #[serde(default)]
    pub lx: i64,
    /// A window of the pinned column: its frame does not move with the ribbon, and the host keeps it above the ribbon.
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct MapWindow {
    pub id: u32,
    pub app: String,
    pub title: String,
}

/// A minimized or hidden window the core remembers, for the command bar.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct ShelfItem {
    pub id: u32,
    pub app: String,
    pub title: String,
    /// Desktop it belongs to, 1-based.
    pub desk: usize,
    /// true = hidden with its app (⌘H), false = minimized.
    pub hidden: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct MapColumn {
    pub windows: Vec<MapWindow>,
    pub width_frac: f64,
    pub focused: bool,
    pub visible: bool,
    /// Tabbed column: one window shows at a time.
    #[serde(default)]
    pub tabbed: bool,
    /// Index of the active tab in `windows` (tabbed columns only).
    #[serde(default)]
    pub active: Option<usize>,
}

/// One tab of a tab bar.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct TabItem {
    pub id: u32,
    pub app: String,
    pub title: String,
}

/// The tab bar of a tabbed column of the ACTIVE desktop: a strip above the active window, as wide as the column.
/// Same rounding as the column's frames. The host draws it (and hides it when `on_screen` is false).
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct TabBar {
    /// Index into `map.columns`.
    pub column: usize,
    pub x: i64,
    pub y: i64,
    pub w: i64,
    pub h: i64,
    pub on_screen: bool,
    /// Window id of the active tab.
    pub active: u32,
    /// The focused window is in this column.
    pub focused: bool,
    pub tabs: Vec<TabItem>,
    /// The tab bar of the pinned column (`column` is then one past the map's columns, so it never names one of them).
    #[serde(default)]
    pub pinned: bool,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct Viewport {
    pub start: f64,
    pub end: f64,
}

/// One virtual desktop in the map: 1-based index, windows on it (tiled + floating), whether it is the active one.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct DesktopInfo {
    pub index: usize,
    pub count: usize,
    pub active: bool,
    /// Window ids on this desktop: tiled in column order, then floating (ascending).
    pub windows: Vec<u32>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct Map {
    /// Columns of the ACTIVE desktop.
    pub columns: Vec<MapColumn>,
    pub viewport: Viewport,
    pub focused_index: Option<usize>,
    /// Active desktop, 1-based.
    pub desktop: usize,
    /// All desktops (always `DESKTOPS` entries), in order.
    pub desktops: Vec<DesktopInfo>,
    /// The pinned column when it shows on the active desktop (never part of `columns`, which stay ribbon-only).
    #[serde(default)]
    pub pin: Option<MapPin>,
    /// The edge `pin` would put the focused ribbon column against (null when focus is not in the ribbon).
    #[serde(default)]
    pub near_edge: Option<PinSide>,
}

/// The pinned column in the map.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct MapPin {
    pub side: PinSide,
    /// Its windows; `width_frac` is the fraction of the whole display's usable width (⅕, ¼ or ⅓, or the next one up
    /// when an app in it needs more), `visible` is always true.
    pub column: MapColumn,
    pub every_desktop: bool,
}

/// Number of virtual desktops.
pub const DESKTOPS: usize = 9;

impl Default for Map {
    fn default() -> Self {
        Map {
            columns: vec![],
            viewport: Viewport { start: 0.0, end: 1.0 },
            focused_index: None,
            desktop: 1,
            desktops: (1..=DESKTOPS).map(|index| DesktopInfo { index, count: 0, active: index == 1, windows: vec![] }).collect(),
            pin: None,
            near_edge: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct Plan {
    pub frames: Vec<PlanFrame>,
    pub focus: Option<u32>,
    pub changed: Vec<u32>,
    pub map: Map,
    pub show_map: bool,
    pub error: Option<String>,
    /// Short feedback the HUD shows instead of its usual caption.
    pub toast: Option<String>,
    /// Apply the frames without animation (a desktop switch moves many windows at once).
    pub jump: bool,
    /// Floating windows of inactive desktops: the host parks them off-screen (they have no frame in the plan)
    /// and puts them back where they were when they leave this list.
    pub floating_parked: Vec<u32>,
    /// Minimized and hidden windows, most recently shelved first.
    pub shelf: Vec<ShelfItem>,
    /// Only set in answer to `snapshot`.
    #[serde(default)]
    pub session: Option<Session>,
    /// Tab bars of the tabbed columns on the active desktop.
    #[serde(default)]
    pub tab_bars: Vec<TabBar>,
}

impl Plan {
    /// A plan carrying only an error: no frames, nothing to apply.
    pub fn error(msg: impl Into<String>) -> Plan {
        Plan {
            frames: vec![],
            focus: None,
            changed: vec![],
            map: Map::default(),
            show_map: false,
            error: Some(msg.into()),
            toast: None,
            jump: false,
            floating_parked: vec![],
            shelf: vec![],
            session: None,
            tab_bars: vec![],
        }
    }
}
