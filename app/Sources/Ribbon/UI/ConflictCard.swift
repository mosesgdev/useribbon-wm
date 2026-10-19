import SwiftUI
import AppKit

/// One calm glass card: names the app that fights Ribbon and offers to quit it or keep both.
struct ConflictCardView: View {
    let conflict: Conflict
    var more = 0
    var icon: NSImage? = nil
    var canQuit = true
    var onQuit: () -> Void = {}
    var onKeep: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: conflict.kind == .stageManager ? "rectangle.3.group" : "arrow.left.arrow.right").font(.system(size: 22)).foregroundStyle(Theme.accent) }
                }.frame(width: 38, height: 38).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ConflictCopy.title(conflict)).font(Theme.display(15))   // 15 semibold: the card title size
                    Text(ConflictCopy.message(conflict)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if conflict.kind == .app, !canQuit {
                        Text("It runs quietly in the background. You can stop it from Activity Monitor.").font(Theme.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            HStack(spacing: 8) {
                if conflict.kind == .stageManager {
                    Button("Open Settings", action: onOpenSettings).buttonStyle(RibbonButtonStyle(.primary))
                    Button("Leave it on", action: onKeep).buttonStyle(RibbonButtonStyle(.secondary))
                } else {
                    if canQuit { Button("Quit \(conflict.name)", action: onQuit).buttonStyle(RibbonButtonStyle(.primary)) }
                    Button("Keep both", action: onKeep).buttonStyle(RibbonButtonStyle(.secondary))
                }
                Spacer()
                if more > 0 { Text("+\(more) more").font(Theme.caption).foregroundStyle(Theme.muted) }
            }.controlSize(.regular)
        }
        .padding(16).frame(width: 360, alignment: .leading)
        .readingSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))   // text on it: a reading surface, not bare glass
        .environment(\.controlActiveState, .key)   // the panel never activates; keep its buttons lit
        .padding(10)   // room for the shadow
        .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : -8)
        .animation(reduceMotion ? Theme.reduced : Theme.panelSpring, value: appeared)
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class ConflictCardController {
    private var panel: NSPanel?
    private var fade: DispatchWorkItem?
    private(set) var current: Conflict?
    var onQuit: (Conflict) -> Void = { _ in }
    var onKeep: (Conflict) -> Void = { _ in }
    var onOpenSettings: (Conflict) -> Void = { _ in }

    func show(_ c: Conflict, more: Int) {
        close()
        current = c
        let running = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == c.pid || ($0.bundleIdentifier != nil && $0.bundleIdentifier == c.bundleID)
        }
        let view = ConflictCardView(conflict: c, more: more, icon: running?.icon, canQuit: running != nil,
                                    onQuit: { [weak self] in self?.onQuit(c) }, onKeep: { [weak self] in self?.onKeep(c) },
                                    onOpenSettings: { [weak self] in self?.onOpenSettings(c) })
        let host = SheetHostingView(rootView: view)   // the first click on a button must work: the card never activates, so it is never key before the click
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        let size = host.fittingSize
        let p = KeyPanel.make(size: size)
        p.hasShadow = false
        p.keyOnClick = true
        p.contentView = host
        if let f = Screens.primary?.visibleFrame { p.setFrameOrigin(NSPoint(x: f.maxX - size.width - Theme.dockInset + 10, y: f.maxY - size.height - Theme.dockInset + 10)) }
        p.orderFrontRegardless()
        panel = p
        // Unanswered, the card slips away on its own (the menu bar item brings it back); nothing is remembered.
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.close() } }
        fade = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: item)
    }

    func close() {
        fade?.cancel(); fade = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
        current = nil
    }
}
