import Observation

/// App-owned maintenance yields while a workout is live. The workout model is
/// still the source of truth; this gate mirrors only the scheduling state that
/// cancellable services and keep-resident views need in order to cooperate.
@MainActor
@Observable
final class LiveWorkoutPerformanceGate {
    static let shared = LiveWorkoutPerformanceGate()

    private(set) var isLiveWorkoutActive = false
    private(set) var transitionRevision = 0
    private(set) var idleRevision = 0

    var allowsNonWorkoutWork: Bool {
        !isLiveWorkoutActive
    }

    @discardableResult
    func setLiveWorkoutActive(_ isActive: Bool) -> Bool {
        guard isLiveWorkoutActive != isActive else { return false }
        isLiveWorkoutActive = isActive
        #if canImport(HealthKit)
        LiveWorkoutHealthQueryGate.shared.setLiveWorkoutActive(isActive)
        #endif
        transitionRevision &+= 1
        if !isActive {
            idleRevision &+= 1
        }
        return true
    }
}
