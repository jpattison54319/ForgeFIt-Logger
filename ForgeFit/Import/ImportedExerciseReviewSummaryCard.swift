import SwiftUI

struct ImportedExerciseReviewSummaryCard: View {
    @Environment(\.theme) private var theme
    let count: Int
    let onApproveAll: () -> Void
    let onDiscardAll: () -> Void

    @State private var isConfirmingDiscardAll = false

    var body: some View {
        Card(fill: theme.accent.opacity(0.09)) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "sparkles")
                        .accessibilityHidden(true)
                    Text("New exercise suggestions")
                        .accessibilityIdentifier("imported-exercise-review-summary")
                }
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)

                Text("ForgeFit could not match these imported names exactly, so it created new library exercises and suggested their type, equipment, and muscles. These suggestions are not workout scores.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Approve keeps an exercise as shown. Edit lets you correct it. Discard removes it from your library. Imported workouts remain in your history.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.sm) {
                    Button(action: onApproveAll) {
                        Text("Approve all")
                            .frame(maxWidth: .infinity)
                    }
                    .minimumTouchTarget()
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .accessibilityIdentifier("approve-all-imported-exercises")

                    Button("Discard all", systemImage: "trash", role: .destructive) {
                        isConfirmingDiscardAll = true
                    }
                    .frame(maxWidth: .infinity)
                    .minimumTouchTarget()
                    .buttonStyle(.bordered)
                    .tint(theme.danger)
                    .accessibilityIdentifier("discard-all-imported-exercises")
                    .alert(
                        "Discard all \(count) exercises?",
                        isPresented: $isConfirmingDiscardAll
                    ) {
                        Button("Discard \(count) exercises", role: .destructive, action: onDiscardAll)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("They will be removed from your exercise library. Imported workouts will remain in your history.")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
            }
        }
    }
}
