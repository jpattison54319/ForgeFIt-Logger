import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Commits the cardio goal edited from a routine card. Keeping the model
/// projection and save boundary together prevents a builder dismissal from
/// leaving an interval plan only in the main context's memory.
@MainActor
enum RoutineIntervalPlanPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func apply(
        _ planJSON: String?,
        to routineExercise: RoutineExerciseModel,
        in context: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        // Older routines stored duration/distance on their synthetic set.
        // Keep that compatibility projection aligned with the JSON plan.
        let legacyTarget = routineExercise.sets.sorted { $0.position < $1.position }.first
        let savedGoal = IntervalPlan.decode(from: planJSON)?.goal
        let previousPlanJSON = routineExercise.intervalPlanJSON
        let previousUpdatedAt = routineExercise.updatedAt
        let previousRoutineUpdatedAt = routineExercise.routine?.updatedAt
        let previousDuration = legacyTarget?.targetDurationSeconds
        let previousDistance = legacyTarget?.targetDistanceMeters

        return (saveCenter ?? .shared).perform({
            routineExercise.intervalPlanJSON = planJSON
            routineExercise.updatedAt = .now
            routineExercise.routine?.updatedAt = .now
            legacyTarget?.targetDurationSeconds = savedGoal?.kind == .duration
                ? Int(savedGoal?.value ?? 0)
                : nil
            legacyTarget?.targetDistanceMeters = savedGoal?.kind == .distance
                ? savedGoal?.value
                : nil
            do {
                try save(context)
            } catch {
                routineExercise.intervalPlanJSON = previousPlanJSON
                routineExercise.updatedAt = previousUpdatedAt
                routineExercise.routine?.updatedAt = previousRoutineUpdatedAt ?? previousUpdatedAt
                legacyTarget?.targetDurationSeconds = previousDuration
                legacyTarget?.targetDistanceMeters = previousDistance
                throw error
            }
        }, onSuccess: onCommit)
    }
}

/// Persists live-workout cardio/yoga plan edits without letting a failed edit
/// survive in the shared logger context or dismiss its builder as if saved.
@MainActor
enum WorkoutIntervalPlanPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func apply(
        _ planJSON: String?,
        to workoutExercise: WorkoutExerciseModel,
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let previousPlanJSON = workoutExercise.intervalPlanJSON
        let previousUpdatedAt = workoutExercise.updatedAt
        return (saveCenter ?? .shared).perform({
            workoutExercise.intervalPlanJSON = planJSON
            workoutExercise.updatedAt = now
            do {
                try save(context)
            } catch {
                workoutExercise.intervalPlanJSON = previousPlanJSON
                workoutExercise.updatedAt = previousUpdatedAt
                throw error
            }
        }, onSuccess: onCommit)
    }
}

/// Keeps a routine's guided yoga plan and its parent timestamp inside one
/// retryable save boundary. A failed builder save restores the editor models,
/// so dismissing another screen or autosave cannot commit the rejected plan.
@MainActor
enum RoutineYogaPlanPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func apply(
        _ planJSON: String?,
        to routineExercise: RoutineExerciseModel,
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let previousPlanJSON = routineExercise.yogaFlowJSON
        let previousUpdatedAt = routineExercise.updatedAt
        let parentRoutine = routineExercise.routine
        let previousRoutineUpdatedAt = parentRoutine?.updatedAt

        return (saveCenter ?? .shared).perform({
            routineExercise.yogaFlowJSON = planJSON
            routineExercise.updatedAt = now
            parentRoutine?.updatedAt = now
            do {
                try save(context)
            } catch {
                routineExercise.yogaFlowJSON = previousPlanJSON
                routineExercise.updatedAt = previousUpdatedAt
                if let previousRoutineUpdatedAt {
                    parentRoutine?.updatedAt = previousRoutineUpdatedAt
                }
                throw error
            }
        }, onSuccess: onCommit)
    }
}

/// Persists a routine-level conditioning/yoga block edit before its value-
/// backed builder dismisses.
@MainActor
enum RoutineBlockPlanPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func apply(
        _ planJSON: String,
        to block: RoutineBlockModel,
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let previousPlanJSON = block.planJSON
        let previousUpdatedAt = block.updatedAt
        let parentRoutine = block.routine
        let previousRoutineUpdatedAt = parentRoutine?.updatedAt

        return (saveCenter ?? .shared).perform({
            block.planJSON = planJSON
            block.updatedAt = now
            parentRoutine?.updatedAt = now
            do {
                try save(context)
            } catch {
                block.planJSON = previousPlanJSON
                block.updatedAt = previousUpdatedAt
                if let previousRoutineUpdatedAt {
                    parentRoutine?.updatedAt = previousRoutineUpdatedAt
                }
                throw error
            }
        }, onSuccess: onCommit)
    }
}

/// Persists the flow edited from an exercise-backed live yoga card together
/// with the not-yet-started session projection it drives.
@MainActor
enum WorkoutYogaPlanPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func apply(
        _ planJSON: String?,
        to workoutExercise: WorkoutExerciseModel,
        session: CardioSessionModel?,
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let previousPlanJSON = workoutExercise.yogaFlowJSON
        let previousUpdatedAt = workoutExercise.updatedAt
        let previousStyleRaw = session?.yogaStyleRaw
        let previousDuration = session?.durationSeconds

        return (saveCenter ?? .shared).perform({
            workoutExercise.yogaFlowJSON = planJSON
            workoutExercise.updatedAt = now
            if let updated = YogaFlowPlan.decode(from: planJSON) {
                session?.yogaStyleRaw = updated.styleRaw
                if session?.endedAt == nil {
                    session?.durationSeconds = updated.totalSeconds > 0 ? updated.totalSeconds : nil
                }
            }
            do {
                try save(context)
            } catch {
                workoutExercise.yogaFlowJSON = previousPlanJSON
                workoutExercise.updatedAt = previousUpdatedAt
                session?.yogaStyleRaw = previousStyleRaw
                session?.durationSeconds = previousDuration
                throw error
            }
        }, onSuccess: onCommit)
    }
}

/// Persists a first-class live block's plan and all derived pre-start state as
/// one unit. Failed saves restore the logger immediately and Retry reapplies
/// the exact plan before any Watch/UI publication occurs.
@MainActor
enum WorkoutBlockPlanPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func apply(
        _ planJSON: String,
        to block: WorkoutBlockModel,
        parentWorkout: WorkoutModel,
        session: CardioSessionModel?,
        generatedExercise: WorkoutExerciseModel?,
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let previousPlanJSON = block.planSnapshotJSON
        let previousProgressJSON = block.progressJSON
        let previousResultJSON = block.resultJSON
        let previousUpdatedAt = block.updatedAt
        let previousParentUpdatedAt = parentWorkout.updatedAt
        let previousStyleRaw = session?.yogaStyleRaw
        let previousDuration = session?.durationSeconds
        let previousExercisePlanJSON = generatedExercise?.yogaFlowJSON

        return (saveCenter ?? .shared).perform({
            block.planSnapshotJSON = planJSON
            block.updatedAt = now
            // A completed block edit is a historical workout edit. Keep its
            // shallow parent clock in the same transaction so analytics/query
            // fingerprints observe equal-volume structural changes without
            // faulting relationships. Active parents wait for Finish.
            let didStampParent = WorkoutMutationContract.stampParentForNestedMutation(
                parentWorkout,
                at: now
            )
            if block.kind == .conditioning {
                block.progressJSON = ConditioningProgress().encodedJSON()
                block.resultJSON = nil
            } else if let plan = YogaFlowPlan.decode(from: planJSON) {
                session?.durationSeconds = plan.totalSeconds > 0 ? plan.totalSeconds : nil
                session?.yogaStyleRaw = plan.styleRaw
                generatedExercise?.yogaFlowJSON = planJSON
            }
            do {
                try save(context)
            } catch {
                block.planSnapshotJSON = previousPlanJSON
                block.progressJSON = previousProgressJSON
                block.resultJSON = previousResultJSON
                block.updatedAt = previousUpdatedAt
                if didStampParent {
                    parentWorkout.updatedAt = previousParentUpdatedAt
                }
                session?.yogaStyleRaw = previousStyleRaw
                session?.durationSeconds = previousDuration
                generatedExercise?.yogaFlowJSON = previousExercisePlanJSON
                throw error
            }
        }, onSuccess: onCommit)
    }
}
