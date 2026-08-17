import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CardioSessionTerminalPersistenceTests {
    private enum InjectedFailure: Error { case save }

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
