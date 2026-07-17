import Foundation

/// Live pace over a short trailing window of cumulative-distance samples —
/// the number a pace alert compares against a target band. Instantaneous
/// GPS/watch deltas are too jittery to cue on; a whole-session average is
/// too sluggish to notice a surge. Thirty seconds of trailing distance is
/// the honest middle.
public struct RollingPaceWindow: Sendable {
    /// Below these floors the math is noise, not pace: report nothing.
    public static let minimumMeters: Double = 15
    public static let minimumSeconds: TimeInterval = 10

    private var samples: [(time: Date, meters: Double)] = []
    private let window: TimeInterval

    public init(window: TimeInterval = 30) {
        self.window = window
    }

    /// Feed a cumulative session distance. Non-monotonic readings (feed
    /// restarts, source switches) reset the window rather than emit a
    /// negative split.
    public mutating func add(meters: Double, at date: Date) {
        if let last = samples.last, meters < last.meters {
            samples.removeAll()
        }
        samples.append((date, meters))
        let cutoff = date.addingTimeInterval(-window)
        samples.removeAll { $0.time < cutoff }
    }

    /// Trailing pace in seconds per km; nil until the window holds enough
    /// real movement to be honest (and nil again if the athlete stops).
    public func paceSecondsPerKm(asOf date: Date? = nil) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let anchor = date ?? last.time
        // A stale window (no fresh samples) is a stopped athlete, not a pace.
        if anchor.timeIntervalSince(last.time) > window { return nil }
        let meters = last.meters - first.meters
        let seconds = last.time.timeIntervalSince(first.time)
        guard meters >= Self.minimumMeters, seconds >= Self.minimumSeconds else { return nil }
        return seconds / (meters / 1000)
    }

    public mutating func reset() {
        samples.removeAll()
    }
}
