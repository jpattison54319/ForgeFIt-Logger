import ForgeData
import SwiftUI

struct MicrocycleBackfillCandidateRow: View {
    @Environment(\.theme) private var theme

    let workout: WorkoutModel
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.md) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(theme.accentForeground)
                    .frame(width: 36, height: 36)
                    .background(theme.accent.opacity(0.12))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.title ?? "Workout")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    Text("Logged \(workout.startedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }

                Spacer(minLength: Space.sm)

                Text("Use")
                    .font(.subheadline.bold())
                    .foregroundStyle(theme.accentForeground)
            }
            .padding(Space.md)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(workout.title ?? "workout"), logged \(workout.startedAt.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityHint("Counts this completed workout on the selected microcycle day without changing its original date.")
    }
}
