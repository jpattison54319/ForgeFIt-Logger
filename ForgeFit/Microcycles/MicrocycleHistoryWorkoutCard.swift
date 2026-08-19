import ForgeData
import SwiftUI

struct MicrocycleHistoryWorkoutCard: View {
    @Environment(\.theme) private var theme

    let record: MicrocycleHistoryDayWorkout
    let analytics: TrainingAnalytics

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
            .accessibilityIdentifier("microcycle-history-workout-\(record.workout.id.uuidString)")

            if record.isBackfilled {
                Text("Counted on this microcycle day. The workout's original history date is unchanged.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}
