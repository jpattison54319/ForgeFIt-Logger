import Testing
@testable import ForgeFit

@MainActor
struct DeferredSaveCoordinatorTests {
    @Test("Rapid row edits coalesce without a synchronous commit")
    func rapidEditsCoalesceUntilTheScreenFlushes() {
        let coordinator = DeferredSaveCoordinator(delay: .seconds(30))
        var commits = 0

        for _ in 0..<100 {
            coordinator.schedule { commits += 1 }
        }

        #expect(commits == 0)
        #expect(coordinator.hasPendingSave)

        coordinator.flush()
        #expect(commits == 1)
        #expect(!coordinator.hasPendingSave)

        coordinator.flush()
        #expect(commits == 1, "repeated lifecycle flushes must be idempotent")
    }

    @Test("Cancellation prevents a discarded edit from reviving")
    func cancellationDropsThePendingCommit() {
        let coordinator = DeferredSaveCoordinator(delay: .seconds(30))
        var commits = 0
        coordinator.schedule { commits += 1 }

        coordinator.cancel()
        coordinator.flush()

        #expect(commits == 0)
        #expect(!coordinator.hasPendingSave)
    }

    @Test("Scrolling keeps a pending save off the interaction path")
    func pauseDefersTheDeadlineUntilAFullIdleWindow() async throws {
        let coordinator = DeferredSaveCoordinator(delay: .milliseconds(25))
        var commits = 0

        coordinator.pause()
        coordinator.schedule { commits += 1 }
        try await Task.sleep(for: .milliseconds(75))

        #expect(commits == 0)
        #expect(coordinator.hasPendingSave)

        coordinator.resume()
        try await Task.sleep(for: .milliseconds(75))

        #expect(commits == 1)
        #expect(!coordinator.hasPendingSave)
    }
}
