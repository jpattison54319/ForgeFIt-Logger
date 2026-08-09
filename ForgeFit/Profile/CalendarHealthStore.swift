import Foundation
import Observation

nonisolated protocol CalendarHealthLoading: Sendable {
    func load(endingAt end: Date) async -> [RecoveryEngine.DailyHealthMetric]
}

nonisolated struct CalendarHealthWorker: CalendarHealthLoading {
    func load(endingAt end: Date) async -> [RecoveryEngine.DailyHealthMetric] {
        await HealthService.shared.dailyMetrics(days: 60, endingAt: end)
    }
}

/// Small process-local cache for historical calendar selections. A selected
/// day gets its own preceding baseline window; future observations never leak
/// into that day's Health interpretation.
@MainActor
@Observable
final class CalendarHealthStore {
    @ObservationIgnored private let worker: any CalendarHealthLoading
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var cacheOrder: [Date] = []
    private var windows: [Date: [RecoveryEngine.DailyHealthMetric]] = [:]
    private(set) var loadingDays: Set<Date> = []

    init(
        worker: any CalendarHealthLoading = CalendarHealthWorker(),
        calendar: Calendar = .current
    ) {
        self.worker = worker
        self.calendar = calendar
    }

    func metrics(
        for day: Date,
        fallback: [RecoveryEngine.DailyHealthMetric]
    ) -> [RecoveryEngine.DailyHealthMetric] {
        let key = calendar.startOfDay(for: day)
        if let cached = windows[key] { return cached }
        return fallback
            .filter { calendar.startOfDay(for: $0.date) <= key }
            .suffix(60)
            .map { $0 }
    }

    func isLoading(_ day: Date) -> Bool {
        loadingDays.contains(calendar.startOfDay(for: day))
    }

    func load(day: Date, fallback: [RecoveryEngine.DailyHealthMetric]) async {
        let key = calendar.startOfDay(for: day)
        guard windows[key] == nil, !loadingDays.contains(key) else { return }
        loadingDays.insert(key)
        defer { loadingDays.remove(key) }

        let end = calendar.date(byAdding: .day, value: 1, to: key)?.addingTimeInterval(-1) ?? day
        let worker = worker
        // With Swift's approachable-concurrency mode, a plain nonisolated
        // async call may inherit MainActor. HealthKit resumes with up to 60
        // days of samples to sort and aggregate, so make the executor boundary
        // explicit and keep touch/scroll handling unconditionally responsive.
        let loadTask = Task.detached(priority: .utility) {
            await worker.load(endingAt: end)
        }
        let loaded = await withTaskCancellationHandler(
            operation: { await loadTask.value },
            onCancel: { loadTask.cancel() }
        )
        guard !Task.isCancelled else { return }
        let resolved = loaded.isEmpty
            ? metrics(for: key, fallback: fallback)
            : SleepOverrideStore.shared.process(loaded)
        windows[key] = resolved
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 12 {
            windows.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
