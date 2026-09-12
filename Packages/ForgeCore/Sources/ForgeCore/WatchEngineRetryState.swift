import Foundation

public struct WatchEngineRetryState: Equatable, Sendable {
    public enum Issue: String, Sendable {
        case transient, permissionRequired, anotherWorkout, retryLimit

        public var message: String {
            switch self {
            case .transient: "Heart-rate recording interrupted"
            case .permissionRequired: "Health access is needed on Apple Watch"
            case .anotherWorkout: "Another app is recording a workout"
            case .retryLimit: "Heart-rate recording could not restart"
            }
        }
    }

    public private(set) var workoutID: UUID?
    public private(set) var issue: Issue?
    public private(set) var failures = 0
    public private(set) var nextAttemptAt: Date?

    public init() {}

    public mutating func mayStart(_ id: UUID?, at now: Date) -> Bool {
        if workoutID != id { self = Self(); workoutID = id }
        if let issue, issue != .transient { return false }
        return nextAttemptAt.map { now >= $0 } ?? true
    }

    public mutating func started() {
        issue = nil
        nextAttemptAt = nil
        // The budget belongs to the workout, not to a stream of snapshots.
    }

    public mutating func failed(_ failure: Issue, at now: Date) {
        failures += 1
        issue = failure == .transient && failures >= 3 ? .retryLimit : failure
        nextAttemptAt = issue == .transient ? now.addingTimeInterval(failures == 1 ? 3 : 10) : nil
    }

    public mutating func bind(_ id: UUID) { workoutID = id }

    public mutating func retryExplicitly() {
        issue = nil
        failures = 0
        nextAttemptAt = nil
    }
}
