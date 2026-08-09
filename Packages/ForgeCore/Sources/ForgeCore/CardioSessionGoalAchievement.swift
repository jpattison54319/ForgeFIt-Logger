import Foundation

/// One-shot threshold state for a live cardio session goal. The UI, GPS
/// recorder, and Watch metric stream can all feed the same tracker without
/// producing duplicate celebrations when several updates arrive above target.
public struct CardioSessionGoalAchievementTracker: Equatable, Sendable {
    public let goal: IntervalPlan.SessionGoal
    public private(set) var hasReachedGoal: Bool

    public init(
        goal: IntervalPlan.SessionGoal,
        hasReachedGoal: Bool = false
    ) {
        self.goal = goal
        self.hasReachedGoal = hasReachedGoal
    }

    /// Returns true exactly once, on the first finite reading at or above the
    /// configured target. Missing/invalid readings never count as progress.
    public mutating func consume(current: Double?) -> Bool {
        guard !hasReachedGoal,
              goal.isMeaningful,
              let current,
              current.isFinite,
              current >= goal.value else { return false }
        hasReachedGoal = true
        return true
    }
}
