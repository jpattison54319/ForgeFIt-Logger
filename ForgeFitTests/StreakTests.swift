import Testing
import Foundation
import ForgeCore
import ForgeData
@testable import ForgeFit

/// Streak math drives both the Profile stat and the streak-protection nudge —
/// pinned here with a fixed clock.
@MainActor
struct StreakTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func workout(daysAgo: Int) -> WorkoutModel {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return WorkoutModel(userID: userID, startedAt: start, endedAt: start.addingTimeInterval(3600))
    }

    private func analytics(_ workouts: [WorkoutModel]) -> TrainingAnalytics {
        TrainingAnalytics(workouts: workouts, exercises: [], now: now)
    }

    @Test func noWorkoutsMeansNoStreak() {
        #expect(analytics([]).currentStreak() == 0)
    }

    @Test func consecutiveDaysCount() {
        let a = analytics([workout(daysAgo: 0), workout(daysAgo: 1), workout(daysAgo: 2)])
        #expect(a.currentStreak() == 3)
        #expect(a.trainedToday())
    }

    @Test func streakSurvivesUntilTodayEnds() {
        // Trained yesterday and the day before, not yet today: the streak is
        // alive at 2 (today isn't over) — exactly the nudge scenario.
        let a = analytics([workout(daysAgo: 1), workout(daysAgo: 2)])
        #expect(a.currentStreak() == 2)
        #expect(!a.trainedToday())
    }

    @Test func gapBreaksStreak() {
        let a = analytics([workout(daysAgo: 0), workout(daysAgo: 2), workout(daysAgo: 3)])
        #expect(a.currentStreak() == 1)
    }

    @Test func twoDayOldWorkoutIsNoStreak() {
        let a = analytics([workout(daysAgo: 2), workout(daysAgo: 3)])
        #expect(a.currentStreak() == 0)
    }

    @Test func multipleWorkoutsSameDayCountOnce() {
        let a = analytics([workout(daysAgo: 0), workout(daysAgo: 0), workout(daysAgo: 1)])
        #expect(a.currentStreak() == 2)
    }

    @Test func discardedWorkoutsDoNotCount() {
        let discarded = workout(daysAgo: 0)
        discarded.deletedAt = now
        let a = analytics([discarded, workout(daysAgo: 1)])
        #expect(a.currentStreak() == 1)
        #expect(!a.trainedToday())
    }
}
