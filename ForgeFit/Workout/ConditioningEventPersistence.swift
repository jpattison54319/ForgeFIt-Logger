import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Commits one conditioning interaction as an isolated transaction.
///
/// The progress reducer, generated set/cardio logs, and block session are one
/// user action. Keeping that graph off the shared UI context until `save()`
/// succeeds prevents a rejected write from leaving a running clock without a
/// durable session, or from rolling back unrelated edits in another tab.
@MainActor
enum ConditioningEventPersistence {
    struct Outcome {
        let progress: ConditioningProgress
        let startedSessionID: UUID?
        let completedSessionID: UUID?
        let applied: Bool
    }

    private final class OutcomeBox {
        var value: Outcome?
    }

    private enum PersistenceError: LocalizedError {
        case missingWorkout
        case missingBlock
        case invalidPlan

        var errorDescription: String? {
            switch self {
            case .missingWorkout: "The active workout could not be found."
            case .missingBlock: "This conditioning block could not be found."
            case .invalidPlan: "This conditioning plan could not be read."
            }
        }
    }

    /// Presents the app-wide persistence alert on failure and retains an exact
    /// retry of the same stable IDs and event. Side effects belong in
    /// `onCommit`, which only runs after the transaction is durable.
    @discardableResult
    static func perform(
        container: ModelContainer,
        workoutID: UUID,
        blockID: UUID?,
        event: ConditioningProgressEvent,
        sourceDevice: String,
        distanceSource: CardioDistanceSource,
        onCommit: @escaping @MainActor (Outcome) -> Void
    ) -> Bool {
        let outcome = OutcomeBox()
        return PersistentChangeSaveCenter.shared.perform({
            outcome.value = try commit(
                container: container,
                workoutID: workoutID,
                blockID: blockID,
                event: event,
                sourceDevice: sourceDevice,
                distanceSource: distanceSource
            )
        }, onSuccess: {
            if let value = outcome.value {
                onCommit(value)
            }
        })
    }

    /// Exposed internally so failure-injection tests can prove that the
    /// isolated transaction neither leaks partial logs nor touches pending
    /// changes in the caller's context.
    static func commit(
        container: ModelContainer,
        workoutID: UUID,
        blockID: UUID?,
        event: ConditioningProgressEvent,
        sourceDevice: String,
        distanceSource: CardioDistanceSource,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Outcome {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false

        do {
            guard let workout = try transaction.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.id == workoutID }
            )).first else {
                throw PersistenceError.missingWorkout
            }

            let block: WorkoutBlockModel?
            let plan: ConditioningPlan
            if let blockID {
                guard let fetchedBlock = try transaction.fetch(FetchDescriptor<WorkoutBlockModel>(
                    predicate: #Predicate { $0.id == blockID }
                )).first,
                fetchedBlock.kind == .conditioning else {
                    throw PersistenceError.missingBlock
                }
                guard let decoded = ConditioningPlan.decode(from: fetchedBlock.planSnapshotJSON) else {
                    throw PersistenceError.invalidPlan
                }
                block = fetchedBlock
                plan = decoded
            } else {
                guard let decoded = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON) else {
                    throw PersistenceError.invalidPlan
                }
                block = nil
                plan = decoded
            }

            let current = ConditioningProgress.decode(
                from: block?.progressJSON ?? workout.conditioningProgressJSON
            ) ?? ConditioningProgress()
            if case .setScore = event.action,
               ConditioningProgressEngine.requiredRoundsRemaining(for: current, plan: plan) > 0 {
                return Outcome(
                    progress: current,
                    startedSessionID: nil,
                    completedSessionID: nil,
                    applied: false
                )
            }
            if case .start = event.action,
               let blockID,
               workout.cardioSessions.contains(where: {
                   $0.workoutBlockID != blockID
                       && $0.liveStartedAt != nil
                       && $0.endedAt == nil
                       && $0.deletedAt == nil
               }) {
                return Outcome(
                    progress: current,
                    startedSessionID: nil,
                    completedSessionID: nil,
                    applied: false
                )
            }

            var next = ConditioningProgressEngine.apply(event, to: current, plan: plan)
            // `setScore` is the user's explicit terminal confirmation. The
            // pure reducer also supports editing an expired provisional score,
            // so it intentionally leaves status alone; the persistence
            // boundary owns the terminal transition for live phone/Watch
            // actions and keeps progress aligned with the ended session.
            if case .setScore = event.action {
                next.status = .completed
                next.completedAt = event.timestamp
                next.pausedAt = nil
            }
            guard next != current else {
                return Outcome(
                    progress: current,
                    startedSessionID: nil,
                    completedSessionID: nil,
                    applied: false
                )
            }

            materializeChanges(
                from: current,
                to: next,
                plan: plan,
                block: block,
                workout: workout,
                context: transaction,
                at: event.timestamp,
                sourceDevice: sourceDevice,
                distanceSource: distanceSource
            )

            let resultJSON = ConditioningProgressEngine.result(for: next, plan: plan).encodedJSON()
            if let block {
                block.progressJSON = next.encodedJSON()
                block.resultJSON = resultJSON
                block.updatedAt = event.timestamp
            } else {
                workout.conditioningProgressJSON = next.encodedJSON()
                workout.conditioningResultJSON = resultJSON
            }

            var startedSession: CardioSessionModel?
            if let block, current.status == .ready, next.status != .ready {
                startedSession = startBlockSession(
                    block,
                    in: workout,
                    context: transaction,
                    at: event.timestamp,
                    sourceDevice: sourceDevice
                )
            }

            let explicitlyFinished: Bool
            if case .setScore = event.action {
                explicitlyFinished = true
            } else {
                explicitlyFinished = false
            }
            var completedSession: CardioSessionModel?
            if let block,
               explicitlyFinished || next.status == .completed || next.status == .expired {
                let alreadyEnded = workout.cardioSessions.first {
                    $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
                }?.endedAt != nil
                let session = completeBlockSession(
                    block,
                    progress: next,
                    in: workout,
                    context: transaction,
                    endedAt: event.timestamp,
                    sourceDevice: sourceDevice
                )
                if !alreadyEnded {
                    completedSession = session
                }
            }

            workout.recomputeTotalVolume()
            workout.updatedAt = event.timestamp
            try save(transaction)
            return Outcome(
                progress: next,
                startedSessionID: startedSession?.id,
                completedSessionID: completedSession?.id,
                applied: true
            )
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private static func startBlockSession(
        _ block: WorkoutBlockModel,
        in workout: WorkoutModel,
        context: ModelContext,
        at startedAt: Date,
        sourceDevice: String
    ) -> CardioSessionModel? {
        let existing = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
        }
        guard workout.cardioSessions.contains(where: {
            $0.id != existing?.id
                && $0.liveStartedAt != nil
                && $0.endedAt == nil
                && $0.deletedAt == nil
        }) == false else { return nil }

        let session = existing ?? CardioSessionModel(
            userID: workout.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: startedAt,
            sourceDevice: sourceDevice
        )
        if existing == nil {
            context.insert(session)
            workout.cardioSessions.append(session)
        }
        session.startedAt = startedAt
        session.liveStartedAt = startedAt
        session.endedAt = nil
        session.updatedAt = startedAt
        block.updatedAt = startedAt
        return session
    }

    private static func completeBlockSession(
        _ block: WorkoutBlockModel,
        progress: ConditioningProgress,
        in workout: WorkoutModel,
        context: ModelContext,
        endedAt: Date,
        sourceDevice: String
    ) -> CardioSessionModel {
        let session = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
        } ?? CardioSessionModel(
            userID: workout.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: endedAt,
            sourceDevice: sourceDevice
        )
        if session.workout == nil {
            context.insert(session)
            workout.cardioSessions.append(session)
        }
        let start = session.liveStartedAt ?? progress.startedAt ?? endedAt
        session.startedAt = start
        session.liveStartedAt = start
        session.endedAt = endedAt
        session.durationSeconds = max(1, Int(endedAt.timeIntervalSince(start)))
        session.updatedAt = endedAt
        block.updatedAt = endedAt
        return session
    }

    private static func materializeChanges(
        from old: ConditioningProgress,
        to new: ConditioningProgress,
        plan: ConditioningPlan,
        block: WorkoutBlockModel?,
        workout: WorkoutModel,
        context: ModelContext,
        at date: Date,
        sourceDevice: String,
        distanceSource: CardioDistanceSource
    ) {
        for movement in plan.sections.flatMap(\.movements) {
            let delta = (new.movementTotals[movement.id] ?? 0)
                - (old.movementTotals[movement.id] ?? 0)
            guard delta != 0 else { continue }

            let existingExercise = workout.exercises.first {
                $0.generatedByWorkoutBlockID == block?.id
                    && $0.exerciseID == movement.exerciseID
            }
            if delta < 0 {
                guard let workoutExercise = existingExercise else { continue }
                if let set = workoutExercise.sets
                    .filter({ $0.completedAt != nil })
                    .sorted(by: { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
                    .first {
                    context.delete(set)
                    workoutExercise.sets.removeAll { $0.id == set.id }
                } else if let session = workout.cardioSessions.first(where: {
                    $0.workoutExerciseID == workoutExercise.id
                }) {
                    if movement.targetUnit == .seconds {
                        session.durationSeconds = max(0, (session.durationSeconds ?? 0) - Int(-delta))
                    }
                    if movement.targetUnit == .meters {
                        session.distanceMeters = max(0, (session.distanceMeters ?? 0) - (-delta))
                        session.distanceSource = distanceSource
                    }
                }
                continue
            }

            let workoutExercise = existingExercise ?? {
                let created = WorkoutExerciseModel(
                    userID: workout.userID,
                    exerciseID: movement.exerciseID,
                    position: block?.position ?? workout.exercises.count,
                    generatedByWorkoutBlockID: block?.id
                )
                context.insert(created)
                workout.exercises.append(created)
                return created
            }()

            let library = exercise(for: workoutExercise, in: context)
            if library?.isCardio == true || library?.isYoga == true {
                let session = workout.cardioSessions.first { $0.workoutExerciseID == workoutExercise.id }
                    ?? CardioSessionModel(
                        userID: workout.userID,
                        workoutExerciseID: workoutExercise.id,
                        workoutBlockID: block?.id,
                        modality: library?.isYoga == true
                            ? CardioSessionModel.yogaModality
                            : CardioKind.infer(
                                name: library?.name ?? "Cardio",
                                equipment: library?.equipment
                            ).rawValue,
                        startedAt: block == nil ? workout.startedAt : date,
                        liveStartedAt: block == nil ? workout.startedAt : nil,
                        endedAt: date,
                        sourceDevice: sourceDevice
                    )
                if session.workout == nil {
                    context.insert(session)
                    workout.cardioSessions.append(session)
                }
                if movement.targetUnit == .seconds {
                    session.durationSeconds = (session.durationSeconds ?? 0) + Int(delta)
                }
                if movement.targetUnit == .meters {
                    session.distanceMeters = (session.distanceMeters ?? 0) + delta
                    session.distanceSource = distanceSource
                }
                session.endedAt = date
                session.updatedAt = date
            } else {
                let set = SetModel(
                    userID: workout.userID,
                    position: workoutExercise.sets.count,
                    weightMode: movement.weightMode,
                    reps: movement.targetUnit == .reps ? Int(delta) : nil,
                    durationSeconds: movement.targetUnit == .seconds ? Int(delta) : nil,
                    completedAt: date
                )
                set.setModeWeight(movement.targetLoad)
                context.insert(set)
                workoutExercise.sets.append(set)
            }
        }
    }

    private static func exercise(
        for workoutExercise: WorkoutExerciseModel,
        in context: ModelContext
    ) -> ExerciseLibraryModel? {
        let exerciseID = workoutExercise.exerciseID
        var descriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
