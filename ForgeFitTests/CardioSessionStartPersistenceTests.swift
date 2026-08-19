import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CardioSessionStartPersistenceTests {
    private enum SimulatedSaveFailure: Error {
        case failed
    }

    @Test func failedStartRestoresInactiveStateAndRetryStartsRuntimeAfterCommit() async throws {
        let (container, context) = try TestStore.make()
        let originalStart = Date(timeIntervalSince1970: 9_000_000)
        let requestedStart = originalStart.addingTimeInterval(120)
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: "run",
            startedAt: originalStart
        )
        context.insert(session)
        try context.save()

        let saveCenter = PersistentChangeSaveCenter()
        var attempts = 0
        var runtimeStarts = 0
        let committedImmediately = CardioSessionStartPersistence.perform(
            session: session,
            startedAt: requestedStart,
            context: context,
            saveCenter: saveCenter,
            save: { context in
                attempts += 1
                if attempts == 1 { throw SimulatedSaveFailure.failed }
                try context.save()
            },
            onCommit: { runtimeStarts += 1 }
        )

        #expect(!committedImmediately)
        #expect(session.liveStartedAt == nil)
        #expect(session.startedAt == originalStart)
        #expect(runtimeStarts == 0)
        #expect(saveCenter.failure != nil)

        saveCenter.retry()
        // Retry intentionally yields once so SwiftUI can finish dismissing the
        // first alert. Suspend this test long enough for that retained action
        // to run before the in-memory store is torn down.
        try await Task.sleep(for: .milliseconds(25))

        #expect(saveCenter.failure == nil)
        #expect(session.liveStartedAt == requestedStart)
        #expect(session.startedAt == requestedStart)
        #expect(runtimeStarts == 1)

        let freshContext = ModelContext(container)
        let sessionID = session.id
        let persisted = try #require(freshContext.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        #expect(persisted.liveStartedAt == requestedStart)
        #expect(persisted.startedAt == requestedStart)
    }
}
