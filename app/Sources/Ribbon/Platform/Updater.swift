import AppKit
import Sparkle

/// Sparkle updates. Only a release bundle carries a feed URL and key (see scripts/release.sh); any other
/// build never starts the updater, so nothing here touches the network. --selftest never calls start().
///
/// A menu bar app has no Dock icon, so Sparkle's own scheduled-update window could open behind other apps unnoticed.
/// Scheduled finds are shown as "Update available…" in the menu instead (`onPending`); asking for it opens Sparkle's window.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    /// A scheduled check found an update that Sparkle is holding back until the user asks (true), or that is done with (false).
    var onPending: (Bool) -> Void = { _ in }

    /// True once the updater runs, which is when the menu offers "Check for Updates…".
    var isRunning: Bool { controller != nil }

    /// Whether a bundle's Info.plist carries both a feed URL and a public key.
    nonisolated static func feedConfigured(_ info: [String: Any]) -> Bool {
        for key in ["SUFeedURL", "SUPublicEDKey"] {
            guard let value = info[key] as? String, !value.isEmpty else { return false }
        }
        return true
    }

    /// Starts Sparkle if the bundle was given a feed URL and a public key. Returns whether it did.
    @discardableResult
    func start() -> Bool {
        guard Self.feedConfigured(Bundle.main.infoDictionary ?? [:]) else { return false }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        do { try c.updater.start() } catch {
            NSLog("Ribbon: the updater did not start: \(error.localizedDescription)")
            return false
        }
        controller = c
        return true
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !handleShowingUpdate { MainActor.assumeIsolated { onPending(true) } }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { MainActor.assumeIsolated { onPending(false) } }

    nonisolated func standardUserDriverWillFinishUpdateSession() { MainActor.assumeIsolated { onPending(false) } }
}
