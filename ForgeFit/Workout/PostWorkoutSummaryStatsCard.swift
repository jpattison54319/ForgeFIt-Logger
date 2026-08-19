import ForgeData
import SwiftUI

/// Modality-aware headline facts for the completion sheet. This keeps yoga
/// and conditioning summaries from falling back to zero strength metrics.
struct PostWorkoutSummaryStatsCard: View {
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let durationSeconds: Int
    let awardCount: Int

    @Environment(\.theme) private var theme

    private var facts: [WorkoutOverviewPresentation.Fact] {
        Array(WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: exercises,
            durationSeconds: durationSeconds
        ).facts.prefix(3))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        StatColumn(label: fact.label, value: fact.value)
                    }
                }
                if awardCount > 0 {
                    Divider().overlay(theme.separator)
                    HStack(spacing: Space.sm) {
                        Label("Awards", systemImage: "trophy.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.warmup)
                        Spacer()
                        Text("\(awardCount)")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.warmup)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            facts.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
                + (awardCount > 0 ? ", \(awardCount) awards" : "")
        )
    }
}
