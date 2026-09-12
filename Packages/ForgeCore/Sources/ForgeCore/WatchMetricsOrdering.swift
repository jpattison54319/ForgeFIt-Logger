import Foundation

/// Shared by immediate and latest-context delivery. Ordering is per workout,
/// with a stream identity across sequence resets and a timestamp fallback for
/// older peers. A newer protocol stream cannot be replaced by legacy packets.
public struct WatchMetricsOrdering: Sendable {
    private var latest: WatchLiveMetrics?

    public init() {}

    public func mayAccept(_ metrics: WatchLiveMetrics, at now: Date = Date()) -> Bool {
        let modern = metrics.streamID != nil && metrics.sequence != nil && metrics.sentAt != nil
        let legacy = metrics.streamID == nil && metrics.sequence == nil && metrics.sentAt == nil
        guard modern || legacy else { return false }
        let timestamp = metrics.sentAt ?? metrics.asOf
        let age = now.timeIntervalSince(timestamp)
        guard age.isFinite, age >= -2, age <= WatchLiveMetrics.heartRateFreshnessInterval else { return false }
        if metrics.heartRate != nil {
            let sampleAge = now.timeIntervalSince(metrics.asOf)
            guard sampleAge.isFinite, sampleAge >= -2 else { return false }
        }
        guard let latest, latest.workoutID == metrics.workoutID else { return true }
        if let stream = latest.streamID {
            guard modern, let sequence = metrics.sequence, let lastSequence = latest.sequence else { return false }
            if stream == metrics.streamID {
                guard sequence > lastSequence else { return false }
            } else {
                guard timestamp > (latest.sentAt ?? latest.asOf) else { return false }
            }
        } else if timestamp <= (latest.sentAt ?? latest.asOf) {
            return false
        }
        if latest.heartRate != nil, metrics.heartRate != nil, metrics.asOf < latest.asOf { return false }
        return true
    }

    @discardableResult
    public mutating func accept(_ metrics: WatchLiveMetrics, at now: Date = Date()) -> Bool {
        guard mayAccept(metrics, at: now) else { return false }
        latest = metrics
        return true
    }
}
