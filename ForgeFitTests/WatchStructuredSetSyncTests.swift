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

    @Test func queuedNextTrackedWorkoutCommandIsIgnored() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let now = Date()
        let exercise = ExerciseLibraryModel(name: "Queued Guard Exercise")
        let routine = RoutineModel(
            userID: userID,
            name: "Queued Guard Routine",
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: exercise.id
            )]
        )
        let tracking = MicrocycleTrackingModel(
            userID: userID,
            folderID: UUID(),
            folderName: "Queued Guard",
            anchorDate: now.addingTimeInterval(-60),
            durationDays: 7,
            timeZoneIdentifier: "UTC",
            stateRaw: "active",
            createdAt: now,
            updatedAt: now
        )
        let window = MicrocycleWindowModel(
            userID: userID,
            trackingID: tracking.id,
            folderID: tracking.folderID,
            folderName: tracking.folderName,
            index: 0,
            startsAt: now.addingTimeInterval(-60),
            endsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
            timeZoneIdentifier: "UTC",
            routines: [MicrocycleRoutineSnapshot(
                id: routine.id,
                name: routine.name,
                position: 0
            )],
            createdAt: now,
            updatedAt: now
        )
        context.insert(exercise)
        context.insert(routine)
        context.insert(tracking)
        context.insert(window)
        try context.save()

        let link = WatchLink()
        link.configure(context: context)
        link.handle(.startNextTrackedWorkout)

        let verificationContext = ModelContext(container)
        let activeWorkouts = try verificationContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil }
        ))
        #expect(activeWorkouts.isEmpty)
    }

    @Test func routineStartUsesFreshestAuthoredGraphForDuplicateID() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let id = UUID()
        let staleExercise = ExerciseLibraryModel(name: "Stale Exercise")
        let editedExercise = ExerciseLibraryModel(name: "Edited Exercise")
        let staleGraph = RoutineModel(
            id: id,
            userID: userID,
            name: "Stale Routine",
            updatedAt: Date(timeIntervalSince1970: 900),
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: staleExercise.id,
                updatedAt: Date(timeIntervalSince1970: 100)
            )]
        )
        let editedGraph = RoutineModel(
            id: id,
            userID: userID,
            name: "Edited Routine",
            updatedAt: Date(timeIntervalSince1970: 500),
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: editedExercise.id,
                updatedAt: Date(timeIntervalSince1970: 500)
            )]
        )
        context.insert(staleExercise)
        context.insert(editedExercise)
        context.insert(staleGraph)
        context.insert(editedGraph)
        try context.save()

        let link = WatchLink()
        link.configure(context: context)
        link.handle(.startRoutine(routineID: id))

        let verificationContext = ModelContext(container)
        let workouts = try verificationContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil }
        ))
        let workout = try #require(workouts.first)
        #expect(workouts.count == 1)
        #expect(workout.title == "Edited Routine")
        #expect(workout.exercises.map(\.exerciseID) == [editedExercise.id])
    }

    @Test func myoCommandsPersistActivationMiniSetsAndDerivedVolume() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let originalWorkoutUpdatedAt = Date(timeIntervalSince1970: 1_000)
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
        let workout = WorkoutModel(
            userID: userID,
            title: "Watch Myo",
            updatedAt: originalWorkoutUpdatedAt,
            exercises: [exercise]
        )
        context.insert(workout)
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
        #expect(workout.totalVolume == nil)
        #expect(workout.updatedAt == originalWorkoutUpdatedAt)

        let verificationContext = ModelContext(container)
        let descriptor = FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == setID }
        )
        let persisted = try #require(try verificationContext.fetch(descriptor).first)
        #expect(persisted.reps == 12)
        #expect(persisted.miniReps == [4, 3])
        #expect(persisted.totalVolume == 950)
        let workoutID = workout.id
        let persistedWorkout = try #require(try verificationContext.fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == workoutID })
        ).first)
        #expect(persistedWorkout.totalVolume == nil)
        #expect(persistedWorkout.updatedAt == originalWorkoutUpdatedAt)
    }

    @Test func watchSetUpdateAndCompletionKeepTheActiveParentStable() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let originalWorkoutUpdatedAt = Date(timeIntervalSince1970: 2_000)
        let set = SetModel(
            userID: userID,
            setType: .working,
            weight: 40
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Watch strength",
            updatedAt: originalWorkoutUpdatedAt,
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: UUID(),
                sets: [set]
            )]
        )
        context.insert(workout)
        try context.save()

        let timer = RestTimerController.shared
        timer.skip()
        defer {
            timer.skip()
            timer.onStateChange = nil
        }
        let link = WatchLink()
        link.configure(context: context)
        link.handle(.updateSet(
            setID: set.id,
            weightKg: 50,
            reps: 10,
            partialReps: nil
        ))
        link.handle(.toggleSet(setID: set.id, completed: true))

        #expect(set.modeWeight == 50)
        #expect(set.reps == 10)
        #expect(set.completedAt != nil)
        #expect(set.totalVolume == 500)
        #expect(workout.totalVolume == nil)
        #expect(workout.updatedAt == originalWorkoutUpdatedAt)

        let workoutID = workout.id
        let verificationContext = ModelContext(container)
        let persisted = try #require(try verificationContext.fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == workoutID })
        ).first)
        #expect(persisted.exercises.first?.sets.first?.totalVolume == 500)
        #expect(persisted.totalVolume == nil)
        #expect(persisted.updatedAt == originalWorkoutUpdatedAt)
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

    @Test func staleSetAndTimerCommandsCannotMutateACompletedWorkout() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let base = Date(timeIntervalSince1970: 7_000)

        let working = SetModel(
            userID: userID,
            setType: .working,
            reps: 5,
            weight: 20
        )
        let structured = SetModel(
            userID: userID,
            setType: .myoRep,
            reps: 8,
            weight: 30
        )
        let amrap = SetModel(
            userID: userID,
            setType: .amrap,
            durationSeconds: 12
        )
        let historical = WorkoutModel(
            userID: userID,
            title: "Already finished",
            startedAt: base,
            endedAt: base.addingTimeInterval(300),
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: UUID(),
                sets: [working, structured, amrap]
            )]
        )
        let active = WorkoutModel(
            userID: userID,
            title: "Current workout",
            startedAt: base.addingTimeInterval(600),
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: UUID(),
                sets: [SetModel(userID: userID, setType: .working)]
            )]
        )
        context.insert(historical)
        context.insert(active)
        try context.save()

        let timer = RestTimerController.shared
        timer.skip()
        defer {
            timer.skip()
            timer.onStateChange = nil
        }
        let link = WatchLink()
        link.configure(context: context)

        link.handle(.updateSet(
            setID: working.id,
            weightKg: 99,
            reps: 99,
            partialReps: nil
        ))
        link.handle(.toggleSet(setID: working.id, completed: true))
        link.handle(.updateStructuredSet(
            setID: structured.id,
            update: WatchStructuredSetUpdate(
                progress: WatchStructuredSetProgress(
                    activationReps: 12,
                    miniReps: [4]
                ),
                event: .miniSet,
                side: 1,
                occurredAt: base.addingTimeInterval(700),
                weightKg: 50
            )
        ))
        link.handle(.startSetTimer(
            setID: amrap.id,
            durationSeconds: 60,
            endsAt: .now.addingTimeInterval(60)
        ))
        link.handle(.stopSetTimer(setID: amrap.id, elapsedSeconds: 37))

        #expect(working.modeWeight == 20)
        #expect(working.reps == 5)
        #expect(working.completedAt == nil)
        #expect(structured.modeWeight == 30)
        #expect(structured.reps == 8)
        #expect(structured.miniReps.isEmpty)
        #expect(amrap.durationSeconds == 12)
        #expect(timer.ownerID != structured.id)
        #expect(timer.ownerID != amrap.id)

        let workingID = working.id
        let structuredID = structured.id
        let amrapID = amrap.id
        let verificationContext = ModelContext(container)
        let persistedWorking = try #require(try verificationContext.fetch(
            FetchDescriptor<SetModel>(predicate: #Predicate { $0.id == workingID })
        ).first)
        let persistedStructured = try #require(try verificationContext.fetch(
            FetchDescriptor<SetModel>(predicate: #Predicate { $0.id == structuredID })
        ).first)
        let persistedAMRAP = try #require(try verificationContext.fetch(
            FetchDescriptor<SetModel>(predicate: #Predicate { $0.id == amrapID })
        ).first)
        #expect(persistedWorking.modeWeight == 20)
        #expect(persistedWorking.reps == 5)
        #expect(persistedWorking.completedAt == nil)
        #expect(persistedStructured.modeWeight == 30)
        #expect(persistedStructured.reps == 8)
        #expect(persistedStructured.miniReps.isEmpty)
        #expect(persistedAMRAP.durationSeconds == 12)
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
