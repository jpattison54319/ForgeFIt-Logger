import ForgeCore
import SwiftUI

/// Appearance and approved color-family controls.
struct SettingsAppearanceSection: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.theme) {
                SettingsRow(
                    title: "Theme",
                    subtitle: themeManager.family.displayName
                ) {
                    DiagonalThemeSwatch(
                        primary: theme.accent,
                        accent: theme.secondaryAccent
                    )
                    .frame(width: 58, height: 34)
                }
            }
            .accessibilityIdentifier("theme-picker-link")
            .themedListRow()

            SettingsRow(title: "Appearance") {
                Picker("Appearance", selection: $themeManager.mode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .frame(minHeight: TouchTarget.minimum)
            }
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Appearance")
        }
    }
}
