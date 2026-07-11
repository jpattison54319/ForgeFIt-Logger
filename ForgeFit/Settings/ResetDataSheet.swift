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
    let onFinished: () -> Void

    @State private var isResetting = false
    @State private var errorMessage: String?

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

                    PrimaryButton(title: isResetting ? "Resetting..." : "Reset all app data", systemImage: "trash.fill", tint: theme.danger) {
                        reset()
                    }
                    .disabled(isResetting)
                    SecondaryButton(title: "Cancel") {
                        dismiss()
                    }
                    .disabled(isResetting)
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled(isResetting)
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
        isResetting = true
        errorMessage = nil
        do {
            try AccountResetService.resetAllAppData(in: modelContext)
            dismiss()
            onFinished()
        } catch {
            errorMessage = "Reset failed: \(error.localizedDescription)"
            isResetting = false
        }
    }
}
