import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

struct TrainingLoadCalculatorTests {
    private let userID = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func missingWholeSessionCR10FallsBackToStrengthAndCardioComponents() {
        let start = date(daysAgo: 1)
        let set = SetModel(
            userID: userID,
            setType: .working,
            reps: 8,
            weight: 100,
            rpe: 10,
            completedAt: start.addingTimeInterval(600)
        )
        let cardio = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            durationSeconds: 3_600,
            hrZoneSeconds: [0, 0, 0, 0, 3_600],
            effort: 9,
            tss: 500
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Mixed",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [set])],
            cardioSessions: [cardio]
        )

        let estimate = calculator([]).sessionEstimate(workout)

        #expect(abs(estimate.strength - 50.75) < 0.001)
        #expect(estimate.cardio == 540)
        #expect(estimate.effortWasEstimated)
    }

    @Test func wholeSessionCR10UsesDurationTimesRatingForStrength() {
        let workout = strength(daysAgo: 1, minutes: 70, cr10: 8)

        let estimate = calculator([]).sessionEstimate(workout)

        #expect(estimate.strength == 560)
        #expect(estimate.cardio == 0)
        #expect(!estimate.effortWasEstimated)
        #expect(TrainingLoadCalculator.methodID == "hybrid_session_load_v3")
    }

    @Test func wholeSessionCR10UsesOneDoseForCardio() {
        let workout = cardio(daysAgo: 1, minutes: 45, cr10: 4)

        let estimate = calculator([]).sessionEstimate(workout)

        #expect(estimate.cardio == 180)
        #expect(estimate.strength == 0)
    }

    @Test func mixedWorkoutIsNeverDoubleCountedAcrossModalities() {
        let workout = strength(daysAgo: 1, minutes: 60, cr10: 7)
        workout.cardioSessions = [
            CardioSessionModel(
                userID: userID,
                modality: "run",
                startedAt: workout.startedAt,
                endedAt: workout.endedAt,
                durationSeconds: 3_600
            ),
        ]

        let estimate = calculator([]).sessionEstimate(workout)

        #expect(estimate.total == 420)
        #expect(estimate.strength == 420)
        #expect(estimate.cardio == 0)
    }

    @Test func comparisonWaitsForSixCompletePriorWeeks() {
        let workouts = [
            cardio(daysAgo: 1, minutes: 60, cr10: 5),
            cardio(daysAgo: 34, minutes: 60, cr10: 5),
        ]

        let comparison = calculator(workouts).comparison()

        #expect(comparison.state == .building)
        #expect(comparison.baselineWeekCount < 6)
        #expect(comparison.ratio == nil)
    }

    @Test func comparisonUsesSixNonOverlappingCompleteWeeksAndMedian() throws {
        let baselineAges = [13, 20, 27, 34, 41, 48]
        let baseline = baselineAges.map { cardio(daysAgo: $0, minutes: 60, cr10: 5) }
        let recent = cardio(daysAgo: 1, minutes: 60, cr10: 5)

        let comparison = calculator(baseline + [recent]).comparison()

        #expect(comparison.state == .ready)
        #expect(comparison.baselineWeekCount == 6)
        #expect(comparison.recentLoad == 300)
        #expect(comparison.baselineWeeklyLoad == 300)
        #expect(try #require(comparison.ratio) == 1)
        #expect(comparison.baselineIQRLower == 300)
        #expect(comparison.baselineIQRUpper == 300)
    }

    @Test func unratedHistoryUsesAnExplicitlyEstimatedFallback() {
        let rated = cardio(daysAgo: 1, minutes: 60, cr10: 5)
        let unrated = cardio(daysAgo: 2, minutes: 60, cr10: nil)

        let calculator = calculator([rated, unrated])

        #expect(calculator.dailyLoads(days: 3) == [0, 300, 360])
        #expect(calculator.comparison().recentSessionCount == 2)
        #expect(calculator.comparison().estimatedEffortSessionCount == 1)
    }

    @Test func setRPEThenRIRThenNeutralDefaultResolveStrengthEffort() {
        let start = date(daysAgo: 1)
        let sets = [
            SetModel(userID: userID, setType: .working, reps: 8, rpe: 8, completedAt: start),
            SetModel(userID: userID, setType: .working, reps: 8, rir: 2, completedAt: start),
            SetModel(userID: userID, setType: .working, reps: 8, completedAt: start),
        ]
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: sets)]
        )

        let estimate = calculator([]).sessionEstimate(workout)

        // RPE 8 and RIR 2 each anchor at 35; the neutral RPE 6 fallback is 24.5.
        #expect(abs(estimate.strength - 94.5) < 0.001)
        #expect(estimate.effortWasEstimated)
    }

    @Test func cardioZonesBeatTheNeutralFallbackWhenSessionEffortIsMissing() {
        let start = date(daysAgo: 1)
        let session = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            durationSeconds: 3_600,
            hrZoneSeconds: [0, 1_800, 0, 0, 1_800]
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Intervals",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            cardioSessions: [session]
        )

        let estimate = calculator([]).sessionEstimate(workout)

        // Half Z2 (effort 4), half Z5 (effort 9): 60 × 6.5.
        #expect(estimate.cardio == 390)
        #expect(estimate.effortWasEstimated)
    }

    @Test func detailLessHealthStrengthImportRequiresAnEffortSignal() {
        let start = date(daysAgo: 1)
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            hkWorkoutUUID: UUID(),
            sourceDevice: "healthkit-fitness"
        )

        let estimate = calculator([]).sessionEstimate(workout)

        #expect(estimate.total == 0)
        #expect(!estimate.effortWasEstimated)
    }

    @Test func detailLessHealthStrengthImportUsesMeasuredHeartRate() {
        let start = date(daysAgo: 1)
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            hkWorkoutUUID: UUID(),
            sourceDevice: "healthkit-fitness",
            avgHR: 150
        )

        let estimate = calculator([]).sessionEstimate(workout)

        #expect(estimate.strength > 0)
        #expect(estimate.effortWasEstimated)
    }

    @Test func duplicateHealthUUIDCountsOnce() {
        let healthUUID = UUID()
        let start = date(daysAgo: 1)
        let duplicate = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            hkWorkoutUUID: healthUUID,
            sourceDevice: "healthkit-fitness"
        )
        let detailed = strength(daysAgo: 1, minutes: 60, cr10: 7)
        detailed.hkWorkoutUUID = healthUUID

        let calculator = calculator([duplicate, detailed])

        #expect(calculator.completedWorkouts.count == 1)
        #expect(calculator.sessionEstimate(calculator.completedWorkouts[0]).total == 420)
    }

    private func calculator(_ workouts: [WorkoutModel]) -> TrainingLoadCalculator {
        TrainingLoadCalculator(workouts: workouts, calendar: calendar, now: now)
    }

    private func cardio(daysAgo: Int, minutes: Int, cr10: Double?) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let end = start.addingTimeInterval(Double(minutes * 60))
        let workout = WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: start,
            endedAt: end,
            cardioSessions: [
                CardioSessionModel(
                    userID: userID,
                    modality: "run",
                    startedAt: start,
                    endedAt: end,
                    durationSeconds: minutes * 60
                ),
            ]
        )
        workout.wholeSessionRPE = cr10
        return workout
    }

    private func strength(daysAgo: Int, minutes: Int, cr10: Double?) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let set = SetModel(
            userID: userID,
            setType: .working,
            reps: 8,
            weight: 100,
            completedAt: start.addingTimeInterval(600)
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength",
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(minutes * 60)),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [set])]
        )
        workout.wholeSessionRPE = cr10
        return workout
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }
}
