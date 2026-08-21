import ForgeData
import Foundation
import SwiftData

/// One isolated terminal transaction for a cardio or yoga segment.
/// Runtime, Health, Watch, and UI completion effects must run from `onCommit`.
@MainActor
enum CardioSessionTerminalPersistence {
    struct Outcome {
        let sessionID: UUID
        let blockID: UUID?
        let start: Date
        let end: Date
        let durationSeconds: Int
        let distanceMeters: Double?
        let distanceSourceRaw: String?
        let elevationGainMeters: Double?
        let activeEnergyKcal: Double?
        let yogaStyleRaw: String?
        let flexibilityExposureJSON: String?
        let posesCompleted: Int?
        let updatedAt: Date
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
        session: CardioSessionModel,
        block: WorkoutBlockModel? = nil,
        context: ModelContext,
        endedAt: Date,
        completesYoga: Bool,
        useClockDuration: Bool,
        stagesRoute: Bool,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping (ModelContext) throws -> Void = { try $0.save() },
        onCommit: @escaping @MainActor (Outcome) -> Void
    ) -> Bool {
        let outcome = OutcomeBox()
        let resolvedSaveCenter = saveCenter ?? .shared
        return resolvedSaveCenter.perform({
            outcome.value = try commit(
                container: context.container,
                sessionID: session.id,
                blockID: block?.id,
                endedAt: endedAt,
                completesYoga: completesYoga,
                useClockDuration: useClockDuration,
                stagesRoute: stagesRoute,
                save: save
            )
        }, onSuccess: {
            if let value = outcome.value {
                mirror(value, onto: session, block: block, in: context)
                onCommit(value)
            }
        })
    }

    /// The isolated context owns the durable terminal transaction, but live
    /// cards and Watch publication still observe models registered in their
    /// caller context. Mirror only the exact fields that transaction committed;
    /// do not save the caller context or sweep unrelated pending user edits into
    /// the terminal write.
    private static func mirror(
        _ outcome: Outcome,
        onto session: CardioSessionModel,
        block: WorkoutBlockModel?,
        in context: ModelContext
    ) {
        guard session.id == outcome.sessionID else { return }
        session.endedAt = outcome.end
        session.durationSeconds = outcome.durationSeconds
        session.distanceMeters = outcome.distanceMeters
        session.distanceSourceRaw = outcome.distanceSourceRaw
        session.elevationGainMeters = outcome.elevationGainMeters
        session.activeEnergyKcal = outcome.activeEnergyKcal
        session.yogaStyleRaw = outcome.yogaStyleRaw
        session.flexibilityExposureJSON = outcome.flexibilityExposureJSON
        session.posesCompleted = outcome.posesCompleted
        session.updatedAt = outcome.updatedAt
        let sessionID = outcome.sessionID
        if let routePoints = try? context.fetch(FetchDescriptor<CardioRoutePointModel>(
            predicate: #Predicate { $0.cardioSessionID == sessionID }
        )) {
            session.routePoints = routePoints.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        if let splits = try? context.fetch(FetchDescriptor<CardioSplitModel>(
            predicate: #Predicate { $0.cardioSessionID == sessionID }
        )) {
            session.splits = splits.sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        if block?.id == outcome.blockID {
            block?.updatedAt = outcome.end
        }
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
            var committedBlockID: UUID?
            if let blockID,
               let block = try transaction.fetch(FetchDescriptor<WorkoutBlockModel>(
                   predicate: #Predicate { $0.id == blockID }
               )).first {
                block.updatedAt = endedAt
                committedBlockID = block.id
            }
            try save(transaction)
            return Outcome(
                sessionID: session.id,
                blockID: committedBlockID,
                start: start,
                end: endedAt,
                durationSeconds: session.durationSeconds ?? max(1, Int(endedAt.timeIntervalSince(start))),
                distanceMeters: session.distanceMeters,
                distanceSourceRaw: session.distanceSourceRaw,
                elevationGainMeters: session.elevationGainMeters,
                activeEnergyKcal: session.activeEnergyKcal,
                yogaStyleRaw: session.yogaStyleRaw,
                flexibilityExposureJSON: session.flexibilityExposureJSON,
                posesCompleted: session.posesCompleted,
                updatedAt: session.updatedAt
            )
        } catch {
            transaction.rollback()
            throw error
        }
    }
}
