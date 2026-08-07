import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct DailyStrainEngineTests {
    private let userID = ForgeFitDemo.userID
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func sameTimeMovementPercentileRaisesStrain() throws {
        let usual = activityHistory(todayComparableSteps: 5_000, todayFullSteps: 5_000)
        let active = activityHistory(todayComparableSteps: 12_000, todayFullSteps: 12_000)

        let usualReport = engine(activity: usual).report()
        let activeReport = engine(activity: active).report()

        #expect(try #require(activeReport.score) > #require(usualReport.score) + 1.5)
        #expect(activeReport.coverage == 1)
    }

    @Test func fullDayStepTotalsDoNotChangeSameClockComparison() {
        let lowFullDay = activityHistory(todayComparableSteps: 5_000, todayFullSteps: 5_000)
        let highFullDay = activityHistory(todayComparableSteps: 5_000, todayFullSteps: 20_000)

        let low = engine(activity: lowFullDay).report()
        let high = engine(activity: highFullDay).report()

        #expect(low.score == high.score)
        #expect(low.movementRatio == high.movementRatio)
    }

    @Test func ratedWorkoutRaisesTrainingPercentile() throws {
        let activity = activityHistory(todayComparableSteps: 5_000, todayFullSteps: 5_000)
        let before = engine(activity: activity).report()
        let after = engine(
            workouts: [workout(daysAgo: 0, durationMinutes: 60, cr10: 8)],
            activity: activity
        ).report()

        #expect(try #require(after.score) > #require(before.score) + 2)
        #expect(after.workoutLoad == 480)
    }

    @Test func unratedWorkoutUsesEstimatedTrainingLoad() {
        let report = engine(
            workouts: [workout(daysAgo: 0, durationMinutes: 60, cr10: nil)],
            activity: activityHistory(todayComparableSteps: 5_000, todayFullSteps: 5_000)
        ).report()

        #expect(report.workoutLoad == 360)
        #expect(report.workoutRatio != nil)
        #expect(report.workoutLoadWasEstimated)
        #expect(report.coverage == 1)
    }

    @Test func recoveryNeverMovesStrainOrUsualRange() {
        let activity = activityHistory(todayComparableSteps: 7_000, todayFullSteps: 7_000)
        let low = DailyStrainEngine(
            workouts: [],
            activityMetrics: activity,
            dailyReadiness: 0.2,
            trendRecovery: 0.2,
            calendar: calendar,
            now: now
        ).report()
        let high = DailyStrainEngine(
            workouts: [],
            activityMetrics: activity,
            dailyReadiness: 1,
            trendRecovery: 1,
            calendar: calendar,
            now: now
        ).report()

        #expect(low.score == high.score)
        #expect(low.targetRange == high.targetRange)
    }

    @Test func statusIsFullyDeterminedByScoreAndUsualRange() {
        typealias Report = DailyStrainEngine.Report
        #expect(Report.status(score: nil, targetRange: nil) == .building)
        #expect(Report.status(score: 4.0, targetRange: nil) == .targetBuilding)
        #expect(Report.status(score: 3.9, targetRange: 4.0...6.0) == .belowTarget)
        #expect(Report.status(score: 5.0, targetRange: 4.0...6.0) == .inTarget)
        #expect(Report.status(score: 6.1, targetRange: 4.0...6.0) == .aboveTarget)
    }

    @Test func shortHistoryDoesNotClaimAPersonalScore() {
        let today = calendar.startOfDay(for: now)
        let activity = (0...4).map { offset in
            DailyActivityMetric(
                date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                steps: 5_000,
                exerciseMinutes: 25,
                activeEnergyKcal: 350,
                comparableTimeSteps: 3_000
            )
        }

        let report = engine(activity: activity).report()

        #expect(report.score == nil)
        #expect(report.coverage == 0)
        #expect(report.status == .building)
    }

    private func engine(
        workouts: [WorkoutModel] = [],
        activity: [DailyActivityMetric]
    ) -> DailyStrainEngine {
        DailyStrainEngine(
            workouts: workouts,
            activityMetrics: activity,
            dailyReadiness: 0.80,
            trendRecovery: 0.75,
            calendar: calendar,
            now: now
        )
    }

    private func activityHistory(
        todayComparableSteps: Double,
        todayFullSteps: Double
    ) -> [DailyActivityMetric] {
        let today = calendar.startOfDay(for: now)
        var metrics = (1...28).map { day in
            DailyActivityMetric(
                date: calendar.date(byAdding: .day, value: -day, to: today)!,
                steps: 9_000,
                exerciseMinutes: 25,
                activeEnergyKcal: 350,
                comparableTimeSteps: 5_000
            )
        }
        metrics.append(DailyActivityMetric(
            date: today,
            steps: todayFullSteps,
            exerciseMinutes: 25,
            activeEnergyKcal: 350,
            comparableTimeSteps: todayComparableSteps
        ))
        return metrics
    }

    private func workout(daysAgo: Int, durationMinutes: Int, cr10: Double?) -> WorkoutModel {
        let end = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let start = end.addingTimeInterval(Double(-durationMinutes * 60))
        let workout = WorkoutModel(
            userID: userID,
            title: "Training",
            startedAt: start,
            endedAt: end,
            cardioSessions: [
                CardioSessionModel(
                    userID: userID,
                    modality: "run",
                    startedAt: start,
                    endedAt: end,
                    durationSeconds: durationMinutes * 60
                ),
            ]
        )
        workout.wholeSessionRPE = cr10
        return workout
    }
}
