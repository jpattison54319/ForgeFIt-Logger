import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutDetailPersistenceTests {
    private enum InjectedFailure: Error { case save }

    @Test func failedSplitDeleteCannotRollbackOrRideAlongWithUnrelatedPendingEdit() throws {
        let (container, context) = try TestStore.make()
        let splitStart = Date(timeIntervalSince1970: 1_800_000_000)
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: CardioKind.run.rawValue
        )
        let split = CardioSplitModel(
            userID: ForgeFitDemo.userID,
            cardioSessionID: session.id,
            index: 0,
            distanceMeters: 1_000,
            durationSeconds: 300,
            paceSecondsPerKm: 300,
            startedAt: splitStart,
            endedAt: splitStart.addingTimeInterval(300)
        )
        session.splits = [split]
        let workout = WorkoutModel(userID: ForgeFitDemo.userID, cardioSessions: [session])
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Before")
        context.insert(workout)
        context.insert(routine)
        try context.save()
        let sessionID = session.id
        let splitID = split.id
        routine.name = "Still pending"

        #expect(throws: InjectedFailure.save) {
            try WorkoutDetailPersistence.deleteSplits(
                container: container,
                sessionID: sessionID,
                splitIDs: [splitID],
                updatedAt: .now,
                save: { _ in throw InjectedFailure.save }
            )
        }
        #expect(context.hasChanges)
        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<CardioSplitModel>()).count == 1)

        try WorkoutDetailPersistence.deleteSplits(
            container: container,
            sessionID: sessionID,
            splitIDs: [splitID],
            updatedAt: .now
        )
        #expect(context.hasChanges)
        try context.save()

        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<CardioSplitModel>()).isEmpty)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Still pending")
    }
}
