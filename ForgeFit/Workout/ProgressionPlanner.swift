import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// One exercise's resolved next-session plan: what the progression engine
/// (or a coach hold override) suggests, plus the concrete weight/reps that
/// should land on that exercise's pending working sets. `apply(to:...)` and
/// `preview(routine:...)` both build this list from the identical planning
/// step (`plan(routine:...)`), so a future preview UI can show exactly what
/// starting the workout will do before it happens.
struct PlannedProgression: Equatable {
    /// Identifies the `RoutineExerciseModel` this plan came from, so
    /// `apply(to:...)` can match it back to the matching `WorkoutExerciseModel`
    /// via `sourceRoutineExerciseID`.
    let routineExerciseID: UUID
    let exerciseID: UUID
    let exerciseName: String
    let suggestion: ProgressionSuggestion
    /// The weight (kg) that should land on pending external-mode working
    /// sets; nil means leave the routine's own planned weight alone
    /// (bodyweight exercises, reps-only "addReps" suggestions, and plain
    /// engine holds never touch weight).
    let targetWeightKg: Double?
    /// The rep target that should land on pending working sets; nil means
    /// leave the routine's own planned reps alone.
    let targetRepsLow: Int?
}

/// Applies the progression engine when a routine-driven workout starts:
/// advances pending working-set targets from the exercise's last completed
/// session and records one `ProgressionSuggestionModel` per exercise so the
/// logger can explain itself and the save path can resolve what the lifter
/// did with the suggestion. Readiness is deliberately NOT an input — the
/// coach's version (`CoachAdjustments`) stays a separate layer on top.
@MainActor
enum ProgressionPlanner {

    /// Runs once at start. No-ops per exercise when: rule is `.off`, the
    /// exercise is cardio/yoga, or there is no prior completed session
    /// (brand-new exercises keep their plain routine targets — no banner).
    ///
    /// `heldExerciseIDs`/`holdReasons` let a coach's weekly review (or any
    /// future UI) override specific exercises — identified by
    /// `ExerciseLibraryModel.id`, matching `LiftWeekOutcome.exerciseID` from
    /// `CoachingPolicy` — to hold at last session's numbers instead of
    /// whatever the engine would otherwise suggest. Both default to empty,
    /// so a plain call is byte-for-byte today's behavior.
    static func apply(
        to workout: WorkoutModel,
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        in context: ModelContext,
        heldExerciseIDs: Set<UUID> = [],
        holdReasons: [UUID: String] = [:]
    ) {
        let planned = plan(
            routine: routine, exercises: exercises, in: context,
            excludingWorkoutID: workout.id,
            heldExerciseIDs: heldExerciseIDs, holdReasons: holdReasons
        )
        guard !planned.isEmpty else { return }
        let plannedByRoutineExerciseID = Dictionary(
            planned.map { ($0.routineExerciseID, $0) }, uniquingKeysWith: { first, _ in first }
        )

        for workoutExercise in workout.exercises {
            guard let sourceID = workoutExercise.sourceRoutineExerciseID,
                  let matchedPlan = plannedByRoutineExerciseID[sourceID] else { continue }

            applyTargets(to: workoutExercise, weightKg: matchedPlan.targetWeightKg, repsLow: matchedPlan.targetRepsLow)

            context.insert(ProgressionSuggestionModel(
                userID: ForgeFitDemo.userID,
                exerciseID: workoutExercise.exerciseID,
                workoutID: workout.id,
                workoutExerciseID: workoutExercise.id,
                kindRaw: matchedPlan.suggestion.kind.rawValue,
                suggestedWeightKg: matchedPlan.suggestion.weightKg,
                suggestedRepsLow: matchedPlan.suggestion.repsLow,
                suggestedRepsHigh: matchedPlan.suggestion.repsHigh,
                rationale: matchedPlan.suggestion.rationale
            ))
        }
    }

    /// Computes exactly what `apply(to:...)` WOULD do for this routine,
    /// without creating or mutating anything — for a future "here's what
    /// starting this workout will suggest" preview. Takes the same
    /// hold-override parameters as `apply` so preview and start always
    /// agree.
    static func preview(
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        in context: ModelContext,
        heldExerciseIDs: Set<UUID> = [],
        holdReasons: [UUID: String] = [:]
    ) -> [PlannedProgression] {
        plan(
            routine: routine, exercises: exercises, in: context,
            excludingWorkoutID: nil,
            heldExerciseIDs: heldExerciseIDs, holdReasons: holdReasons
        )
    }

    /// The shared, non-mutating planning step behind both `apply` and
    /// `preview`. Walks the routine's exercises (not the workout's — at
    /// preview time there is no workout yet, and at start time
    /// `WorkoutFactory` always builds a 1:1 `workout.exercises` mapping from
    /// `routine.exercises` before calling `apply`, so the two are
    /// equivalent).
    private static func plan(
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        in context: ModelContext,
        excludingWorkoutID: UUID?,
        heldExerciseIDs: Set<UUID>,
        holdReasons: [UUID: String]
    ) -> [PlannedProgression] {
        let history = completedHistory(in: context, excluding: excludingWorkoutID)
        guard !history.isEmpty else { return [] }
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var planned: [PlannedProgression] = []
        for routineExercise in routine.exercises {
            guard let exercise = exerciseByID[routineExercise.exerciseID],
                  !exercise.isCardio, !exercise.isYoga else { continue }
            let rule = ProgressionRule.decode(from: routineExercise.progressionRuleJSON) ?? .doubleProgression
            if case .off = rule { continue }
            let lastSets = lastSessionWorkingSets(exerciseID: routineExercise.exerciseID, history: history)
            guard !lastSets.isEmpty else { continue }

            let targets = routineExercise.sets.sorted { $0.position < $1.position }
            let input = ProgressionInput(
                lastSessionSets: lastSets.map { .init(weightKg: $0.modeWeight ?? $0.weight, reps: $0.reps) },
                targetRepsLow: targets.compactMap(\.targetRepsLow).min(),
                targetRepsHigh: targets.compactMap(\.targetRepsHigh).max(),
                rule: rule,
                increment: increment(for: exercise),
                isBodyweight: exercise.defaultWeightMode == .bodyweight
            )

            let isHeld = heldExerciseIDs.contains(routineExercise.exerciseID)
            let suggestion = isHeld
                ? heldSuggestion(input: input, reason: holdReasons[routineExercise.exerciseID])
                : ProgressionEngine.suggest(input)
            guard let suggestion else { continue }

            planned.append(PlannedProgression(
                routineExerciseID: routineExercise.id,
                exerciseID: routineExercise.exerciseID,
                exerciseName: exercise.name,
                suggestion: suggestion,
                targetWeightKg: isHeld ? suggestion.weightKg : increaseWeightKg(suggestion),
                targetRepsLow: isHeld ? suggestion.repsLow : increaseRepsLow(suggestion)
            ))
        }
        return planned
    }

    /// A held exercise skips the engine's increase math entirely: it always
    /// holds at last session's top weight/reps, explaining itself with the
    /// override reason (falling back to a plain default when none was
    /// given). Mirrors `ProgressionEngine`'s own hold shape so downstream
    /// code (banners, `resolveStatuses`) can't tell the difference.
    private static func heldSuggestion(input: ProgressionInput, reason: String?) -> ProgressionSuggestion? {
        let sets = input.lastSessionSets.filter { $0.reps != nil }
        guard !sets.isEmpty else { return nil }
        let reps = sets.compactMap(\.reps)
        let topWeightKg = sets.compactMap(\.weightKg).filter { $0 > 0 }.max()
        guard input.isBodyweight || topWeightKg != nil else { return nil }

        let low = input.targetRepsLow ?? input.targetRepsHigh ?? (reps.min() ?? 0)
        let high = input.targetRepsHigh ?? input.targetRepsLow.map { $0 + 2 } ?? (low + 2)

        return ProgressionSuggestion(
            kind: .hold,
            weightKg: input.isBodyweight ? nil : topWeightKg,
            repsLow: low,
            repsHigh: high,
            rationale: reason ?? "Held — repeat last session's numbers before progressing again."
        )
    }

    /// The weight `apply` writes for a real (non-held) increase; nil for
    /// every other kind, so weight is left untouched.
    private static func increaseWeightKg(_ suggestion: ProgressionSuggestion) -> Double? {
        guard suggestion.kind == .increase else { return nil }
        return suggestion.weightKg
    }

    /// The reps `apply` writes for a real (non-held) increase; nil for
    /// every other kind, so reps are left untouched.
    private static func increaseRepsLow(_ suggestion: ProgressionSuggestion) -> Int? {
        guard suggestion.kind == .increase, suggestion.weightKg != nil else { return nil }
        return suggestion.repsLow
    }

    /// Writes a resolved target onto an exercise's pending external-mode
    /// working sets — the one mutation point shared by every progression
    /// path (plain increase or held override). No-ops entirely when there
    /// is nothing to write, so it never touches a set it wouldn't have
    /// touched before.
    private static func applyTargets(to workoutExercise: WorkoutExerciseModel, weightKg: Double?, repsLow: Int?) {
        guard weightKg != nil || repsLow != nil else { return }
        for set in workoutExercise.sets
        where set.completedAt == nil
            && !set.setType.isBlockType
            && set.setType != .warmup
            && set.setType != .amrap
            && set.weightMode == .external {
            if let weightKg { set.weight = weightKg }
            if let repsLow { set.reps = repsLow }
            set.recomputeDerivedMetrics()
        }
    }

    /// Resolves pending suggestions when the workout saves: completed working
    /// sets at the suggested weight (±10 g) = accepted; at a different weight
    /// = edited; exercise never trained = stays pending. Rejection happens
    /// live via the banner's ✕.
    static func resolveStatuses(for workout: WorkoutModel, in context: ModelContext) {
        let workoutID = workout.id
        let pending = (try? context.fetch(FetchDescriptor<ProgressionSuggestionModel>(
            predicate: #Predicate { $0.workoutID == workoutID && $0.statusRaw == "pending" && $0.deletedAt == nil }
        ))) ?? []
        guard !pending.isEmpty else { return }
        let exercisesByID = Dictionary(workout.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for suggestion in pending {
            guard let workoutExercise = exercisesByID[suggestion.workoutExerciseID] else { continue }
            let completed = workoutExercise.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
            guard !completed.isEmpty else { continue }
            if let target = suggestion.suggestedWeightKg, suggestion.kindRaw == ProgressionSuggestion.Kind.increase.rawValue {
                let matched = completed.contains { abs(($0.modeWeight ?? $0.weight ?? 0) - target) < 0.01 }
                suggestion.statusRaw = matched ? "accepted" : "edited"
            } else {
                suggestion.statusRaw = "accepted"
            }
            suggestion.updatedAt = Date()
        }
    }

    /// The most recent completed session's working sets for an exercise.
    static func lastSessionWorkingSets(exerciseID: UUID, history: [WorkoutModel]) -> [SetModel] {
        for past in history {
            for we in past.exercises where we.exerciseID == exerciseID {
                let sets = we.sets
                    .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume && !$0.setType.isBlockType }
                    .sorted { $0.position < $1.position }
                if !sets.isEmpty { return sets }
            }
        }
        return []
    }

    /// Completed workouts, most recent first. `excluding` optionally drops
    /// one workout by id (the one just created at start, before it has an
    /// `endedAt` anyway) — nil when there's no workout yet, as at preview
    /// time before a routine has been started.
    static func completedHistory(in context: ModelContext, excluding workoutID: UUID? = nil) -> [WorkoutModel] {
        let all = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        return all
            .filter { $0.id != workoutID && $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Display-unit jump size: barbell-class equipment moves in full plate
    /// pairs (5 lb / 2.5 kg), everything else in the small step.
    static func increment(for exercise: ExerciseLibraryModel) -> ProgressionIncrement {
        let unit = exercise.effectiveWeightUnit
        let equipment = exercise.equipment?.lowercased() ?? ""
        let barbellClass = equipment.contains("barbell") || equipment.contains("smith") || equipment.contains("e-z")
        let displayPerKilogram = unit == .lb ? 2.2046226218 : 1.0
        let step: Double = unit == .lb ? (barbellClass ? 5 : 2.5) : (barbellClass ? 2.5 : 1.25)
        return ProgressionIncrement(displayPerKilogram: displayPerKilogram, stepDisplay: step, suffix: unit.shortSuffix)
    }
}
