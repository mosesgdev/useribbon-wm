import Foundation
import SwiftUI
import RibbonCoreFFI

// The two editions of Ribbon, and the one place a paid ("Plus") feature adds to the app's UI.
//
//  - The open-source repo is exported from the private one with Plus/ deleted and Free/ kept; this file and everything else shared
//    compiles in both. Plus/ files are wrapped whole in `#if RIBBON_PLUS`, Free/ files in `#if !RIBBON_PLUS`.
//  - A Plus feature never edits a menu, a table or a list in shared code. It describes what it adds (`RibbonFeature`) and
//    Plus/ registers it (`PlusFeatureList`); Free/ registers none. The tables below (shortcuts, command bar, menu bar, settings, the
//    shortcuts sheet) read the registry.
//  - Parts of the app a feature has to draw into (a tab bar's button, the strip's tile) go through a type that Plus/ and Free/ both
//    declare with the same name: the real one in Plus/, an inert stand-in in Free/.

/// Which edition is running. Plus features need BOTH the app (built with RIBBON_PLUS) and its core (built with `--features plus`).
enum Edition {
    /// What this binary was compiled as: "plus" or "free" (declared by the file in Plus/ or Free/ that was compiled).
    static var built: String { BuiltEdition.name }
    /// What the linked core says it was built as (`ribbon_core_edition()`).
    static var core: String { String(cString: ribbon_core_edition()) }
    /// The app and its core are the same edition. The Makefile never links the other one; --selftest fails if it happened anyway.
    static var matches: Bool { built == core }
    /// Plus features are on: a Plus app on a Plus core. A mismatch runs as free (`logMismatch` says so once).
    static var plusActive: Bool { built == "plus" && core == "plus" }
    /// "plus" when Plus features are on, else "free": the edition the user gets.
    static var running: String { plusActive ? "plus" : "free" }

    /// A line for the log when the app and its core disagree; nil when they agree.
    static var mismatchNote: String? {
        matches ? nil : "ribbon: this app is the \(built) edition but its core is the \(core) edition; running as free"
    }

    /// Called once at launch.
    static func logMismatch() { if let note = mismatchNote { NSLog("%@", note) } }
}

// MARK: - What a feature adds

/// A shortcut a feature adds to `Hotkeys.table`. `after`: the id of the row it follows, so the Shortcuts sheet lists it where it
/// belongs; nil puts it at the end.
struct FeatureHotkey {
    let hotkey: Hotkey
    var after: String? = nil
}

/// A command bar row a feature adds. `standIn`: the row is only for a bar with no window to name; with a window in front the
/// feature supplies rows made for that window instead (and `keywords` find the stand-in). `after`: the title of the row it follows.
struct FeatureBarRow {
    let title: String
    let symbol: String
    let action: BarAction
    /// The second line; "%@" is the app of the window the bar names.
    let detail: String
    var keywords = ""
    var standIn = false
    var after: String? = nil
}

/// A menu bar item that runs an engine command. `after`: the title of the item it follows.
struct FeatureMenuItem {
    let title: String
    let command: String
    var symbol: String? = nil
    var after: String? = nil
}

extension FeatureMenuItem {
    /// Where it goes in a menu whose items have these titles: after the item it names, else at the end.
    func index(in titles: [String]) -> Int { after.flatMap { titles.firstIndex(of: $0) }.map { $0 + 1 } ?? titles.count }
}

/// A tab of Settings of its own (`id` is its title).
struct FeatureSettingsTab {
    let title: String
    let subtitle: String
    let view: @MainActor () -> AnyView
}

/// A control (any view; `SettingsGroup` turns each child into a row) added to one of Settings' tabs, named by its title.
struct FeatureSettingsRow {
    let tab: String
    let view: @MainActor () -> AnyView
}

/// A group of the Shortcuts sheet that no built-in shortcut belongs to (its shortcuts name it as their `group`).
struct FeatureShortcutGroup {
    let name: String
    /// 0 = the left column, 1 = the right one.
    var column = 1
}

protocol RibbonFeature {
    var id: String { get }
    /// Actions with a default shortcut.
    var hotkeys: [FeatureHotkey] { get }
    /// Engine commands that change the focused window or its column (the command bar names that window while one is selected).
    var windowCommands: [String] { get }
    var barRows: [FeatureBarRow] { get }
    var menuItems: [FeatureMenuItem] { get }
    var settingsTabs: [FeatureSettingsTab] { get }
    var settingsRows: [FeatureSettingsRow] { get }
    var shortcutGroups: [FeatureShortcutGroup] { get }
    /// Checks of the feature's own pieces. --selftest runs them only when the feature is on, and counts them with the rest.
    var selfTests: [(_ check: (Bool, String) -> Void) -> Void] { get }
    /// The share of the display a column the feature holds outside the ribbon has, as the map measures it from whole pixels,
    /// named by the size it is meant to be (the bar says "now 20 %" for a measured 0.1999). Others are left as they are.
    func nominalHeldWidth(_ fraction: Double) -> Double
}

extension RibbonFeature {
    var hotkeys: [FeatureHotkey] { [] }
    var windowCommands: [String] { [] }
    var barRows: [FeatureBarRow] { [] }
    var menuItems: [FeatureMenuItem] { [] }
    var settingsTabs: [FeatureSettingsTab] { [] }
    var settingsRows: [FeatureSettingsRow] { [] }
    var shortcutGroups: [FeatureShortcutGroup] { [] }
    var selfTests: [(_ check: (Bool, String) -> Void) -> Void] { [] }
    func nominalHeldWidth(_ fraction: Double) -> Double { fraction }
}

/// The features that are on, and what they add. `shared` is what the app uses; the checks build their own to try the slots.
struct FeatureRegistry {
    var features: [any RibbonFeature]

    /// Plus features only when the app and its core are both Plus. Free/ lists none, so a free build is always empty.
    static let shared = FeatureRegistry(features: Edition.plusActive ? PlusFeatureList.all : [])

    var isEmpty: Bool { features.isEmpty }

    /// `base` with the features' shortcuts put after the row they name.
    func hotkeys(merging base: [Hotkey]) -> [Hotkey] {
        Self.insert(features.flatMap(\.hotkeys).map { ($0.hotkey, $0.after) }, into: base) { $0.id }
    }

    var windowCommands: Set<String> { Set(features.flatMap(\.windowCommands)) }

    /// `base` rows (title, symbol, action) with the features' rows after the row they name.
    func barRows(merging base: [(String, String, BarAction)]) -> [(String, String, BarAction)] {
        let extra = features.flatMap(\.barRows).map { (($0.title, $0.symbol, $0.action), $0.after) }
        return Self.insert(extra, into: base) { $0.0 }
    }

    var barRows: [FeatureBarRow] { features.flatMap(\.barRows) }
    /// Titles of the rows that stand in for the feature's own rows when the bar has no window to name.
    var standInTitles: Set<String> { Set(barRows.filter(\.standIn).map(\.title)) }
    /// Keywords of the stand-in rows, by title.
    var barKeywords: [String: String] { Dictionary(barRows.map { ($0.title, $0.keywords) }, uniquingKeysWith: { a, _ in a }) }
    /// The second lines of the features' rows, by title.
    var barDetails: [String: String] { Dictionary(barRows.map { ($0.title, $0.detail) }, uniquingKeysWith: { a, _ in a }) }

    var menuItems: [FeatureMenuItem] { features.flatMap(\.menuItems) }
    var settingsTabs: [FeatureSettingsTab] { features.flatMap(\.settingsTabs) }
    func settingsRows(in tab: String) -> [FeatureSettingsRow] { features.flatMap(\.settingsRows).filter { $0.tab == tab } }
    var shortcutGroups: [FeatureShortcutGroup] { features.flatMap(\.shortcutGroups) }
    var selfTests: [(_ check: (Bool, String) -> Void) -> Void] { features.flatMap(\.selfTests) }
    func nominalHeldWidth(_ fraction: Double) -> Double { features.reduce(fraction) { $1.nominalHeldWidth($0) } }
    func shortcutGroups(inColumn c: Int) -> [String] { shortcutGroups.filter { $0.column == c }.map(\.name) }

    /// Every id the features' shortcuts and commands use: what a saved setting may name without being dangling.
    var shortcutIDs: Set<String> { Set(features.flatMap(\.hotkeys).map(\.hotkey.id)) }

    /// Items placed after the element they name (or at the end), in the order given; one that names an element still to come
    /// (another feature's, listed later) follows once that one is in.
    private static func insert<T>(_ extra: [(T, String?)], into base: [T], key: (T) -> String) -> [T] {
        var out = base
        for (item, after) in extra {
            if let after, let i = out.firstIndex(where: { key($0) == after }) { out.insert(item, at: i + 1) }
            else { out.append(item) }
        }
        return out
    }
}
