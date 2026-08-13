import ForgeData
import SwiftUI

/// Shared replacement result: recognizable exercise art, a conventional
/// disclosure link for details, and one unmistakable swap action.
struct ReplacementExerciseRow: View {
    @Environment(\.theme) private var theme

    let exercise: ExerciseLibraryModel
    let onShowDetails: () -> Void
    let onSwap: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            ExerciseThumbnail(exercise: exercise)
                .accessibilityHidden(true)

            Button(action: onShowDetails) {
                ExerciseNameLabel(name: exercise.name)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .minimumTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View details for \(exercise.name)")
            .accessibilityIdentifier("replacement-detail-\(exercise.name)")

            Button("Swap to \(exercise.name)", systemImage: "arrow.triangle.2.circlepath", action: onSwap)
                .labelStyle(.iconOnly)
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(theme.secondaryAccent)
                .frame(width: 48, height: 48)
                .background(theme.surfaceElevated, in: Circle())
                .buttonStyle(.plain)
                .accessibilityIdentifier("replacement-swap-\(exercise.name)")
        }
        .padding(Space.md)
        .background(theme.surface)
        .clipShape(.rect(cornerRadius: Radius.control))
    }
}
