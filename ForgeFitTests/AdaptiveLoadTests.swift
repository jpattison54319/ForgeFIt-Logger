import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct AdaptiveLoadTests {
    private let userID = ForgeFitDemo.userID

    @Test func loadBasisLabelsDescribeThePrescriptionInsteadOfTheUnit() {
        #expect(LoadPrescriptionPresentation.basisSelectorLabel(for: .fixed) == "Fixed")
        #expect(LoadPrescriptionPresentation.basisSelectorLabel(for: .percentEstimatedOneRepMax) == "% e1RM")
    }

    @Test func bestEstimateUsesCompletedWorkingHistoryOnly() {
        let exerciseID = UUID()
        let valid = historyWorkout(exerciseID: exerciseID, estimate: 100)
        let stronger = historyWorkout(exerciseID: exerciseID, estimate: 120)
        let deleted = historyWorkout(exerciseID: exerciseID, estimate: 160)
        deleted.deletedAt = .now
        let unfinishedWorkout = historyWorkout(exerciseID: exerciseID, estimate: 170)
        unfinishedWorkout.endedAt = nil
        let unfinishedSet = historyWorkout(exerciseID: exerciseID, estimate: 180)
        unfinishedSet.exercises[0].sets[0].completedAt = nil
        let warmup = historyWorkout(exerciseID: exerciseID, estimate: 190, setType: .warmup)

        let best = AdaptiveLoadResolver.bestEstimatedOneRepMax(
            exerciseID: exerciseID,
            workouts: [valid, stronger, deleted, unfinishedWorkout, unfinishedSet, warmup]
        )

        #expect(best == 120)
    }

    @Test func rangeResolvesAndSnapsToTheExerciseIncrement() throws {
        let exercise = machineExercise()
        let history = historyWorkout(exerciseID: exercise.id, estimate: 100)
        let prescription = try #require(
            EstimatedOneRepMaxPrescription(lowPercent: 67, highPercent: 72)
        )

        let resolution = try #require(AdaptiveLoadResolver.resolve(
            prescription,
            exercise: exercise,
            workouts: [history]
        ))

        #expect(resolution.baselineKg == 100)
        #expect(resolution.loadLowKg == 67.5)
        #expect(resolution.loadHighKg == 72.5)
    }

    @Test func routineStartSnapshotsAdaptiveLoadAndUsesAnImprovedEstimateNextTime() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = machineExercise()
        let originalHistory = historyWorkout(exerciseID: exercise.id, estimate: 100)
        let target = RoutineSetModel(
            userID: userID,
            position: 0,
            targetRepsLow: 5,
            targetWeight: 42,
            loadPrescriptionMode: .percentEstimatedOneRepMax,
            target1RMPercentLow: 67,
            target1RMPercentHigh: 72
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            sets: [target]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Adaptive Strength",
            exercises: [routineExercise]
        )
        context.insert(exercise)
        context.insert(originalHistory)
        context.insert(routine)
        try context.save()

        let firstWorkout = WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            in: context,
            onCommit: { _ in }
        )
        let first = try #require(firstWorkout)
        let firstSet = try #require(first.exercises.first?.sets.first)
        #expect(firstSet.weight == 67.5)
        #expect(firstSet.loadPrescriptionMode == .percentEstimatedOneRepMax)
        #expect(firstSet.prescribed1RMPercentLow == 67)
        #expect(firstSet.prescribed1RMPercentHigh == 72)
        #expect(firstSet.prescribed1RMBaselineKg == 100)
        #expect(firstSet.prescribedLoadLowKg == 67.5)
        #expect(firstSet.prescribedLoadHighKg == 72.5)
        #expect(firstSet.prescribedRepsLow == 5)
        #expect(firstSet.prescribedRepsHigh == nil)
        #expect(firstSet.reps == 5)
        #expect(target.targetWeight == 42, "Resolving a workout must not rewrite the authored fixed fallback.")

        let improvedHistory = historyWorkout(exerciseID: exercise.id, estimate: 120)
        context.insert(improvedHistory)
        try context.save()

        let secondWorkout = WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            in: context,
            onCommit: { _ in }
        )
        let second = try #require(secondWorkout)
        let secondSet = try #require(second.exercises.first?.sets.first)
        #expect(secondSet.prescribed1RMBaselineKg == 120)
        #expect(secondSet.weight == 80)
        #expect(secondSet.prescribedLoadLowKg == 80)
        #expect(secondSet.prescribedLoadHighKg == 86.25)

        // Fresh-context verification proves all immutable prescription fields
        // survived the isolated WorkoutFactory commit, not merely in-memory.
        let verification = ModelContext(container)
        let secondID = second.id
        let persisted = try #require(verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == secondID }
        )).first)
        let persistedSet = try #require(persisted.exercises.first?.sets.first)
        #expect(persistedSet.loadPrescriptionMode == .percentEstimatedOneRepMax)
        #expect(persistedSet.prescribed1RMBaselineKg == 120)
        #expect(persistedSet.prescribedLoadLowKg == 80)
        #expect(persistedSet.prescribedLoadHighKg == 86.25)
        #expect(persistedSet.prescribedRepsLow == 5)
        #expect(persistedSet.prescribedRepsHigh == nil)
        #expect(persistedSet.reps == 5)
    }

    @Test func percentageRepRangeIsSnapshottedWithoutInventingPerformedReps() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = machineExercise()
        let history = historyWorkout(exerciseID: exercise.id, estimate: 100)
        let target = RoutineSetModel(
            userID: userID,
            targetRepsLow: 5,
            targetRepsHigh: 8,
            loadPrescriptionMode: .percentEstimatedOneRepMax,
            target1RMPercentLow: 82.5
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Adaptive Range",
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: exercise.id,
                sets: [target]
            )]
        )
        context.insert(exercise)
        context.insert(history)
        context.insert(routine)
        try context.save()

        let workout = try #require(WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            in: context,
            onCommit: { _ in }
        ))
        let set = try #require(workout.exercises.first?.sets.first)

        #expect(set.prescribedRepsLow == 5)
        #expect(set.prescribedRepsHigh == 8)
        #expect(set.prescribedRepTarget?.displayText == "5–8")
        #expect(set.reps == nil)
        #expect(set.requiresConcreteRepsBeforeCompletion)

        let verification = ModelContext(container)
        let workoutID = workout.id
        let persisted = try #require(verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        let persistedSet = try #require(persisted.exercises.first?.sets.first)
        #expect(persistedSet.prescribedRepsLow == 5)
        #expect(persistedSet.prescribedRepsHigh == 8)
        #expect(persistedSet.reps == nil)
        #expect(persistedSet.requiresConcreteRepsBeforeCompletion)
    }

    @Test func missingEstimateKeepsLoadBlankButPreservesPrescription() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = machineExercise()
        let target = RoutineSetModel(
            userID: userID,
            loadPrescriptionMode: .percentEstimatedOneRepMax,
            target1RMPercentLow: 82.5
        )
        let routine = RoutineModel(
            userID: userID,
            name: "No Baseline Yet",
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: exercise.id,
                sets: [target]
            )]
        )
        context.insert(exercise)
        context.insert(routine)
        try context.save()

        let startedWorkout = WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            in: context,
            onCommit: { _ in }
        )
        let workout = try #require(startedWorkout)
        let set = try #require(workout.exercises.first?.sets.first)

        #expect(set.weight == nil)
        #expect(set.loadPrescriptionMode == .percentEstimatedOneRepMax)
        #expect(set.prescribed1RMPercentLow == 82.5)
        #expect(set.prescribed1RMBaselineKg == nil)
        #expect(set.prescribedLoadLowKg == nil)
        #expect(LoadPrescriptionPresentation.liveLabel(for: set, unit: .kg)?.contains("enter load") == true)
    }

    @Test func incompletePercentageNeverFallsBackToHiddenFixedWeight() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = machineExercise()
        let target = RoutineSetModel(
            userID: userID,
            targetWeight: 42,
            loadPrescriptionMode: .percentEstimatedOneRepMax
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Incomplete Percentage",
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: exercise.id,
                sets: [target]
            )]
        )
        context.insert(exercise)
        context.insert(routine)
        try context.save()

        let startedWorkout = WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            in: context,
            onCommit: { _ in }
        )
        let workout = try #require(startedWorkout)
        let set = try #require(workout.exercises.first?.sets.first)

        #expect(set.loadPrescriptionMode == .percentEstimatedOneRepMax)
        #expect(set.estimatedOneRepMaxPrescription == nil)
        #expect(set.weight == nil)
        #expect(LoadPrescriptionPresentation.liveLabel(for: set, unit: .kg)?.contains("percentage not set") == true)
    }

    @Test func guidedEstimateStartsConservativeAuditableWorkout() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = machineExercise()
        context.insert(exercise)
        try context.save()

        let startedWorkout = WorkoutFactory.startEstimatedOneRepMaxAssessment(
            exercise: exercise,
            in: context,
            onCommit: { _ in }
        )
        let workout = try #require(startedWorkout)

        #expect(workout.title == "Estimate 1RM · Machine Press")
        #expect(workout.sourceDevice == "iphone-1rm-estimate")
        let workoutExercise = try #require(workout.exercises.first)
        #expect(workoutExercise.restSeconds == 180)
        #expect(workoutExercise.notes?.contains("3–8 clean reps") == true)
        let orderedSets = workoutExercise.sets.sorted { $0.position < $1.position }
        #expect(orderedSets.map(\.setType) == [.warmup, .warmup, .working])
        #expect(orderedSets.last?.rpe == 9)
        #expect(orderedSets.last?.rir == 1)
    }

    @Test func appIntentRoutineStartKeepsAuthoredFixedTargets() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = machineExercise()
        let target = RoutineSetModel(
            userID: userID,
            targetRepsLow: 7,
            targetRepsHigh: 9,
            targetWeight: 31.5
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Intent Strength",
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: exercise.id,
                sets: [target]
            )]
        )
        context.insert(exercise)
        context.insert(routine)
        try context.save()

        let workout = try #require(WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            in: context,
            applyProgression: false,
            onCommit: { _ in }
        ))
        let set = try #require(workout.exercises.first?.sets.first)

        #expect(set.reps == 7)
        #expect(set.weight == 31.5)
        #expect(set.sourceRoutineSetID == target.id)

        let verification = ModelContext(container)
        let workoutID = workout.id
        let persisted = try #require(verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        let persistedSet = try #require(persisted.exercises.first?.sets.first)
        #expect(persistedSet.reps == 7)
        #expect(persistedSet.weight == 31.5)
    }

    private func machineExercise() -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            name: "Machine Press",
            primaryMuscles: ["chest"],
            equipment: "machine",
            defaultWeightMode: .external,
            preferredWeightUnitRaw: WeightUnit.kg.rawValue
        )
    }

    private func historyWorkout(
        exerciseID: UUID,
        estimate: Double,
        setType: SetType = .working
    ) -> WorkoutModel {
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000 + estimate)
        let set = SetModel(
            userID: userID,
            setType: setType,
            reps: 5,
            weight: estimate * 0.85,
            completedAt: completedAt
        )
        set.estimated1RM = estimate
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exerciseID,
            sets: [set]
        )
        return WorkoutModel(
            userID: userID,
            title: "History",
            startedAt: completedAt.addingTimeInterval(-600),
            endedAt: completedAt,
            exercises: [workoutExercise]
        )
    }
}
