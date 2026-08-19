import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Explicit, user-facing Apple Health connection state. HealthKit exposes
/// write authorization status but deliberately hides per-type read decisions;
/// ForgeFit therefore calls the connection "denied" when workout write access
/// was denied, while individual read channels continue to degrade privately.
nonisolated enum HealthAuthorizationState: Equatable, Sendable {
    case unavailable
    case notDetermined
    case requesting
    case connected
    case denied
    case timedOut
    case cancelled
    case failed(String)

    var isConnected: Bool { self == .connected }
    var isRequesting: Bool { self == .requesting }
    var requiresPermissionReview: Bool { self == .denied }
    /// The system permission sheet completed without an infrastructure error.
    /// A denied workout-write type still counts: HealthKit intentionally does
    /// not reveal which read types the person allowed, so onboarding must not
    /// strand someone who granted reads but declined writes.
    var permissionRequestResolved: Bool {
        self == .connected || self == .denied
    }

    var issueMessage: String? {
        switch self {
        case .denied:
            "Writing workouts to Apple Health is off. ForgeFit will still use any Health data you allowed. Review ForgeFit's permissions in Settings or the Health app."
        case .timedOut:
            "Apple Health did not finish responding. You can try again; this screen is no longer locked."
        case .cancelled:
            "Apple Health connection was interrupted. You can try again."
        case .failed(let message):
            "Apple Health could not connect: \(message)"
        case .unavailable:
            "Apple Health is not available on this device."
        case .notDetermined, .requesting, .connected:
            nil
        }
    }
}

/// Once-only result gate for the HealthKit completion, timeout, and task
/// cancellation race. The permission sheet itself cannot be force-dismissed,
/// but ForgeFit's controls always recover when its deadline expires.
nonisolated private final class HealthAuthorizationResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var delivery: ((HealthAuthorizationState) -> Void)?
    private var pending: HealthAuthorizationState?
    private var resolved = false

    func register(_ delivery: @escaping (HealthAuthorizationState) -> Void) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            delivery(pending)
        } else {
            self.delivery = delivery
            lock.unlock()
        }
    }

    func resolve(_ value: HealthAuthorizationState) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        if let delivery {
            self.delivery = nil
            lock.unlock()
            delivery(value)
        } else {
            pending = value
            lock.unlock()
        }
    }
}

/// HealthKit-free timeout/cancellation seam used by production and tests.
nonisolated enum HealthAuthorizationRequestRunner {
    static func run(
        timeout: Duration,
        start: @escaping @Sendable (
            @escaping @Sendable (HealthAuthorizationState) -> Void
        ) -> Void
    ) async -> HealthAuthorizationState {
        let gate = HealthAuthorizationResolutionGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.register { continuation.resume(returning: $0) }
                guard !Task.isCancelled else {
                    gate.resolve(.cancelled)
                    return
                }
                start { gate.resolve($0) }
                Task.detached(priority: .utility) {
                    do {
                        try await Task.sleep(for: timeout)
                        gate.resolve(.timedOut)
                    } catch {
                        // This detached deadline is never the source of the
                        // enclosing request's cancellation result.
                    }
                }
            }
        } onCancel: {
            gate.resolve(.cancelled)
        }
    }
}

@MainActor
@Observable
final class HealthAuthorizationStore {
    static let shared = HealthAuthorizationStore()

    private(set) var state: HealthAuthorizationState

    init(initialState: HealthAuthorizationState? = nil) {
        state = initialState ?? HealthService.shared.authorizationState
    }

    func refresh() {
        guard !state.isRequesting else { return }
        state = HealthService.shared.authorizationState
    }

    @discardableResult
    func connect(timeout: Duration = .seconds(45)) async -> Bool {
        await connect {
            await HealthService.shared.requestAuthorizationOutcome(timeout: timeout)
        }
    }

    @discardableResult
    func connect(
        using request: @escaping @Sendable () async -> HealthAuthorizationState
    ) async -> Bool {
        guard !state.isRequesting else { return false }
        state = .requesting
        let resolved = await request()
        state = resolved
        return resolved.permissionRequestResolved
    }

    func apply(_ state: HealthAuthorizationState) {
        self.state = state
    }
}

@MainActor
enum HealthAuthorizationRecovery {
    static func openSettings() {
        #if canImport(UIKit)
        // Use Apple's documented app-settings URL. The previously used
        // `x-apple-health://` scheme is undocumented and therefore an avoidable
        // App Review risk. Copy also gives the Health-app path when a person
        // prefers to manage the fine-grained categories there.
        guard let settings = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settings)
        #endif
    }
}
