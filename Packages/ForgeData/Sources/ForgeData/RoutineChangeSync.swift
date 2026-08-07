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
public enum RoutineChangeSync {

    // MARK: - Plan

    /// A description of the structural differences between a workout and the
    /// routine it was started from. Pure value type; safe to inspect before
    /// deciding whether to apply.
    public struct Plan: Equatable {
        public struct BlockPlan: Equatable {
            public let workoutBlockID: UUID
            public let matchedRoutineBlockID: UUID?
            public let movedPosition: Bool
            public let planChanged: Bool

            public init(
                workoutBlockID: UUID,
                matchedRoutineBlockID: UUID?,
                movedPosition: Bool,
                planChanged: Bool
            ) {
                self.workoutBlockID = workoutBlockID
                self.matchedRoutineBlockID = matchedRoutineBlockID
                self.movedPosition = movedPosition
                self.planChanged = planChanged
            }
        }

        public struct ExercisePlan: Equatable {
            /// Workout exercise driving the change (reference; not owned).
            public let workoutExerciseID: UUID
            /// Matching routine exercise, nil when the exercise was added
            /// mid-session.
            public let matchedRoutineExerciseID: UUID?
            /// The row was swapped to a different exercise mid-session
            /// (in-place replace keeps the routine lineage but changes
            /// `exerciseID`). Without this the swap was invisible: every other
            /// change applied and the routine silently kept the old movement.
            public let exerciseChanged: Bool
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
            /// The workout's guided yoga flow differs from the routine's
            /// (edited mid-session), so the routine's flow gets updated.
            public let flowChanged: Bool

            public init(
                workoutExerciseID: UUID,
                matchedRoutineExerciseID: UUID?,
                exerciseChanged: Bool = false,
                movedPosition: Bool,
                supersetChanged: Bool,
                addedWorkoutSetIDs: [UUID],
                removedRoutineSetIDs: [UUID],
                setTypeChangedRoutineSetIDs: [UUID],
                flowChanged: Bool = false
            ) {
                self.workoutExerciseID = workoutExerciseID
                self.matchedRoutineExerciseID = matchedRoutineExerciseID
                self.exerciseChanged = exerciseChanged
                self.movedPosition = movedPosition
                self.supersetChanged = supersetChanged
                self.addedWorkoutSetIDs = addedWorkoutSetIDs
                self.removedRoutineSetIDs = removedRoutineSetIDs
                self.setTypeChangedRoutineSetIDs = setTypeChangedRoutineSetIDs
                self.flowChanged = flowChanged
            }
        }

        /// Workout exercise ids with no matching routine exercise (added).
        public let addedExerciseIDs: [UUID]
        /// Routine exercise ids no longer referenced by the workout (removed).
        public let removedRoutineExerciseIDs: [UUID]
        public let exercisePlans: [ExercisePlan]
        public let addedBlockIDs: [UUID]
        public let removedRoutineBlockIDs: [UUID]
        public let blockPlans: [BlockPlan]

        public init(
            addedExerciseIDs: [UUID],
            removedRoutineExerciseIDs: [UUID],
            exercisePlans: [ExercisePlan],
            addedBlockIDs: [UUID] = [],
            removedRoutineBlockIDs: [UUID] = [],
            blockPlans: [BlockPlan] = []
        ) {
            self.addedExerciseIDs = addedExerciseIDs
            self.removedRoutineExerciseIDs = removedRoutineExerciseIDs
            self.exercisePlans = exercisePlans
            self.addedBlockIDs = addedBlockIDs
            self.removedRoutineBlockIDs = removedRoutineBlockIDs
            self.blockPlans = blockPlans
        }

        public var hasChanges: Bool {
            !addedExerciseIDs.isEmpty
                || !removedRoutineExerciseIDs.isEmpty
                || !addedBlockIDs.isEmpty
                || !removedRoutineBlockIDs.isEmpty
                || blockPlans.contains { $0.movedPosition || $0.planChanged }
                || exercisePlans.contains {
                    $0.exerciseChanged
                        || $0.movedPosition
                        || $0.supersetChanged
                        || !$0.addedWorkoutSetIDs.isEmpty
                        || !$0.removedRoutineSetIDs.isEmpty
                        || !$0.setTypeChangedRoutineSetIDs.isEmpty
                        || $0.flowChanged
                }
        }

        /// Short, human-readable summary for the confirmation prompt.
        public var summary: String {
            var parts: [String] = []
            let addedEx = addedExerciseIDs.count
            let removedEx = removedRoutineExerciseIDs.count
            if addedEx > 0 { parts.append("\(addedEx) exercise\(addedEx == 1 ? "" : "s") added") }
            if removedEx > 0 { parts.append("\(removedEx) exercise\(removedEx == 1 ? "" : "s") removed") }
            let swapped = exercisePlans.count(where: \.exerciseChanged)
            if swapped > 0 { parts.append("\(swapped) exercise\(swapped == 1 ? "" : "s") swapped") }
            let addedBlocks = addedBlockIDs.count
            let removedBlocks = removedRoutineBlockIDs.count
            if addedBlocks > 0 { parts.append("\(addedBlocks) block\(addedBlocks == 1 ? "" : "s") added") }
            if removedBlocks > 0 { parts.append("\(removedBlocks) block\(removedBlocks == 1 ? "" : "s") removed") }
            var addedSets = 0, removedSets = 0, typeChanged = 0
            var moved = false, regrouped = false
            for p in exercisePlans {
                addedSets += p.addedWorkoutSetIDs.count
                removedSets += p.removedRoutineSetIDs.count
                typeChanged += p.setTypeChangedRoutineSetIDs.count
                moved = moved || p.movedPosition
                regrouped = regrouped || p.supersetChanged
            }
            moved = moved || blockPlans.contains(where: \.movedPosition)
            if addedSets > 0 { parts.append("\(addedSets) set\(addedSets == 1 ? "" : "s") added") }
            if removedSets > 0 { parts.append("\(removedSets) set\(removedSets == 1 ? "" : "s") removed") }
            if typeChanged > 0 { parts.append("\(typeChanged) set type\(typeChanged == 1 ? "" : "s") changed") }
            if moved { parts.append("order changed") }
            if regrouped { parts.append("supersets changed") }
            if exercisePlans.contains(where: \.flowChanged) { parts.append("yoga flow updated") }
            if blockPlans.contains(where: \.planChanged) { parts.append("block plan updated") }
            return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
        }
    }

    // MARK: - Detect

    /// Builds a `Plan` describing how `workout` differs structurally from the
    /// `routine` it was started from. Does not mutate anything.
    public static func detect(workout: WorkoutModel, routine: RoutineModel) -> Plan {
        let workoutExercises = workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .sorted { $0.position < $1.position }
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

        let workoutBlocks = workout.blocks.sorted { $0.position < $1.position }
        let routineBlocks = routine.blocks.sorted { $0.position < $1.position }
        let routineBlocksByID = Dictionary(routineBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let referencedRoutineBlockIDs = Set(workoutBlocks.compactMap(\.sourceRoutineBlockID))
        var addedBlockIDs: [UUID] = []
        var blockPlans: [Plan.BlockPlan] = []
        for block in workoutBlocks {
            guard let routineID = block.sourceRoutineBlockID,
                  let routineBlock = routineBlocksByID[routineID] else {
                addedBlockIDs.append(block.id)
                continue
            }
            blockPlans.append(Plan.BlockPlan(
                workoutBlockID: block.id,
                matchedRoutineBlockID: routineBlock.id,
                movedPosition: block.position != routineBlock.position,
                planChanged: block.planSnapshotJSON != routineBlock.planJSON
            ))
        }
        let removedRoutineBlockIDs = routineBlocks
            .filter { !referencedRoutineBlockIDs.contains($0.id) }
            .map(\.id)

        return Plan(
            addedExerciseIDs: addedExerciseIDs,
            removedRoutineExerciseIDs: removedRoutineExerciseIDs,
            exercisePlans: exercisePlans,
            addedBlockIDs: addedBlockIDs,
            removedRoutineBlockIDs: removedRoutineBlockIDs,
            blockPlans: blockPlans
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
        // In-place replace keeps the routine lineage and changes only the
        // exercise identity — the one structural change the diff used to
        // ignore entirely.
        let exerciseChanged = we.exerciseID != re.exerciseID
        let movedPosition = we.position != re.position
        let supersetChanged = we.supersetGroup != re.supersetGroup

        // Guided-flow drift: the routine had a flow that was edited
        // mid-session, or a bare pose grew a real multi-pose flow. A workout
        // flow synthesized from a single pose (routine flow nil) is factory
        // scaffolding, not a user change.
        let flowChanged: Bool = {
            guard let workoutFlow = we.yogaFlowJSON else { return false }
            if let routineFlow = re.yogaFlowJSON { return workoutFlow != routineFlow }
            return (YogaFlowPlan.decode(from: workoutFlow)?.steps.count ?? 0) > 1
        }()

        let routineSets = re.sets.sorted { $0.position < $1.position }
        // AMRAP is a strength set with a time window, not a session-based
        // cardio target. Treating every duration target as cardio made later
        // AMRAP type changes invisible to the routine sync.
        let isCardio = we.sets.isEmpty && routineSets.allSatisfy {
            $0.targetDurationSeconds != nil && $0.setType != .amrap
        }
        if isCardio {
            return Plan.ExercisePlan(
                workoutExerciseID: we.id,
                matchedRoutineExerciseID: re.id,
                exerciseChanged: exerciseChanged,
                movedPosition: movedPosition,
                supersetChanged: supersetChanged,
                addedWorkoutSetIDs: [],
                removedRoutineSetIDs: [],
                setTypeChangedRoutineSetIDs: [],
                flowChanged: flowChanged
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
            exerciseChanged: exerciseChanged,
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
        let workoutByID = Dictionary(
            workout.exercises.filter { $0.generatedByWorkoutBlockID == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let routineExercises = routine.exercises.sorted { $0.position < $1.position }
        let routineByID = Dictionary(routineExercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let workoutBlocksByID = Dictionary(workout.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let routineBlocksByID = Dictionary(routine.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // 1. Remove exercises no longer present in the workout.
        for removedID in plan.removedRoutineExerciseIDs {
            if let re = routineByID[removedID] {
                context.delete(re)
            }
        }
        for removedID in plan.removedRoutineBlockIDs {
            if let block = routineBlocksByID[removedID] { context.delete(block) }
        }

        // 2. Update matched exercises + their sets.
        for ep in plan.exercisePlans {
            guard let we = workoutByID[ep.workoutExerciseID],
                  let re = ep.matchedRoutineExerciseID.flatMap({ routineByID[$0] }) else { continue }
            if ep.exerciseChanged {
                re.exerciseID = we.exerciseID
                re.intervalPlanJSON = we.intervalPlanJSON
                re.yogaFlowJSON = we.yogaFlowJSON
            }
            if ep.movedPosition { re.position = we.position }
            if ep.supersetChanged { re.supersetGroup = we.supersetGroup }
            if ep.flowChanged { re.yogaFlowJSON = we.yogaFlowJSON }
            re.updatedAt = Date()
            applySets(ep, workoutExercise: we, routineExercise: re, in: context)

            // A swap across modalities empties the row's set list (the work
            // moved into a cardio/yoga session), leaving the routine exercise
            // with its old-shaped or no targets. Reseed the same target shape
            // the added-exercise path uses so the routine stays editable.
            if ep.exerciseChanged, we.sets.isEmpty,
               let session = workout.cardioSessions.first(where: { $0.workoutExerciseID == we.id }) {
                if session.modality == CardioSessionModel.yogaModality {
                    re.yogaFlowJSON = we.yogaFlowJSON
                    for rs in re.sets { context.delete(rs) }
                    re.sets = []
                } else if re.sets.contains(where: { $0.targetDurationSeconds == nil }) || re.sets.isEmpty {
                    for rs in re.sets { context.delete(rs) }
                    let cardioTarget = RoutineSetModel(
                        userID: routine.userID,
                        position: 0,
                        targetDurationSeconds: session.durationSeconds ?? 1_800
                    )
                    context.insert(cardioTarget)
                    re.sets = [cardioTarget]
                }
            }
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
                intervalPlanJSON: we.intervalPlanJSON,
                yogaFlowJSON: we.yogaFlowJSON,
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
                if session?.modality == CardioSessionModel.yogaModality {
                    // Yoga blocks carry no target sets — the flow is the target.
                    re.yogaFlowJSON = we.yogaFlowJSON
                } else {
                    let cardioTarget = RoutineSetModel(
                        userID: routine.userID,
                        position: 0,
                        targetDurationSeconds: session?.durationSeconds ?? 1_800
                    )
                    context.insert(cardioTarget)
                    re.sets = [cardioTarget]
                }
            } else {
                let newSets = sortedWorkoutSets.map { ws -> RoutineSetModel in
                    let target = routineTarget(from: ws, userID: routine.userID)
                    context.insert(target)
                    return target
                }
                re.sets = newSets
            }
        }

        for blockPlan in plan.blockPlans {
            guard let workoutBlock = workoutBlocksByID[blockPlan.workoutBlockID],
                  let routineBlockID = blockPlan.matchedRoutineBlockID,
                  let routineBlock = routineBlocksByID[routineBlockID] else { continue }
            if blockPlan.movedPosition { routineBlock.position = workoutBlock.position }
            if blockPlan.planChanged { routineBlock.planJSON = workoutBlock.planSnapshotJSON }
            routineBlock.updatedAt = .now
        }

        for addedID in plan.addedBlockIDs {
            guard let workoutBlock = workoutBlocksByID[addedID] else { continue }
            let block = RoutineBlockModel(
                userID: routine.userID,
                kind: workoutBlock.kind,
                position: workoutBlock.position,
                planJSON: workoutBlock.planSnapshotJSON
            )
            context.insert(block)
            routine.blocks.append(block)
        }

        if routine.blocks.contains(where: { $0.kind == .conditioning }) {
            routine.conditioningPlanJSON = nil
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
        // A session-based row (cardio target, yoga flow) carries no workout
        // sets at all — its work lives in a CardioSessionModel. `detect`
        // already skips set-level diffing for these; the rebuild below must
        // skip them too, or it "rebuilds" the routine's target list from an
        // empty workout list and silently wipes every cardio duration target
        // in the routine on any accepted update.
        let workoutSets = we.sets.sorted { $0.position < $1.position }
        guard !(workoutSets.isEmpty && ep.removedRoutineSetIDs.isEmpty) else { return }

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
                applyTypeSpecificPlan(from: ws, to: rs)
            }
        }

        // Rebuild the sets array in workout order, repositioning matched sets
        // and creating new targets for added sets.
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

    /// Type-specific shape is structural routine intent. When a flat set is
    /// converted live, preserve the performed block shape (or seed the same
    /// usable defaults as the routine editor) while leaving standing load,
    /// rep-range, and effort targets untouched.
    private static func applyTypeSpecificPlan(from workoutSet: SetModel, to routineSet: RoutineSetModel) {
        routineSet.plannedMiniSetCount = nil
        routineSet.plannedMiniRepsJSON = nil
        routineSet.targetDurationSeconds = nil

        switch workoutSet.setType {
        case .myoRep:
            routineSet.plannedMiniSetCount = max(
                1,
                max(workoutSet.miniReps.count, workoutSet.plannedMiniSetCount ?? 0)
            )
        case .cluster:
            let plan = workoutSet.miniReps.isEmpty ? workoutSet.plannedMiniReps : workoutSet.miniReps
            routineSet.plannedMiniReps = plan.isEmpty ? [3, 3, 3, 3] : plan
        case .amrap:
            routineSet.targetDurationSeconds = workoutSet.durationSeconds ?? 60
        default:
            break
        }
    }

    /// Maps a performed `SetModel` onto a `RoutineSetModel` target. Performed
    /// reps collapse to a single-value range (`low == high`), and performed
    /// weight/rpe/duration carry through. Structured sets carry their shape:
    /// the minis a lifter actually did become the plan (myo keeps the count,
    /// cluster keeps the segment reps as goals). Used only for newly added sets.
    private static func routineTarget(from ws: SetModel, userID: UUID) -> RoutineSetModel {
        let target = RoutineSetModel(
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
        applyTypeSpecificPlan(from: ws, to: target)
        return target
    }
}
