import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ProgressionPlannerTests {
    private let userID = ForgeFitDemo.userID

    /// Returns the container WITH its context: returning only
    /// `container.mainContext` lets the container deinit mid-test, which
    /// resets the context and destroys every model (see
    /// `RoutineProgramImportTests`). Callers must keep `container` alive.
    private static func makeContainer() throws -> (container: ModelContainer, context: ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    /// A barbell-class strength exercise with a clean 5 lb step, so an
    /// increase suggestion is exactly +5 lb with no rounding noise.
    private func makeExercise(id: UUID, bodyweight: Bool = false) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: id, name: "Bench Press", equipment: "Barbell",
            defaultWeightMode: bodyweight ? .bodyweight : .external,
            preferredWeightUnitRaw: WeightUnit.lb.rawValue
        )
    }

    /// A one-exercise routine, default (double-progression) rule, 8–10 rep
    /// target.
    private func makeRoutine(exerciseID: UUID) -> RoutineModel {
        let routineExercise = RoutineExerciseModel(
            userID: userID, exerciseID: exerciseID,
            sets: (0..<3).map {
                RoutineSetModel(userID: userID, position: $0, targetRepsLow: 8, targetRepsHigh: 10, targetWeight: 100)
            }
        )
        return RoutineModel(userID: userID, name: "Push Day", exercises: [routineExercise])
    }

    /// A completed past workout: one exercise, 3 working sets at
    /// `weight`/`reps` — feeds `apply`/`preview`'s "last session" lookup.
    @discardableResult
    private func completedHistoryWorkout(
        exerciseID: UUID, weight: Double?, reps: Int, weightMode: WeightMode = .external, in context: ModelContext
    ) -> WorkoutModel {
        let sets = (0..<3).map {
            SetModel(
                userID: userID, position: $0, weightMode: weightMode, reps: reps, weight: weight,
                completedAt: Date(timeIntervalSinceNow: -3600)
            )
        }
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: sets)
        let workout = WorkoutModel(
            userID: userID, startedAt: Date(timeIntervalSinceNow: -7200), endedAt: Date(timeIntervalSinceNow: -3600),
            exercises: [exercise]
        )
        context.insert(workout)
        return workout
    }

    /// Builds a fresh pending workout the way `WorkoutFactory.start` does:
    /// one `WorkoutExerciseModel` per routine exercise, sets seeded from the
    /// routine's targets, `sourceRoutineExerciseID` wired up so
    /// `ProgressionPlanner.apply` can match them back up.
    private func startWorkout(routine: RoutineModel, in context: ModelContext) -> WorkoutModel {
        let workoutExercises = routine.exercises.map { routineExercise -> WorkoutExerciseModel in
            let sets = routineExercise.sets.sorted { $0.position < $1.position }.map { target in
                SetModel(
                    userID: userID, position: target.position, setType: target.setType,
                    reps: target.targetRepsLow, weight: target.targetWeight,
                    sourceRoutineSetID: target.id
                )
            }
            return WorkoutExerciseModel(
                userID: userID, exerciseID: routineExercise.exerciseID, position: routineExercise.position,
                sourceRoutineExerciseID: routineExercise.id, sets: sets
            )
        }
        let workout = WorkoutModel(userID: userID, routineID: routine.id, exercises: workoutExercises)
        context.insert(workout)
        return workout
    }

    // MARK: (a) preview targets == what apply() writes, external increase

    @Test func previewTargetsMatchApplyForExternalIncrease() throws {
        let (container, context) = try Self.makeContainer()
        let exerciseID = UUID()
        let exercise = makeExercise(id: exerciseID)
        context.insert(exercise)
        let routine = makeRoutine(exerciseID: exerciseID)
        context.insert(routine)
        // Topped the range (10 reps ≥ target high 10) at 100 lb → earns +5 lb.
        let lastWeightKg = WeightUnit.lb.kilograms(fromDisplayValue: 100)
        completedHistoryWorkout(exerciseID: exerciseID, weight: lastWeightKg, reps: 10, in: context)
        try context.save()

        let workout = startWorkout(routine: routine, in: context)

        let previewed = ProgressionPlanner.preview(routine: routine, exercises: [exercise], in: context)
        ProgressionPlanner.apply(to: workout, routine: routine, exercises: [exercise], in: context)

        let plan = try #require(previewed.first)
        #expect(previewed.count == 1)
        #expect(plan.suggestion.kind == .increase)
        #expect(plan.targetWeightKg != nil)
        #expect(plan.targetRepsLow == 8)

        let pendingSets = workout.exercises[0].sets.filter { $0.completedAt == nil }
        #expect(!pendingSets.isEmpty)
        for set in pendingSets {
            #expect(set.weight == plan.targetWeightKg)
            #expect(set.reps == plan.targetRepsLow)
        }

        let suggestions = try context.fetch(FetchDescriptor<ProgressionSuggestionModel>())
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.kindRaw == ProgressionSuggestion.Kind.increase.rawValue)
        #expect(suggestions.first?.suggestedWeightKg == plan.targetWeightKg)
        _ = container
    }

    // MARK: (b) bodyweight exercise → reps-only, sets untouched, preview matches

    @Test func bodyweightExerciseIsRepsOnlyAndLeavesSetsUntouched() throws {
        let (container, context) = try Self.makeContainer()
        let exerciseID = UUID()
        let exercise = makeExercise(id: exerciseID, bodyweight: true)
        context.insert(exercise)
        let routine = makeRoutine(exerciseID: exerciseID)
        context.insert(routine)
        // Topped the range (12 ≥ target high 10) — bodyweight progression is
        // reps-only, never a weight change.
        completedHistoryWorkout(exerciseID: exerciseID, weight: nil, reps: 12, weightMode: .bodyweight, in: context)
        try context.save()

        let workout = startWorkout(routine: routine, in: context)
        let beforeReps = workout.exercises[0].sets.map(\.reps)
        let beforeWeights = workout.exercises[0].sets.map(\.weight)

        let previewed = ProgressionPlanner.preview(routine: routine, exercises: [exercise], in: context)
        ProgressionPlanner.apply(to: workout, routine: routine, exercises: [exercise], in: context)

        let plan = try #require(previewed.first)
        #expect(plan.suggestion.kind == .addReps)
        #expect(plan.suggestion.weightKg == nil)
        #expect(plan.targetWeightKg == nil)
        #expect(plan.targetRepsLow == nil)

        let afterReps = workout.exercises[0].sets.map(\.reps)
        let afterWeights = workout.exercises[0].sets.map(\.weight)
        #expect(afterReps == beforeReps)
        #expect(afterWeights == beforeWeights)
        _ = container
    }

    // MARK: (c) held exercise → hold with override reason, last-session numbers, preview matches

    @Test func heldExerciseHoldsAtLastSessionNumbersWithOverrideReason() throws {
        let (container, context) = try Self.makeContainer()
        let exerciseID = UUID()
        let exercise = makeExercise(id: exerciseID)
        context.insert(exercise)
        let routine = makeRoutine(exerciseID: exerciseID)
        context.insert(routine)
        // Topped the range — the engine alone would suggest an increase, but
        // the hold override must suppress that entirely.
        let lastWeightKg = WeightUnit.lb.kilograms(fromDisplayValue: 100)
        completedHistoryWorkout(exerciseID: exerciseID, weight: lastWeightKg, reps: 10, in: context)
        try context.save()

        let workout = startWorkout(routine: routine, in: context)
        let reason = "Form broke down under load — repeat this weight."

        let previewed = ProgressionPlanner.preview(
            routine: routine, exercises: [exercise], in: context,
            heldExerciseIDs: [exerciseID], holdReasons: [exerciseID: reason]
        )
        ProgressionPlanner.apply(
            to: workout, routine: routine, exercises: [exercise], in: context,
            heldExerciseIDs: [exerciseID], holdReasons: [exerciseID: reason]
        )

        let plan = try #require(previewed.first)
        #expect(plan.suggestion.kind == .hold)
        #expect(plan.suggestion.rationale == reason)
        let targetWeight = try #require(plan.targetWeightKg)
        #expect(abs(targetWeight - lastWeightKg) < 0.001)

        let pendingSets = workout.exercises[0].sets.filter { $0.completedAt == nil }
        #expect(!pendingSets.isEmpty)
        for set in pendingSets {
            let weight = try #require(set.weight)
            #expect(abs(weight - lastWeightKg) < 0.001)
        }

        let suggestions = try context.fetch(FetchDescriptor<ProgressionSuggestionModel>())
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.rationale == reason)
        #expect(suggestions.first?.kindRaw == ProgressionSuggestion.Kind.hold.rawValue)
        _ = container
    }

    // MARK: (d) no history → no suggestions in either path

    @Test func noHistoryProducesNoSuggestionsInEitherPath() throws {
        let (container, context) = try Self.makeContainer()
        let exerciseID = UUID()
        let exercise = makeExercise(id: exerciseID)
        context.insert(exercise)
        let routine = makeRoutine(exerciseID: exerciseID)
        context.insert(routine)
        try context.save()

        let workout = startWorkout(routine: routine, in: context)

        let previewed = ProgressionPlanner.preview(routine: routine, exercises: [exercise], in: context)
        ProgressionPlanner.apply(to: workout, routine: routine, exercises: [exercise], in: context)

        #expect(previewed.isEmpty)
        let suggestions = try context.fetch(FetchDescriptor<ProgressionSuggestionModel>())
        #expect(suggestions.isEmpty)
        _ = container
    }
}
