import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One-tap "coach's version" of a routine for days when readiness says to back
/// off. Adjustments are applied to the *started workout only* — the saved
/// routine is never touched, so tomorrow starts from the normal plan.
///
/// The dose adjustments follow the same evidence the readiness engine cites:
///  - Reduce volume: drop ~one working set per exercise and cap effort at
///    RPE 8 (≥2 RIR). Stopping short of failure preserves the stimulus while
///    cutting the recovery cost (Morán-Navarro 2017; Helms 2016 RIR-based
///    autoregulation).
///  - Deload/recover: roughly halve working sets and take ~10% off the load,
///    capping at RPE 7 — the volume-first deload structure practitioners
///    converge on (Bell et al. 2023 deload survey; Schoenfeld 2016 dose
///    guidance).
///
/// Coach's Corner review (Phase 4) lets the lifter see and edit every one of
/// these numbers before a workout starts — `AdjustmentDraft` is the editable
/// value model behind that screen. `apply(_:to:in:)` (the original one-tap
/// path) is now a thin wrapper that builds the *default*, unedited draft and
/// runs it through `apply(draft:to:in:)`, so its behavior is byte-for-byte
/// what it always was.
enum CoachAdjustments {

    struct Plan: Equatable {
        let action: RecoveryEngine.Action
        let affectedExerciseIDs: Set<UUID>?
        /// Button-length summary, e.g. "1 set less per lift, cap at RPE 8".
        let summary: String
        /// Bullet detail of what will change, for the confirmation UI.
        let changes: [String]

        /// The RPE ceiling this plan's dose implies. Deload caps harder than
        /// a plain volume reduction.
        var rpeCapValue: Double { action == .deloadRecover ? 7 : 8 }
        /// The RIR floor paired with `rpeCapValue`.
        var rirFloorValue: Int { action == .deloadRecover ? 3 : 2 }
        /// Only deload trims load — a plain volume reduction never touches
        /// weight. Drives whether the review screen even offers a weight-cut
        /// control.
        var scalesWeight: Bool { action == .deloadRecover }
    }

    /// The coach's proposed modification for today's action — nil when the plan
    /// should run as written (push / train-as-planned).
    static func plan(for action: RecoveryEngine.Action) -> Plan? {
        switch action {
        case .push, .trainAsPlanned:
            return nil
        case .reduceVolume:
            return Plan(
                action: action,
                affectedExerciseIDs: nil,
                summary: "1 working set less per lift · cap RPE 8",
                changes: [
                    "Removes the last working set of each exercise that has 3+",
                    "Caps set targets at RPE 8 (≈2 reps in reserve)",
                    "Your saved routine is not changed",
                ]
            )
        case .deloadRecover:
            return Plan(
                action: action,
                affectedExerciseIDs: nil,
                summary: "Half the working sets · −10% load · cap RPE 7",
                changes: [
                    "Halves the working sets of each exercise (minimum 1)",
                    "Reduces target weights by 10%",
                    "Caps set targets at RPE 7 (≈3 reps in reserve)",
                    "Your saved routine is not changed",
                ]
            )
        }
    }

    /// Human-readable source labels for `effectivePlan`'s winning plan — used
    /// verbatim by the review screen so the lifter always knows WHY today is
    /// lighter, not just that it is.
    static let weeklySourceLabel = "This week: deload"
    static let dailySourceLabel = "Today: readiness"

    /// Resolves a weekly deload-week override (Coach's Corner weekly review)
    /// against the daily readiness plan into the single winning dose — never
    /// stacking two reductions. A deload's volume/load cut is always at
    /// least as conservative as a plain volume reduction, so an active
    /// weekly deload always wins outright over the daily plan, whatever the
    /// daily plan is; otherwise the daily plan (if any) runs alone. Returns
    /// nil when neither applies (train as written).
    static func effectivePlan(daily: Plan?, weeklyDeloadActive: Bool) -> (plan: Plan, sourceLabel: String)? {
        if weeklyDeloadActive, let weeklyPlan = plan(for: .deloadRecover) {
            return (weeklyPlan, weeklySourceLabel)
        }
        if let daily {
            return (daily, dailySourceLabel)
        }
        return nil
    }

    /// A voluntary, muscle-specific lighter version for an otherwise green
    /// day. It never changes the global daily verdict or the saved routine.
    static func localizedPlan(for context: RoutineDoseContext) -> Plan? {
        guard context.needsLocalizedLighterVersion else { return nil }
        return Plan(
            action: .reduceVolume,
            affectedExerciseIDs: context.affectedExerciseIDs,
            summary: "1 working set less from \(context.affectedMuscleNames) work · cap RPE 8",
            changes: [
                "Removes the last working set only from exercises loading \(context.affectedMuscleNames)",
                "Caps those set targets at RPE 8 (≈2 reps in reserve)",
                "Your saved routine is not changed",
            ]
        )
    }

    /// Apply the plan to a freshly started workout. Returns a short description
    /// stamped into the workout notes so the session records why it was lighter.
    /// Delegates through the default (unedited) `AdjustmentDraft` — see
    /// `apply(draft:to:in:)` for the actual mutation logic.
    @MainActor
    static func apply(_ plan: Plan, to workout: WorkoutModel, in context: ModelContext) {
        apply(draft: defaultDraft(for: plan, workout: workout), to: workout, in: context)
    }

    // MARK: - Adjustment draft (Coach's Corner review)

    /// The editable value model behind the coach-adjustment review screen:
    /// built from `Plan` + a routine, mutated by the UI (per-exercise
    /// include/exclude, sets-to-drop, global weight cut, RPE cap), and
    /// applied via `apply(draft:to:in:)`. A draft built by `draft(for:routine:exercises:)`
    /// and never edited applies identically to the legacy `apply(_:to:in:)`.
    struct AdjustmentDraft: Equatable {
        struct ExerciseDraft: Identifiable {
            /// `ExerciseLibraryModel.id` — matches `WorkoutExerciseModel.exerciseID`.
            let id: UUID
            var exerciseName: String
            let workingSetCount: Int
            var included: Bool
            var setsToDrop: Int

            /// Floor-1-working-set: never lets the stepper drop the last set.
            var maxSetsToDrop: Int { max(0, workingSetCount - 1) }
        }

        let plan: Plan
        var exercises: [ExerciseDraft]
        /// Percent off target weight (0/5/10/15), applied to every included
        /// exercise's remaining sets. Only meaningful when `plan.scalesWeight`.
        var weightCutPercent: Double
        var rpeCapEnabled: Bool
    }

    /// Builds the draft the review screen edits, from the *saved routine* —
    /// before any workout exists. `WorkoutFactory.start` copies
    /// `routine.exercises` 1:1 into the workout, so these working-set counts
    /// (and the exercise IDs used to match rows back at apply time) are
    /// exactly what the started workout will have.
    @MainActor
    static func draft(for plan: Plan, routine: RoutineModel, exercises: [ExerciseLibraryModel]) -> AdjustmentDraft {
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows: [AdjustmentDraft.ExerciseDraft] = routine.exercises
            .sorted { $0.position < $1.position }
            .compactMap { routineExercise -> AdjustmentDraft.ExerciseDraft? in
                let libraryExercise = exerciseByID[routineExercise.exerciseID]
                guard libraryExercise?.isCardio != true, libraryExercise?.isYoga != true else { return nil }
                let workingCount = routineExercise.sets.filter { $0.setType.countsAsWorkingVolume }.count
                guard workingCount > 0 else { return nil }
                return AdjustmentDraft.ExerciseDraft(
                    id: routineExercise.exerciseID,
                    exerciseName: libraryExercise?.name ?? "Exercise",
                    workingSetCount: workingCount,
                    included: plan.affectedExerciseIDs?.contains(routineExercise.exerciseID) ?? true,
                    setsToDrop: defaultSetsToDrop(for: plan.action, workingCount: workingCount)
                )
            }
        return AdjustmentDraft(
            plan: plan,
            exercises: rows,
            weightCutPercent: defaultWeightCutPercent(for: plan.action),
            rpeCapEnabled: true
        )
    }

    /// The same default draft, built from an already-started workout instead
    /// of the routine — used internally so `apply(_:to:in:)` stays exact.
    /// Exercise names aren't needed here (nothing renders this draft), so
    /// they're left blank; `AdjustmentDraft.ExerciseDraft`'s `Equatable`
    /// conformance ignores the name for that reason.
    @MainActor
    private static func defaultDraft(for plan: Plan, workout: WorkoutModel) -> AdjustmentDraft {
        let rows: [AdjustmentDraft.ExerciseDraft] = workout.exercises.compactMap { workoutExercise -> AdjustmentDraft.ExerciseDraft? in
            let workingCount = workoutExercise.sets.filter { $0.setType.countsAsWorkingVolume }.count
            guard workingCount > 0 else { return nil }
            return AdjustmentDraft.ExerciseDraft(
                id: workoutExercise.exerciseID,
                exerciseName: "",
                workingSetCount: workingCount,
                included: plan.affectedExerciseIDs?.contains(workoutExercise.exerciseID) ?? true,
                setsToDrop: defaultSetsToDrop(for: plan.action, workingCount: workingCount)
            )
        }
        return AdjustmentDraft(
            plan: plan,
            exercises: rows,
            weightCutPercent: defaultWeightCutPercent(for: plan.action),
            rpeCapEnabled: true
        )
    }

    private static func defaultSetsToDrop(for action: RecoveryEngine.Action, workingCount: Int) -> Int {
        switch action {
        case .reduceVolume:
            // Drop the final working set, but never below 2.
            return workingCount >= 3 ? 1 : 0
        case .deloadRecover:
            let keep = max(1, workingCount / 2)
            return max(0, workingCount - keep)
        case .push, .trainAsPlanned:
            return 0
        }
    }

    private static func defaultWeightCutPercent(for action: RecoveryEngine.Action) -> Double {
        action == .deloadRecover ? 10 : 0
    }

    /// Applies an (possibly edited) draft to a freshly started workout.
    /// Honors per-exercise inclusion and edited set-drop counts, the global
    /// weight cut, and whether the RPE/RIR cap is on — a draft built by
    /// `draft(for:routine:exercises:)` and never touched by the UI applies
    /// identically to the legacy `apply(_:to:in:)`.
    @MainActor
    static func apply(draft: AdjustmentDraft, to workout: WorkoutModel, in context: ModelContext) {
        // Compare against the equivalent default BEFORE mutating anything —
        // `defaultDraft(for:workout:)` re-derives working-set counts from the
        // live workout, which the loop below is about to change.
        let isEdited = draft != defaultDraft(for: draft.plan, workout: workout)
        let rowsByExerciseID = Dictionary(draft.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cap = draft.plan.rpeCapValue
        let rirFloor = draft.plan.rirFloorValue

        for exercise in workout.exercises {
            guard let row = rowsByExerciseID[exercise.exerciseID], row.included else { continue }
            let ordered = exercise.sets.sorted { $0.position < $1.position }
            let working = ordered.filter { $0.setType.countsAsWorkingVolume }
            guard !working.isEmpty else { continue }

            // Floor 1 remaining working set no matter how large setsToDrop is.
            let keep = max(1, working.count - max(0, row.setsToDrop))
            let toRemove = Array(working.dropFirst(keep))

            let removedIDs = Set(toRemove.map(\.id))
            exercise.sets.removeAll { removedIDs.contains($0.id) }
            toRemove.forEach { context.delete($0) }

            for set in exercise.sets {
                if draft.weightCutPercent > 0, let weight = set.weight {
                    set.weight = (weight * (1 - draft.weightCutPercent / 100)).rounded(.toNearestOrAwayFromZero)
                }
                if draft.rpeCapEnabled {
                    if let rpe = set.rpe { set.rpe = min(rpe, cap) }
                    if let rir = set.rir { set.rir = max(rir, rirFloor) }
                }
                set.recomputeDerivedMetrics()
            }
        }

        let stamp = isEdited
            ? "Coach-adjusted (edited): \(editedSummary(draft))"
            : "Coach-adjusted (\(draft.plan.action.title.lowercased())): \(draft.plan.summary)"
        workout.notes = [workout.notes, stamp].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
        workout.updatedAt = Date()
        try? context.save()
    }

    /// Short human summary of what an edited draft actually did, for the
    /// workout-notes stamp.
    private static func editedSummary(_ draft: AdjustmentDraft) -> String {
        let included = draft.exercises.filter(\.included)
        let totalDropped = included.reduce(0) { $0 + max(0, $1.setsToDrop) }
        var parts: [String] = []
        parts.append("\(included.count) exercise\(included.count == 1 ? "" : "s") adjusted")
        if totalDropped > 0 {
            parts.append("\(totalDropped) set\(totalDropped == 1 ? "" : "s") dropped")
        }
        if draft.weightCutPercent > 0 {
            parts.append("weight −\(Int(draft.weightCutPercent))%")
        }
        parts.append(draft.rpeCapEnabled ? "RPE capped at \(Int(draft.plan.rpeCapValue))" : "RPE cap off")
        return parts.joined(separator: " · ")
    }
}

extension CoachAdjustments.AdjustmentDraft.ExerciseDraft: Equatable {
    /// Deliberately ignores `exerciseName` and `workingSetCount` (pure
    /// display metadata derived from the same routine/workout) so a draft
    /// built for display (with names) compares equal to one built for
    /// applying (without) when nothing the user could edit differs.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.included == rhs.included && lhs.setsToDrop == rhs.setsToDrop
    }
}
