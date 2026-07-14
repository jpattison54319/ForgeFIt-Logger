import Testing
@testable import ForgeFit

/// The rest timer's `onStateChange` hook is what pushes start / ±adjust / skip
/// to the watch instantly (wired to `WatchLink.publishState` in
/// `WatchLink.configure`). It must fire on every state transition, or a
/// countdown a lifter extends or skips on the phone goes stale on the wrist.
@MainActor
struct RestTimerWatchHookTests {

    @Test func onStateChangeFiresForStartAdjustAndSkip() {
        let timer = RestTimerController.shared
        timer.skip() // clean slate
        var fires = 0
        timer.onStateChange = { fires += 1 }
        defer { timer.onStateChange = nil; timer.skip() }

        // Large duration so the completion task never fires mid-test.
        timer.start(seconds: 600, label: "Rest")
        #expect(fires == 1)

        timer.adjust(by: 15)
        #expect(fires == 2)

        timer.skip()
        #expect(fires == 3)
    }

    @Test func adjustWithoutRunningTimerDoesNotFire() {
        let timer = RestTimerController.shared
        timer.skip()
        var fires = 0
        timer.onStateChange = { fires += 1 }
        defer { timer.onStateChange = nil }

        timer.adjust(by: 15) // no running timer → guarded no-op
        #expect(fires == 0)
    }
}
