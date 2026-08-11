import SwiftUI

/// A visible control and recovery surface for the automatic workout-history
/// backup. Routines do not need a manual button: SwiftData mirrors the plan
/// store through the user's private CloudKit database automatically.
struct BackupSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var backup = BackupScheduler.shared
    @State private var showDeleteConfirmation = false
    @State private var actionMessage: String?

    var body: some View {
        List {
            Section {
                statusRow

                if let lastSuccessAt = backup.lastSuccessAt {
                    SettingsRow(title: "Last successful backup") {
                        Text(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .themedListRow()
                }

                if case .failed(let message) = backup.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .themedListRow()
                        .accessibilityIdentifier("icloud-backup-error")
                }
            } header: {
                SettingsSectionHeader(title: "Status")
            }

            Section {
                Button {
                    backup.exportNow()
                } label: {
                    SettingsRowLabel(
                        icon: "arrow.clockwise.icloud.fill",
                        iconTint: theme.accent,
                        title: "Back up now",
                        subtitle: "Retry immediately or save a fresh copy."
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .disabled(backup.state.isBusy)
                .accessibilityIdentifier("icloud-backup-now")

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    SettingsRowLabel(
                        icon: "trash.fill",
                        iconTint: theme.danger,
                        title: "Delete workout backup",
                        subtitle: "Keeps workouts on this iPhone and leaves routine sync on."
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .disabled(backup.state.isBusy)
                .accessibilityIdentifier("delete-icloud-workout-backup")
            } header: {
                SettingsSectionHeader(title: "Controls")
            } footer: {
                Text("Automatic backup stays on. If you delete the copy, ForgeFit creates a new one after future workout-history changes or the next daily catch-up.")
            }

            Section {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Training plan", systemImage: "icloud.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Routines, folders, your exercise library, presets, and XP sync automatically through your private CloudKit database.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .themedListRow()

                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Workout history", systemImage: "externaldrive.fill.badge.icloud")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Completed workouts, sets, cardio details, routes, microcycle tracking, and rest markers are copied automatically to iCloud Drive. HealthKit-imported workouts, HealthKit-filled distance, heart rate, calories, sleep, body weight, readiness, check-ins, and experiments are excluded.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .themedListRow()
            } header: {
                SettingsSectionHeader(title: "What iCloud stores")
            } footer: {
                Text("ForgeFit’s developer does not receive or have access to these private iCloud files. Restore them from Settings → Import workout history on another iPhone signed into the same iCloud account.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("iCloud Backup")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete workout backup?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Backup", role: .destructive) {
                deleteBackup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes ForgeFit’s latest and previous workout-history files from iCloud Drive. It does not delete workouts on this iPhone or your synced routines. Automatic backup will create a new copy after future changes.")
        }
        .alert(
            "iCloud backup",
            isPresented: Binding(
                get: { actionMessage != nil },
                set: { if !$0 { actionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionMessage = nil }
        } message: {
            Text(actionMessage ?? "")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        SettingsRow(
            icon: statusIcon,
            iconTint: statusTint,
            title: statusTitle,
            subtitle: statusSubtitle
        ) {
            if backup.state.isBusy {
                ProgressView()
                    .tint(theme.accent)
            }
        }
        .themedListRow()
        .accessibilityIdentifier("icloud-backup-status")
    }

    private var statusTitle: String {
        switch backup.state {
        case .waitingForFirstBackup: "Waiting for first backup"
        case .pending: "Backup pending"
        case .exporting: "Backing up"
        case .upToDate: "Up to date"
        case .unavailable: "iCloud Drive unavailable"
        case .failed: "Backup needs attention"
        case .deleting: "Deleting backup"
        }
    }

    private var statusSubtitle: String {
        switch backup.state {
        case .waitingForFirstBackup:
            "ForgeFit will save the first copy shortly."
        case .pending:
            "Changes are saved locally and queued for iCloud."
        case .exporting:
            "Creating a sanitized workout-history copy."
        case .upToDate:
            "Your latest completed workout changes are in iCloud Drive."
        case .unavailable:
            "Sign in to iCloud and turn on iCloud Drive, then try again."
        case .failed:
            "Your local workouts are safe. Tap Back up now to retry."
        case .deleting:
            "Removing the latest and previous copies from iCloud Drive."
        }
    }

    private var statusIcon: String {
        switch backup.state {
        case .upToDate: "checkmark.icloud.fill"
        case .unavailable, .failed: "exclamationmark.icloud.fill"
        case .deleting: "trash.fill"
        default: "icloud.and.arrow.up.fill"
        }
    }

    private var statusTint: Color {
        switch backup.state {
        case .upToDate: theme.success
        case .unavailable, .failed, .deleting: theme.danger
        default: theme.accent
        }
    }

    private func deleteBackup() {
        Task {
            let result = await backup.deleteBackup()
            switch result {
            case .deleted:
                actionMessage = "The workout-history backup was deleted. Local workouts and synced routines were not changed."
            case .unavailable:
                actionMessage = "The iCloud Drive backup could not be reached and may still exist. Check iCloud Drive and try again."
            case .cancelled:
                actionMessage = "Backup deletion was interrupted and the files may still exist. Try again."
            case .failed(let message):
                actionMessage = "The backup could not be deleted and may still exist. \(message)"
            }
        }
    }
}
