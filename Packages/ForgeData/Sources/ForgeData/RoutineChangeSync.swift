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
            /// Exact routine-set lineage for the workout sets that remain in
            /// the routine. Normally this mirrors `sourceRoutineSetID`. It is
            /// explicit so a legacy split replacement can bind its fresh
            /// replacement rows back to the unfinished routine targets rather
            /// than treating every one as an added target.
            public let matchedRoutineSetIDsByWorkoutSetID: [UUID: UUID]
            /// Routine targets retained ahead of the replacement row. Old
            /// versions split a live replacement into a completed history row
            /// plus a fresh exercise row; those completed targets still belong
            /// to the routine even though the history row itself must not.
            public let retainedRoutineSetIDs: [UUID]
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
                matchedRoutineSetIDsByWorkoutSetID: [UUID: UUID] = [:],
                retainedRoutineSetIDs: [UUID] = [],
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
                self.matchedRoutineSetIDsByWorkoutSetID = matchedRoutineSetIDsByWorkoutSetID
                self.retainedRoutineSetIDs = retainedRoutineSetIDs
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
        /// Completed history rows left behind by the pre-August-2026 split
        /// replacement implementation. They remain part of workout history,
        /// but are deliberately excluded from the routine graph.
        public let historyOnlyWorkoutExerciseIDs: [UUID]

        public init(
            addedExerciseIDs: [UUID],
            removedRoutineExerciseIDs: [UUID],
            exercisePlans: [ExercisePlan],
            addedBlockIDs: [UUID] = [],
            removedRoutineBlockIDs: [UUID] = [],
            blockPlans: [BlockPlan] = [],
            historyOnlyWorkoutExerciseIDs: [UUID] = []
        ) {
            self.addedExerciseIDs = addedExerciseIDs
            self.removedRoutineExerciseIDs = removedRoutineExerciseIDs
            self.exercisePlans = exercisePlans
            self.addedBlockIDs = addedBlockIDs
            self.removedRoutineBlockIDs = removedRoutineBlockIDs
            self.blockPlans = blockPlans
            self.historyOnlyWorkoutExerciseIDs = historyOnlyWorkoutExerciseIDs
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
            .sorted(by: positionThenID)
        let routineExercises = routine.exercises.sorted(by: positionThenID)
        let routineByID = Dictionary(routineExercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // c98cc28-era workouts split a replacement into two adjacent rows:
        // completed work kept the routine lineage on the old exercise, while
        // the replacement received nil lineage. Detect that exact persisted
        // fingerprint so accepting "Update Routine" means replacement, not
        // "keep old + add new". Current replacements are one-row/in-place;
        // this compatibility path is intentionally narrow to avoid guessing
        // about ordinary exercises the user deliberately added.
        let legacySplits = legacySplitReplacements(
            workoutExercises: workoutExercises,
            routineByID: routineByID
        )
        let legacyByReplacementID = Dictionary(
            legacySplits.map { ($0.replacementWorkoutExerciseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let historyOnlyIDs = Set(legacySplits.map(\.historyWorkoutExerciseID))

        var addedExerciseIDs: [UUID] = []
        var exercisePlans: [Plan.ExercisePlan] = []
        var referencedRoutineIDs = Set<UUID>()

        for we in workoutExercises {
            guard !historyOnlyIDs.contains(we.id) else { continue }
            let legacy = legacyByReplacementID[we.id]
            let routineID = legacy?.routineExerciseID ?? we.sourceRoutineExerciseID
            guard let routineID,
                  let re = routineByID[routineID],
                  referencedRoutineIDs.insert(routineID).inserted else {
                addedExerciseIDs.append(we.id)
                continue
            }
            exercisePlans.append(plan(
                for: we,
                matchedTo: re,
                explicitSetMatches: legacy?.routineSetIDByWorkoutSetID ?? [:],
                retainedRoutineSetIDs: legacy?.retainedRoutineSetIDs ?? []
            ))
        }

        let removedRoutineExerciseIDs = routineExercises
            .filter { !referencedRoutineIDs.contains($0.id) }
            .map(\.id)

        let workoutBlocks = workout.blocks.sorted(by: positionThenID)
        let routineBlocks = routine.blocks.sorted(by: positionThenID)
        let routineBlocksByID = Dictionary(routineBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var referencedRoutineBlockIDs = Set<UUID>()
        var addedBlockIDs: [UUID] = []
        var blockPlans: [Plan.BlockPlan] = []
        for block in workoutBlocks {
            guard let routineID = block.sourceRoutineBlockID,
                  let routineBlock = routineBlocksByID[routineID],
                  referencedRoutineBlockIDs.insert(routineID).inserted else {
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
            blockPlans: blockPlans,
            historyOnlyWorkoutExerciseIDs: historyOnlyIDs.sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// Per-exercise set-level diff. Cardio exercises carry their target as a
    /// single `RoutineSetModel` with a duration; the workout has no strength
    /// sets for them, so set-level diffing is skipped to avoid falsely
    /// reporting the cardio target as "removed".
    private static func plan(
        for we: WorkoutExerciseModel,
        matchedTo re: RoutineExerciseModel,
        explicitSetMatches: [UUID: UUID] = [:],
        retainedRoutineSetIDs: [UUID] = []
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
                matchedRoutineSetIDsByWorkoutSetID: [:],
                retainedRoutineSetIDs: retainedRoutineSetIDs,
                flowChanged: flowChanged
            )
        }

        let workoutSets = we.sets.sorted { $0.position < $1.position }
        let routineSetByID = Dictionary(routineSets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var addedWorkoutSetIDs: [UUID] = []
        var setTypeChangedRoutineSetIDs: [UUID] = []
        var matchedRoutineSetIDsByWorkoutSetID: [UUID: UUID] = [:]
        var referencedRoutineSetIDs = Set(retainedRoutineSetIDs.filter { routineSetByID[$0] != nil })

        for ws in workoutSets {
            let candidateID = explicitSetMatches[ws.id] ?? ws.sourceRoutineSetID
            if let routineSetID = candidateID,
               let rs = routineSetByID[routineSetID],
               referencedRoutineSetIDs.insert(routineSetID).inserted {
                matchedRoutineSetIDsByWorkoutSetID[ws.id] = routineSetID
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
            setTypeChangedRoutineSetIDs: setTypeChangedRoutineSetIDs,
            matchedRoutineSetIDsByWorkoutSetID: matchedRoutineSetIDsByWorkoutSetID,
            retainedRoutineSetIDs: retainedRoutineSetIDs
        )
    }

    // MARK: - Legacy replacement recovery

    private struct LegacySplitReplacement {
        let historyWorkoutExerciseID: UUID
        let replacementWorkoutExerciseID: UUID
        let routineExerciseID: UUID
        let retainedRoutineSetIDs: [UUID]
        let routineSetIDByWorkoutSetID: [UUID: UUID]
    }

    /// Recognizes only the exact graph shape written by the retired split
    /// replacement implementation. The timestamp equality is its strongest
    /// provenance marker: that implementation stamped the old row's
    /// `updatedAt` and the replacement row's `createdAt` with the same `now`.
    private static func legacySplitReplacements(
        workoutExercises: [WorkoutExerciseModel],
        routineByID: [UUID: RoutineExerciseModel]
    ) -> [LegacySplitReplacement] {
        guard workoutExercises.count > 1 else { return [] }
        var results: [LegacySplitReplacement] = []
        var consumed = Set<UUID>()

        for index in workoutExercises.indices.dropLast() {
            let history = workoutExercises[index]
            let replacement = workoutExercises[index + 1]
            guard !consumed.contains(history.id), !consumed.contains(replacement.id),
                  let routineID = history.sourceRoutineExerciseID,
                  let routineExercise = routineByID[routineID],
                  history.exerciseID == routineExercise.exerciseID,
                  replacement.sourceRoutineExerciseID == nil,
                  replacement.exerciseID != history.exerciseID,
                  replacement.position == history.position + 1,
                  replacement.supersetGroup == nil,
                  history.restSeconds == replacement.restSeconds,
                  history.microRestSeconds == replacement.microRestSeconds,
                  abs(history.updatedAt.timeIntervalSince(replacement.createdAt)) < 0.001
            else { continue }

            let routineSets = routineExercise.sets.sorted(by: positionThenID)
            let routineSetByID = Dictionary(
                routineSets.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let completedHistorySets = history.sets.sorted(by: positionThenID)
            guard !completedHistorySets.isEmpty,
                  completedHistorySets.allSatisfy({ $0.completedAt != nil }),
                  replacement.sets.allSatisfy({ $0.sourceRoutineSetID == nil })
            else { continue }

            let retained = completedHistorySets.compactMap(\.sourceRoutineSetID)
            guard retained.count == completedHistorySets.count,
                  Set(retained).count == retained.count,
                  retained.allSatisfy({ routineSetByID[$0] != nil })
            else { continue }

            let retainedSet = Set(retained)
            let retainedInRoutineOrder = routineSets.filter { retainedSet.contains($0.id) }.map(\.id)
            let remainingRoutineIDs = routineSets.filter { !retainedSet.contains($0.id) }.map(\.id)
            let replacementSets = replacement.sets.sorted(by: positionThenID)
            var matches: [UUID: UUID] = [:]
            for (workoutSet, routineSetID) in zip(replacementSets, remainingRoutineIDs) {
                matches[workoutSet.id] = routineSetID
            }

            results.append(LegacySplitReplacement(
                historyWorkoutExerciseID: history.id,
                replacementWorkoutExerciseID: replacement.id,
                routineExerciseID: routineID,
                retainedRoutineSetIDs: retainedInRoutineOrder,
                routineSetIDByWorkoutSetID: matches
            ))
            consumed.insert(history.id)
            consumed.insert(replacement.id)
        }
        return results
    }

    private static func positionThenID<T: AnyObject>(_ lhs: T, _ rhs: T) -> Bool {
        switch (lhs, rhs) {
        case let (lhs as WorkoutExerciseModel, rhs as WorkoutExerciseModel):
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        case let (lhs as RoutineExerciseModel, rhs as RoutineExerciseModel):
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        case let (lhs as SetModel, rhs as SetModel):
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        case let (lhs as RoutineSetModel, rhs as RoutineSetModel):
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        case let (lhs as WorkoutBlockModel, rhs as WorkoutBlockModel):
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        case let (lhs as RoutineBlockModel, rhs as RoutineBlockModel):
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.id.uuidString < rhs.id.uuidString
        default:
            return false
        }
    }

    // MARK: - Apply

    /// Mutates `routine` so its structure mirrors the structural changes in
    /// `workout`, preserving standing targets on matched sets and exercises.
    /// Newly added sets have their performed values copied into target fields
    /// (reps → `targetRepsLow`/`High`, weight → `targetWeight`, rpe →
    /// `targetRPE`, setType → setType, durationSeconds →
    /// `targetDurationSeconds`). Inserts new models into `context`.
    public static func apply(
        _ plan: Plan,
        to routine: RoutineModel,
        from workout: WorkoutModel,
        in context: ModelContext,
        now: Date = Date()
    ) {
        let originalExercises = routine.exercises
        let originalBlocks = routine.blocks
        let routineByID = Dictionary(
            originalExercises.sorted(by: positionThenID).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let routineBlocksByID = Dictionary(
            originalBlocks.sorted(by: positionThenID).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let exercisePlanByWorkoutID = Dictionary(
            plan.exercisePlans.map { ($0.workoutExerciseID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let blockPlanByWorkoutID = Dictionary(
            plan.blockPlans.map { ($0.workoutBlockID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let historyOnlyIDs = Set(plan.historyOnlyWorkoutExerciseIDs)

        let visibleExercises = workout.exercises.filter {
            $0.generatedByWorkoutBlockID == nil && !historyOnlyIDs.contains($0.id)
        }
        var orderedItems = visibleExercises.map(ReconciliationItem.exercise)
            + workout.blocks.map(ReconciliationItem.block)
        orderedItems.sort(by: reconciliationOrder)

        var desiredExercises: [RoutineExerciseModel] = []
        var desiredBlocks: [RoutineBlockModel] = []

        for (position, item) in orderedItems.enumerated() {
            switch item {
            case .exercise(let workoutExercise):
                let exercisePlan = exercisePlanByWorkoutID[workoutExercise.id]
                let routineExerciseID = exercisePlan?.matchedRoutineExerciseID ?? workoutExercise.id
                let isNew = exercisePlan?.matchedRoutineExerciseID == nil
                let routineExercise = routineByID[routineExerciseID]
                    ?? fetchRoutineExercise(id: routineExerciseID, in: context)
                    ?? {
                        let created = RoutineExerciseModel(
                            id: routineExerciseID,
                            userID: routine.userID,
                            exerciseID: workoutExercise.exerciseID,
                            position: position,
                            supersetGroup: workoutExercise.supersetGroup,
                            notes: isNew ? workoutExercise.notes : nil,
                            intervalPlanJSON: workoutExercise.intervalPlanJSON,
                            yogaFlowJSON: workoutExercise.yogaFlowJSON,
                            createdAt: now,
                            updatedAt: now
                        )
                        context.insert(created)
                        return created
                    }()

                // Identity and order are the accepted structural truth. Keep
                // standing notes/progression on matched rows; only a genuinely
                // new row adopts the workout note.
                routineExercise.exerciseID = workoutExercise.exerciseID
                routineExercise.position = position
                routineExercise.supersetGroup = workoutExercise.supersetGroup
                if isNew { routineExercise.notes = workoutExercise.notes }
                if isNew || exercisePlan?.exerciseChanged == true {
                    routineExercise.intervalPlanJSON = workoutExercise.intervalPlanJSON
                    routineExercise.yogaFlowJSON = workoutExercise.yogaFlowJSON
                } else if exercisePlan?.flowChanged == true {
                    routineExercise.yogaFlowJSON = workoutExercise.yogaFlowJSON
                }
                routineExercise.updatedAt = now

                let effectivePlan = exercisePlan ?? Plan.ExercisePlan(
                    workoutExerciseID: workoutExercise.id,
                    matchedRoutineExerciseID: nil,
                    movedPosition: false,
                    supersetChanged: false,
                    addedWorkoutSetIDs: workoutExercise.sets.map(\.id),
                    removedRoutineSetIDs: [],
                    setTypeChangedRoutineSetIDs: []
                )
                reconcileSets(
                    effectivePlan,
                    workoutExercise: workoutExercise,
                    routineExercise: routineExercise,
                    isNewExercise: isNew,
                    in: context,
                    now: now
                )
                desiredExercises.append(routineExercise)

            case .block(let workoutBlock):
                let blockPlan = blockPlanByWorkoutID[workoutBlock.id]
                let routineBlockID = blockPlan?.matchedRoutineBlockID ?? workoutBlock.id
                let isNew = blockPlan?.matchedRoutineBlockID == nil
                let routineBlock = routineBlocksByID[routineBlockID]
                    ?? fetchRoutineBlock(id: routineBlockID, in: context)
                    ?? {
                        let created = RoutineBlockModel(
                            id: routineBlockID,
                            userID: routine.userID,
                            kind: workoutBlock.kind,
                            position: position,
                            planJSON: workoutBlock.planSnapshotJSON,
                            createdAt: now,
                            updatedAt: now
                        )
                        context.insert(created)
                        return created
                    }()
                routineBlock.kind = workoutBlock.kind
                routineBlock.position = position
                if isNew || blockPlan?.planChanged == true {
                    routineBlock.planJSON = workoutBlock.planSnapshotJSON
                }
                routineBlock.updatedAt = now
                desiredBlocks.append(routineBlock)
            }
        }

        // Assign the exact graph before deleting stale objects. Relying on a
        // cascade delete alone leaves stale to-many snapshots in long-lived
        // contexts — the mechanism behind "old + replacement" and bad order.
        routine.exercises = desiredExercises
        routine.blocks = desiredBlocks
        let desiredExerciseObjects = Set(desiredExercises.map(ObjectIdentifier.init))
        for orphan in originalExercises where !desiredExerciseObjects.contains(ObjectIdentifier(orphan)) {
            context.delete(orphan)
        }
        let desiredBlockObjects = Set(desiredBlocks.map(ObjectIdentifier.init))
        for orphan in originalBlocks where !desiredBlockObjects.contains(ObjectIdentifier(orphan)) {
            context.delete(orphan)
        }

        if desiredBlocks.contains(where: { $0.kind == .conditioning }) {
            routine.conditioningPlanJSON = nil
        }
        routine.updatedAt = now
    }

    /// Rebuilds one exercise's exact target relationship. Existing lineage
    /// preserves standing targets; new workout rows use their performed values.
    /// IDs for new targets are the workout-set IDs, making a success mirror or
    /// retry idempotent across SwiftData contexts.
    private static func reconcileSets(
        _ plan: Plan.ExercisePlan,
        workoutExercise: WorkoutExerciseModel,
        routineExercise: RoutineExerciseModel,
        isNewExercise: Bool,
        in context: ModelContext,
        now: Date
    ) {
        let originalSets = routineExercise.sets
        let routineSetByID = Dictionary(
            originalSets.sorted(by: positionThenID).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let workoutSets = workoutExercise.sets.sorted(by: positionThenID)

        // A session-backed row has no strength sets. Preserve untouched legacy
        // data during an unrelated structural update, but never turn today's
        // completed session duration into tomorrow's goal. Explicit cardio
        // intent already lives on `intervalPlanJSON`.
        if workoutSets.isEmpty {
            let preservesExistingSessionTarget = !isNewExercise
                && !plan.exerciseChanged
                && plan.removedRoutineSetIDs.isEmpty
            if preservesExistingSessionTarget {
                let preserved = originalSets.sorted(by: positionThenID)
                for (index, set) in preserved.enumerated() { set.position = index }
                routineExercise.sets = preserved
                return
            }
            replaceSets(on: routineExercise, with: [], original: originalSets, in: context)
            return
        }

        var rebuilt: [RoutineSetModel] = []
        var usedRoutineSetIDs = Set<UUID>()

        for retainedID in plan.retainedRoutineSetIDs {
            guard usedRoutineSetIDs.insert(retainedID).inserted,
                  let retained = routineSetByID[retainedID]
                    ?? fetchRoutineSet(id: retainedID, in: context) else { continue }
            retained.position = rebuilt.count
            rebuilt.append(retained)
        }

        let changedTypeIDs = Set(plan.setTypeChangedRoutineSetIDs)
        for workoutSet in workoutSets {
            let matchedID = plan.matchedRoutineSetIDsByWorkoutSetID[workoutSet.id]
                ?? workoutSet.sourceRoutineSetID
            let usableMatchedID = matchedID.flatMap {
                usedRoutineSetIDs.insert($0).inserted ? $0 : nil
            }

            let target: RoutineSetModel
            if let usableMatchedID,
               let existing = routineSetByID[usableMatchedID]
                ?? fetchRoutineSet(id: usableMatchedID, in: context) {
                target = existing
                if changedTypeIDs.contains(usableMatchedID) {
                    target.setType = workoutSet.setType
                    applyTypeSpecificPlan(from: workoutSet, to: target)
                }
            } else {
                let deterministicID = workoutSet.id
                if let existing = routineSetByID[deterministicID]
                    ?? fetchRoutineSet(id: deterministicID, in: context) {
                    target = existing
                } else {
                    target = routineTarget(
                        from: workoutSet,
                        id: deterministicID,
                        userID: routineExercise.userID,
                        createdAt: now
                    )
                    context.insert(target)
                }
                usedRoutineSetIDs.insert(deterministicID)
            }
            target.position = rebuilt.count
            rebuilt.append(target)
        }

        replaceSets(on: routineExercise, with: rebuilt, original: originalSets, in: context)
    }

    private static func replaceSets(
        on exercise: RoutineExerciseModel,
        with desired: [RoutineSetModel],
        original: [RoutineSetModel],
        in context: ModelContext
    ) {
        exercise.sets = desired
        let desiredObjects = Set(desired.map(ObjectIdentifier.init))
        for orphan in original where !desiredObjects.contains(ObjectIdentifier(orphan)) {
            context.delete(orphan)
        }
    }

    private enum ReconciliationItem {
        case exercise(WorkoutExerciseModel)
        case block(WorkoutBlockModel)

        var position: Int {
            switch self {
            case .exercise(let value): value.position
            case .block(let value): value.position
            }
        }

        var id: UUID {
            switch self {
            case .exercise(let value): value.id
            case .block(let value): value.id
            }
        }

        // Old workout graphs can contain a position collision. Blocks were
        // explicitly placed into the mixed sequence, so keep them first at a
        // tie and then canonicalize every position to remove the ambiguity.
        var tiePriority: Int {
            switch self {
            case .block: 0
            case .exercise: 1
            }
        }
    }

    private static func reconciliationOrder(_ lhs: ReconciliationItem, _ rhs: ReconciliationItem) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.tiePriority != rhs.tiePriority { return lhs.tiePriority < rhs.tiePriority }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func fetchRoutineExercise(id: UUID, in context: ModelContext) -> RoutineExerciseModel? {
        let requestedID = id
        var descriptor = FetchDescriptor<RoutineExerciseModel>(predicate: #Predicate { $0.id == requestedID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchRoutineSet(id: UUID, in context: ModelContext) -> RoutineSetModel? {
        let requestedID = id
        var descriptor = FetchDescriptor<RoutineSetModel>(predicate: #Predicate { $0.id == requestedID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func fetchRoutineBlock(id: UUID, in context: ModelContext) -> RoutineBlockModel? {
        let requestedID = id
        var descriptor = FetchDescriptor<RoutineBlockModel>(predicate: #Predicate { $0.id == requestedID })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
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
    private static func routineTarget(
        from ws: SetModel,
        id: UUID,
        userID: UUID,
        createdAt: Date
    ) -> RoutineSetModel {
        let target = RoutineSetModel(
            id: id,
            userID: userID,
            position: ws.position,
            setType: ws.setType,
            targetRepsLow: ws.reps,
            targetRepsHigh: ws.reps,
            // Assisted and added-bodyweight loads live in mode-specific
            // fields. `modeWeight` is the number the user entered and saw.
            targetWeight: ws.modeWeight,
            targetRPE: ws.rpe,
            targetRIR: ws.rir,
            targetDurationSeconds: ws.durationSeconds,
            createdAt: createdAt
        )
        applyTypeSpecificPlan(from: ws, to: target)
        return target
    }
}
