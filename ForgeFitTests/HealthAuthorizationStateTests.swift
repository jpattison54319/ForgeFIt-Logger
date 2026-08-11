import Foundation
import Testing
@testable import ForgeFit

struct HealthAuthorizationStateTests {
    @Test func completedDenialIsAnExplicitActionableState() async {
        let outcome = await HealthAuthorizationRequestRunner.run(timeout: .seconds(1)) { finish in
            finish(.denied)
        }

        #expect(outcome == .denied)
        #expect(outcome.requiresPermissionReview)
        #expect(outcome.permissionRequestResolved)
        #expect(outcome.issueMessage?.contains("still use any Health data") == true)
    }

    @Test func stalledRequestTimesOutAndReturnsControl() async {
        let outcome = await HealthAuthorizationRequestRunner.run(timeout: .milliseconds(20)) { _ in
            // Deliberately never calls its completion.
        }

        #expect(outcome == .timedOut)
        #expect(!outcome.isRequesting)
        #expect(outcome.issueMessage?.contains("try again") == true)
    }

    @Test func cancellationResolvesExactlyOnce() async {
        let task = Task {
            await HealthAuthorizationRequestRunner.run(timeout: .seconds(5)) { finish in
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(100))
                    finish(.connected)
                }
            }
        }
        task.cancel()

        #expect(await task.value == .cancelled)
    }

    @Test @MainActor func storeReenablesAfterFailureAndCanRetry() async {
        let store = HealthAuthorizationStore(initialState: .notDetermined)

        #expect(!(await store.connect(using: { .timedOut })))
        #expect(store.state == .timedOut)
        #expect(!store.state.isRequesting)

        #expect(await store.connect(using: { .connected }))
        #expect(store.state == .connected)
    }

    @Test @MainActor func writeDenialDoesNotStrandReadOnlyOnboarding() async {
        let store = HealthAuthorizationStore(initialState: .notDetermined)

        #expect(await store.connect(using: { .denied }))
        #expect(store.state == .denied)
        #expect(store.state.permissionRequestResolved)
        #expect(!store.state.isConnected)
    }
}
