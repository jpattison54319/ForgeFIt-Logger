import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct DeferredInteractionWorkTests {
    @Test func scheduledWorkNeverRunsSynchronously() {
        let scheduler = DeferredInteractionWork(delay: .milliseconds(20))
        var count = 0

        scheduler.schedule { count += 1 }

        #expect(count == 0)
        #expect(scheduler.hasPendingWork)
        scheduler.flush()
        #expect(count == 1)
        #expect(!scheduler.hasPendingWork)
    }

    @Test func repeatedInteractionChangesCoalesceToLatestWork() {
        let scheduler = DeferredInteractionWork(delay: .milliseconds(20))
        var values: [Int] = []

        scheduler.schedule { values.append(1) }
        scheduler.schedule { values.append(2) }
        scheduler.schedule { values.append(3) }

        #expect(values.isEmpty)
        scheduler.flush()
        #expect(values == [3])
    }

    @Test func lifecycleFlushRunsPendingWorkImmediatelyAndOnlyOnce() async {
        let scheduler = DeferredInteractionWork(delay: .milliseconds(100))
        var count = 0

        scheduler.schedule { count += 1 }
        scheduler.flush()

        #expect(count == 1)
        #expect(!scheduler.hasPendingWork)
        try? await Task.sleep(for: .milliseconds(140))
        #expect(count == 1)
    }
}
