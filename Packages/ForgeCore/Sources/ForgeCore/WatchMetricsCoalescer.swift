import Foundation

/// Keeps one latest pending packet. A skipped callback always has a scheduled
/// flush; a quiet sensor or a burst of energy updates cannot starve HR.
@MainActor
public final class WatchMetricsCoalescer {
    private let heartRateInterval: TimeInterval
    private let otherMetricsInterval: TimeInterval
    private let now: () -> Date
    private let emit: (WatchLiveMetrics) -> Void
    private var lastSentAt: Date?
    private var lastHeartRateSampleAt: Date?
    private var pending: WatchLiveMetrics?
    private var scheduledAt: Date?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(
        heartRateInterval: TimeInterval = 1,
        otherMetricsInterval: TimeInterval = 5,
        now: @escaping () -> Date = { Date() },
        emit: @escaping (WatchLiveMetrics) -> Void
    ) {
        self.heartRateInterval = heartRateInterval
        self.otherMetricsInterval = otherMetricsInterval
        self.now = now
        self.emit = emit
    }

    public func submit(_ metrics: WatchLiveMetrics, force: Bool = false) {
        let date = now()
        pending = metrics
        let hasNewHR = metrics.freshHeartRate(at: date) != nil
            && metrics.asOf != lastHeartRateSampleAt
        let firstHR = hasNewHR && lastHeartRateSampleAt == nil
        let interval = hasNewHR ? heartRateInterval : otherMetricsInterval
        let due: Date
        if !force, !firstHR, let lastSentAt {
            due = max(date, lastSentAt.addingTimeInterval(interval))
        } else {
            due = date
        }
        if due <= date {
            flush()
        } else if scheduledAt.map({ due < $0 }) ?? true {
            task?.cancel()
            generation &+= 1
            let token = generation
            scheduledAt = due
            task = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(due.timeIntervalSince(date))) }
                catch { return }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.flush()
            }
        }
    }

    public func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        pending = nil
        scheduledAt = nil
        lastSentAt = nil
        lastHeartRateSampleAt = nil
    }

    private func flush() {
        generation &+= 1
        task?.cancel()
        task = nil
        scheduledAt = nil
        guard var metrics = pending else { return }
        pending = nil
        let date = now()
        metrics.heartRate = metrics.freshHeartRate(at: date)
        lastSentAt = date
        if metrics.heartRate != nil { lastHeartRateSampleAt = metrics.asOf }
        emit(metrics)
    }

    deinit { task?.cancel() }
}
