import SwiftUI

/// Theme picker section — switches between Sage light, dark, and auto modes.
struct SettingsAppearanceSection: View {
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        Section {
            SettingsRow(title: "Theme") {
                Picker("Appearance", selection: $themeManager.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Appearance")
        }
    }
}
