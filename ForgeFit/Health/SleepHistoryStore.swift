import Foundation
import Observation

nonisolated protocol SleepHistoryLoading: Sendable {
    func load() async -> [RecoveryEngine.DailyHealthMetric]
}

nonisolated struct SleepHistoryWorker: SleepHistoryLoading {
    func load() async -> [RecoveryEngine.DailyHealthMetric] {
        await HealthService.shared.sleepHistory()
    }
}

/// On-demand, process-local sleep history. It intentionally does not enlarge
/// Home's bounded recovery cache or persist raw Health data outside HealthKit.
@MainActor
@Observable
final class SleepHistoryStore {
    static let shared = SleepHistoryStore()

    @ObservationIgnored private let worker: any SleepHistoryLoading
    @ObservationIgnored private var rawNights: [RecoveryEngine.DailyHealthMetric] = []
    @ObservationIgnored private var loadTask: Task<[RecoveryEngine.DailyHealthMetric], Never>?

    private(set) var nights: [RecoveryEngine.DailyHealthMetric] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    init(worker: any SleepHistoryLoading = SleepHistoryWorker()) {
        self.worker = worker
    }

    func load(recentMetrics: [RecoveryEngine.DailyHealthMetric]) async {
        if hasLoaded {
            publish(recentMetrics: recentMetrics)
            return
        }
        if let loadTask {
            rawNights = await loadTask.value
            publish(recentMetrics: recentMetrics)
            return
        }

        isLoading = true
        let worker = worker
        // Full-history HealthKit aggregation can span years. An explicit
        // detached boundary is required under approachable concurrency; a
        // plain Task here inherits MainActor and can freeze the history view.
        let task = Task.detached(priority: .utility) {
            await worker.load()
        }
        loadTask = task
        rawNights = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        guard !Task.isCancelled else {
            loadTask = nil
            isLoading = false
            return
        }
        loadTask = nil
        hasLoaded = true
        isLoading = false
        publish(recentMetrics: recentMetrics)
    }

    private func publish(recentMetrics: [RecoveryEngine.DailyHealthMetric]) {
        let calendar = Calendar.current
        var byDay = Dictionary(
            uniqueKeysWithValues: SleepOverrideStore.shared.processHistory(rawNights).map {
                (calendar.startOfDay(for: $0.date), $0)
            }
        )
        for metric in recentMetrics where metric.sleepTotalMinutes != nil || metric.sleepOverrideStatus != nil {
            byDay[calendar.startOfDay(for: metric.date)] = metric
        }
        nights = byDay.values.sorted { $0.date > $1.date }
    }
}
