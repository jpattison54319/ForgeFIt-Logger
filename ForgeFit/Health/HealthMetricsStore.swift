import ForgeCore
import ForgeData
import Foundation
import Observation

/// App-wide cache of the daily HealthKit recovery series. Every readiness
/// computation reads from here, so HRV / resting HR / sleep baselines feed the
/// score the moment Health is connected — refreshed on launch, on
/// foreground, and after connecting Apple Health.
@MainActor
@Observable
final class HealthMetricsStore {
    static let shared = HealthMetricsStore()

    /// 60-day daily series for RecoveryEngine (HRV, resting HR, sleep).
    private(set) var metrics: [RecoveryEngine.DailyHealthMetric] = []
    /// Supplemental full-day signals (respiratory, SpO₂, VO₂max, HR recovery,
    /// steps, energy) surfaced on the recovery detail screen.
    private(set) var extraSignals: [RecoveryEngine.Signal] = []
    /// Body-mass history in kilograms.
    private(set) var bodyweightSeries: [(date: Date, value: Double)] = []
    var latestBodyweight: Double? { bodyweightSeries.last?.value }
    /// Garmin sleep is flowing into Apple Health but HRV isn't (Garmin
    /// Connect doesn't sync it) — the recovery screen explains the gap.
    private(set) var hrvGapDetected = false
    private(set) var lastRefreshed: Date?

    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Safe to call often; coalesces and skips when refreshed very recently.
    func refresh(force: Bool = false) {
        if !force, let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < 300 { return }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
    }

    /// Awaitable variant for pull-to-refresh: always re-queries HealthKit so
    /// today's new data (sleep synced late, a morning HRV reading, a weigh-in)
    /// lands in the readiness score immediately.
    func refreshNow() async {
        await performRefresh()
    }

    private func performRefresh() async {
        let daily = await HealthService.shared.dailyMetrics()
        let extras = await HealthService.shared.todaySignals()
        let bodyweight = await HealthService.shared.bodyMassSeries()
        metrics = daily
        extraSignals = extras
        bodyweightSeries = bodyweight
        hrvGapDetected = await HealthService.shared.detectGarminHRVGap()
        lastRefreshed = Date()
    }

    /// Bodyweight-mode sets get the user's latest body mass so their volume
    /// counts — the load math treats it like any other stored kilogram value.
    func fillBodyweight(_ set: SetModel) {
        guard set.weightMode != .external, set.bodyweightKg == nil, let bw = latestBodyweight else { return }
        set.bodyweightKg = bw
        set.recomputeDerivedMetrics()
    }
}
