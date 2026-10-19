import Foundation

/// Zero-config default widths: a small built-in table by bundle id, overridden by what the user last chose per app.
enum AppWidths {
    private static let key = "learnedAppWidths"
    private static let narrow = 0.333, wide = 0.667

    private static let builtIn: [String: Double] = {
        let terminals = ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty"]
        let chat = ["com.apple.Notes", "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                    "com.apple.reminders", "com.spotify.client"]
        let big = ["com.apple.Safari", "company.thebrowser.dia", "company.thebrowser.Browser", "com.google.Chrome", "org.mozilla.firefox",
                   "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.figma.Desktop", "com.apple.dt.Xcode"]
        return Dictionary(uniqueKeysWithValues: (terminals + chat).map { ($0, narrow) } + big.map { ($0, wide) })
    }()

    static func hint(bundleID: String?) -> Double? {
        guard let bundleID else { return nil }
        let learned = UserDefaults.standard.dictionary(forKey: key) as? [String: Double]
        return learned?[bundleID] ?? builtIn[bundleID]
    }

    static func learn(bundleID: String?, frac: Double) {
        guard let bundleID, frac > 0, frac <= 1 else { return }
        var learned = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        learned[bundleID] = frac
        UserDefaults.standard.set(learned, forKey: key)
    }
}
