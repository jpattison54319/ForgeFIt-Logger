import ForgeCore
import ForgeData
import Foundation
import Observation

/// The complete value-only HealthKit refresh result. No HealthKit object or
/// SwiftData model crosses this boundary.
nonisolated struct HealthMetricsRefreshResult: Sendable {
    let daily: [RecoveryEngine.DailyHealthMetric]
    let extras: [RecoveryEngine.Signal]
    let activity: [DailyActivityMetric]
    let bodyweight: [(date: Date, value: Double)]
    let hrvGapDetected: Bool
}

/// HealthKit queries are asynchronous, but the substantial work begins after
/// they answer: sorting raw samples, grouping 60–90 days into buckets, and
/// deriving nocturnal readings. The app target defaults to MainActor, so this
/// explicit worker boundary is what keeps that post-query work away from touch
/// and scroll handling.
nonisolated struct HealthMetricsWorker: Sendable {
    func load() async -> HealthMetricsRefreshResult {
        async let daily = HealthService.shared.dailyMetrics()
        async let extras = HealthService.shared.todaySignals()
        async let activity = HealthService.shared.dailyActivityMetrics()
        async let bodyweight = HealthService.shared.bodyMassSeries()
        async let hrvGap = HealthService.shared.detectGarminHRVGap()
        return await HealthMetricsRefreshResult(
            daily: daily,
            extras: extras,
            activity: activity,
            bodyweight: bodyweight,
            hrvGapDetected: hrvGap
        )
    }

    #if DEBUG
    func isExecutingOnMainThreadForTesting() async -> Bool {
        Self.currentThreadIsMain()
    }

    private static func currentThreadIsMain() -> Bool { Thread.isMainThread }
    #endif
}

nonisolated protocol HealthMetricsLoading: Sendable {
    func load() async -> HealthMetricsRefreshResult
}

extension HealthMetricsWorker: HealthMetricsLoading {}

/// App-wide cache of the daily HealthKit recovery series. Every readiness
/// computation reads from here, so HRV / resting HR / sleep baselines feed the
/// score the moment Health is connected — refreshed on launch, on
/// foreground, and after connecting Apple Health.
@MainActor
@Observable
final class HealthMetricsStore {
    static let shared = HealthMetricsStore()

    @ObservationIgnored private let worker: any HealthMetricsLoading

    /// 60-day daily series for RecoveryEngine and Health personal ranges,
    /// already annotated for sleep integrity and with the user's per-night
    /// corrections applied (`SleepIntegrity` + `SleepOverrideStore`).
    private(set) var metrics: [RecoveryEngine.DailyHealthMetric] = []
    /// Monotonic invalidation token for derived recovery reports. A correction
    /// changes values in place without changing the Health row count or date.
    private(set) var metricsRevision = 0
    /// The raw HealthKit series before integrity annotation — kept so a new
    /// user correction can be re-applied without re-querying HealthKit.
    @ObservationIgnored private var rawMetrics: [RecoveryEngine.DailyHealthMetric] = []
    /// Supplemental full-day signals (respiratory, SpO₂, VO₂max, HR recovery,
    /// steps, energy) surfaced on the recovery detail screen.
    private(set) var extraSignals: [RecoveryEngine.Signal] = []
    /// Rolling movement history for daily strain. Health data remains in this
    /// process-local cache and never enters a synced model or backup.
    private(set) var activityMetrics: [DailyActivityMetric] = []
    /// Body-mass history in kilograms.
    private(set) var bodyweightSeries: [(date: Date, value: Double)] = []
    var latestBodyweight: Double? { bodyweightSeries.last?.value }
    /// Garmin sleep is flowing into Apple Health but HRV isn't (Garmin
    /// Connect doesn't sync it) — the recovery screen explains the gap.
    private(set) var hrvGapDetected = false
    private(set) var lastRefreshed: Date?
    /// In-flight HealthKit refresh state. All triggers now join one shared task;
    /// the integer remains API-compatible with Home's existing activity state.
    private(set) var activeRefreshCount = 0
    var isRefreshing: Bool { activeRefreshCount > 0 }

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(worker: any HealthMetricsLoading = HealthMetricsWorker()) {
        self.worker = worker
    }

    #if DEBUG
    /// When a demo seed is active, real HealthKit refreshes are suppressed so
    /// they can't overwrite the synthetic series with an empty query.
    @ObservationIgnored private var demoSeeded = false
    #endif

    /// Safe to call often; coalesces and skips when refreshed very recently.
    func refresh(force: Bool = false) {
        #if DEBUG
        if demoSeeded { return }
        #endif
        Task { @MainActor [weak self] in
            await self?.refreshCoalesced(force: force)
        }
    }

    /// Awaitable variant for pull-to-refresh: always re-queries HealthKit so
    /// today's new data (sleep synced late, a morning HRV reading, a weigh-in)
    /// lands in the readiness score immediately.
    func refreshNow() async {
        #if DEBUG
        if demoSeeded { return }
        #endif
        await refreshCoalesced(force: true)
    }

    /// Foreground maintenance variant: preserves the five-minute freshness gate
    /// and honors cancellation before publishing observable results. This keeps
    /// a just-started live workout from inheriting an idle-screen refresh.
    func refreshIfStaleNow() async {
        #if DEBUG
        if demoSeeded { return }
        #endif
        await refreshCoalesced(force: false)
    }

    /// Every trigger joins one shared query instead of starting another set of
    /// five HealthKit reads while launch's refresh is still in flight.
    private func refreshCoalesced(force: Bool) async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        if !force,
           let lastRefreshed,
           Date().timeIntervalSince(lastRefreshed) < 300 {
            return
        }

        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh()
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        activeRefreshCount += 1
        defer { activeRefreshCount -= 1 }

        let worker = worker
        let workerTask = Task.detached(priority: .utility) {
            await worker.load()
        }
        let result = await withTaskCancellationHandler(
            operation: { await workerTask.value },
            onCancel: { workerTask.cancel() }
        )
        guard !Task.isCancelled else { return }
        rawMetrics = result.daily
        metrics = SleepOverrideStore.shared.process(result.daily)
        metricsRevision &+= 1
        extraSignals = result.extras
        activityMetrics = result.activity
        bodyweightSeries = result.bodyweight
        hrvGapDetected = result.hrvGapDetected
        lastRefreshed = Date()
    }

    /// Re-applies sleep-integrity annotation and the user's corrections to the
    /// cached raw series — call after a `SleepOverrideStore` change so the
    /// readiness score and the Home banner update without a HealthKit round-trip.
    func reprocessSleep() {
        metrics = SleepOverrideStore.shared.process(rawMetrics)
        metricsRevision &+= 1
    }

    /// The latest measured night when it is still flagged after processing.
    /// Older unresolved nights never replace the sleep currently shown on Home.
    var partialSleepAlert: SleepIntegrityAlert? {
        guard let latest = metrics.max(by: { $0.date < $1.date }) else { return nil }
        return SleepIntegrityAlert(metric: latest)
    }

    #if DEBUG
    /// UI automation: blocks every HealthKit refresh WITHOUT stamping
    /// `lastRefreshed`, freezing the app in its pre-refresh state so the
    /// cold-launch dashboard paths (loader vs. same-day cache) can be
    /// asserted deterministically.
    func suppressRefreshForTesting() {
        demoSeeded = true
    }

    /// Injects a synthetic 20-night history plus a flagged partial-wear last
    /// night, so the Home sleep-integrity affordance can be seen and UI-tested
    /// without a paired watch or HealthKit data. Debug/automation only.
    func seedPartialSleepDemo(resetOverride: Bool = true) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var raw: [RecoveryEngine.DailyHealthMetric] = []
        for day in 1...20 {
            let date = cal.date(byAdding: .day, value: -day, to: today)!
            let start = cal.date(bySettingHour: 23, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: date)!)
            let end = cal.date(bySettingHour: 7, minute: 0, second: 0, of: date)
            raw.append(RecoveryEngine.DailyHealthMetric(
                date: date, hrvSDNN: 60, restingHR: 58,
                respiratoryRate: 14.5, oxygenSaturationPercent: 97, sleepTotalMinutes: 470,
                source: "demo", hrvSampleCount: 40, nocturnalHRV: 65, sleepingHR: 52,
                sleepingHRSampleCount: 60, sleepStart: start, sleepEnd: end))
        }
        // Last night: a 2 h fragment with sparse coverage — the forgotten watch.
        let lateStart = cal.date(bySettingHour: 5, minute: 0, second: 0, of: today)
        let wake = cal.date(bySettingHour: 7, minute: 0, second: 0, of: today)
        raw.append(RecoveryEngine.DailyHealthMetric(
            date: today, hrvSDNN: 60, restingHR: 58,
            respiratoryRate: 14.7, oxygenSaturationPercent: 97, sleepTotalMinutes: 120,
            source: "demo", hrvSampleCount: 2, nocturnalHRV: 80, sleepingHR: 48,
            sleepingHRSampleCount: 3, sleepStart: lateStart, sleepEnd: wake))
        // A normal demo launch starts clean. Persistence tests opt out on their
        // second launch so the saved choice is applied to the same raw night.
        if resetOverride {
            SleepOverrideStore.shared.clear(for: today)
        }
        rawMetrics = raw
        metrics = SleepOverrideStore.shared.process(raw)
        metricsRevision &+= 1
        activityMetrics = (0...28).map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today)!
            return DailyActivityMetric(
                date: day,
                steps: offset == 0 ? 8_500 : 6_000,
                exerciseMinutes: offset == 0 ? 55 : 30,
                activeEnergyKcal: offset == 0 ? 620 : 390
            )
        }
        lastRefreshed = Date()
        demoSeeded = true
    }
    #endif

    /// Bodyweight-mode sets get the user's latest body mass so their volume
    /// counts — the load math treats it like any other stored kilogram value.
    func fillBodyweight(_ set: SetModel) {
        guard set.weightMode != .external, set.bodyweightKg == nil, let bw = latestBodyweight else { return }
        set.bodyweightKg = bw
        set.recomputeDerivedMetrics()
    }
}
