import Foundation

/// Deferral policy and queue for deep links that arrive while onboarding is
/// on screen. A non-plan link routed during onboarding starts its scene on a
/// half-initialized shell behind the cover and can be lost (or its workout
/// deleted) when the slate cleanup runs at dismissal. Plan-file links are
/// deliberately excluded: `handleDeepLink` already defers those into the
/// onboarding import sheet (`receivePlanFile` → `onboardingPlanImport`).
enum DeepLinkDeferralPolicy {
    /// True when a non-plan `forgefit://` link must be held instead of routed.
    static func shouldDefer(url: URL, onboardingPresented: Bool) -> Bool {
        guard onboardingPresented else { return false }
        guard url.scheme?.lowercased() == "forgefit" else { return false }
        return url.pathExtension.lowercased() != "forgefitplan"
    }

    /// Replay is safe only after launch tasks have finished (routines,
    /// exercises, and watch services exist) and onboarding is fully dismissed —
    /// otherwise the replayed link routes into the same half-initialized stack
    /// the deferral exists to avoid.
    static func canReplay(launchTasksFinished: Bool, onboardingPresented: Bool) -> Bool {
        launchTasksFinished && !onboardingPresented
    }
}

/// FIFO hold for deep links that arrived while onboarding was up. Kept as a
/// plain value type so the queuing/replay state transitions are unit-testable
/// without mounting the full ContentView shell.
struct PendingDeepLinkQueue {
    private(set) var urls: [URL] = []

    var isEmpty: Bool { urls.isEmpty }

    mutating func deferLink(_ url: URL) {
        urls.append(url)
    }

    /// Hands back held links in arrival order and empties the queue. Replay is
    /// idempotent from the caller's side: a drained queue cannot double-route
    /// a link, and a second drain is empty.
    mutating func drain() -> [URL] {
        let drained = urls
        urls = []
        return drained
    }
}