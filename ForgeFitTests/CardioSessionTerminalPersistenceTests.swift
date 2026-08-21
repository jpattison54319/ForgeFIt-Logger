import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CardioSessionTerminalPersistenceTests {
    private enum InjectedFailure: Error { case save }

    @Test func successfulTerminalWriteImmediatelyMirrorsCallerWithoutSavingUnrelatedEdits() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let start = Date(timeIntervalSince1970: 9_200_000)
        let end = start.addingTimeInterval(489)
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            liveStartedAt: start
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            exercises: [workoutExercise],
            cardioSessions: [session]
        )
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Before")
        context.insert(workout)
        context.insert(routine)
        try context.save()
        let sessionID = session.id
        let routineID = routine.id
        routine.name = "Still pending"

        var callbackSawEnd: Date?
        let didFinish = CardioSessionTerminalPersistence.perform(
            session: session,
            context: context,
            endedAt: end,
            completesYoga: false,
            useClockDuration: true,
            stagesRoute: false,
            saveCenter: PersistentChangeSaveCenter()
        ) { _ in
            callbackSawEnd = session.endedAt
        }

        #expect(didFinish)
        #expect(callbackSawEnd == end)
        #expect(session.endedAt == end)
        #expect(session.durationSeconds == 489)
        #expect(routine.name == "Still pending")
        #expect(context.hasChanges)

        var verification = ModelContext(container)
        var persistedSession = try #require(try verification.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        var persistedRoutine = try #require(try verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(persistedSession.endedAt == end)
        #expect(persistedSession.durationSeconds == 489)
        #expect(persistedRoutine.name == "Before")

        // A later caller-context save keeps the terminal truth and commits the
        // unrelated edit; it must not resurrect the recording state.
        try context.save()
        verification = ModelContext(container)
        persistedSession = try #require(try verification.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        persistedRoutine = try #require(try verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(persistedSession.endedAt == end)
        #expect(persistedSession.durationSeconds == 489)
        #expect(persistedRoutine.name == "Still pending")
    }

    @Test func failedTerminalWriteLeavesSessionLiveAndUnrelatedEditPendingUntilExactRetry() throws {
        let (container, context) = try TestStore.make()
        let start = Date(timeIntervalSince1970: 9_300_000)
        let end = start.addingTimeInterval(75)
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            liveStartedAt: start
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            exercises: [workoutExercise],
            cardioSessions: [session]
        )
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Before")
        context.insert(workout)
        context.insert(routine)
        try context.save()
        let sessionID = session.id
        let routineID = routine.id
        routine.name = "Still pending"

        #expect(throws: InjectedFailure.save) {
            _ = try CardioSessionTerminalPersistence.commit(
                container: container,
                sessionID: sessionID,
                endedAt: end,
                completesYoga: false,
                useClockDuration: true,
                stagesRoute: false,
                save: { _ in throw InjectedFailure.save }
            )
        }

        var verification = ModelContext(container)
        var persistedSession = try #require(try verification.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        #expect(persistedSession.endedAt == nil)
        #expect(persistedSession.durationSeconds == nil)
        #expect(routine.name == "Still pending")
        #expect(context.hasChanges)

        let outcome = try CardioSessionTerminalPersistence.commit(
            container: container,
            sessionID: sessionID,
            endedAt: end,
            completesYoga: false,
            useClockDuration: true,
            stagesRoute: false
        )
        #expect(outcome.end == end)
        #expect(outcome.durationSeconds == 75)
        #expect(routine.name == "Still pending")
        #expect(context.hasChanges)

        try context.save()
        verification = ModelContext(container)
        persistedSession = try #require(try verification.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        let persistedRoutine = try #require(try verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(persistedSession.endedAt == end)
        #expect(persistedSession.durationSeconds == 75)
        #expect(persistedRoutine.name == "Still pending")
    }
}
