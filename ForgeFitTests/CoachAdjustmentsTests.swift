import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CoachAdjustmentsTests {
    private let userID = ForgeFitDemo.userID

    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Workout with one exercise: 1 warmup + 4 working sets at 100, RPE 9.
    private func workout(in context: ModelContext, exerciseID: UUID = UUID()) -> WorkoutModel {
        let sets = [SetModel(userID: userID, position: 0, setType: .warmup, reps: 10, weight: 50)]
            + (1...4).map { SetModel(userID: userID, position: $0, reps: 8, weight: 100, rpe: 9) }
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: sets)
        let w = WorkoutModel(userID: userID, exercises: [exercise])
        context.insert(w)
        try? context.save()
        return w
    }

    /// Two exercises, each shaped like `workout(in:)`'s single exercise —
    /// used to test per-exercise include/exclude.
    private func twoExerciseWorkout(in context: ModelContext, idA: UUID, idB: UUID) -> WorkoutModel {
        func sets() -> [SetModel] {
            [SetModel(userID: userID, position: 0, setType: .warmup, reps: 10, weight: 50)]
                + (1...4).map { SetModel(userID: userID, position: $0, reps: 8, weight: 100, rpe: 9) }
        }
        let exerciseA = WorkoutExerciseModel(userID: userID, exerciseID: idA, sets: sets())
        let exerciseB = WorkoutExerciseModel(userID: userID, exerciseID: idB, sets: sets())
        let w = WorkoutModel(userID: userID, exercises: [exerciseA, exerciseB])
        context.insert(w)
        try? context.save()
        return w
    }

    /// A routine whose single exercise mirrors `workout(in:exerciseID:)`'s
    /// shape (4 working sets) — used to build a `draft(for:routine:exercises:)`
    /// that should match `apply(_:to:in:)`'s legacy defaults exactly.
    private func matchingRoutine(exerciseID: UUID) -> (routine: RoutineModel, exercise: ExerciseLibraryModel) {
        let libraryExercise = ExerciseLibraryModel(id: exerciseID, name: "Bench Press")
        let routine = RoutineModel(userID: userID, name: "Test Routine", exercises: [
            RoutineExerciseModel(
                userID: userID, exerciseID: exerciseID,
                sets: (0..<4).map { RoutineSetModel(userID: userID, position: $0, targetRepsLow: 8, targetWeight: 100) }
            ),
        ])
        return (routine, libraryExercise)
    }

    @Test func noPlanForGreenDays() {
        #expect(CoachAdjustments.plan(for: .push) == nil)
        #expect(CoachAdjustments.plan(for: .trainAsPlanned) == nil)
        #expect(CoachAdjustments.plan(for: .reduceVolume) != nil)
        #expect(CoachAdjustments.plan(for: .deloadRecover) != nil)
    }

    @Test func reduceVolumeDropsOneSetAndCapsRPE() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let w = workout(in: context)
        let plan = CoachAdjustments.plan(for: .reduceVolume)!

        CoachAdjustments.apply(plan, to: w, in: context)

        let sets = w.exercises[0].sets.sorted { $0.position < $1.position }
        #expect(sets.filter { $0.setType == .working }.count == 3)   // 4 → 3
        #expect(sets.contains { $0.setType == .warmup })             // warmup preserved
        #expect(sets.filter { $0.setType == .working }.allSatisfy { ($0.rpe ?? 0) <= 8 })
        #expect(sets.filter { $0.setType == .working }.allSatisfy { $0.weight == 100 })  // load untouched
        #expect(w.notes?.contains("Coach-adjusted") == true)
    }

    @Test func deloadHalvesSetsAndTrimsLoad() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let w = workout(in: context)
        let plan = CoachAdjustments.plan(for: .deloadRecover)!

        CoachAdjustments.apply(plan, to: w, in: context)

        let working = w.exercises[0].sets.filter { $0.setType == .working }
        #expect(working.count == 2)                                  // 4 → 2
        #expect(working.allSatisfy { $0.weight == 90 })              // −10%
        #expect(working.allSatisfy { ($0.rpe ?? 0) <= 7 })
        // Removed sets are actually deleted, not orphaned.
        let all = try context.fetch(FetchDescriptor<SetModel>())
        #expect(all.filter { $0.setType == .working }.count == 2)
    }

    @Test func smallExercisesKeepMinimumOneWorkingSet() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let exercise = WorkoutExerciseModel(
            userID: userID, exerciseID: UUID(),
            sets: [SetModel(userID: userID, position: 0, reps: 8, weight: 60, rpe: 8)]
        )
        let w = WorkoutModel(userID: userID, exercises: [exercise])
        context.insert(w)
        try context.save()

        CoachAdjustments.apply(CoachAdjustments.plan(for: .deloadRecover)!, to: w, in: context)
        #expect(w.exercises[0].sets.count == 1)

        // reduceVolume never cuts a 2-set exercise below 2.
        let context2 = ModelContext(try inMemoryContainer())
        let two = WorkoutExerciseModel(
            userID: userID, exerciseID: UUID(),
            sets: (0..<2).map { SetModel(userID: userID, position: $0, reps: 8, weight: 60, rpe: 9) }
        )
        let w2 = WorkoutModel(userID: userID, exercises: [two])
        context2.insert(w2)
        try context2.save()
        CoachAdjustments.apply(CoachAdjustments.plan(for: .reduceVolume)!, to: w2, in: context2)
        #expect(w2.exercises[0].sets.count == 2)
    }

    // MARK: - AdjustmentDraft

    /// A draft built by `draft(for:routine:exercises:)` and never edited
    /// must apply byte-for-byte identically to the legacy `apply(_:to:in:)` —
    /// that's the whole point of the refactor.
    @Test func defaultDraftMatchesLegacyApplyBehavior() throws {
        let exerciseID = UUID()
        let plan = CoachAdjustments.plan(for: .deloadRecover)!

        let legacyContainer = try inMemoryContainer()
        let legacyContext = ModelContext(legacyContainer)
        let legacyWorkout = workout(in: legacyContext, exerciseID: exerciseID)
        CoachAdjustments.apply(plan, to: legacyWorkout, in: legacyContext)

        let draftContainer = try inMemoryContainer()
        let draftContext = ModelContext(draftContainer)
        let draftWorkout = workout(in: draftContext, exerciseID: exerciseID)
        let (routine, libraryExercise) = matchingRoutine(exerciseID: exerciseID)
        let draft = CoachAdjustments.draft(for: plan, routine: routine, exercises: [libraryExercise])
        CoachAdjustments.apply(draft: draft, to: draftWorkout, in: draftContext)

        let legacySets = legacyWorkout.exercises[0].sets.sorted { $0.position < $1.position }
        let draftSets = draftWorkout.exercises[0].sets.sorted { $0.position < $1.position }
        #expect(legacySets.count == draftSets.count)
        #expect(zip(legacySets, draftSets).allSatisfy {
            $0.weight == $1.weight && $0.rpe == $1.rpe && $0.setType == $1.setType
        })
        #expect(legacyWorkout.notes == draftWorkout.notes)
        _ = (legacyContainer, draftContainer)
    }

    @Test func excludedExerciseStaysUntouched() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let idA = UUID()
        let idB = UUID()
        let w = twoExerciseWorkout(in: context, idA: idA, idB: idB)
        let plan = CoachAdjustments.plan(for: .reduceVolume)!

        let draft = CoachAdjustments.AdjustmentDraft(
            plan: plan,
            exercises: [
                .init(id: idA, exerciseName: "A", workingSetCount: 4, included: true, setsToDrop: 1),
                .init(id: idB, exerciseName: "B", workingSetCount: 4, included: false, setsToDrop: 1),
            ],
            weightCutPercent: 0,
            rpeCapEnabled: true
        )
        CoachAdjustments.apply(draft: draft, to: w, in: context)

        let exerciseA = try #require(w.exercises.first { $0.exerciseID == idA })
        let exerciseB = try #require(w.exercises.first { $0.exerciseID == idB })
        #expect(exerciseA.sets.filter { $0.setType == .working }.count == 3)   // included: 4 → 3
        let workingB = exerciseB.sets.filter { $0.setType == .working }
        #expect(workingB.count == 4)                                          // excluded: untouched
        #expect(workingB.allSatisfy { $0.rpe == 9 && $0.weight == 100 })
    }

    @Test func editedSetsToDropFloorsAtOneWorkingSet() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let exerciseID = UUID()
        let w = workout(in: context, exerciseID: exerciseID)
        let plan = CoachAdjustments.plan(for: .reduceVolume)!

        // Ask for far more than there are — the floor keeps 1 remaining
        // working set no matter how the user drags the stepper.
        let draft = CoachAdjustments.AdjustmentDraft(
            plan: plan,
            exercises: [.init(id: exerciseID, exerciseName: "Bench", workingSetCount: 4, included: true, setsToDrop: 10)],
            weightCutPercent: 0,
            rpeCapEnabled: true
        )
        CoachAdjustments.apply(draft: draft, to: w, in: context)
        #expect(w.exercises[0].sets.filter { $0.setType == .working }.count == 1)
    }

    @Test func editedWeightCutIsApplied() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let exerciseID = UUID()
        let w = workout(in: context, exerciseID: exerciseID)
        // reduceVolume never scales weight by default — the review screen's
        // edited weight cut must still take effect.
        let plan = CoachAdjustments.plan(for: .reduceVolume)!

        let draft = CoachAdjustments.AdjustmentDraft(
            plan: plan,
            exercises: [.init(id: exerciseID, exerciseName: "Bench", workingSetCount: 4, included: true, setsToDrop: 0)],
            weightCutPercent: 15,
            rpeCapEnabled: false
        )
        CoachAdjustments.apply(draft: draft, to: w, in: context)

        let working = w.exercises[0].sets.filter { $0.setType == .working }
        #expect(working.count == 4)                                   // no sets dropped
        #expect(working.allSatisfy { $0.weight == 85 })                // 100 × (1 − 15%)
        #expect(working.allSatisfy { ($0.rpe ?? 0) == 9 })              // cap disabled: untouched
    }

    @Test func notesStampReflectsEditedVsDefault() throws {
        let exerciseID = UUID()
        let plan = CoachAdjustments.plan(for: .reduceVolume)!
        let (routine, libraryExercise) = matchingRoutine(exerciseID: exerciseID)
        let baseDraft = CoachAdjustments.draft(for: plan, routine: routine, exercises: [libraryExercise])

        let defaultContainer = try inMemoryContainer()
        let defaultContext = ModelContext(defaultContainer)
        let defaultWorkout = workout(in: defaultContext, exerciseID: exerciseID)
        CoachAdjustments.apply(draft: baseDraft, to: defaultWorkout, in: defaultContext)
        #expect(defaultWorkout.notes?.hasPrefix("Coach-adjusted (reduce volume):") == true)

        let editedContainer = try inMemoryContainer()
        let editedContext = ModelContext(editedContainer)
        let editedWorkout = workout(in: editedContext, exerciseID: exerciseID)
        var editedDraft = baseDraft
        editedDraft.exercises[0].setsToDrop = 2
        CoachAdjustments.apply(draft: editedDraft, to: editedWorkout, in: editedContext)
        #expect(editedWorkout.notes?.hasPrefix("Coach-adjusted (edited):") == true)
        _ = (defaultContainer, editedContainer)
    }
}
