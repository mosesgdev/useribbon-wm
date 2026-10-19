import CoreGraphics
import Foundation

// Pure logic for "Other windows: Normal / Dim / Blur" and Focus mode. No AppKit state, so the self tests can pin every rule down.
// Rects are in AX space (global, top-left origin) unless a name says otherwise.

/// What happens to the windows you are not in. The Settings choice.
enum OtherWindows: String, CaseIterable, Identifiable {
    case normal, dim, blur
    var id: String { rawValue }
    var label: String { switch self { case .normal: "Normal"; case .dim: "Dim"; case .blur: "Blur" } }
    static let key = "otherWindows"

    /// The saved choice. Before this setting existed there was only the "Dim other windows" switch: an old `true` reads as Dim.
    static func resolve(stored: String?, legacyDim: Bool) -> OtherWindows {
        stored.flatMap(OtherWindows.init(rawValue:)) ?? (legacyDim ? .dim : .normal)
    }
}

/// Focus mode is a session choice on top of the Settings choice; it never persists (Ribbon starts calm, with it off).
/// - follow: Settings decides. - on: blur. - off: nothing, whatever Settings says (so the hotkey can always switch it off).
enum FocusSession: Equatable {
    case follow, on, off

    /// What the Focus mode hotkey / menu item / command does next. One press always flips between "something is
    /// hiding the other windows" and "nothing is", so it is never a silent no-op, even when Settings already says Blur.
    func toggled(setting: OtherWindows) -> FocusSession {
        switch self {
        case .on: setting == .blur ? .off : .follow
        case .off: .on
        case .follow: setting == .blur ? .off : .on
        }
    }

    /// The mode in force once the session has had its say over the Settings choice.
    func mode(setting: OtherWindows) -> OtherWindows {
        switch self { case .on: .blur; case .off: .normal; case .follow: setting }
    }
}

/// How the overlay looks, after the settings, focus mode and the accessibility switches have all had their say.
enum OverlayStyle: Equatable {
    case off
    /// Black layer of this opacity.
    case dim(CGFloat)
    /// Behind-window blur plus a light black tint of this opacity.
    case blur(tint: CGFloat)

    /// Reduce Transparency has no blur to give: the same job is done by a stronger dim.
    static let strongDim: CGFloat = 0.62
    static let blurTint: CGFloat = 0.12

    static func resolve(setting: OtherWindows, session: FocusSession, level: DimLevel, reduceTransparency: Bool) -> OverlayStyle {
        switch session.mode(setting: setting) {
        case .normal: return .off
        case .dim: return .dim(level.alpha)
        case .blur: return reduceTransparency ? .dim(strongDim) : .blur(tint: blurTint)
        }
    }

    var isOn: Bool { self != .off }
}

extension WidthPresets {
    /// The name of a width step in the shortcuts sheet and the command bar. Matches the core's toast ("Width 66 %").
    static func title(_ fraction: Double) -> String { "Width \(percent(fraction))" }
    /// A width as every width toast and row says it: whole percent, rounded down as the core does (⅔ is "66 %"), the % kept
    /// beside its number.
    static func percent(_ fraction: Double) -> String { "\(Int(fraction * 100 + 1e-6))\u{00A0}%" }
    /// The steps of the width list currently chosen in Settings.
    static func current(_ defaults: UserDefaults = .standard) -> [Double] { list(for: defaults.string(forKey: key)) }
}

/// Whether the focus ring and the dim/blur cutout may show. While a window is dragged by its title bar they would trail it
/// (the plan is not moving it), so both fade out when the drag starts and come back at the window's final frame once it landed.
struct RingVisibility: Equatable {
    enum Phase: Equatable { case idle, dragging, landed }
    private(set) var phase = Phase.idle
    mutating func dragStarted() { phase = .dragging }
    /// The button came up and the drop (or snap back) was applied.
    mutating func dragEnded() { if phase == .dragging { phase = .landed } }
    /// The ring is back at the final frame.
    mutating func settled() { if phase == .landed { phase = .idle } }
    mutating func reset() { phase = .idle }
    var visible: Bool { phase != .dragging }
}

/// One hole in the overlay: a rect and its corner radius.
struct OverlayHole: Equatable {
    var rect: CGRect
    var radius: CGFloat
}

extension DimGeometry {
    /// A tab bar sits in a strip above its window; the gap between the two is at most this much (the core lays them out flush).
    static let barSeam: CGFloat = 16

    /// The holes for the focused window and (when its column is tabbed) its tab bar, clipped to `area`, in the layer's own
    /// top-left coordinates. The bar's hole reaches down to the window so no blurred seam shows between them.
    static func holes(area: CGRect, focused: CGRect?, tabBar: CGRect?, windowRadius: CGFloat = 12) -> [OverlayHole] {
        var out: [OverlayHole] = []
        if let window = cutout(area: area, focused: focused) {
            out.append(OverlayHole(rect: window, radius: radius(of: window, windowRadius: windowRadius)))
        }
        if var bar = tabBar {
            let r = min(bar.height / 2, 14)
            if let focused, bar.maxY <= focused.minY + 0.5, focused.minY - bar.maxY <= barSeam, bar.maxX > focused.minX, bar.minX < focused.maxX {
                bar.size.height = focused.minY - bar.minY   // down to the window's top edge
            }
            if let h = cutout(area: area, focused: bar) {
                out.append(OverlayHole(rect: h, radius: min(r, h.height / 2)))
            }
        }
        return out
    }
}
