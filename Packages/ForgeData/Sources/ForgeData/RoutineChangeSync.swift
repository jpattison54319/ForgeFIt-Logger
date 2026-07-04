import Foundation
import ForgeCore
import SwiftData

/// Detects and applies structural drift between a routine and the workout that
/// was run from it, so the user can be asked at finish: "update the routine
/// with today's changes?"
///
/// Scope is **structural only**: exercises / sets added, removed, reordered,
/// regrouped into supersets, or whose set type changed. Performed weight, reps,
/// and RPE from the session are intentionally **not** diffed — they describe
/// what happened today, not the routine's standing targets. Performed values
/// are only carried onto the routine for *newly added* sets (which have no
/// standing target to preserve).
///
/// Identity is preserved via `WorkoutExerciseModel.sourceRoutineExerciseID` and
/// `SetModel.sourceRoutineSetID`, stamped by `WorkoutFactory.start`. Sets and
/// exercises added mid-session have nil origin IDs; routine entries whose id is
/// no longer referenced were removed.
/// Detects and applies structural drift between a routine and the workout that
/// was run from it, so the user can be asked at finish: "update the routine
/// with today's changes?"
///
/// Scope is **structural only**: exercises / sets added, removed, reordered,
/// regrouped into supersets, or whose set type changed. Performed weight, reps,
/// and RPE from the session are intentionally **not** diffed — they describe
/// what happened today, not the routine's standing targets. Performed values
/// are only carried onto the routine for *newly added* sets (which have no
/// standing target to preserve).
///
/// Identity is preserved via `WorkoutExerciseModel.sourceRoutineExerciseID` and
/// `SetModel.sourceRoutineSetID`, stamped by `WorkoutFactory.start`. Sets and
/// exercises added mid-session have nil origin IDs; routine entries whose id is
/// no longer referenced were removed.
public enum RoutineChangeSync {

    // MARK: - Plan

    /// A description of the structural differences between a workout and the
    /// routine it was started from. Pure value type; safe to inspect before
    /// deciding whether to apply.
    public struct Plan: Equatable {
        public struct ExercisePlan: Equatable {
            /// Workout exercise driving the change (reference; not owned).
            public let workoutExerciseID: UUID
            /// Matching routine exercise, nil when the exercise was added
            /// mid-session.
            public let matchedRoutineExerciseID: UUID?
            public let movedPosition: Bool
            public let supersetChanged: Bool
            /// Workout set ids whose origin is nil (added mid-session) — these
            /// become new routine sets.
            public let addedWorkoutSetIDs: [UUID]
            /// Routine set ids that are no longer referenced (removed).
            public let removedRoutineSetIDs: [UUID]
            /// Matched routine set ids whose set type differs from the
            /// workout set that originated from them.
            public let setTypeChangedRoutineSetIDs: [UUID]

            public init(
                workoutExerciseID: UUID,
                matchedRoutineExerciseID: UUID?,
                movedPosition: Bool,
                supersetChanged: Bool,
                addedWorkoutSetIDs: [UUID],
                removedRoutineSetIDs: [UUID],
                setTypeChangedRoutineSetIDs: [UUID]
            ) {
                self.workoutExerciseID = workoutExerciseID
                self.matchedRoutineExerciseID = matchedRoutineExerciseID
                self.movedPosition = movedPosition
                self.supersetChanged = supersetChanged
                self.addedWorkoutSetIDs = addedWorkoutSetIDs
                self.removedRoutineSetIDs = removedRoutineSetIDs
                self.setTypeChangedRoutineSetIDs = setTypeChangedRoutineSetIDs
            }
        }

        /// Workout exercise ids with no matching routine exercise (added).
        public let addedExerciseIDs: [UUID]
        /// Routine exercise ids no longer referenced by the workout (removed).
        public let removedRoutineExerciseIDs: [UUID]
        public let exercisePlans: [ExercisePlan]

        public init(
            addedExerciseIDs: [UUID],
            removedRoutineExerciseIDs: [UUID],
            exercisePlans: [ExercisePlan]
        ) {
            self.addedExerciseIDs = addedExerciseIDs
            self.removedRoutineExerciseIDs = removedRoutineExerciseIDs
            self.exercisePlans = exercisePlans
        }

        public var hasChanges: Bool {
            !addedExerciseIDs.isEmpty
                || !removedRoutineExerciseIDs.isEmpty
                || exercisePlans.contains {
                    $0.movedPosition
                        || $0.supersetChanged
                        || !$0.addedWorkoutSetIDs.isEmpty
                        || !$0.removedRoutineSetIDs.isEmpty
                        || !$0.setTypeChangedRoutineSetIDs.isEmpty
                }
        }

        /// Short, human-readable summary for the confirmation prompt.
        public var summary: String {
            var parts: [String] = []
            let addedEx = addedExerciseIDs.count
            let removedEx = removedRoutineExerciseIDs.count
            if addedEx > 0 { parts.append("\(addedEx) exercise\(addedEx == 1 ? "" : "s") added") }
            if removedEx > 0 { parts.append("\(removedEx) exercise\(removedEx == 1 ? "" : "s") removed") }
            var addedSets = 0, removedSets = 0, typeChanged = 0
            var moved = false, regrouped = false
            for p in exercisePlans {
                addedSets += p.addedWorkoutSetIDs.count
                removedSets += p.removedRoutineSetIDs.count
                typeChanged += p.setTypeChangedRoutineSetIDs.count
                moved = moved || p.movedPosition
                regrouped = regrouped || p.supersetChanged
            }
            if addedSets > 0 { parts.append("\(addedSets) set\(addedSets == 1 ? "" : "s") added") }
            if removedSets > 0 { parts.append("\(removedSets) set\(removedSets == 1 ? "" : "s") removed") }
            if typeChanged > 0 { parts.append("\(typeChanged) set type\(typeChanged == 1 ? "" : "s") changed") }
            if moved { parts.append("order changed") }
            if regrouped { parts.append("supersets changed") }
            return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
        }
    }

    // MARK: - Detect

    /// Builds a `Plan` describing how `workout` differs structurally from the
    /// `routine` it was started from. Does not mutate anything.
    public static func detect(workout: WorkoutModel, routine: RoutineModel) -> Plan {
        let workoutExercises = workout.exercises.sorted { $0.position < $1.position }
        let routineExercises = routine.exercises.sorted { $0.position < $1.position }
        let routineByID = Dictionary(routineExercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var addedExerciseIDs: [UUID] = []
        var exercisePlans: [Plan.ExercisePlan] = []
        let referencedRoutineIDs = Set(workoutExercises.compactMap(\.sourceRoutineExerciseID))

        for we in workoutExercises {
            guard let routineID = we.sourceRoutineExerciseID,
                  let re = routineByID[routineID] else {
                addedExerciseIDs.append(we.id)
                continue
            }
            exercisePlans.append(plan(for: we, matchedTo: re))
        }

        let removedRoutineExerciseIDs = routineExercises
            .filter { !referencedRoutineIDs.contains($0.id) }
            .map(\.id)

        return Plan(
            addedExerciseIDs: addedExerciseIDs,
            removedRoutineExerciseIDs: removedRoutineExerciseIDs,
            exercisePlans: exercisePlans
        )
    }

    /// Per-exercise set-level diff. Cardio exercises carry their target as a
    /// single `RoutineSetModel` with a duration; the workout has no strength
    /// sets for them, so set-level diffing is skipped to avoid falsely
    /// reporting the cardio target as "removed".
    private static func plan(
        for we: WorkoutExerciseModel,
        matchedTo re: RoutineExerciseModel
    ) -> Plan.ExercisePlan {
        let movedPosition = we.position != re.position
        let supersetChanged = we.supersetGroup != re.supersetGroup

        let routineSets = re.sets.sorted { $0.position < $1.position }
        let isCardio = routineSets.allSatisfy { $0.targetDurationSeconds != nil }
        if isCardio {
            return Plan.ExercisePlan(
                workoutExerciseID: we.id,
                matchedRoutineExerciseID: re.id,
                movedPosition: movedPosition,
                supersetChanged: supersetChanged,
                addedWorkoutSetIDs: [],
                removedRoutineSetIDs: [],
                setTypeChangedRoutineSetIDs: []
            )
        }

        let workoutSets = we.sets.sorted { $0.position < $1.position }
        let routineSetByID = Dictionary(routineSets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var addedWorkoutSetIDs: [UUID] = []
        var setTypeChangedRoutineSetIDs: [UUID] = []
        let referencedRoutineSetIDs = Set(workoutSets.compactMap(\.sourceRoutineSetID))

        for ws in workoutSets {
            if let routineSetID = ws.sourceRoutineSetID,
               let rs = routineSetByID[routineSetID] {
                if ws.setType != rs.setType {
                    setTypeChangedRoutineSetIDs.append(rs.id)
                }
            } else {
                addedWorkoutSetIDs.append(ws.id)
            }
        }

        let removedRoutineSetIDs = routineSets
            .filter { !referencedRoutineSetIDs.contains($0.id) }
            .map(\.id)

        return Plan.ExercisePlan(
            workoutExerciseID: we.id,
            matchedRoutineExerciseID: re.id,
            movedPosition: movedPosition,
            supersetChanged: supersetChanged,
            addedWorkoutSetIDs: addedWorkoutSetIDs,
            removedRoutineSetIDs: removedRoutineSetIDs,
            setTypeChangedRoutineSetIDs: setTypeChangedRoutineSetIDs
        )
    }

    // MARK: - Apply

    /// Mutates `routine` so its structure mirrors the structural changes in
    /// `workout`, preserving standing targets on matched sets and exercises.
    /// Newly added sets have their performed values copied into target fields
    /// (reps → `targetRepsLow`/`High`, weight → `targetWeight`, rpe →
    /// `targetRPE`, setType → setType, durationSeconds →
    /// `targetDurationSeconds`). Inserts new models into `context`.
    public static func apply(_ plan: Plan, to routine: RoutineModel, from workout: WorkoutModel, in context: ModelContext) {
        let workoutByID = Dictionary(workout.exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let routineExercises = routine.exercises.sorted { $0.position < $1.position }
        let routineByID = Dictionary(routineExercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Remove exercises no longer present in the workout.
        for removedID in plan.removedRoutineExerciseIDs {
            if let re = routineByID[removedID] {
                context.delete(re)
            }
        }

        // 2. Update matched exercises + their sets.
        for ep in plan.exercisePlans {
            guard let we = workoutByID[ep.workoutExerciseID],
                  let re = ep.matchedRoutineExerciseID.flatMap({ routineByID[$0] }) else { continue }
            if ep.movedPosition { re.position = we.position }
            if ep.supersetChanged { re.supersetGroup = we.supersetGroup }
            re.updatedAt = Date()
            applySets(ep, workoutExercise: we, routineExercise: re, in: context)
        }

        // 3. Add exercises created mid-session.
        for addedID in plan.addedExerciseIDs {
            guard let we = workoutByID[addedID] else { continue }
            let re = RoutineExerciseModel(
                userID: routine.userID,
                exerciseID: we.exerciseID,
                position: we.position,
                supersetGroup: we.supersetGroup,
                notes: we.notes,
                sets: []
            )
            context.insert(re)
            routine.exercises.append(re)
            // Seed routine sets from the workout's performed values. Cardio
            // exercises carry no strength sets in the workout (a linked
            // CardioSessionModel holds their data), so fall back to a single
            // duration target seeded from the session — mirroring the routine
            // editor's cardio target shape.
            let sortedWorkoutSets = we.sets.sorted { $0.position < $1.position }
            if sortedWorkoutSets.isEmpty {
                let session = workout.cardioSessions.first { $0.workoutExerciseID == we.id }
                let cardioTarget = RoutineSetModel(
                    userID: routine.userID,
                    position: 0,
                    targetDurationSeconds: session?.durationSeconds ?? 1_800
                )
                context.insert(cardioTarget)
                re.sets = [cardioTarget]
            } else {
                let newSets = sortedWorkoutSets.map { ws -> RoutineSetModel in
                    let target = routineTarget(from: ws, userID: routine.userID)
                    context.insert(target)
                    return target
                }
                re.sets = newSets
            }
        }

        routine.updatedAt = Date()
    }

    /// Applies set-level changes to a matched routine exercise: deletes removed
    /// sets, updates set type on matched sets (preserving targets), and creates
    /// new routine sets for sets added mid-session.
    private static func applySets(
        _ ep: Plan.ExercisePlan,
        workoutExercise we: WorkoutExerciseModel,
        routineExercise re: RoutineExerciseModel,
        in context: ModelContext
    ) {
        let routineSets = re.sets.sorted { $0.position < $1.position }
        let routineSetByID = Dictionary(routineSets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Delete removed sets.
        for removedID in ep.removedRoutineSetIDs {
            if let rs = routineSetByID[removedID] {
                context.delete(rs)
            }
        }

        // Update set type on matched sets (keep standing targets).
        for changedID in ep.setTypeChangedRoutineSetIDs {
            if let rs = routineSetByID[changedID],
               let ws = we.sets.first(where: { $0.sourceRoutineSetID == changedID }) {
                rs.setType = ws.setType
            }
        }

        // Rebuild the sets array in workout order, repositioning matched sets
        // and creating new targets for added sets.
        let workoutSets = we.sets.sorted { $0.position < $1.position }
        var rebuilt: [RoutineSetModel] = []
        for ws in workoutSets {
            if let routineSetID = ws.sourceRoutineSetID,
               let rs = routineSetByID[routineSetID] {
                rs.position = ws.position
                rebuilt.append(rs)
            } else {
                let target = routineTarget(from: ws, userID: re.userID)
                target.position = ws.position
                context.insert(target)
                rebuilt.append(target)
            }
        }
        re.sets = rebuilt
    }

    /// Maps a performed `SetModel` onto a `RoutineSetModel` target. Performed
    /// reps collapse to a single-value range (`low == high`), and performed
    /// weight/rpe/duration carry through. Used only for newly added sets.
    private static func routineTarget(from ws: SetModel, userID: UUID) -> RoutineSetModel {
        RoutineSetModel(
            userID: userID,
            position: ws.position,
            setType: ws.setType,
            targetRepsLow: ws.reps,
            targetRepsHigh: ws.reps,
            targetWeight: ws.weight,
            targetRPE: ws.rpe,
            targetRIR: ws.rir,
            targetDurationSeconds: ws.durationSeconds
        )
    }
}
