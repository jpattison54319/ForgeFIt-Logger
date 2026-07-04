//
//  ForgeFitTests.swift
//  ForgeFitTests
//
//  Created by James Pattison on 6/29/26.
//

import Testing
import Foundation
import ForgeCore
import ForgeData
import SwiftData
@testable import ForgeFit

@MainActor
struct ForgeFitTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func weightUnitFormatsAndParsesCanonicalKilograms() {
        #expect(Fmt.load(100, unit: .kg) == "100")
        #expect(Fmt.load(100, unit: .lb) == "220.5")

        let parsed = Fmt.loadKilograms(from: "220.5", unit: .lb)
        #expect(abs((parsed ?? 0) - 100) < 0.05)
    }

    @MainActor
    @Test func cardioRoutineStartsAsCardioSessionWithoutStrengthSets() async throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let userID = ForgeFitDemo.userID
        let treadmill = ExerciseLibraryModel(
            name: "Treadmill Run",
            movementPattern: "cardio",
            primaryMuscles: ["cardiovascular", "quadriceps", "glutes"],
            equipment: "treadmill",
            defaultWeightMode: .bodyweight,
            isCardio: true,
            category: "cardio"
        )
        let target = RoutineSetModel(
            userID: userID,
            position: 0,
            targetDurationSeconds: 1_800
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: treadmill.id,
            position: 0,
            sets: [target]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Zone 2 Base",
            exercises: [routineExercise]
        )

        context.insert(treadmill)
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [treadmill], in: context)

        #expect(workout.exercises.count == 1)
        #expect(workout.exercises.first?.sets.isEmpty == true)
        #expect(workout.cardioSessions.count == 1)
        #expect(workout.cardioSessions.first?.modality == CardioKind.run.rawValue)
        #expect(workout.cardioSessions.first?.durationSeconds == 1_800)
    }

    @Test func cardioSRPELoadFallsBackToDurationTimesEffort() {
        let workout = cardioWorkout(daysAgo: 1, minutes: 60, effort: 5)
        let report = RecoveryEngine(workouts: [workout], now: now).report()

        #expect(abs(report.acuteLoad - 300) < 0.001)
        #expect(abs(report.cardioLoad - 300) < 0.001)
        #expect(report.strengthLoad == 0)
    }

    @Test func importedHealthStrengthWorkoutContributesModerateLoadWithoutSets() {
        let startedAt = now.addingTimeInterval(-86_400)
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength Training",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(45 * 60),
            hkWorkoutUUID: UUID(),
            sourceDevice: "healthkit-fitness",
            activeEnergyKcal: nil
        )

        let report = RecoveryEngine(workouts: [workout], now: now).report()

        #expect(abs(report.acuteLoad - 225) < 0.001)
        #expect(abs(report.strengthLoad - 225) < 0.001)
        #expect(report.cardioLoad == 0)
    }

    @Test func strengthLoadUsesTonnageAndProximityToFailure() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(daysAgo: 1, exercise: bench, reps: 10, weight: 100, rpe: 8)
        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()

        #expect(abs(report.strengthLoad - 252.9822) < 0.001)
        #expect(abs(report.acuteLoad - report.strengthLoad) < 0.001)
        #expect(report.cardioLoad == 0)
    }

    @Test func singleLowHRVAfter48HoursAllowsTrainingWithCaution() {
        let squat = exercise("Back Squat", muscles: ["quadriceps"])
        let workouts = recurringWorkouts(exercise: squat, daysAgo: [2, 9, 16, 23])
        let health = healthSeries(currentHRV: 35, priorLowDays: 0)

        let report = RecoveryEngine(
            workouts: workouts,
            exercises: [squat],
            healthMetrics: health,
            targetMuscles: ["quadriceps"],
            now: now
        ).report()

        #expect(report.action == .trainAsPlanned)
        #expect(report.reasonChips.contains { $0.text == "HRV low today" })
        #expect(report.reasonChips.contains { $0.text == "48h recovered" })
    }

    @Test func sustainedLowHRVAfter48HoursReducesVolume() {
        let squat = exercise("Back Squat", muscles: ["quadriceps"])
        let workouts = recurringWorkouts(exercise: squat, daysAgo: [2, 9, 16, 23])
        let health = healthSeries(currentHRV: 35, priorLowDays: 2)

        let report = RecoveryEngine(
            workouts: workouts,
            exercises: [squat],
            healthMetrics: health,
            targetMuscles: ["quadriceps"],
            now: now
        ).report()

        #expect(report.action == .reduceVolume)
        #expect(report.reasonChips.contains { $0.text == "HRV low trend" })
    }

    @Test func elevatedRHRPlusPoorSleepReducesVolume() {
        let run = cardioWorkout(daysAgo: 2, minutes: 40, effort: 6)
        let health = healthSeries(currentHRV: 50, currentRHR: 72, currentSleep: 330)

        let report = RecoveryEngine(workouts: [run], healthMetrics: health, now: now).report()

        #expect(report.action == .reduceVolume)
        #expect(report.reasonChips.contains { $0.text == "RHR elevated" })
        #expect(report.reasonChips.contains { $0.text == "Sleep debt" })
    }

    @Test func largeLoadSpikeDeloadsInsteadOfCallingItASweetSpot() {
        let run = cardioWorkout(daysAgo: 0, minutes: 120, effort: 9)
        let report = RecoveryEngine(workouts: [run], now: now).report()

        #expect(report.action == .deloadRecover)
        #expect(report.reasonChips.contains { $0.text == "Large load spike" })
        #expect(report.insights.contains { $0.contains("not an injury prediction") })
    }

    @Test func targetMuscleTrainedYesterdayReducesLocalVolume() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workouts = recurringWorkouts(exercise: bench, daysAgo: [1, 8, 15, 22])

        let report = RecoveryEngine(
            workouts: workouts,
            exercises: [bench],
            targetMuscles: ["chest"],
            now: now
        ).report()

        #expect(report.action == .reduceVolume)
        #expect(report.reasonChips.contains { $0.text == "Chest trained yesterday" })
    }

    @Test func fourDaysOffEasesBackInRatherThanPushingBlindly() {
        let press = exercise("Overhead Press", muscles: ["shoulders"])
        let workouts = recurringWorkouts(exercise: press, daysAgo: [4, 11, 18, 25])

        let report = RecoveryEngine(
            workouts: workouts,
            exercises: [press],
            targetMuscles: ["shoulders"],
            now: now
        ).report()

        #expect(report.action == .trainAsPlanned)
        #expect(report.reasonChips.contains { $0.text == "4d since workout" })
        #expect(report.recommendation.contains("Ease in"))
    }

    private func exercise(_ name: String, muscles: [String]) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: UUID(),
            name: name,
            movementPattern: nil,
            primaryMuscles: muscles,
            equipment: "barbell"
        )
    }

    private func strengthWorkout(daysAgo: Int, exercise: ExerciseLibraryModel, reps: Int, weight: Double, rpe: Double) -> WorkoutModel {
        let startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let endedAt = startedAt.addingTimeInterval(3_600)
        let set = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            reps: reps,
            weight: weight,
            rpe: rpe,
            completedAt: startedAt.addingTimeInterval(1_200)
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            sets: [set]
        )
        let workout = WorkoutModel(
            userID: userID,
            title: exercise.name,
            startedAt: startedAt,
            endedAt: endedAt,
            exercises: [workoutExercise]
        )
        workout.recomputeTotalVolume()
        return workout
    }

    private func recurringWorkouts(exercise: ExerciseLibraryModel, daysAgo: [Int]) -> [WorkoutModel] {
        daysAgo.map { strengthWorkout(daysAgo: $0, exercise: exercise, reps: 10, weight: 100, rpe: 8) }
    }

    private func cardioWorkout(daysAgo: Int, minutes: Int, effort: Int) -> WorkoutModel {
        let startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let endedAt = startedAt.addingTimeInterval(Double(minutes * 60))
        let cardio = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: minutes * 60,
            effort: effort
        )
        return WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: startedAt,
            endedAt: endedAt,
            cardioSessions: [cardio]
        )
    }

    private func healthSeries(
        currentHRV: Double,
        priorLowDays: Int = 0,
        currentRHR: Int = 55,
        currentSleep: Int = 480
    ) -> [RecoveryEngine.DailyHealthMetric] {
        var metrics: [RecoveryEngine.DailyHealthMetric] = []
        for day in 1...21 {
            let hrv = day <= priorLowDays ? 35.0 : 50.0
            metrics.append(RecoveryEngine.DailyHealthMetric(
                date: now.addingTimeInterval(-Double(day) * 86_400),
                hrvSDNN: hrv,
                restingHR: 55,
                sleepTotalMinutes: 480
            ))
        }
        metrics.append(RecoveryEngine.DailyHealthMetric(
            date: now,
            hrvSDNN: currentHRV,
            restingHR: currentRHR,
            sleepTotalMinutes: currentSleep
        ))
        return metrics
    }

    // MARK: - RPE quick picks

    @Test func rpeQuickPicksLeadWithWarmupThenSixToTenInHalfSteps() {
        let options = RPEQuickPick.allOptions
        #expect(options.first == .warmup)

        let numeric = options.compactMap(\.numericValue)
        #expect(numeric == [6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10])
    }

    @Test func warmupQuickPickStoresRPEFiveAndLabelsAsW() {
        #expect(RPEQuickPick.warmupRPE == 5.0)
        #expect(RPEQuickPick.warmup.rpeValue == 5.0)
        #expect(RPEQuickPick.warmup.label == "W")
    }

    @Test func numericQuickPickLabelIsValueWithoutTrailingZero() {
        #expect(RPEQuickPick.value(8).label == "8")
        #expect(RPEQuickPick.value(8.5).label == "8.5")
        #expect(RPEQuickPick.value(8).rpeValue == 8)
    }
}
