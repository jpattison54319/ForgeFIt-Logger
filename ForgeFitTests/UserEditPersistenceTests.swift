import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct UserEditPersistenceTests {
    @Test func routineRenameIsVisibleFromAFreshContextAfterCommit() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Push 1"
        )
        context.insert(routine)
        try context.save()

        let renamedAt = Date.now.addingTimeInterval(5)
        routine.name = "Push 1 + mile"
        routine.updatedAt = renamedAt

        #expect(context.saveUserChanges())

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let routineID = routine.id
        let persisted = try #require(verificationContext.fetch(
            FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == routineID })
        ).first)
        #expect(persisted.name == "Push 1 + mile")
        #expect(persisted.updatedAt == renamedAt)
    }

    @Test func failedUserOperationKeepsAnExactRetryAndCompletion() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let center = PersistentChangeSaveCenter()
        var attempts = 0
        var completions = 0

        let initiallySucceeded = center.perform({
            attempts += 1
            if attempts == 1 { throw ExpectedFailure.firstAttempt }
        }, onSuccess: {
            completions += 1
        })

        #expect(!initiallySucceeded)
        #expect(center.failure != nil)
        #expect(attempts == 1)
        #expect(completions == 0)

        // Exercise the worst-case SwiftUI ordering: the alert binding is set
        // false before its Retry button action runs. The retained operation
        // must still be available to that action.
        center.endAlertPresentation()
        center.retry()
        // `retry()` deliberately yields one main-actor turn so an alert can
        // finish dismissing before a second failure is presented. Sleeping
        // briefly lets that queued turn run without depending on executor
        // ordering between two consecutive `Task.yield()` calls.
        try await Task.sleep(for: .milliseconds(20))

        #expect(center.failure == nil)
        #expect(attempts == 2)
        #expect(completions == 1)
    }
}
