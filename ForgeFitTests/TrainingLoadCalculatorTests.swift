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

    @Test func comparisonWaitsForTwentyEightCompletePriorDays() {
        let workouts = [
            cardio(daysAgo: 1, minutes: 60, effort: 5),
            cardio(daysAgo: 20, minutes: 60, effort: 5),
        ]
        let comparison = calculator(workouts).comparison()

        #expect(comparison.state == .building)
        #expect(comparison.baselineDaysAvailable == 14)
        #expect(comparison.baselineDaysRemaining == 14)
        #expect(comparison.ratio == nil)
    }

    @Test func readyComparisonUsesThePrecedingNonOverlappingTwentyEightDays() throws {
        let baseline = [7, 14, 21, 28, 34].map {
            cardio(daysAgo: $0, minutes: 60, effort: 5)
        }
        let recent = cardio(daysAgo: 1, minutes: 60, effort: 5)
        let comparison = calculator(baseline + [recent]).comparison()

        #expect(comparison.state == .ready)
        #expect(comparison.baselineDaysAvailable == 28)
        #expect(abs(comparison.recentLoad - 300) < 0.001)
        #expect(abs(comparison.baselineWeeklyLoad - 375) < 0.001)
        #expect(abs(try #require(comparison.ratio) - 0.8) < 0.001)
    }

    @Test func completeHistoryWithNoPriorFourWeekLoadDoesNotInventARatio() {
        let old = cardio(daysAgo: 40, minutes: 60, effort: 5)
        let recent = cardio(daysAgo: 1, minutes: 60, effort: 5)
        let comparison = calculator([old, recent]).comparison()

        #expect(comparison.state == .noRecentLoad)
        #expect(comparison.baselineDaysAvailable == 28)
        #expect(comparison.ratio == nil)
    }

    @Test func aNearEmptyBaselineIsSparseNotASpike() {
        // One light 20-minute session in the whole prior month: an honest app
        // says "too light to compare", not "+900% spike".
        let span = cardio(daysAgo: 40, minutes: 20, effort: 4)
        let lonely = cardio(daysAgo: 20, minutes: 20, effort: 4)
        let recent = cardio(daysAgo: 1, minutes: 60, effort: 8)
        let comparison = calculator([span, lonely, recent]).comparison()

        #expect(comparison.state == .sparseBaseline)
        #expect(comparison.baselineDaysAvailable == 28)
        #expect(abs(comparison.baselineWeeklyLoad - 20) < 0.001)
        #expect(comparison.ratio == nil)
    }

    /// Calibration golden: a canonical fully logged hypertrophy session
    /// (16 straight sets at RPE 8 in ~70 minutes) lands on the same scale a
    /// detail-less imported strength workout estimates from duration, so
    /// set-based and minute-based load stay commensurate.
    @Test func fullyLoggedStrengthLandsOnTheImportedDurationScale() {
        let start = date(daysAgo: 1)
        let sets = (0..<16).map { index in
            SetModel(
                userID: userID,
                position: index,
                setType: .working,
                reps: 8,
                weight: 100,
                rpe: 8,
                completedAt: start.addingTimeInterval(Double(index) * 240)
            )
        }
        let detailed = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(70 * 60),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: sets)]
        )
        let imported = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(70 * 60),
            hkWorkoutUUID: UUID(),
            sourceDevice: "healthkit-fitness"
        )
        let estimator = calculator([])

        // 16 sets × 35 points × weight(RPE 8) = 560, all strength.
        let detailedEstimate = estimator.sessionEstimate(detailed)
        #expect(abs(detailedEstimate.strength - 560) < 0.001)
        #expect(!detailedEstimate.effortWasEstimated)
        // 70 min × neutral effort 6 = 420 — same order of magnitude, and
        // honestly labeled as estimated.
        let importedEstimate = estimator.sessionEstimate(imported)
        #expect(abs(importedEstimate.strength - 420) < 0.001)
        #expect(importedEstimate.effortWasEstimated)
    }

    @Test func unloggedStrengthEffortFollowsTheFailureConvention() {
        let workout = strengthWorkout(daysAgo: 1, minutes: 60, setCount: 10, rpe: nil)

        // Failure training on: an unlogged completed working set IS RPE 10 —
        // the same convention WorkoutEffortPolicy stamps at finish. It is the
        // user's declared convention, not an estimate.
        let failureMode = calculator([], assumesFailure: true).sessionEstimate(workout)
        #expect(abs(failureMode.strength - 10 * 35 * 1.45) < 0.001)
        #expect(!failureMode.effortWasEstimated)

        // Failure training off: neutral default, flagged as estimated.
        let neutralMode = calculator([]).sessionEstimate(workout)
        #expect(abs(neutralMode.strength - 10 * 35 * 0.7) < 0.001)
        #expect(neutralMode.effortWasEstimated)
    }

    /// The bug that maxed the Home gauge: imported baseline history carries
    /// nil efforts while freshly finished workouts carry stamped RPE 10s.
    /// Under failure mode both must produce identical load, or the ratio
    /// inflates by convention mismatch alone.
    @Test func importedNilEffortBaselineMatchesStampedRecentUnderFailureMode() {
        let nilEfforts = strengthWorkout(daysAgo: 10, minutes: 60, setCount: 12, rpe: nil)
        let stamped = strengthWorkout(daysAgo: 1, minutes: 60, setCount: 12, rpe: 10)
        let estimator = calculator([], assumesFailure: true)

        let baseline = estimator.sessionEstimate(nilEfforts)
        let recent = estimator.sessionEstimate(stamped)
        #expect(abs(baseline.total - recent.total) < 0.001)
    }

    @Test func intensityTechniquesCarryTheirExtraFatigue() {
        let start = date(daysAgo: 1)
        let straight = SetModel(
            userID: userID,
            setType: .working,
            reps: 8,
            weight: 100,
            rpe: 8,
            completedAt: start.addingTimeInterval(300)
        )
        let myoRep = SetModel(
            userID: userID,
            position: 1,
            setType: .myoRep,
            reps: 12,
            weight: 60,
            completedAt: start.addingTimeInterval(600)
        )
        myoRep.miniReps = [3, 3, 2]
        let drop = SetModel(
            userID: userID,
            position: 2,
            setType: .drop,
            reps: 10,
            weight: 40,
            rpe: 8,
            completedAt: start.addingTimeInterval(900)
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength",
            startedAt: start,
            endedAt: start.addingTimeInterval(30 * 60),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [straight, myoRep, drop])]
        )

        let estimate = calculator([], assumesFailure: true).sessionEstimate(workout)
        // Straight RPE 8: 1.0 × 35 × 1.0 = 35.
        // Myo-rep, unlogged → failure: (1 + 0.5×3) × 35 × 1.45 = 126.875.
        // Drop at RPE 8: 0.5 × 35 × 1.0 = 17.5.
        #expect(abs(estimate.strength - (35 + 126.875 + 17.5)) < 0.001)
    }

    @Test func intervalCardioLoadsFromTimeInZonesNotTheAverage() {
        let start = date(daysAgo: 1)
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            endedAt: start.addingTimeInterval(3600),
            durationSeconds: 3600,
            hrZoneSeconds: [0, 1800, 0, 0, 1800]
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(3600),
            cardioSessions: [session]
        )

        let estimate = calculator([]).sessionEstimate(workout)
        // Half the hour in Z2 (effort 4), half in Z5 (effort 9): 60 × 6.5.
        // An average-HR read would have filed the whole session in one zone.
        #expect(abs(estimate.cardio - 390) < 0.001)
        #expect(estimate.effortWasEstimated)
    }

    @Test func loggedSessionEffortBeatsZonesAndTSS() {
        let start = date(daysAgo: 1)
        func workout(tss: Double) -> WorkoutModel {
            let session = CardioSessionModel(
                userID: userID,
                modality: CardioKind.run.rawValue,
                startedAt: start,
                endedAt: start.addingTimeInterval(45 * 60),
                durationSeconds: 45 * 60,
                effort: 4,
                tss: tss
            )
            return WorkoutModel(
                userID: userID,
                startedAt: start,
                endedAt: start.addingTimeInterval(45 * 60),
                cardioSessions: [session]
            )
        }
        let estimator = calculator([])

        #expect(estimator.sessionEstimate(workout(tss: 10)).total == 180)
        #expect(estimator.sessionEstimate(workout(tss: 500)).total == 180)
    }

    @Test func duplicateHealthUUIDCountsOnceAndKeepsTheRicherWorkout() {
        let healthUUID = UUID()
        let start = date(daysAgo: 1)
        let duplicate = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(60 * 60),
            hkWorkoutUUID: healthUUID,
            sourceDevice: "healthkit-fitness"
        )
        let set = SetModel(
            userID: userID,
            setType: .working,
            reps: 5,
            weight: 100,
            rpe: 8,
            completedAt: start.addingTimeInterval(1_200)
        )
        let detailed = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: start,
            endedAt: start.addingTimeInterval(60 * 60),
            hkWorkoutUUID: healthUUID,
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [set])]
        )
        let estimator = calculator([duplicate, detailed])

        #expect(estimator.completedWorkouts.count == 1)
        // The detailed record wins and is valued by its one logged set,
        // not the duplicate's duration estimate.
        #expect(abs(estimator.sessionEstimate(estimator.completedWorkouts[0]).total - 35) < 0.001)
        #expect(abs(estimator.comparison().recentLoad - 35) < 0.001)
    }

    private func calculator(
        _ workouts: [WorkoutModel],
        assumesFailure: Bool = false
    ) -> TrainingLoadCalculator {
        TrainingLoadCalculator(
            workouts: workouts,
            calendar: calendar,
            now: now,
            assumesFailureWhenUnlogged: assumesFailure
        )
    }

    private func cardio(daysAgo: Int, minutes: Int, effort: Int) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let end = start.addingTimeInterval(Double(minutes * 60))
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            endedAt: end,
            durationSeconds: minutes * 60,
            effort: effort
        )
        return WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: start,
            endedAt: end,
            cardioSessions: [session]
        )
    }

    private func strengthWorkout(
        daysAgo: Int,
        minutes: Int,
        setCount: Int,
        rpe: Double?
    ) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let sets = (0..<setCount).map { index in
            SetModel(
                userID: userID,
                position: index,
                setType: .working,
                reps: 8,
                weight: 100,
                rpe: rpe,
                completedAt: start.addingTimeInterval(Double(index + 1) * 180)
            )
        }
        return WorkoutModel(
            userID: userID,
            title: "Strength",
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(minutes * 60)),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: sets)]
        )
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }
}
