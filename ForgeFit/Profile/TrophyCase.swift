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
    /// "182/250" progress caption while locked.
    let progress: String?
}

enum TrophyCatalog {
    struct Inputs {
        let completedWorkouts: Int
        let totalSets: Int
        let totalDistanceMeters: Double
        let lifetimeHours: Double
        let longestStreakWeeks: Int
        let recordCount: Int
    }

    static func trophies(_ inputs: Inputs) -> [Trophy] {
        var list: [Trophy] = []

        func tier(_ id: String, _ title: String, _ icon: String, value: Int, threshold: Int) {
            list.append(Trophy(
                id: "\(id)-\(threshold)",
                title: title,
                icon: icon,
                achieved: value >= threshold,
                progress: value >= threshold ? nil : "\(value)/\(threshold)"
            ))
        }

        tier("workouts", "First session", "hammer.fill", value: inputs.completedWorkouts, threshold: 1)
        tier("workouts", "Ten deep", "dumbbell.fill", value: inputs.completedWorkouts, threshold: 10)
        tier("workouts", "Fifty forged", "dumbbell.fill", value: inputs.completedWorkouts, threshold: 50)
        tier("workouts", "Century club", "trophy.fill", value: inputs.completedWorkouts, threshold: 100)
        tier("workouts", "250 sessions", "crown.fill", value: inputs.completedWorkouts, threshold: 250)

        tier("streak", "4-week streak", "flame.fill", value: inputs.longestStreakWeeks, threshold: 4)
        tier("streak", "8-week streak", "flame.fill", value: inputs.longestStreakWeeks, threshold: 8)
        tier("streak", "12-week streak", "flame.fill", value: inputs.longestStreakWeeks, threshold: 12)
        tier("streak", "Half-year streak", "flame.circle.fill", value: inputs.longestStreakWeeks, threshold: 26)

        tier("sets", "1,000 sets", "checklist.checked", value: inputs.totalSets, threshold: 1000)
        tier("sets", "5,000 sets", "checklist.checked", value: inputs.totalSets, threshold: 5000)

        let km = Int(inputs.totalDistanceMeters / 1000)
        tier("distance", "50 km covered", "point.topleft.down.to.point.bottomright.curvepath.fill", value: km, threshold: 50)
        tier("distance", "250 km covered", "map.fill", value: km, threshold: 250)

        tier("records", "5 records", "rosette", value: inputs.recordCount, threshold: 5)
        tier("records", "25 records", "medal.fill", value: inputs.recordCount, threshold: 25)

        tier("hours", "10 hours trained", "clock.fill", value: Int(inputs.lifetimeHours), threshold: 10)
        tier("hours", "100 hours trained", "clock.badge.checkmark.fill", value: Int(inputs.lifetimeHours), threshold: 100)

        return list
    }
}

struct TrophyCaseCard: View {
    @Environment(\.theme) private var theme
    let trophies: [Trophy]

    private var earnedCount: Int { trophies.filter(\.achieved).count }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Text("\(earnedCount) of \(trophies.count) earned")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: 3), spacing: Space.md) {
                    // Earned first — the case leads with what's been won.
                    ForEach(trophies.sorted { $0.achieved && !$1.achieved }) { trophy in
                        VStack(spacing: 5) {
                            Image(systemName: trophy.icon)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(trophy.achieved ? theme.accent : theme.textTertiary)
                                .frame(width: 46, height: 46)
                                .background(
                                    Circle().fill(trophy.achieved ? theme.accent.opacity(0.16) : theme.surfaceElevated)
                                )
                            Text(trophy.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(trophy.achieved ? theme.textPrimary : theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            if let progress = trophy.progress {
                                Text(progress)
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .opacity(trophy.achieved ? 1 : 0.72)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(trophy.title): \(trophy.achieved ? "earned" : "locked, \(trophy.progress ?? "")")")
                    }
                }
            }
        }
    }
}
