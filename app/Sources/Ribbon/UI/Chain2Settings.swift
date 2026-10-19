import SwiftUI

/// Settings rows for width steps and dimming, as SettingsRows (they go inside a SettingsGroup in Settings.swift).

/// "Width steps": the list ⌃⌥R cycles through. Default 25 · 33 · 50 · 66 · 75 · 100; "Simple" keeps ⅓ ½ ⅔ full.
struct WidthStepsRow: View {
    @AppStorage(WidthPresets.key) private var choice = "rich"
    var body: some View {
        SettingsRow(title: "Width steps", detail: "What the width key cycles through") {
            Picker("Width steps", selection: $choice) {
                Text("25 · 33 · 50 · 66 · 75 · 100 %").tag("rich")
                Text("Simple: ⅓ · ½ · ⅔ · full").tag("simple")
            }.labelsHidden().fixedSize()
        }
    }
}

/// "Other windows": Normal / Dim / Blur. The Focus mode hotkey (blur) works on top of whatever this says.
struct OtherWindowsRow: View {
    @AppStorage(OtherWindows.key) private var stored = ""
    @AppStorage(DimPrefs.enabledKey) private var legacyDim = false
    var body: some View {
        let mode = OtherWindows.resolve(stored: stored.isEmpty ? nil : stored, legacyDim: legacyDim)
        SettingsRow(title: "Other windows", detail: mode == .blur ? "Blurred, except the one you're in. Clicking one still focuses it"
                    : "Only the window you're in stays clear. Focus mode blurs them on a key") {
            Picker("Other windows", selection: Binding(get: { mode.rawValue }, set: { stored = $0 })) {
                ForEach(OtherWindows.allCases) { Text($0.label).tag($0.rawValue) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
        }
    }
}

struct DimStrengthRow: View {
    @AppStorage(OtherWindows.key) private var stored = ""
    @AppStorage(DimPrefs.enabledKey) private var legacyDim = false
    @AppStorage(DimPrefs.levelKey) private var level = DimLevel.subtle.rawValue
    var body: some View {
        let on = OtherWindows.resolve(stored: stored.isEmpty ? nil : stored, legacyDim: legacyDim) == .dim
        SettingsRow(title: "Dim strength") {
            Picker("Dim strength", selection: $level) { ForEach(DimLevel.allCases) { Text($0.label).tag($0.rawValue) } }
                .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(!on)
        }
    }
}
