import ForgeData
import Foundation
import SwiftData

/// One isolated terminal transaction for a cardio or yoga segment.
/// Runtime, Health, Watch, and UI completion effects must run from `onCommit`.
@MainActor
enum CardioSessionTerminalPersistence {
    struct Outcome {
        let sessionID: UUID
        let start: Date
        let end: Date
        let durationSeconds: Int
        let distanceMeters: Double?
        let elevationGainMeters: Double?
        let activeEnergyKcal: Double?
    }

    private final class OutcomeBox {
        var value: Outcome?
    }

    private enum PersistenceError: LocalizedError {
        case missingSession

        var errorDescription: String? {
            "The active session could not be found."
        }
    }

    @discardableResult
    static func perform(
        container: ModelContainer,
        sessionID: UUID,
        blockID: UUID? = nil,
        endedAt: Date,
        completesYoga: Bool,
        useClockDuration: Bool,
        stagesRoute: Bool,
        onCommit: @escaping @MainActor (Outcome) -> Void
    ) -> Bool {
        let outcome = OutcomeBox()
        return PersistentChangeSaveCenter.shared.perform({
            outcome.value = try commit(
                container: container,
                sessionID: sessionID,
                blockID: blockID,
                endedAt: endedAt,
                completesYoga: completesYoga,
                useClockDuration: useClockDuration,
                stagesRoute: stagesRoute
            )
        }, onSuccess: {
            if let value = outcome.value {
                onCommit(value)
            }
        })
    }

    static func commit(
        container: ModelContainer,
        sessionID: UUID,
        blockID: UUID? = nil,
        endedAt: Date,
        completesYoga: Bool,
        useClockDuration: Bool,
        stagesRoute: Bool,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> Outcome {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            guard let session = try transaction.fetch(FetchDescriptor<CardioSessionModel>(
                predicate: #Predicate { $0.id == sessionID }
            )).first else {
                throw PersistenceError.missingSession
            }
            let start = session.liveStartedAt ?? session.startedAt
            if completesYoga {
                let workoutExercise: WorkoutExerciseModel?
                if let workoutExerciseID = session.workoutExerciseID {
                    workoutExercise = try transaction.fetch(FetchDescriptor<WorkoutExerciseModel>(
                        predicate: #Predicate { $0.id == workoutExerciseID }
                    )).first
                } else {
                    workoutExercise = nil
                }
                let exercise: ExerciseLibraryModel?
                if let exerciseID = workoutExercise?.exerciseID {
                    exercise = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>(
                        predicate: #Predicate { $0.id == exerciseID }
                    )).first
                } else {
                    exercise = nil
                }
                YogaSessionCompletion.complete(
                    session: session,
                    workoutExercise: workoutExercise,
                    exercise: exercise,
                    context: transaction,
                    endedAt: endedAt,
                    useClockDuration: useClockDuration,
                    clearCheckpoint: false
                )
            } else {
                session.endedAt = endedAt
                session.durationSeconds = max(1, Int(endedAt.timeIntervalSince(start)))
                session.updatedAt = endedAt
            }
            if stagesRoute {
                CardioRouteRecorder.shared.stageRouteForTerminalSave(
                    session: session,
                    in: transaction
                )
            }
            if let blockID,
               let block = try transaction.fetch(FetchDescriptor<WorkoutBlockModel>(
                   predicate: #Predicate { $0.id == blockID }
               )).first {
                block.updatedAt = endedAt
            }
            try save(transaction)
            return Outcome(
                sessionID: session.id,
                start: start,
                end: endedAt,
                durationSeconds: session.durationSeconds ?? max(1, Int(endedAt.timeIntervalSince(start))),
                distanceMeters: session.distanceMeters,
                elevationGainMeters: session.elevationGainMeters,
                activeEnergyKcal: session.activeEnergyKcal
            )
        } catch {
            transaction.rollback()
            throw error
        }
    }
}
