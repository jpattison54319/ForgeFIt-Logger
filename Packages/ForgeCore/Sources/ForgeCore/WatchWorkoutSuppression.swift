import Foundation

/// Only bounded workout identities are persisted, never the workout or metrics.
/// A local stop survives late callbacks, refreshed snapshots, and app relaunch.
public struct WatchWorkoutSuppression: Codable, Equatable, Sendable {
    public private(set) var terminalIDs: [UUID] = []
    public private(set) var stoppedIDs: [UUID] = []
    public private(set) var stopUnidentifiedWorkout = false

    public init() {}

    public mutating func finish(_ id: UUID) {
        terminalIDs.removeAll { $0 == id }
        terminalIDs.append(id)
        terminalIDs = Array(terminalIDs.suffix(24))
    }

    public mutating func stop(_ id: UUID?) {
        guard let id else { stopUnidentifiedWorkout = true; return }
        stoppedIDs.removeAll { $0 == id }
        stoppedIDs.append(id)
        stoppedIDs = Array(stoppedIDs.suffix(24))
    }

    public mutating func resolve(_ id: UUID?) {
        guard stopUnidentifiedWorkout else { return }
        stopUnidentifiedWorkout = false
        if let id { stop(id) }
    }

    public mutating func resume(_ id: UUID?) {
        stopUnidentifiedWorkout = false
        if let id { stoppedIDs.removeAll { $0 == id } }
    }

    public func isSuppressed(_ id: UUID?) -> Bool {
        stopUnidentifiedWorkout || id.map { terminalIDs.contains($0) || stoppedIDs.contains($0) } == true
    }
}
