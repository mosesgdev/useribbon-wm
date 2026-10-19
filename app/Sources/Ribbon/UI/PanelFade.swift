import Foundation

/// A panel's opacity fade, kept on the clock. `NSWindow.alphaValue` only says where an animation is headed, so a refresh that lands
/// while a panel fades in cannot tell a fade from a finished one without this; cutting the fade to full opacity is a pop.
struct PanelFade: Equatable {
    private(set) var from = 1.0, to = 1.0
    private var start = 0.0, duration = 0.0

    /// The opacity at `now`, linear between the two ends (close enough for a fade of 150 ms).
    func alpha(at now: Double) -> Double {
        guard duration > 0, now < start + duration else { return to }
        return from + (to - from) * max(0, (now - start) / duration)
    }

    /// A fade has not reached its end yet.
    func isRunning(at now: Double) -> Bool { duration > 0 && now < start + duration }

    /// A fade towards full opacity has not reached it yet: a refresh must leave it alone.
    func isFadingIn(at now: Double) -> Bool { isRunning(at: now) && to > from }

    mutating func begin(from a: Double, to b: Double, duration d: Double, at now: Double) {
        from = a; to = b; duration = d; start = now
    }

    /// No fade (the panel was set to `alpha` outright).
    mutating func stop(at alpha: Double = 1) {
        from = alpha; to = alpha; duration = 0
    }
}

/// The focus ring's opacity. It fades in where it first appears and where focus moves to another window; a refresh meanwhile never
/// cuts that fade short, and a burst of switches (a held arrow key) carries the opacity along instead of dipping to nothing each time.
struct RingFade: Equatable {
    static let duration = 0.15
    /// A switch within this long of the last one (or of the ring appearing) is part of a burst.
    static let burst = 0.2
    /// In a burst the ring never falls below this on its way to the next window.
    static let floor = 0.35
    private(set) var fade = PanelFade()
    private var lastSwitch = -Double.infinity

    /// The ring appears (it was hidden): up from nothing.
    mutating func appear(at now: Double) {
        fade.begin(from: 0, to: 1, duration: Self.duration, at: now)
        lastSwitch = now
    }

    /// Focus moved to another window without a fade (the ring only moved): it still counts for a burst, so that the next switch
    /// that does fade carries on instead of dipping.
    mutating func noteSwitch(at now: Double) { lastSwitch = now }

    /// Focus moved to another window: the opacity the ring starts the new fade-in from. A lone switch starts from nothing (the old
    /// ring is gone with its window); one inside a burst carries on from the opacity the ring has, at least `floor`.
    mutating func switched(at now: Double) -> Double {
        let carried = now - lastSwitch < Self.burst ? max(fade.alpha(at: now), Self.floor) : 0
        fade.begin(from: carried, to: 1, duration: Self.duration, at: now)
        lastSwitch = now
        return carried
    }

    func isFadingIn(at now: Double) -> Bool { fade.isFadingIn(at: now) }

    /// The ring went away or was set outright.
    mutating func stop(at alpha: Double = 1) { fade.stop(at: alpha); lastSwitch = -.infinity }
}
