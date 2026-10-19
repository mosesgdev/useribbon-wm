import SwiftUI
import AppKit

/// One-time note when several displays share one macOS Space: windows may jump between them. The how-to (and the log-out
/// step) lives in Settings → Input; the card only points there.
struct SpacesCardView: View {
    var onShow: () -> Void = {}
    var onLater: () -> Void = {}
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "display.2").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Windows may jump between displays").font(Theme.display(15))
                    Text("Turn on “Displays have separate Spaces” in Desktop & Dock, then log out once.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Show me", action: onShow).buttonStyle(RibbonButtonStyle(.primary))
                Button("Later", action: onLater).buttonStyle(RibbonButtonStyle(.secondary))
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
final class SpacesCard {
    private var panel: NSPanel?
    var isShowing: Bool { panel != nil }

    func show(onShow: @escaping () -> Void) {
        guard panel == nil else { return }
        let view = SpacesCardView(onShow: { [weak self] in self?.close(); onShow() }, onLater: { [weak self] in self?.close() })
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
