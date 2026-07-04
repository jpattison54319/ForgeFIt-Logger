import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct RecoveryScoresTests {
    private let userID = ForgeFitDemo.userID
    private let calendar = Calendar.current
    /// Fixed "now": some morning at 10:00 local time.
    private var now: Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
    }

    // MARK: - Calendar-day regression (the "trained yesterday shows today" bug)

    @Test func workoutLastNightCountsAsYesterdayNotToday() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        // Trained yesterday at 20:00 — only 14 hours ago, but one calendar day.
        let trainedAt = calendar.startOfDay(for: now).addingTimeInterval(-4 * 3600)
        let workout = strengthWorkout(startedAt: trainedAt, exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()

        #expect(report.daysSinceLast == 1)
        #expect(report.muscleFreshness.first { $0.muscle == "chest" }?.daysAgo == 1)
        #expect(!report.reasonChips.contains { $0.text == "Trained today" })
        let chest = report.recovery.muscles.first { $0.muscle == "chest" }
        #expect(chest?.lastTrainedDaysAgo == 1)
    }

    // MARK: - Muscle recovery curve

    @Test func hardSessionYesterdayLeavesMusclePartiallyRecovered() throws {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 9)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()
        let chest = try #require(report.recovery.muscles.first { $0.muscle == "chest" })
        let score = try #require(chest.state.value)

        #expect(score > 0.55 && score < 0.9)
        #expect(chest.readyInHours != nil)
    }

    @Test func muscleIsReadyAgainAfterThreeDays() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-72 * 3600), exercise: bench, sets: 8, rpe: 9)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()
        let score = report.recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 0

        #expect(score >= 0.9)
    }

    @Test func trainingTodayScoresLowerThanTrainingYesterday() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let todayWorkout = strengthWorkout(startedAt: now.addingTimeInterval(-2 * 3600), exercise: bench, sets: 8, rpe: 9)
        let yesterdayWorkout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 9)

        let todayScore = RecoveryEngine(workouts: [todayWorkout], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 1
        let yesterdayScore = RecoveryEngine(workouts: [yesterdayWorkout], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 0

        #expect(todayScore < yesterdayScore)
    }

    @Test func rpeTenSessionRecoversSlowerThanRpeSix() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let grinder = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 10)
        let easy = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 6)

        let grinderScore = RecoveryEngine(workouts: [grinder], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 1
        let easyScore = RecoveryEngine(workouts: [easy], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 0

        #expect(grinderScore < easyScore)
        // The gap should be material, not cosmetic — RPE 10 recovery looks
        // genuinely different from RPE 6.
        #expect(easyScore - grinderScore > 0.08)
    }

    @Test func untrainedMuscleReportsNoDataInsteadOfAScore() throws {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()
        let quads = try #require(report.recovery.muscles.first { $0.muscle == "quadriceps" })

        #expect(quads.state.value == nil)
        #expect(quads.statusLabel == "No data")
    }

    // MARK: - Cardio recovery: modality matters

    @Test func hiitTaxesRecoveryMoreThanZoneTwo() {
        let hiit = cardioWorkout(startedAt: now.addingTimeInterval(-24 * 3600), minutes: 30, avgHR: 176)
        let zone2 = cardioWorkout(startedAt: now.addingTimeInterval(-24 * 3600), minutes: 60, avgHR: 125)

        let hiitScore = RecoveryEngine(workouts: [hiit], now: now).report().recovery.cardio.state.value ?? 1
        let zone2Score = RecoveryEngine(workouts: [zone2], now: now).report().recovery.cardio.state.value ?? 0

        #expect(hiitScore < zone2Score)
        #expect(zone2Score >= 0.8)   // easy work clears in about a day
    }

    @Test func cardioScoreNeedsACardioSessionFirst() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()

        #expect(report.recovery.cardio.state.value == nil)
    }

    // MARK: - Systemic score and data gating

    @Test func systemicScoreIsBuildingWithNoDataAtAll() {
        let report = RecoveryEngine(workouts: [], now: now).report()

        if case .building = report.recovery.systemic.state {
            // expected
        } else {
            Issue.record("Expected building state with no data")
        }
        // Every part should say what it needs.
        #expect(report.recovery.systemic.parts.allSatisfy { $0.state.value == nil })
    }

    @Test func lowSevenDayHRVAverageLowersSystemicScore() {
        let lowWeek = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 35)
        let normalWeek = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)

        let lowScore = RecoveryEngine(workouts: [], healthMetrics: lowWeek, now: now)
            .report().recovery.systemic.state.value ?? 1
        let normalScore = RecoveryEngine(workouts: [], healthMetrics: normalWeek, now: now)
            .report().recovery.systemic.state.value ?? 0

        #expect(lowScore < normalScore)
    }

    @Test func hrvPartRequiresBaselineBeforeScoring() {
        // Only 5 days of history: enough for a 7-day average, no baseline.
        let short = healthSeries(baselineDays: 5, baselineHRV: 50, lastSevenHRV: 50)
        let report = RecoveryEngine(workouts: [], healthMetrics: short, now: now).report()
        let hrvPart = report.recovery.systemic.parts.first { $0.name == "HRV" }

        #expect(hrvPart?.state.value == nil)
    }

    @Test func loadBalancePartRequiresTrainingHistory() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let single = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [single], exercises: [bench], now: now).report()
        let loadPart = report.recovery.systemic.parts.first { $0.name == "Load balance" }

        #expect(loadPart?.state.value == nil)

        // Six weeks of steady training → the part becomes a real score.
        let history = (0..<12).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(2 + index * 3) * 86_400), exercise: bench, sets: 4, rpe: 8)
        }
        let seasoned = RecoveryEngine(workouts: history, exercises: [bench], now: now).report()
        let seasonedPart = seasoned.recovery.systemic.parts.first { $0.name == "Load balance" }
        #expect(seasonedPart?.state.value != nil)
    }

    // MARK: - Confidence reflects data completeness

    /// The reported bug: confidence read 100% even when a signal (sleep) was
    /// missing, because the old formula only graded the signals that were
    /// present. Missing sleep must now pull confidence below full.
    @Test func confidenceDropsWhenSleepIsMissing() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let history = (0..<12).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(2 + index * 3) * 86_400),
                            exercise: bench, sets: 5, rpe: 8)
        }
        let full = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)
        let noSleep = full.map { metric -> RecoveryEngine.DailyHealthMetric in
            var copy = metric
            copy.sleepTotalMinutes = nil
            return copy
        }

        let fullReport = RecoveryEngine(workouts: history, exercises: [bench], healthMetrics: full, now: now).report()
        let noSleepReport = RecoveryEngine(workouts: history, exercises: [bench], healthMetrics: noSleep, now: now).report()

        #expect(noSleepReport.confidence < 1)
        #expect(noSleepReport.confidence < fullReport.confidence)
    }

    @Test func confidenceIsHighWithCompleteData() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let history = (0..<12).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(2 + index * 3) * 86_400),
                            exercise: bench, sets: 5, rpe: 8)
        }
        let full = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)

        let report = RecoveryEngine(workouts: history, exercises: [bench], healthMetrics: full, now: now).report()
        #expect(report.confidence >= 0.85)
    }

    @Test func confidenceIsLowWithNoData() {
        let report = RecoveryEngine(workouts: [], now: now).report()
        #expect(report.confidence <= 0.2)
    }

    // MARK: - Score/action consistency (green ring must never say "Deload")

    @Test func actionAgreesWithTheDisplayedScore() {
        // Engineer the old failure: daily identical training for 4 weeks
        // (monotony) plus a monster session today (load spike + trained
        // today) crushed the legacy composite, while healthy biometrics keep
        // the systemic score green.
        let bench = exercise("Bench Press", muscles: ["chest"])
        var workouts = (1...28).map { day in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(day) * 86_400), exercise: bench, sets: 3, rpe: 7)
        }
        workouts.append(strengthWorkout(startedAt: now.addingTimeInterval(-2 * 3600), exercise: bench, sets: 12, rpe: 9))
        let health = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)

        let report = RecoveryEngine(workouts: workouts, exercises: [bench], healthMetrics: health, now: now).report()

        // The displayed score is healthy…
        #expect(report.displayScore >= 0.55)
        // …so the headline action must not contradict it with a deload call.
        #expect(report.action != .deloadRecover)
    }

    @Test func deloadStillFiresWhenTheDisplayedScoreIsActuallyLow() {
        // No biometrics at all → systemic is building → the legacy composite
        // IS the displayed score, and a giant spike should still deload.
        let spike = WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: now.addingTimeInterval(-3600),
            endedAt: now,
            cardioSessions: [
                CardioSessionModel(
                    userID: userID,
                    modality: "run",
                    startedAt: now.addingTimeInterval(-3600),
                    endedAt: now,
                    durationSeconds: 7_200,
                    effort: 9
                )
            ]
        )

        let report = RecoveryEngine(workouts: [spike], now: now).report()

        #expect(report.displayScore < 0.45)
        #expect(report.action == .deloadRecover)
    }

    // MARK: - Fixtures

    private func exercise(_ name: String, muscles: [String]) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: UUID(),
            name: name,
            movementPattern: nil,
            primaryMuscles: muscles,
            equipment: "barbell"
        )
    }

    private func strengthWorkout(startedAt: Date, exercise: ExerciseLibraryModel, sets: Int, rpe: Double) -> WorkoutModel {
        let workoutSets = (0..<sets).map { position in
            SetModel(
                userID: userID,
                position: position,
                setType: .working,
                reps: 8,
                weight: 100,
                rpe: rpe,
                completedAt: startedAt.addingTimeInterval(Double(position) * 180)
            )
        }
        let we = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: workoutSets)
        let workout = WorkoutModel(
            userID: userID,
            title: exercise.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_600),
            exercises: [we]
        )
        workout.recomputeTotalVolume()
        return workout
    }

    private func cardioWorkout(startedAt: Date, minutes: Int, avgHR: Int) -> WorkoutModel {
        let cardio = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(minutes * 60)),
            durationSeconds: minutes * 60,
            avgHR: avgHR
        )
        return WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(minutes * 60)),
            cardioSessions: [cardio]
        )
    }

    /// `baselineDays` of history at `baselineHRV`, with the last 7 days
    /// (including today) at `lastSevenHRV`.
    private func healthSeries(baselineDays: Int, baselineHRV: Double, lastSevenHRV: Double) -> [RecoveryEngine.DailyHealthMetric] {
        (0..<baselineDays).map { day in
            RecoveryEngine.DailyHealthMetric(
                date: now.addingTimeInterval(-Double(day) * 86_400),
                hrvSDNN: day < 7 ? lastSevenHRV : baselineHRV,
                restingHR: 55,
                sleepTotalMinutes: 480
            )
        }
    }
}
