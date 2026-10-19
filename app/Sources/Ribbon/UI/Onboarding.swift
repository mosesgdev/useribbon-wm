import SwiftUI
import Combine
import ApplicationServices

struct OnboardingView: View {
    enum Stage { case ask, cheatSheet }
    @State var stage: Stage = .ask
    var modifier: ModifierChoice = .ctrlOpt
    var pollTrust = true
    var onAllow: () -> Void = {}
    var onStart: () -> Void = {}
    @State private var bounce = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            switch stage {
            case .ask: ask.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            case .cheatSheet: cheat.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .padding(36).frame(width: 440)
        .adaptiveGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
        .onReceive(timer) { _ in
            if pollTrust, stage == .ask, AXIsProcessTrusted() {
                withAnimation(reduceMotion ? Theme.reduced : Theme.panelSpring) { stage = .cheatSheet }
            }
        }
    }

    private var ask: some View {
        VStack(spacing: 18) {
            AppIconView(size: 64).frame(width: 64, height: 64).accessibilityHidden(true)
            Text("Let Ribbon tidy your windows.").font(Theme.display(26)).multilineTextAlignment(.center)
            Text("Ribbon needs Accessibility access to move your windows. Nothing leaves your Mac.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            VStack(spacing: 10) {
                Button(action: onAllow) { Text("Allow Accessibility").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 4) }
                    .buttonStyle(.glassProminent).controlSize(.large).tint(Theme.accent)
                Text("Opens System Settings. Come back here — Ribbon notices on its own.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
        }
    }

    private var cheat: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(Theme.success)
                    .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating.speed(0) : .nonRepeating, value: bounce)
                    .accessibilityHidden(true)
                Text("You're all set.").font(Theme.display(26))
                Text("Try it now: hold \(modifier.glyphs) and press →").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .onAppear { if !reduceMotion { bounce = true } }
            // Two shortcuts are enough for day one; the rest is one hold away (the strip) or one search away (the bar).
            VStack(spacing: 14) {
                row(modifier.keys("←", "→"), "Glide along the ribbon")
                row(modifier.keys("Space"), "Find anything")
            }
            .padding(16).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Color.primary.opacity(0.05)))
            Text("Hold \(modifier.glyphs) to see your windows. Find anything shows the rest.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button(action: onStart) { Text("Start").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 24).padding(.vertical, 4) }
                .buttonStyle(.glassProminent).controlSize(.large).tint(Theme.accent).keyboardShortcut(.defaultAction)
        }
    }

    private func row(_ keys: [String], _ text: String) -> some View {
        HStack { KeyCaps(keys: keys); Spacer(); Text(text).font(.system(size: 14)) }
    }
}

@MainActor
final class OnboardingController {
    private var window: KeyPanel?

    func show(modifier: ModifierChoice, onStart: @escaping () -> Void) {
        let view = OnboardingView(modifier: modifier,
            onAllow: {
                var ref: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &ref)  // registers us in the list
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            },
            onStart: { [weak self] in self?.close(); onStart() })
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true; host.layer?.backgroundColor = .clear
        let p = KeyPanel.make(size: host.fittingSize, floating: false)
        p.level = NSWindow.Level.normal; p.isMovableByWindowBackground = true
        p.styleMask.remove(.nonactivatingPanel)
        p.contentView = host
        p.center()
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        window = p
    }

    func close() { window?.close(); window = nil }
}
