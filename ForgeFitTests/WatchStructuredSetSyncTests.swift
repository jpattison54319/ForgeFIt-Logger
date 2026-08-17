import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WatchStructuredSetSyncTests {
    private enum InjectedConditioningFailure: Error { case save }

    private let userID = ForgeFitDemo.userID

    @Test func myoCommandsPersistActivationMiniSetsAndDerivedVolume() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let setID = UUID()
        let set = SetModel(
            id: setID,
            userID: userID,
            setType: .myoRep,
            weight: 50
        )
        let exercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            microRestSeconds: 30,
            sets: [set]
        )
        context.insert(WorkoutModel(userID: userID, title: "Watch Myo", exercises: [exercise]))
        try context.save()

        let timer = RestTimerController.shared
        timer.skip()
        defer {
            timer.skip()
            timer.onStateChange = nil
        }

        let link = WatchLink()
        link.configure(context: context)
        link.handle(.updateStructuredSet(
            setID: setID,
            update: WatchStructuredSetUpdate(
                progress: WatchStructuredSetProgress(activationReps: 12),
                event: .activation,
                side: 1,
                occurredAt: .now,
                weightKg: 50
            )
        ))

        #expect(set.reps == 12)
        #expect(set.totalVolume == 600)
        #expect(timer.ownerID == setID)
        #expect(timer.isMicro)

        link.handle(.updateStructuredSet(
            setID: setID,
            update: WatchStructuredSetUpdate(
                progress: WatchStructuredSetProgress(
                    activationReps: 12,
                    miniReps: [4, 3]
                ),
                event: .miniSet,
                side: 1,
                occurredAt: .now,
                weightKg: 50
            )
        ))

        #expect(set.miniReps == [4, 3])
        #expect(set.totalVolume == 950)

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == setID }
        )
        let persisted = try #require(try verificationContext.fetch(descriptor).first)
        #expect(persisted.reps == 12)
        #expect(persisted.miniReps == [4, 3])
        #expect(persisted.totalVolume == 950)
    }

    @Test func amrapCommandsPersistTheSelectedAndElapsedWindow() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let setID = UUID()
        let set = SetModel(id: setID, userID: userID, setType: .amrap)
        let exercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            sets: [set]
        )
        context.insert(WorkoutModel(userID: userID, title: "Watch AMRAP", exercises: [exercise]))
        try context.save()

        let timer = RestTimerController.shared
        timer.skip()
        defer {
            timer.skip()
            timer.onStateChange = nil
        }

        let link = WatchLink()
        link.configure(context: context)
        link.handle(.startSetTimer(
            setID: setID,
            durationSeconds: 60,
            endsAt: .now.addingTimeInterval(60)
        ))

        #expect(set.durationSeconds == 60)
        #expect(timer.ownerID == setID)

        link.handle(.stopSetTimer(setID: setID, elapsedSeconds: 37))

        #expect(set.durationSeconds == 37)
        #expect(!timer.isRunning)

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == setID }
        )
        let persisted = try #require(try verificationContext.fetch(descriptor).first)
        #expect(persisted.durationSeconds == 37)
    }

    @Test func conditioningBlockStartAndCompletionCommitAsWholeEvents() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let movementID = UUID()
        let plan = ConditioningPlan(sections: [
            ConditioningSection(
                name: "Finisher",
                format: .amrap,
                durationSeconds: 600,
                movements: [ConditioningMovement(exerciseID: movementID, targetValue: 10)]
            )
        ])
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            planSnapshotJSON: plan.encodedJSON(),
            progressJSON: ConditioningProgress().encodedJSON()
        )
        let session = CardioSessionModel(
            userID: userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Watch Conditioning",
            cardioSessions: [session],
            blocks: [block]
        )
        context.insert(workout)
        try context.save()
        let blockID = block.id
        let sessionID = session.id

        let link = WatchLink()
        link.configure(context: context)
        let startedAt = Date(timeIntervalSince1970: 9_100_000)
        link.handle(.conditioningBlockEvent(
            blockID: blockID,
            event: ConditioningProgressEvent(timestamp: startedAt, action: .start)
        ))

        // The configured context deliberately already caches this graph.
        // WatchLink's commit callback must therefore resolve terminal/runtime
        // models through a fresh read context, just like this verification.
        var verificationContext = ModelContext(container)
        var persistedBlock = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutBlockModel>(
            predicate: #Predicate { $0.id == blockID }
        )).first)
        var persistedSession = try #require(try verificationContext.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        #expect(ConditioningProgress.decode(from: persistedBlock.progressJSON)?.status == .active)
        #expect(persistedSession.liveStartedAt == startedAt)
        #expect(persistedSession.endedAt == nil)

        let endedAt = startedAt.addingTimeInterval(90)
        link.handle(.conditioningBlockEvent(
            blockID: blockID,
            event: ConditioningProgressEvent(
                timestamp: endedAt,
                action: .setScore(
                    rounds: 1,
                    partialMovementID: nil,
                    partialValue: 0,
                    load: nil
                )
            )
        ))

        verificationContext = ModelContext(container)
        persistedBlock = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutBlockModel>(
            predicate: #Predicate { $0.id == blockID }
        )).first)
        persistedSession = try #require(try verificationContext.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        #expect(ConditioningProgress.decode(from: persistedBlock.progressJSON)?.status == .completed)
        #expect(persistedSession.endedAt == endedAt)
        #expect(persistedSession.durationSeconds == 90)
    }

    @Test func conditioningFailureDoesNotLeakPartialStateOrRollbackAnotherPendingEdit() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let plan = ConditioningPlan(sections: [
            ConditioningSection(
                name: "Finisher",
                format: .amrap,
                durationSeconds: 600,
                movements: []
            )
        ])
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            planSnapshotJSON: plan.encodedJSON(),
            progressJSON: ConditioningProgress().encodedJSON()
        )
        let workout = WorkoutModel(userID: userID, cardioSessions: [], blocks: [block])
        let pendingRoutine = RoutineModel(userID: userID, name: "Before")
        context.insert(workout)
        context.insert(pendingRoutine)
        try context.save()

        let workoutID = workout.id
        let blockID = block.id
        let routineID = pendingRoutine.id
        pendingRoutine.name = "Still pending"
        let startedAt = Date(timeIntervalSince1970: 9_200_000)
        let startEvent = ConditioningProgressEvent(timestamp: startedAt, action: .start)

        #expect(throws: InjectedConditioningFailure.save) {
            _ = try ConditioningEventPersistence.commit(
                container: container,
                workoutID: workoutID,
                blockID: blockID,
                event: startEvent,
                sourceDevice: "watch-conditioning",
                distanceSource: .watchInput,
                save: { _ in throw InjectedConditioningFailure.save }
            )
        }

        var verificationContext = ModelContext(container)
        var persistedBlock = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutBlockModel>(
            predicate: #Predicate { $0.id == blockID }
        )).first)
        #expect(ConditioningProgress.decode(from: persistedBlock.progressJSON)?.status == .ready)
        #expect(try verificationContext.fetch(FetchDescriptor<CardioSessionModel>()).isEmpty)
        #expect(pendingRoutine.name == "Still pending")
        #expect(context.hasChanges)

        let startOutcome = try ConditioningEventPersistence.commit(
            container: container,
            workoutID: workoutID,
            blockID: blockID,
            event: startEvent,
            sourceDevice: "watch-conditioning",
            distanceSource: .watchInput
        )
        let sessionID = try #require(startOutcome.startedSessionID)
        let endedAt = startedAt.addingTimeInterval(60)
        let finishEvent = ConditioningProgressEvent(
            timestamp: endedAt,
            action: .setScore(rounds: 0, partialMovementID: nil, partialValue: 0, load: nil)
        )
        #expect(throws: InjectedConditioningFailure.save) {
            _ = try ConditioningEventPersistence.commit(
                container: container,
                workoutID: workoutID,
                blockID: blockID,
                event: finishEvent,
                sourceDevice: "watch-conditioning",
                distanceSource: .watchInput,
                save: { _ in throw InjectedConditioningFailure.save }
            )
        }

        verificationContext = ModelContext(container)
        persistedBlock = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutBlockModel>(
            predicate: #Predicate { $0.id == blockID }
        )).first)
        let persistedSession = try #require(try verificationContext.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        #expect(ConditioningProgress.decode(from: persistedBlock.progressJSON)?.status == .active)
        #expect(persistedSession.endedAt == nil)
        #expect(pendingRoutine.name == "Still pending")
        #expect(context.hasChanges)

        // A later legitimate save of the caller context persists its own edit
        // only; it cannot carry either failed isolated conditioning attempt.
        try context.save()
        let finalContext = ModelContext(container)
        let savedRoutine = try #require(try finalContext.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(savedRoutine.name == "Still pending")
        let stillActiveSession = try #require(try finalContext.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        #expect(stillActiveSession.endedAt == nil)
    }
}
