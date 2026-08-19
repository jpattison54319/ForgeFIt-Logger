import SwiftUI

/// Data section: export-your-data action plus the destructive reset action
/// that presents the reset confirmation sheet.
struct SettingsDataSection: View {
    @Environment(\.theme) private var theme
    @State private var backup = BackupScheduler.shared
    @Binding var showExportSheet: Bool
    @Binding var showCommunityDeletionSheet: Bool
    @Binding var showResetSheet: Bool

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.iCloudBackup) {
                SettingsRowLabel(
                    icon: backupIcon,
                    iconTint: backupTint,
                    title: "iCloud backup",
                    subtitle: backupSubtitle
                )
            }
            .themedListRow()
            .accessibilityIdentifier("icloud-backup-row")

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

    private var backupSubtitle: String {
        switch backup.state {
        case .waitingForFirstBackup:
            "Workout history is waiting for its first automatic backup."
        case .pending:
            "Workout history changes are waiting to back up."
        case .exporting:
            "Backing up workout history now."
        case .upToDate:
            if let date = backup.lastSuccessAt {
                "Workout history backed up \(date.formatted(date: .abbreviated, time: .shortened))."
            } else {
                "Workout history is backed up automatically."
            }
        case .unavailable:
            "iCloud Drive is unavailable — tap to retry."
        case .failed:
            "Backup needs attention — tap to retry."
        case .deleting:
            "Deleting the workout-history backup."
        }
    }

    private var backupIcon: String {
        switch backup.state {
        case .upToDate: "checkmark.icloud.fill"
        case .unavailable, .failed: "exclamationmark.icloud.fill"
        case .deleting: "trash.fill"
        default: "icloud.and.arrow.up.fill"
        }
    }

    private var backupTint: Color {
        switch backup.state {
        case .upToDate: theme.success
        case .unavailable, .failed, .deleting: theme.danger
        default: theme.accent
        }
    }
}
