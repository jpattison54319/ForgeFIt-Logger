import SwiftUI

/// Confirmation sheet for permanently deleting the user's community profile.
/// Mirrors `ResetDataSheet`'s destructive-confirm pattern: consequences up
/// front, one danger action, cancel. On success the Community hub falls back
/// to its opt-in gate; on failure the profile is still up (the backend
/// deletes it last), so the same action retries cleanly.
struct SocialDeleteProfileSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social

    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(theme.danger)
                        Text("Delete community profile")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("This permanently removes you from the ForgeFit community.")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            deleteBullet("Deleted", "Your public profile and handle, every workout you've shared, and your follows and likes.")
                            Divider().overlay(theme.separator)
                            deleteBullet("Kept on this iPhone", "Your workouts, routines, and progress. Only community data is removed.")
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    PrimaryButton(title: isDeleting ? "Deleting..." : "Delete community profile", systemImage: "trash.fill", tint: theme.danger) {
                        Task { await deleteProfile() }
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("social-delete-profile-confirm")
                    SecondaryButton(title: "Cancel") {
                        dismiss()
                    }
                    .disabled(isDeleting)
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled(isDeleting)
    }

    private func deleteBullet(_ title: String, _ detail: String) -> some View {
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

    private func deleteProfile() async {
        isDeleting = true
        errorMessage = nil
        do {
            try await social.deleteProfile()
            dismiss()
        } catch {
            errorMessage = "Couldn't finish deleting — your profile is still in the community. Check your connection and try again."
            isDeleting = false
        }
    }
}
