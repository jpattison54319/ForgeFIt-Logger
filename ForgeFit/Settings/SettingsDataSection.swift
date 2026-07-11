import SwiftUI

/// Data section: destructive reset action that presents the reset confirmation
/// sheet.
struct SettingsDataSection: View {
    @Environment(\.theme) private var theme
    @Binding var showResetSheet: Bool

    var body: some View {
        Section {
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
