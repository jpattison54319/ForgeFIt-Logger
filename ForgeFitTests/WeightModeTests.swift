import Foundation
import ForgeCore
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

/// Bodyweight-family weight modes: seeded sets must carry the exercise's
/// mode with the target in that mode's field, and the historical backfill
/// must repair sets that were mis-seeded as `.external` — the bug where an
/// assisted pull-up's tonnage was assistance × reps ("551 lbs") instead of
/// (bodyweight − assistance) × reps.
@MainActor
struct WeightModeTests {
    private let userID = ForgeFitDemo.userID
    private let backfillKey = "weightModeBackfilled.v1"

    private func makeRoutine(
        exercise: ExerciseLibraryModel,
        targetWeight: Double?,
        in context: ModelContext
    ) -> RoutineModel {
        let routineSet = RoutineSetModel(
            userID: userID, position: 0, targetRepsLow: 8, targetRepsHigh: 12, targetWeight: targetWeight)
        let routineExercise = RoutineExerciseModel(
            userID: userID, exerciseID: exercise.id, position: 0, sets: [routineSet])
        let routine = RoutineModel(userID: userID, name: "Pull A", exercises: [routineExercise])
        context.insert(exercise)
        context.insert(routine)
        return routine
    }

    @Test func routineSeededSetsCarryTheExerciseModeAndField() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = ExerciseLibraryModel(name: "Assisted Pull-up")
        exercise.defaultWeightMode = .bodyweightAssisted
        let routine = makeRoutine(exercise: exercise, targetWeight: 25, in: context)

        let workout = WorkoutFactory.start(routine: routine, exercises: [exercise], in: context)
        let set = try #require(workout.exercises.first?.sets.first)

        #expect(set.weightMode == .bodyweightAssisted)
        #expect(set.assistanceWeight == 25)
        #expect(set.weight == nil)
    }

    @Test func externalSeedingIsUnchanged() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let exercise = ExerciseLibraryModel(name: "Bench Press")
        let routine = makeRoutine(exercise: exercise, targetWeight: 100, in: context)

        let workout = WorkoutFactory.start(routine: routine, exercises: [exercise], in: context)
        let set = try #require(workout.exercises.first?.sets.first)

        #expect(set.weightMode == .external)
        #expect(set.weight == 100)
        #expect(set.assistanceWeight == nil)
    }

    @Test func assistedTonnageIsEffectiveLoadTimesReps() throws {
        let set = SetModel(
            userID: userID, position: 0, weightMode: .bodyweightAssisted,
            reps: 10, assistanceWeight: 25, bodyweightKg: 97.5)
        set.completedAt = Date()
        set.recomputeDerivedMetrics()
        // 215 lb bodyweight (97.5 kg) minus 25 kg assistance, ×10 reps.
        #expect(set.totalVolume == 725)
        #expect(set.effectiveLoad == 72.5)
    }

    @Test func backfillRepairsMisSeededAssistedHistory() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        UserDefaults.standard.removeObject(forKey: backfillKey)
        defer { UserDefaults.standard.removeObject(forKey: backfillKey) }

        let exercise = ExerciseLibraryModel(name: "Assisted Pull-up")
        exercise.defaultWeightMode = .bodyweightAssisted
        context.insert(exercise)
        // The pre-fix shape: an `.external` set with the assistance in `weight`.
        let set = SetModel(userID: userID, position: 0, reps: 10, weight: 25)
        set.completedAt = Date()
        set.recomputeDerivedMetrics()
        #expect(set.totalVolume == 250)   // the bug: assistance × reps
        let workoutExercise = WorkoutExerciseModel(
            userID: userID, exerciseID: exercise.id, position: 0, sets: [set])
        let workout = WorkoutModel(userID: userID, title: "Pull A")
        workout.exercises = [workoutExercise]
        workout.endedAt = Date()
        context.insert(workout)

        WeightModeBackfill.convertIfNeeded(in: context)
        #expect(set.weightMode == .bodyweightAssisted)
        #expect(set.assistanceWeight == 25)
        #expect(set.weight == nil)

        WeightModeBackfill.fillMissingBodyweight(
            bodyweightSeries: [(date: Date(), value: 97.5)], in: context)
        #expect(set.bodyweightKg == 97.5)
        #expect(set.totalVolume == 725)
        #expect(workout.totalVolume == 725)
    }

    @Test func backfillLeavesExternalExercisesAlone() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        UserDefaults.standard.removeObject(forKey: backfillKey)
        defer { UserDefaults.standard.removeObject(forKey: backfillKey) }

        let exercise = ExerciseLibraryModel(name: "Bench Press")
        context.insert(exercise)
        let set = SetModel(userID: userID, position: 0, reps: 8, weight: 100)
        set.completedAt = Date()
        set.recomputeDerivedMetrics()
        let workoutExercise = WorkoutExerciseModel(
            userID: userID, exerciseID: exercise.id, position: 0, sets: [set])
        let workout = WorkoutModel(userID: userID, title: "Push A")
        workout.exercises = [workoutExercise]
        workout.endedAt = Date()
        context.insert(workout)

        WeightModeBackfill.convertIfNeeded(in: context)
        WeightModeBackfill.fillMissingBodyweight(
            bodyweightSeries: [(date: Date(), value: 97.5)], in: context)

        #expect(set.weightMode == .external)
        #expect(set.weight == 100)
        #expect(set.bodyweightKg == nil)
        #expect(set.totalVolume == 800)
    }

    @Test func watchEditRoutesThroughTheModeField() throws {
        let set = SetModel(
            userID: userID, position: 0, weightMode: .bodyweightAssisted,
            reps: 10, assistanceWeight: 30, bodyweightKg: 97.5)
        set.setModeWeight(25)   // the wrist's weightKg round trip
        #expect(set.assistanceWeight == 25)
        #expect(set.weight == nil)
        #expect(set.effectiveLoad == 72.5)
    }
}
