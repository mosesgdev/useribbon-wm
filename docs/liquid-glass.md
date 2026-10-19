# Liquid Glass cheat sheet (macOS 26 SDK; verified against local swiftinterface)

SwiftUI (SwiftUICore), all macOS 26.0:
- `.glassEffect(_ glass: Glass = .regular, in: some Shape = Capsule)`
- `Glass.regular | .clear | .identity`, `.tint(Color?)`, `.interactive(Bool = true)`
- `GlassEffectContainer(spacing: CGFloat? = nil) { ... }` — glass can't sample glass; group siblings
- `.glassEffectID(id, in: namespace)` morphing; `.glassEffectUnion(id:namespace:)`
- `.glassEffectTransition(.matchedGeometry | .materialize | .identity)`
- Buttons: `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)` (26.0); `.glass(Glass)` 26.1+ (avoid; mini SDK 26.2 ok)

AppKit: `NSGlassEffectView` (contentView, cornerRadius, tintColor, style .regular/.clear);
`NSGlassEffectContainerView` (contentView, spacing). `effectIsInteractive` is macOS 27 only.

Floating HUD panel: styleMask [.borderless, .nonactivatingPanel, .fullSizeContentView], isFloatingPanel,
level .floating (or .statusBar), collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary],
isOpaque=false, backgroundColor=.clear, hasShadow=true, hidesOnDeactivate=false. Every layer must be clear
or the glass renders as a box. Command bar panel needs canBecomeKey = true for text input.

HIG: glass = functional/control layer only, never content. Regular by default; clear only over rich media.
Use sparingly. Reduce Transparency: fall back to opaque windowBackgroundColor
(`@Environment(\.accessibilityReduceTransparency)`).

Lesson (seen in a real WindowServer, invisible in offscreen `--snapshot`): apply `.glassEffect` / `adaptiveGlass` directly to the content view, never as `.background { Color.clear.glassEffect… }` inside a `GlassEffectContainer` — the container composites its glass above sibling content and hides it. Use a container only for several glass shapes that merge/morph.
