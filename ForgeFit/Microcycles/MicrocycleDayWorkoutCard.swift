import ForgeData
import SwiftUI

struct MicrocycleDayWorkoutCard: View {
    @Environment(\.theme) private var theme

    let record: MicrocycleDayAssignmentService.DayWorkout
    let analytics: TrainingAnalytics
    let onRemoveBackfill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if record.isBackfilled {
                Label(
                    "Originally logged \(record.workout.startedAt.formatted(date: .abbreviated, time: .omitted))",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
            }

            NavigationLink(value: record.workout.id) {
                WorkoutFeedRow(workout: record.workout, analytics: analytics)
            }
            .buttonStyle(.plain)

            if record.isBackfilled {
                Text("Counted on this microcycle day. The workout's original history date is unchanged.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)

                SecondaryButton(
                    title: "Remove from This Day",
                    systemImage: "arrow.uturn.backward",
                    action: onRemoveBackfill
                )
                .accessibilityHint("Keeps the workout in history and removes only this microcycle link.")
                .accessibilityIdentifier("microcycle-remove-day-backfill")
            }
        }
    }
}
