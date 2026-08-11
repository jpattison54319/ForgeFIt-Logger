import Foundation
import Testing
@testable import ForgeFit

/// FF-004 regression suite: a non-plan deep link arriving while onboarding is
/// on screen must be queued, not routed; it must then be replayed — once, in
/// arrival order, and only onto a fully-initialized app — after dismissal.
/// This exercises the exact state transitions `ContentView` drives through
/// `DeepLinkDeferralPolicy` + `PendingDeepLinkQueue` (the queue is held in
/// `ContentView`, so the transitions are tested here without mounting the
/// shell).
struct OnboardingDeepLinkDeferralTests {

    @Test func nonPlanLinkDuringOnboardingIsDeferredNotRouted() {
        let link = URL(string: "forgefit://start/\(UUID().uuidString)")!
        #expect(DeepLinkDeferralPolicy.shouldDefer(url: link, onboardingPresented: true))
    }

    @Test func linkOutsideOnboardingRoutesImmediately() {
        let link = URL(string: "forgefit://workout")!
        #expect(!DeepLinkDeferralPolicy.shouldDefer(url: link, onboardingPresented: false))
    }

    /// Plan files already have their own deferred onboarding path
    /// (`receivePlanFile` → `onboardingPlanImport`); a second deferral would
    /// strand them in the queue and break that sheet.
    @Test func planFileLinkKeepsItsExistingDeferredImportPath() {
        let plan = URL(fileURLWithPath: "/tmp/plan.forgefitplan")
        #expect(!DeepLinkDeferralPolicy.shouldDefer(url: plan, onboardingPresented: true))
    }

    @Test func foreignSchemeIsNeverHeld() {
        let foreign = URL(string: "https://example.com/workout")!
        #expect(!DeepLinkDeferralPolicy.shouldDefer(url: foreign, onboardingPresented: true))
    }

    @Test func replayRequiresLaunchedAppAndDismissedOnboarding() {
        #expect(!DeepLinkDeferralPolicy.canReplay(launchTasksFinished: false, onboardingPresented: true))
        #expect(!DeepLinkDeferralPolicy.canReplay(launchTasksFinished: false, onboardingPresented: false))
        #expect(!DeepLinkDeferralPolicy.canReplay(launchTasksFinished: true, onboardingPresented: true))
        #expect(DeepLinkDeferralPolicy.canReplay(launchTasksFinished: true, onboardingPresented: false))
    }

    /// End-to-end trace of the confirmed trigger: two arrivals land while
    /// onboarding is up, one of them a workout-start link. Nothing routes
    /// during onboarding; after dismissal with launch tasks complete both are
    /// replayed to the router in arrival order; nothing double-routes.
    @Test func multipleArrivalsAreHeldThenReplayedOnceInArrivalOrder() {
        var queue = PendingDeepLinkQueue()
        var routed: [URL] = []
        let first = URL(string: "forgefit://insights")!
        let second = URL(string: "forgefit://start/\(UUID().uuidString)")!
        let third = URL(string: "forgefit://workout")!
        let links = [first, second, third]

        // Onboarding on screen: identical to the guard at the top of
        // ContentView.handleDeepLink — defer, never route.
        for link in links {
            guard DeepLinkDeferralPolicy.shouldDefer(url: link, onboardingPresented: true) else {
                Issue.record("non-plan link \(link) must be deferred during onboarding")
                continue
            }
            queue.deferLink(link)
        }
        #expect(routed.isEmpty)
        #expect(queue.urls == links)

        // Dismissal racing a slow launch: the app is not initialized yet, so
        // the held links stay queued — replayPendingDeepLinks would no-op.
        #expect(!DeepLinkDeferralPolicy.canReplay(launchTasksFinished: false, onboardingPresented: false))
        #expect(queue.urls == links)

        // Launch completes, onboarding dismissed: replay drains in arrival
        // order into the router.
        guard DeepLinkDeferralPolicy.canReplay(launchTasksFinished: true, onboardingPresented: false)
        else {
            Issue.record("replay must be permitted after launch + dismissal")
            return
        }
        routed = queue.drain()
        #expect(routed == links)

        // Idempotency: a drained queue routes nothing further.
        #expect(queue.isEmpty)
        #expect(queue.drain().isEmpty)
        #expect(routed.count == links.count)
    }

    @Test func emptyQueueRoutesNothing() {
        var queue = PendingDeepLinkQueue()
        var routed: [URL] = []
        routed = queue.drain()
        #expect(routed.isEmpty)
        #expect(queue.isEmpty)
    }
}