import SwiftUI
import AppKit

/// One-time offer after the first swipe or keyboard glide without Screen Recording: smooth motion is one permission away.
/// Two steps, both on the card: "Turn on" opens the right Privacy pane; once you are back, "Reopen Ribbon" applies it
/// (macOS only grants a running app the permission after a relaunch).
struct SmoothSwipeCardView: View {
    var onTurnOn: () -> Void = {}
    var onReopen: () -> Void = {}
    var onLater: () -> Void = {}
    @State private var asked = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.draw").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(asked ? "One more step" : "Want silky motion?").font(Theme.display(15))
                    Text(asked ? "Switch Ribbon on in the list, then reopen Ribbon to start using it."
                               : "Swiping and keyboard moves glide smoother with Screen Recording. Previews stay in memory and are never saved.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if asked {
                    Button("Reopen Ribbon", action: onReopen).buttonStyle(RibbonButtonStyle(.primary))
                } else {
                    Button("Turn on") { onTurnOn(); withAnimation(reduceMotion ? nil : Theme.panelSpring) { asked = true } }
                        .buttonStyle(RibbonButtonStyle(.primary))
                }
                Button("Not now", action: onLater).buttonStyle(RibbonButtonStyle(.secondary))
                Spacer()
            }.controlSize(.regular)
        }
        .padding(16).frame(width: 360, alignment: .leading)
        .readingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .environment(\.controlActiveState, .key)
        .padding(10)
        .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : -8)
        .animation(reduceMotion ? Theme.reduced : Theme.panelSpring, value: appeared)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class SmoothSwipeCard {
    static let shownKey = "smoothSwipeOffered"
    private var panel: NSPanel?
    var isShowing: Bool { panel != nil }

    /// Show once ever, only when the permission is missing.
    func offerIfNeeded() {
        let d = UserDefaults.standard
        guard panel == nil, !d.bool(forKey: Self.shownKey), !ScreenRecording.granted else { return }
        d.set(true, forKey: Self.shownKey)
        let view = SmoothSwipeCardView(onTurnOn: { ScreenRecording.turnOn() },
                                       onReopen: { [weak self] in self?.close(); ScreenRecording.reopen() },
                                       onLater: { [weak self] in self?.close() })
        let host = SheetHostingView(rootView: view)
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        let size = host.fittingSize
        let p = KeyPanel.make(size: size)
        p.hasShadow = false
        p.keyOnClick = true
        p.contentView = host
        if let f = Screens.primary?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.maxX - size.width - Theme.dockInset + 10, y: f.maxY - size.height - Theme.dockInset + 10)) }
        p.orderFrontRegardless()
        panel = p
    }

    func close() { panel?.orderOut(nil); panel?.close(); panel = nil }
}
