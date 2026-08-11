import ForgeCore
import SwiftData
import SwiftUI

/// Confirmation sheet for the destructive "reset all app data" action.
/// Lists what gets deleted, what stays in Apple Health, and what's restored
/// after the reset.
struct ResetDataSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social
    let onFinished: () -> Void

    /// Consequence copy shown when the reset completed locally but the iCloud
    /// Drive backup could not be deleted. States the remaining state and the
    /// visible recovery path — never reassurance that the backup is gone.
    static let backupDeletionFailedCopy =
        "Your data was reset, but the iCloud Drive backup could not be deleted and may still exist. You can delete it in Files → iCloud Drive → ForgeFit → Backups when you're back online."

    /// Same consequence for an interrupted (cancelled) deletion.
    static let backupDeletionCancelledCopy =
        "Your data was reset, but deleting the iCloud Drive backup was interrupted and it may still exist. You can delete it in Files → iCloud Drive → ForgeFit → Backups when you're back online."

    /// Same consequence when the backup could not be reached at all (signed
    /// out, offline, or inaccessible). Not reaching the backup is NOT proof it
    /// was deleted, so the user must be told it may remain.
    static let backupDeletionUnavailableCopy =
        "Your data was reset, but the iCloud Drive backup could not be reached and may still exist. You can delete it in Files → iCloud Drive → ForgeFit → Backups when you're back online."

    @State private var isResetting = false
    @State private var errorMessage: String?
    @State private var backupWarningMessage: String?
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(theme.danger)
                        Text("Reset ForgeFit")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("This deletes your local ForgeFit data and returns the app to onboarding.")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            resetBullet("Deleted", "Workouts, routines, imports, notes, custom data, XP, levels, reminders, and preferences.")
                            Divider().overlay(theme.separator)
                            resetBullet("Kept in Apple Health", "Health records and permission grants are managed by iOS. ForgeFit will not delete Health workouts.")
                            if social.isOptedIn {
                                Divider().overlay(theme.separator)
                                resetBullet("Kept in the community", "Your public profile and shared workouts stay up. Community → Delete community profile removes them.")
                            }
                            Divider().overlay(theme.separator)
                            resetBullet("After reset", "The bundled exercise library is restored so you can start clean immediately.")
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let backupWarningMessage {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Backup could not be deleted")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.danger)
                            Text(backupWarningMessage)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }

                    PrimaryButton(
                        title: primaryButtonTitle,
                        systemImage: primaryButtonSystemImage,
                        tint: theme.danger
                    ) {
                        if backupWarningMessage == nil {
                            reset()
                        } else {
                            continueAfterBackupFailure()
                        }
                    }
                    .disabled(isResetting)
                    .accessibilityIdentifier(
                        backupWarningMessage == nil ? "reset-all-app-data" : "reset-backup-failure-continue"
                    )

                    if backupWarningMessage == nil {
                        SecondaryButton(title: "Cancel") {
                            dismiss()
                        }
                        .disabled(isResetting)
                        .accessibilityIdentifier("reset-cancel")
                    }
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled(isResetting || backupWarningMessage != nil)
        .onDisappear {
            // A sheet torn down mid-reset must not leave the reset task
            // running or post the shell transition after dismissal.
            resetTask?.cancel()
            resetTask = nil
        }
    }

    private var primaryButtonTitle: String {
        if backupWarningMessage != nil { return "Continue to onboarding" }
        return isResetting ? "Resetting..." : "Reset all app data"
    }

    private var primaryButtonSystemImage: String? {
        if backupWarningMessage != nil { return "arrow.right" }
        return isResetting ? nil : "trash.fill"
    }

    private func resetBullet(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reset() {
        // Duplicate taps must not start a second wipe while one runs.
        guard !isResetting else { return }
        isResetting = true
        errorMessage = nil
        backupWarningMessage = nil
        let context = modelContext
        resetTask = Task { @MainActor in
            do {
                let outcome = try await AccountResetService.resetAllAppData(in: context)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .completed:
                    dismiss()
                    onFinished()
                case .backupDeletionFailed:
                    backupWarningMessage = Self.backupDeletionFailedCopy
                    isResetting = false
                case .backupDeletionCancelled:
                    backupWarningMessage = Self.backupDeletionCancelledCopy
                    isResetting = false
                case .backupDeletionUnavailable:
                    backupWarningMessage = Self.backupDeletionUnavailableCopy
                    isResetting = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Reset failed: \(error.localizedDescription)"
                isResetting = false
            }
        }
    }

    private func continueAfterBackupFailure() {
        // The consequence was shown and acknowledged; only now may the shell
        // return to onboarding. Guarded so a double tap cannot post the
        // completion notification twice.
        guard backupWarningMessage != nil, !isResetting else { return }
        isResetting = true
        AccountResetService.finishResetAfterBackupDeletionFailure()
        dismiss()
        onFinished()
    }
}
