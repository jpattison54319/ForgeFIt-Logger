import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct PendingDraftCoordinatorTests {
    @Test("Untouched local text follows an external model update")
    func untouchedDraftRefreshesFromModel() {
        #expect(LocalTextDraftPolicy.synchronizedDraft(
            currentDraft: "old",
            modelText: "remote update",
            isDirty: false
        ) == "remote update")
        #expect(!LocalTextDraftPolicy.shouldCommit(
            draft: "remote update",
            modelText: "remote update",
            isDirty: false
        ))
    }

    @Test("A dirty local draft wins at its explicit commit boundary")
    func dirtyDraftWinsOverExternalModelUpdate() {
        #expect(LocalTextDraftPolicy.synchronizedDraft(
            currentDraft: "local edit",
            modelText: "remote update",
            isDirty: true
        ) == "local edit")
        #expect(LocalTextDraftPolicy.shouldCommit(
            draft: "local edit",
            modelText: "remote update",
            isDirty: true
        ))
    }

    @Test("Terminal actions commit every registered draft exactly once")
    func commitsRegisteredDrafts() {
        let coordinator = PendingDraftCoordinator()
        let first = UUID()
        let second = UUID()
        var committed: [String] = []

        coordinator.register(first) { committed.append("stale") }
        coordinator.register(first) { committed.append("first") }
        coordinator.register(second) { committed.append("second") }
        coordinator.commitAll()

        #expect(Set(committed) == ["first", "second"])
        #expect(committed.count == 2)

        coordinator.unregister(first)
        coordinator.unregister(second)
        coordinator.commitAll()
        #expect(committed.count == 2)
    }

    @Test("A terminal action is rejected while any registered draft is invalid")
    func rejectsInvalidDraftsUntilCorrected() {
        let coordinator = PendingDraftCoordinator()
        let token = UUID()
        var commits = 0
        var isValid = false

        coordinator.register(
            token,
            commit: { commits += 1 },
            isValid: { isValid }
        )

        #expect(!coordinator.commitAll())
        #expect(commits == 1)

        isValid = true
        #expect(coordinator.commitAll())
        #expect(commits == 2)
    }

    @Test("Deleting an invalid row removes its stale save blocker")
    func removingInvalidRegistrationRestoresTerminalValidity() {
        let coordinator = PendingDraftCoordinator()
        let token = UUID()
        coordinator.register(token, commit: {}, isValid: { false })

        #expect(!coordinator.commitAll())
        coordinator.unregister(token)
        #expect(coordinator.commitAll())
    }

    @Test("Screen teardown breaks a registration cycle")
    func clearAllReleasesCoordinatorCapturedByAChildClosure() {
        weak var released: PendingDraftCoordinator?

        do {
            let coordinator = PendingDraftCoordinator()
            released = coordinator
            coordinator.register(UUID()) {
                coordinator.clearAll()
            }
            coordinator.clearAll()
        }

        #expect(released == nil)
    }
}
