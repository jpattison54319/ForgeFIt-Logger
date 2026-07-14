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

    @Test func walkingAndEverydayMovementRaiseStrain() throws {
        let usual = activityHistory(todaySteps: 5_000, todayExerciseMinutes: 25, todayEnergy: 350)
        let active = activityHistory(todaySteps: 12_000, todayExerciseMinutes: 70, todayEnergy: 800)

        let usualScore = try #require(engine(activity: usual).report().score)
        let activeScore = try #require(engine(activity: active).report().score)

        #expect(activeScore > usualScore + 1.5)
    }

    @Test func completedWorkoutRaisesStrainWithoutChangingMorningRecovery() throws {
        let activity = activityHistory(todaySteps: 5_000, todayExerciseMinutes: 25, todayEnergy: 350)
        let history = [7, 14, 21].map { day in
            workout(daysAgo: day, durationMinutes: 45, averageHeartRate: 135)
        }
        let before = engine(workouts: history, activity: activity).report()
        let after = engine(
            workouts: history + [workout(daysAgo: 0, durationMinutes: 60, averageHeartRate: 172)],
            activity: activity
        ).report()

        let beforeScore = try #require(before.score)
        let afterScore = try #require(after.score)
        #expect(afterScore > beforeScore + 2)

        let health = recoveryHistory()
        let recoveryBefore = RecoveryEngine(workouts: history, healthMetrics: health, calendar: calendar, now: now).report()
        let recoveryAfter = RecoveryEngine(
            workouts: history + [workout(daysAgo: 0, durationMinutes: 60, averageHeartRate: 172)],
            healthMetrics: health,
            calendar: calendar,
            now: now
        ).report()
        #expect(abs(recoveryBefore.displayScore - recoveryAfter.displayScore) < 0.0001)
    }

    @Test func targetUsesBothDailyReadinessAndRecoveryTrend() throws {
        let activity = activityHistory(todaySteps: 5_000, todayExerciseMinutes: 25, todayEnergy: 350)
        let strong = DailyStrainEngine(
            workouts: [], activityMetrics: activity,
            dailyReadiness: 0.90, trendRecovery: 0.90,
            calendar: calendar, now: now
        ).report()
        let lowDaily = DailyStrainEngine(
            workouts: [], activityMetrics: activity,
            dailyReadiness: 0.35, trendRecovery: 0.90,
            calendar: calendar, now: now
        ).report()
        let lowTrend = DailyStrainEngine(
            workouts: [], activityMetrics: activity,
            dailyReadiness: 0.90, trendRecovery: 0.35,
            calendar: calendar, now: now
        ).report()

        let strongTarget = try #require(strong.targetMidpoint)
        let lowDailyTarget = try #require(lowDaily.targetMidpoint)
        let lowTrendTarget = try #require(lowTrend.targetMidpoint)
        #expect(strongTarget > lowDailyTarget)
        #expect(strongTarget > lowTrendTarget)
        // Daily readiness intentionally has more influence than the trend.
        #expect(lowDailyTarget < lowTrendTarget)
    }

    @Test func perfectRecoveryCannotRaiseTargetMoreThanTwentyPercentAboveNorm() throws {
        let report = DailyStrainEngine(
            workouts: [],
            activityMetrics: activityHistory(todaySteps: 5_000, todayExerciseMinutes: 25, todayEnergy: 350),
            dailyReadiness: 1,
            trendRecovery: 1,
            calendar: calendar,
            now: now
        ).report()
        let midpoint = try #require(report.targetMidpoint)
        // Perfect recovery centers the target band on a 1.20× ratio. The
        // display curve is concave, so the band's score midpoint sits just
        // BELOW score(1.20) — the cap holds; equality would be a curve
        // identity no concave mapping can satisfy.
        #expect(midpoint <= DailyStrainEngine.score(forLoadRatio: 1.20))
        #expect(midpoint > DailyStrainEngine.score(forLoadRatio: 1.08))
    }

    @Test func shortMovementHistoryDoesNotClaimAPersonalScore() {
        let today = calendar.startOfDay(for: now)
        let activity = (0...4).map { offset in
            DailyActivityMetric(
                date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                steps: 5_000,
                exerciseMinutes: 25,
                activeEnergyKcal: 350
            )
        }
        let report = engine(activity: activity).report()

        #expect(report.score == nil)
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
        todaySteps: Double,
        todayExerciseMinutes: Double,
        todayEnergy: Double
    ) -> [DailyActivityMetric] {
        let today = calendar.startOfDay(for: now)
        var metrics = (1...28).map { day in
            DailyActivityMetric(
                date: calendar.date(byAdding: .day, value: -day, to: today)!,
                steps: 5_000,
                exerciseMinutes: 25,
                activeEnergyKcal: 350
            )
        }
        metrics.append(DailyActivityMetric(
            date: today,
            steps: todaySteps,
            exerciseMinutes: todayExerciseMinutes,
            activeEnergyKcal: todayEnergy
        ))
        return metrics
    }

    /// A workout shaped like the app actually produces one: load math zeroes
    /// bare local shells (no sets, no cardio, not imported), so the fixture
    /// carries a cardio session and lets effort resolve from the workout HR.
    private func workout(daysAgo: Int, durationMinutes: Int, averageHeartRate: Int) -> WorkoutModel {
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let session = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: start.addingTimeInterval(Double(-durationMinutes * 60)),
            endedAt: start,
            durationSeconds: durationMinutes * 60
        )
        return WorkoutModel(
            userID: userID,
            title: "Training",
            startedAt: start.addingTimeInterval(Double(-durationMinutes * 60)),
            endedAt: start,
            avgHR: averageHeartRate,
            cardioSessions: [session]
        )
    }

    private func recoveryHistory() -> [RecoveryEngine.DailyHealthMetric] {
        let today = calendar.startOfDay(for: now)
        return (0...30).map { day in
            RecoveryEngine.DailyHealthMetric(
                date: calendar.date(byAdding: .day, value: -day, to: today)!,
                hrvSDNN: nil,
                restingHR: nil,
                sleepTotalMinutes: 480,
                source: "test",
                hrvSampleCount: 5,
                nocturnalHRV: 70,
                sleepingHR: 55
            )
        }
    }
}
