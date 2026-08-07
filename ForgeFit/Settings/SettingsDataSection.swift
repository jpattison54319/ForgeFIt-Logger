import SwiftUI

/// Data section: export-your-data action plus the destructive reset action
/// that presents the reset confirmation sheet.
struct SettingsDataSection: View {
    @Environment(\.theme) private var theme
    @Binding var showExportSheet: Bool
    @Binding var showCommunityDeletionSheet: Bool
    @Binding var showResetSheet: Bool

    var body: some View {
        Section {
            Button {
                showExportSheet = true
            } label: {
                SettingsRowLabel(
                    icon: "square.and.arrow.up",
                    iconTint: theme.accent,
                    title: "Export data",
                    subtitle: "Your workouts and routines as JSON or CSV files you own."
                )
            }
            .buttonStyle(.plain)
            .themedListRow()
            .accessibilityIdentifier("export-data-row")

            Button(role: .destructive) {
                showCommunityDeletionSheet = true
            } label: {
                SettingsRowLabel(
                    icon: "person.crop.circle.badge.xmark",
                    iconTint: theme.danger,
                    title: "Delete Community data",
                    subtitle: "Remove any public profile and shared workouts created with an earlier build."
                )
            }
            .buttonStyle(.plain)
            .themedListRow()
            .accessibilityIdentifier("delete-community-data-row")

            Button(role: .destructive) {
                showResetSheet = true
            } label: {
                SettingsRowLabel(
                    icon: "trash.fill",
                    iconTint: theme.danger,
                    title: "Reset all app data",
                    subtitle: "Delete local workouts, routines, imports, notes, progress, reminders, and preferences."
                )
            }
            .buttonStyle(.plain)
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Data")
        }
    }
}
