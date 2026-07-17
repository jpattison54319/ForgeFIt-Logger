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
        let (container, context) = try TestStore.make()

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
        _ = container   // keep models alive to the end (see TestStore.make)
    }

    @MainActor
    @Test func routineStartLoadsSavedSetupNoteWhenRoutineExerciseHasNoNote() async throws {
        let (container, context) = try TestStore.make()

        let exercise = ExerciseLibraryModel(name: "Machine Chest Press", primaryMuscles: ["chest"], equipment: "machine")
        let setupNote = UserExerciseNoteModel(
            userID: userID,
            exerciseID: exercise.id,
            note: "Keep shoulder blades pinned before the first rep."
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            position: 0,
            sets: [RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetWeight: 70)]
        )
        let routine = RoutineModel(userID: userID, name: "Full Body A", exercises: [routineExercise])

        context.insert(exercise)
        context.insert(setupNote)
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [exercise], setupNotes: [setupNote], in: context)

        #expect(workout.exercises.first?.notes == setupNote.note)
        #expect(workout.exercises.first?.notePinned == true)
        _ = container   // keep models alive to the end (see TestStore.make)
    }

    @MainActor
    @Test func routineStartPreservesRoutineExerciseNoteOverSavedSetupNote() async throws {
        let (container, context) = try TestStore.make()

        let exercise = ExerciseLibraryModel(name: "Machine Chest Press", primaryMuscles: ["chest"], equipment: "machine")
        let setupNote = UserExerciseNoteModel(userID: userID, exerciseID: exercise.id, note: "Saved setup cue")
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            position: 0,
            notes: "Routine-specific cue",
            sets: [RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetWeight: 70)]
        )
        let routine = RoutineModel(userID: userID, name: "Full Body A", exercises: [routineExercise])

        context.insert(exercise)
        context.insert(setupNote)
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [exercise], setupNotes: [setupNote], in: context)

        #expect(workout.exercises.first?.notes == "Routine-specific cue")
        #expect(workout.exercises.first?.notePinned == false)
        _ = container   // keep models alive to the end (see TestStore.make)
    }

    @Test func cardioSRPELoadFallsBackToDurationTimesEffort() {
        let workout = cardioWorkout(daysAgo: 1, minutes: 60, effort: 5)
        let report = RecoveryEngine(workouts: [workout], now: now).report()

        #expect(abs(report.acuteLoad - 300) < 0.001)
        #expect(abs(report.cardioLoad - 300) < 0.001)
        #expect(report.strengthLoad == 0)
    }

    @Test func mixedWorkoutSummaryUsesWholeWorkoutDurationNotCardioBlockDuration() {
        let startedAt = now.addingTimeInterval(-3_600)
        let completedSet = SetModel(
            userID: userID,
            reps: 10,
            weight: 50,
            completedAt: startedAt.addingTimeInterval(1_200)
        )
        let strength = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 0,
            sets: [completedSet]
        )
        let jog = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            durationSeconds: 600
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Push 2",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_000),
            exercises: [strength],
            cardioSessions: [jog]
        )

        let summary = TrainingAnalytics(workouts: [workout], exercises: []).summary(for: workout)

        #expect(summary.durationSeconds == 3_000)
        #expect(summary.hasStrength)
        #expect(summary.hasCardio)
        #expect(!summary.isCardio)
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

        #expect(abs(report.acuteLoad - 270) < 0.001)
        #expect(abs(report.strengthLoad - 270) < 0.001)
        #expect(report.cardioLoad == 0)
    }

    @Test func strengthLoadCountsCompletedSetsScaledByEffort() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(daysAgo: 1, exercise: bench, reps: 10, weight: 100, rpe: 8)
        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()

        // One working set at RPE 8 = 35 load points; a lone set in a long
        // workout no longer inherits the whole hour as load.
        #expect(abs(report.strengthLoad - 35) < 0.001)
        #expect(abs(report.acuteLoad - report.strengthLoad) < 0.001)
        #expect(report.cardioLoad == 0)
    }

    /// A single low-HRV morning scales with severity. Both examples fall below
    /// the agreed 70-ready boundary, so their global verdict is reduce volume;
    /// the deeper crash is still reflected by a much lower numeric score.
    @Test func singleLowHRVSeverityScalesTheResponse() {
        let squat = exercise("Back Squat", muscles: ["quadriceps"])
        let workouts = recurringWorkouts(exercise: squat, daysAgo: [2, 9, 16, 23])

        let mildDip = RecoveryEngine(
            workouts: workouts,
            exercises: [squat],
            healthMetrics: healthSeries(currentHRV: 46, priorLowDays: 0),
            targetMuscles: ["quadriceps"],
            now: now
        ).report()
        #expect(mildDip.action == .reduceVolume)
        #expect(mildDip.reasonChips.contains { $0.text == "HRV low today" })
        #expect(mildDip.reasonChips.contains { $0.text == "48h recovered" })

        let crash = RecoveryEngine(
            workouts: workouts,
            exercises: [squat],
            healthMetrics: healthSeries(currentHRV: 35, priorLowDays: 0),
            targetMuscles: ["quadriceps"],
            now: now
        ).report()
        #expect(crash.action == .reduceVolume)
        #expect(crash.displayScore < 0.6)   // number agrees with the action
    }

    /// When every trained muscle is recovered, the chip says so collectively —
    /// naming the single longest-rested muscle ("Triceps fresh") reads as
    /// arbitrary when the whole body is ready.
    @Test func allMusclesFreshGetsCollectiveChipNotArbitrarySingleMuscle() {
        let squat = exercise("Back Squat", muscles: ["quadriceps"])
        let curl = exercise("Curl", muscles: ["biceps"])
        let pushdown = exercise("Pushdown", muscles: ["triceps"])
        let workouts = [
            strengthWorkout(daysAgo: 3, exercise: squat, reps: 8, weight: 100, rpe: 8),
            strengthWorkout(daysAgo: 4, exercise: curl, reps: 10, weight: 20, rpe: 8),
            strengthWorkout(daysAgo: 6, exercise: pushdown, reps: 10, weight: 25, rpe: 8),
        ]
        let report = RecoveryEngine(workouts: workouts, exercises: [squat, curl, pushdown], now: now).report()

        #expect(report.reasonChips.contains { $0.text == "All muscles fresh" })
        #expect(!report.reasonChips.contains { $0.text.hasSuffix(" fresh") && $0.text != "All muscles fresh" })

        // Mixed picture: biceps trained yesterday → the named-muscle chip is
        // back, because now it is informative.
        let mixed = workouts + [strengthWorkout(daysAgo: 1, exercise: curl, reps: 10, weight: 20, rpe: 8)]
        let mixedReport = RecoveryEngine(workouts: mixed, exercises: [squat, curl, pushdown], now: now).report()
        #expect(!mixedReport.reasonChips.contains { $0.text == "All muscles fresh" })
        #expect(mixedReport.reasonChips.contains { $0.text == "Triceps fresh" })
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

    @Test func recentLoadWaitsForBaselineAndDoesNotDriveReadiness() {
        let run = cardioWorkout(daysAgo: 0, minutes: 120, effort: 9)
        let report = RecoveryEngine(workouts: [run], now: now).report()

        #expect(report.trainingLoad.state == .building)
        #expect(report.loadRatio == nil)
        #expect(report.action != .deloadRecover)
        #expect(!report.reasonChips.contains { $0.text.localizedCaseInsensitiveContains("load") })
    }

    @Test func targetMuscleTrainedYesterdayIsContextNotAnAutomaticReduction() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workouts = recurringWorkouts(exercise: bench, daysAgo: [1, 8, 15, 22])

        let report = RecoveryEngine(
            workouts: workouts,
            exercises: [bench],
            healthMetrics: healthSeries(currentHRV: 48),
            targetMuscles: ["chest"],
            now: now
        ).report()

        #expect(report.action == .trainAsPlanned)
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
        #expect(report.insights.contains { $0 == "It has been 4 days since your last workout." })
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
