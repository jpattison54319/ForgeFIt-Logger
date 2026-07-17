import ForgeCore
import ForgeData
import SwiftUI

/// Persistent achievements derived entirely from workout history — nothing
/// to store, sync, or lose, and always true. (Wrapped's badges are yearly
/// and buried; these are lifetime and permanent.) Locked trophies show live
/// progress toward the threshold, which is the actually motivating part.
struct Trophy: Identifiable {
    let id: String
    let title: String
    let icon: String
    let achieved: Bool
    let currentValue: Int
    let threshold: Int
    let unit: String

    var progress: Double {
        min(Double(currentValue) / Double(threshold), 1)
    }

    var progressLabel: String {
        "\(min(currentValue, threshold).formatted()) of \(threshold.formatted()) \(unit)"
    }

    var requirement: String {
        "Reach \(threshold.formatted()) \(unit) to earn this trophy. Only training logged in ForgeFit counts — imported history doesn't."
    }
}

enum TrophyCatalog {
    struct Inputs {
        let completedWorkouts: Int
        let totalSets: Int
        let totalDistanceMeters: Double
        let lifetimeHours: Double
        let recordCount: Int
    }

    /// Trophy progress counts only training logged in ForgeFit. Imported
    /// history — Hevy/Strong/CSV files, Apple Health, GPX — fills the feed
    /// and charts but never earns a trophy.
    static func inputs(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel]
    ) -> Inputs {
        let analytics = TrainingAnalytics(
            workouts: workouts.filter { !$0.isImportedHistory },
            exercises: exercises
        )
        let native = analytics.completed
        let sets = native.reduce(0) { total, workout in
            total + workout.exercises.reduce(0) { $0 + $1.sets.filter { $0.completedAt != nil }.count }
        }
        let distance = native.reduce(0.0) { total, workout in
            total + workout.cardioSessions.reduce(0.0) { $0 + ($1.distanceMeters ?? 0) }
        }
        let totalSeconds = native.reduce(0) { $0 + analytics.summary(for: $1).durationSeconds }
        return Inputs(
            completedWorkouts: native.count,
            totalSets: sets,
            totalDistanceMeters: distance,
            lifetimeHours: Double(totalSeconds) / 3600,
            recordCount: analytics.records().count
        )
    }

    static func trophies(_ inputs: Inputs) -> [Trophy] {
        var list: [Trophy] = []

        func tier(_ id: String, _ title: String, _ icon: String, value: Int, threshold: Int, unit: String) {
            list.append(Trophy(
                id: "\(id)-\(threshold)",
                title: title,
                icon: icon,
                achieved: value >= threshold,
                currentValue: value,
                threshold: threshold,
                unit: unit
            ))
        }

        tier("workouts", "First session", "hammer.fill", value: inputs.completedWorkouts, threshold: 1, unit: "completed workout")
        tier("workouts", "Ten deep", "dumbbell.fill", value: inputs.completedWorkouts, threshold: 10, unit: "completed workouts")
        tier("workouts", "Fifty forged", "dumbbell.fill", value: inputs.completedWorkouts, threshold: 50, unit: "completed workouts")
        tier("workouts", "Century club", "trophy.fill", value: inputs.completedWorkouts, threshold: 100, unit: "completed workouts")
        tier("workouts", "250 sessions", "crown.fill", value: inputs.completedWorkouts, threshold: 250, unit: "completed workouts")

        tier("sets", "1,000 sets", "checklist.checked", value: inputs.totalSets, threshold: 1000, unit: "completed sets")
        tier("sets", "5,000 sets", "checklist.checked", value: inputs.totalSets, threshold: 5000, unit: "completed sets")

        let km = Int(inputs.totalDistanceMeters / 1000)
        tier("distance", "50 km covered", "point.topleft.down.to.point.bottomright.curvepath.fill", value: km, threshold: 50, unit: "kilometres covered")
        tier("distance", "250 km covered", "map.fill", value: km, threshold: 250, unit: "kilometres covered")

        tier("records", "5 records", "rosette", value: inputs.recordCount, threshold: 5, unit: "personal records")
        tier("records", "25 records", "medal.fill", value: inputs.recordCount, threshold: 25, unit: "personal records")

        tier("hours", "10 hours trained", "clock.fill", value: Int(inputs.lifetimeHours), threshold: 10, unit: "training hours")
        tier("hours", "100 hours trained", "clock.badge.checkmark.fill", value: Int(inputs.lifetimeHours), threshold: 100, unit: "training hours")

        return list
    }
}

struct TrophyCaseCard: View {
    @Environment(\.theme) private var theme
    @State private var selectedTrophy: Trophy?
    let trophies: [Trophy]

    private var earnedCount: Int { trophies.filter(\.achieved).count }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text("\(earnedCount) of \(trophies.count) earned")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)

                ScrollView(.horizontal) {
                    HStack(spacing: Space.md) {
                        ForEach(trophies.sorted { $0.achieved && !$1.achieved }) { trophy in
                            Button {
                                selectedTrophy = trophy
                            } label: {
                                TrophyShelfItem(trophy: trophy)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityIdentifier("trophy-\(trophy.id)")
                            .accessibilityLabel("\(trophy.title), \(trophy.achieved ? "earned" : trophy.progressLabel)")
                            .accessibilityHint("Shows how to earn this trophy")
                        }
                    }
                    .frame(minHeight: 84, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("trophy-shelf")
                // Fade the trailing edge so the cut-off trophy reads as "there's
                // more this way," making the horizontal scroll discoverable.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
        .sheet(item: $selectedTrophy, content: TrophyDetailSheet.init)
    }
}
