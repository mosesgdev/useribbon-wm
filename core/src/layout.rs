//! Pure layout: columns + display + scroll -> frames. No state, no side effects.

use crate::model::{Config, PlanFrame, Rect, ScrollMode};

/// Column width: a fraction of the usable width, or absolute px after a user drag.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Width {
    Frac(f64),
    Px(f64),
    /// Exact px an app insisted on (it refuses to resize): never raised to the drag minimum, never snapped.
    Fixed(f64),
}

#[derive(Clone, Debug, PartialEq)]
pub struct Column {
    pub windows: Vec<u32>,
    pub width: Width,
    /// Width to return to when `toggle_full` is pressed again.
    pub restore: Option<Width>,
    /// Height share of each window (sums to 1, same length as `windows`); `None` = equal split.
    pub heights: Option<Vec<f64>>,
    /// Tabbed: one window fills the column below a tab bar, the others are parked (only with 2+ windows).
    pub tabbed: bool,
    /// The active tab (a window of this column); only kept while tabbed.
    pub active: Option<u32>,
    /// The column's own width while an app holds it wider (`width` is then the `Fixed` px the app would not go below): it
    /// takes it back once the band it plans in gives it at least that much. Only counts while `width` is `Fixed`.
    pub held: Option<Width>,
}

impl Column {
    pub fn new(id: u32, width: Width) -> Column {
        Column { windows: vec![id], width, restore: None, heights: None, tabbed: false, active: None, held: None }
    }

    /// The width the column chose: the one an app holds it wider than, else `width`.
    pub fn own_width(&self) -> Width {
        match (self.width, self.held) {
            (Width::Fixed(_), Some(own)) => own,
            (w, _) => w,
        }
    }

    /// An app will not go below `px`: hold the column there, keeping its own width to go back to (none when an app already
    /// set its width).
    pub fn hold_at(&mut self, px: f64) {
        if !matches!(self.width, Width::Fixed(_)) {
            self.held = Some(self.width);
        }
        self.width = Width::Fixed(px);
    }

    /// Back to its own width when, `avail` px wide, that is at least the px an app holds it at.
    pub fn release(&mut self, cfg: &Config, avail: f64) {
        if let (Width::Fixed(px), Some(own)) = (self.width, self.held) {
            if width_px(own, cfg, avail) + 0.5 >= px {
                (self.width, self.held) = (own, None);
            }
        }
    }

    /// Whether the column really shows tabs (a single window never does).
    pub fn is_tabbed(&self) -> bool {
        self.tabbed && self.windows.len() >= 2
    }

    /// Row of the active tab (the first window when unset or stale).
    pub fn active_index(&self) -> usize {
        self.active.and_then(|a| self.windows.iter().position(|w| *w == a)).unwrap_or(0)
    }

    /// Back to the equal split (whenever the set of stacked windows changes).
    pub fn reset_heights(&mut self) {
        self.heights = None;
    }

    /// Per-window height shares; equal when unset (or stale, which only a bug could cause).
    pub fn shares(&self) -> Vec<f64> {
        let n = self.windows.len();
        match &self.heights {
            Some(h) if h.len() == n => h.clone(),
            _ => vec![1.0 / n.max(1) as f64; n],
        }
    }
}

/// A stacked window never gets shorter than this (or 15% of the usable height, whichever is larger).
pub const MIN_WIN_PX: f64 = 120.0;

/// Height of a tabbed column's tab bar, and the gap below it. The window's frame starts below bar + gap so nothing is
/// covered; the gap leaves room for the focus ring (drawn just outside the window) so ring and tabs never collide.
pub const TAB_BAR_H: f64 = 32.0;
pub const TAB_GAP: f64 = 8.0;

/// Where a tabbed column's tab bar sits (same rounding as its frames).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BarRect {
    pub column: usize,
    pub x: i64,
    pub y: i64,
    pub w: i64,
    pub h: i64,
    pub on_screen: bool,
}

/// Usable height between the outer gaps.
pub fn avail_height(cfg: &Config, display: &Rect) -> f64 {
    (display.h - 2.0 * outer_gap(cfg, display)).max(1.0)
}

/// Height available to the windows of an `n`-stack (the usable height minus the gaps between them).
pub fn stack_px(avail_h: f64, n: usize, cfg: &Config) -> f64 {
    (avail_h - (n.max(1) as f64 - 1.0) * cfg.gap).max(1.0)
}

/// Smallest share a window of an `n`-stack may have.
pub fn min_share(avail_h: f64, n: usize, cfg: &Config) -> f64 {
    let usable = stack_px(avail_h, n, cfg);
    MIN_WIN_PX.max(0.15 * avail_h).min(usable / n.max(1) as f64) / usable
}

/// Dragged columns never get narrower than this (or 20% of the usable width, whichever is larger).
pub const MIN_COL_PX: f64 = 360.0;
/// Space that must stay usable on the smaller display axis, whatever `outer_gap` says.
const MIN_USABLE_PX: f64 = 100.0;

/// The configured outer gap, clamped so at least `MIN_USABLE_PX` remains on the smaller display axis.
pub fn outer_gap(cfg: &Config, display: &Rect) -> f64 {
    let room = ((display.w.min(display.h) - MIN_USABLE_PX) / 2.0).max(0.0);
    cfg.outer_gap.min(room)
}

/// Usable width between the outer gaps.
pub fn avail_width(cfg: &Config, display: &Rect) -> f64 {
    (display.w - 2.0 * outer_gap(cfg, display)).max(1.0)
}

/// Usable width of a band of the display (the ribbon's share next to a pinned column), between the display's outer gaps.
pub fn band_width(cfg: &Config, display: &Rect, band: &Rect) -> f64 {
    (band.w - 2.0 * outer_gap(cfg, display)).max(1.0)
}

/// The part of `display` a ribbon plans in when `inset` px (a pinned column plus one gap) are taken from one side.
pub fn band(display: &Rect, inset: f64, from_left: bool) -> Rect {
    let inset = inset.clamp(0.0, (display.w - 1.0).max(0.0));
    Rect { x: if from_left { display.x + inset } else { display.x }, w: display.w - inset, ..*display }
}

/// Narrowest and widest a dragged (px) column can be.
fn px_range(avail: f64) -> (f64, f64) {
    (MIN_COL_PX.max(0.2 * avail).min(avail), avail)
}

/// A dragged width may be stored before the display is known; it is clamped when laid out.
fn clamp_px(p: f64, avail: f64) -> f64 {
    let (lo, hi) = px_range(avail);
    p.clamp(lo, hi)
}

/// Pixel width of a column. Two 0.5 columns plus one gap fill `avail` exactly.
pub fn width_px(w: Width, cfg: &Config, avail: f64) -> f64 {
    match w {
        Width::Frac(f) => f * (avail + cfg.gap) - cfg.gap,
        Width::Px(p) => clamp_px(p, avail),
        Width::Fixed(p) => p.clamp(1.0, avail.max(1.0)),
    }
    .max(1.0)
}

/// Inverse of `width_px` for the map / preset cycling.
pub fn width_frac(w: Width, cfg: &Config, avail: f64) -> f64 {
    match w {
        Width::Frac(f) => f,
        Width::Px(p) => (clamp_px(p, avail) + cfg.gap) / (avail + cfg.gap),
        Width::Fixed(p) => (p.clamp(1.0, avail.max(1.0)) + cfg.gap) / (avail + cfg.gap),
    }
}

/// `(left, width)` of every column in content coordinates (first column at 0).
pub fn spans(cols: &[Column], cfg: &Config, avail: f64) -> Vec<(f64, f64)> {
    let mut left = 0.0;
    cols.iter()
        .map(|c| {
            let w = width_px(c.width, cfg, avail);
            let s = (left, w);
            left += w + cfg.gap;
            s
        })
        .collect()
}

pub fn content_width(spans: &[(f64, f64)]) -> f64 {
    spans.last().map_or(0.0, |(l, w)| l + w)
}

/// Scroll offset that centers column `idx`.
pub fn center_scroll(spans: &[(f64, f64)], idx: usize, avail: f64) -> f64 {
    let (l, w) = spans[idx];
    l + w / 2.0 - avail / 2.0
}

/// Scroll offset after focusing column `idx` according to the scroll mode.
/// `keep_visible` moves minimally (aligning the left edge if the column is wider than the
/// screen) and keeps the offset within the content; `center` always centers; `center_on_overflow` moves like
/// `keep_visible` while the column is fully in view and centers it (within the content) once it is not.
pub fn reveal(spans: &[(f64, f64)], idx: usize, scroll: f64, mode: ScrollMode, avail: f64) -> f64 {
    match mode {
        ScrollMode::Center => center_scroll(spans, idx, avail),
        ScrollMode::CenterOnOverflow => {
            let (l, w) = spans[idx];
            let max = (content_width(spans) - avail).max(0.0);
            if w > avail || l < scroll || l + w > scroll + avail {
                center_scroll(spans, idx, avail).clamp(0.0, max)
            } else {
                scroll.clamp(0.0, max)
            }
        }
        ScrollMode::KeepVisible => {
            let (l, w) = spans[idx];
            let s = if w > avail || l < scroll {
                l
            } else if l + w > scroll + avail {
                l + w - avail
            } else {
                scroll
            };
            s.clamp(0.0, (content_width(spans) - avail).max(0.0))
        }
    }
}

/// Scroll offsets a ribbon with no pin rests at: every column start the content allows (a column's left edge at the band's
/// start) and the offset that brings the content's end flush with the band's end, so a release never leaves a window cut at
/// either display edge and never leaves blank room after the last column. A start within `merge_px` of the end gives way to
/// it (two stops barely apart are one page), except the first, so the ribbon can always return to its beginning.
pub fn free_rest_offsets(spans: &[(f64, f64)], avail: f64, merge_px: f64) -> Vec<f64> {
    let end = (content_width(spans) - avail).max(0.0);
    let mut rest: Vec<f64> = spans.iter().map(|(l, _)| *l).filter(|l| *l <= end + 1e-6).collect();
    rest.retain(|l| *l <= 1e-6 || end - *l >= merge_px);
    if rest.last().is_none_or(|l| end - *l > 1e-6) {
        rest.push(end);
    }
    rest
}

/// Scroll offsets that centre each column: where a `center` ribbon rests (the first and last columns centre too, so the
/// ends reach past the content).
pub fn center_rest_offsets(spans: &[(f64, f64)], avail: f64) -> Vec<f64> {
    (0..spans.len()).map(|i| center_scroll(spans, i, avail)).collect()
}

/// Whether the span `[left, left + w)` shares more than half a pixel with the viewport `[0, avail)`. A rest beside a pin is a
/// whole pixel, up to half a pixel off the column edge it stands for: with no gap between columns, the column under the pin
/// can reach that far into view, and it is drawn under the pin all the same.
pub fn span_visible(left: f64, w: f64, scroll: f64, avail: f64) -> bool {
    left - scroll < avail - 0.5 && left + w - scroll > 0.5
}

/// Frames for every tiled window, column by column, top to bottom.
pub fn frames(cols: &[Column], cfg: &Config, display: &Rect, scroll: f64) -> Vec<PlanFrame> {
    frames_and_bars(cols, cfg, display, scroll).0
}

/// Frames plus the tab bars of tabbed columns. A tabbed column puts its active window below the bar at the full
/// column height; its other windows get the same size but are parked at the display's right edge (`on_screen` false),
/// exactly like windows of inactive desktops, so nothing depends on window raise order.
pub fn frames_and_bars(cols: &[Column], cfg: &Config, display: &Rect, scroll: f64) -> (Vec<PlanFrame>, Vec<BarRect>) {
    frames_and_bars_in(cols, cfg, display, display, scroll)
}

/// Like `frames_and_bars`, laid out in `band` (a part of `display`, same height): a column is on screen while it
/// overlaps the band, and off-screen windows park at the display's own edges (never inside it, under a pinned column).
pub fn frames_and_bars_in(cols: &[Column], cfg: &Config, display: &Rect, band: &Rect, scroll: f64) -> (Vec<PlanFrame>, Vec<BarRect>) {
    let avail = band_width(cfg, display, band);
    let outer = outer_gap(cfg, display);
    let top = display.y + outer;
    let avail_h = (display.h - 2.0 * outer).max(1.0);
    let (d_top, d_bottom) = (display.y, display.y + display.h);
    let (d_left, d_right) = (display.x.round(), (display.x + display.w).round());
    // What the band can show: the display, or up to the pinned column's edge on the pin's side (one gap inside the band).
    let b_left = if band.x > display.x { band.x + outer - cfg.gap } else { band.x }.round();
    let b_right = if band.x + band.w < display.x + display.w { band.x + band.w - outer + cfg.gap } else { band.x + band.w }.round();
    let mut out = vec![];
    let mut bars = vec![];
    // Columns sit on whole pixels in content space (both edges rounded there, so neighbours never overlap) and the band
    // moves by whole pixels: a column keeps its exact width while it scrolls. Rounding the edges on screen instead made a
    // fractional width flip between two sizes as the scroll moved, a resize the app had to lay out again on every step.
    let origin = (band.x + outer - scroll).round();
    for (ci, (col, (left, w))) in cols.iter().zip(spans(cols, cfg, avail)).enumerate() {
        let (l0, l1) = (left.round(), (left + w).round());
        let mut x = origin + l0;
        let lx = x as i64;
        let wr = (l1 - l0).max(1.0);
        let on_screen = x < b_right && x + wr > b_left && top < d_bottom && top + avail_h > d_top;
        if !on_screen {
            // Park just beyond the edge, keeping 1pt overlap so macOS keeps the window alive.
            x = if x + wr <= b_left { d_left - wr + 1.0 } else { d_right - 1.0 };
        }
        if col.is_tabbed() {
            let (win_top, bottom) = ((top + TAB_BAR_H + TAB_GAP).min(top + avail_h - 1.0), top + avail_h);
            let (ya, yb) = (win_top.round(), bottom.round());
            bars.push(BarRect { column: ci, x: x as i64, y: top.round() as i64, w: wr as i64, h: TAB_BAR_H as i64, on_screen });
            let act = col.active_index();
            for (i, id) in col.windows.iter().enumerate() {
                let shown = i == act;
                let px = if shown { x } else { d_right - 1.0 };
                out.push(PlanFrame { id: *id, lx, x: px as i64, y: ya as i64, w: wr as i64, h: (yb - ya).max(1.0) as i64, on_screen: on_screen && shown, pinned: false });
            }
            continue;
        }
        let n = col.windows.len();
        let usable = stack_px(avail_h, n, cfg);
        let shares = col.shares();
        let mut y0 = top;
        for (i, id) in col.windows.iter().enumerate() {
            let h = usable * shares[i];
            let (ya, yb) = (y0.round(), (y0 + h).round());
            y0 += h + cfg.gap;
            out.push(PlanFrame {
                id: *id,
                x: x as i64,
                y: ya as i64,
                w: wr as i64,
                h: (yb - ya).max(1.0) as i64,
                on_screen,
                lx,
                pinned: false,
            });
        }
    }
    (out, bars)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn disp() -> Rect {
        Rect { x: 0.0, y: 25.0, w: 1000.0, h: 800.0 }
    }
    fn cols(n: u32, f: f64) -> Vec<Column> {
        (1..=n).map(|i| Column::new(i, Width::Frac(f))).collect()
    }

    #[test]
    fn two_half_columns_fill_exactly() {
        let cfg = Config::default();
        let f = frames(&cols(2, 0.5), &cfg, &disp(), 0.0);
        assert_eq!((f[0].x, f[0].w), (12, 482));
        assert_eq!((f[1].x, f[1].w), (506, 482));
        assert_eq!(f[1].x + f[1].w, 1000 - 12);
        assert_eq!((f[0].y, f[0].h), (37, 776));
        assert!(f.iter().all(|f| f.on_screen));
    }

    #[test]
    fn rounding_sweep_no_overlap_and_exact_gaps() {
        let cfg = Config::default();
        for dw in (1000..=3840).step_by(7) {
            let d = Rect { x: 0.0, y: 25.0, w: dw as f64, h: 800.0 };
            for n in 2..=4 {
                for f in [0.25, 0.333, 0.5, 0.667] {
                    let f = frames(&cols(n, f), &cfg, &d, 0.0);
                    for pair in f.windows(2) {
                        if pair[0].on_screen && pair[1].on_screen {
                            assert_eq!(pair[1].x - (pair[0].x + pair[0].w), 12, "dw={dw} n={n}");
                        }
                    }
                }
            }
        }
    }

    #[test]
    fn scrolling_never_resizes_a_column() {
        // A fractional column width (two halves of an odd band) must not flip between two sizes as the band scrolls: that is
        // a resize per frame for the app. The gaps stay exact at every offset too.
        let cfg = Config::default();
        let d = Rect { x: 0.0, y: 25.0, w: 2883.0, h: 800.0 };
        let base = frames(&cols(4, 0.5), &cfg, &d, 0.0);
        for s in 0..400 {
            let f = frames(&cols(4, 0.5), &cfg, &d, s as f64 * 3.7);
            for (a, b) in base.iter().zip(&f) {
                assert_eq!(a.w, b.w, "scroll={} id={}", s as f64 * 3.7, a.id);
            }
            for pair in f.windows(2) {
                if pair[0].on_screen && pair[1].on_screen {
                    assert_eq!(pair[1].x - (pair[0].x + pair[0].w), 12, "scroll={}", s as f64 * 3.7);
                }
            }
        }
    }

    #[test]
    fn huge_outer_gap_is_clamped() {
        let cfg = Config { outer_gap: 200.0, ..Config::default() };
        let d = Rect { x: 0.0, y: 0.0, w: 1000.0, h: 100.0 };
        let f = frames(&cols(1, 1.0), &cfg, &d, 0.0);
        assert!(f[0].on_screen && f[0].h >= 100 - 1 && f[0].w >= 100, "{f:?}");
        assert_eq!(outer_gap(&cfg, &d), 0.0);
        assert_eq!(outer_gap(&cfg, &Rect { h: 400.0, ..d }), 150.0);
    }

    #[test]
    fn full_width_is_avail() {
        let cfg = Config::default();
        let f = frames(&cols(1, 1.0), &cfg, &disp(), 0.0);
        assert_eq!((f[0].x, f[0].w), (12, 976));
    }

    #[test]
    fn stacked_heights_split_with_gap() {
        let cfg = Config::default();
        let c = vec![Column { windows: vec![1, 2, 3], width: Width::Frac(0.5), restore: None, heights: None, tabbed: false, active: None, held: None }];
        let f = frames(&c, &cfg, &disp(), 0.0);
        // avail_h 776, 2 gaps -> 752 / 3 = 250.67
        assert_eq!(f[0].y, 37);
        assert_eq!(f[2].y + f[2].h, 25 + 800 - 12);
        assert!(f[1].y >= f[0].y + f[0].h + 11 && f[1].y <= f[0].y + f[0].h + 13);
        assert!(f.iter().all(|f| f.x == 12));
    }

    #[test]
    fn off_screen_right_and_left_placement() {
        let cfg = Config::default();
        let c = cols(4, 0.5); // x: 12, 506, 1000, 1494
        let f = frames(&c, &cfg, &disp(), 0.0);
        assert!(f[0].on_screen && f[1].on_screen);
        assert!(!f[2].on_screen && !f[3].on_screen);
        assert_eq!(f[2].x, 999); // display.right - 1
        assert_eq!(f[3].x, 999);
        // scrolled so columns 0 is far left: x = 12 - 1000 -> right edge < 0
        let f = frames(&c, &cfg, &disp(), 1000.0);
        assert!(!f[0].on_screen);
        assert_eq!(f[0].x, 0 - 482 + 1); // display.left - w + 1
        assert!(f[2].on_screen);
    }

    #[test]
    fn partially_visible_is_on_screen_with_natural_frame() {
        let cfg = Config::default();
        let f = frames(&cols(3, 0.5), &cfg, &disp(), 300.0);
        assert!(f[0].on_screen && f[0].x == -288);
    }

    #[test]
    fn parked_windows_keep_their_logical_position() {
        let cfg = Config::default();
        let f = frames(&cols(4, 0.5), &cfg, &disp(), 0.0);
        assert!(f.iter().filter(|f| f.on_screen).all(|f| f.lx == f.x));
        let off: Vec<_> = f.iter().filter(|f| !f.on_screen).collect();
        assert!(!off.is_empty() && off.iter().all(|f| f.lx >= 1000 && f.x == 999));
    }

    #[test]
    fn keep_visible_math() {
        let cfg = Config::default();
        let s = spans(&cols(4, 0.5), &cfg, 976.0); // lefts 0, 494, 988, 1482 w 482
        let k = ScrollMode::KeepVisible;
        assert_eq!(reveal(&s, 0, 0.0, k, 976.0), 0.0);
        assert_eq!(reveal(&s, 1, 0.0, k, 976.0), 0.0); // fully visible: stay
        assert_eq!(reveal(&s, 2, 0.0, k, 976.0), 988.0 + 482.0 - 976.0);
        assert_eq!(reveal(&s, 0, 494.0, k, 976.0), 0.0);
        assert_eq!(reveal(&s, 3, 0.0, k, 976.0), content_width(&s) - 976.0);
    }

    #[test]
    fn keep_visible_wide_column_aligns_left() {
        let cfg = Config::default();
        let c = vec![Column::new(1, Width::Frac(0.5)), Column::new(2, Width::Px(2000.0))];
        let s = spans(&c, &cfg, 976.0);
        assert_eq!(reveal(&s, 1, 0.0, ScrollMode::KeepVisible, 976.0), 494.0);
    }

    #[test]
    fn center_math() {
        let cfg = Config::default();
        let s = spans(&cols(4, 0.5), &cfg, 976.0);
        assert_eq!(reveal(&s, 2, 0.0, ScrollMode::Center, 976.0), 988.0 + 241.0 - 488.0);
        // first column centers too (negative offset), no clamping
        assert_eq!(reveal(&s, 0, 0.0, ScrollMode::Center, 976.0), 241.0 - 488.0);
    }

    #[test]
    fn px_width_and_frac_roundtrip() {
        let cfg = Config::default();
        let w = Width::Frac(0.667);
        let px = width_px(w, &cfg, 976.0);
        assert!((width_frac(Width::Px(px), &cfg, 976.0) - 0.667).abs() < 1e-9);
    }
}
