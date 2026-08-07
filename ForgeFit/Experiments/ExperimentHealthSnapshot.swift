import ForgeCore
import Foundation

/// A transient, on-device projection of HealthKit data for the exact two
/// windows being compared. Nothing here is persisted: results and exports
/// re-query HealthKit so an eight- or twelve-week experiment is not limited
/// by the shorter rolling cache used by Home.
struct ExperimentHealthSnapshot: Sendable, Equatable {
    struct Day: Sendable, Equatable {
        /// Noon in the window's stored calendar. Using a midpoint keeps the
        /// observation inside the complete day across DST changes.
        var timestamp: Date
        var hrvMilliseconds: Double? = nil
        var restingHeartRate: Int? = nil
        var respiratoryRate: Double? = nil
        var oxygenSaturationPercent: Double? = nil
        var sleepTotalMinutes: Int? = nil
        var sleepDeepMinutes: Int? = nil
        var sleepREMMinutes: Int? = nil
        var bodyWeightKilograms: Double? = nil
        var steps: Double? = nil
        var exerciseMinutes: Double? = nil
        var activeEnergyKilocalories: Double? = nil
        var provenance: InsightProvenance = .measured

        var hasAnyValue: Bool {
            hrvMilliseconds != nil
                || restingHeartRate != nil
                || respiratoryRate != nil
                || oxygenSaturationPercent != nil
                || sleepTotalMinutes != nil
                || sleepDeepMinutes != nil
                || sleepREMMinutes != nil
                || bodyWeightKilograms != nil
                || steps != nil
                || exerciseMinutes != nil
                || activeEnergyKilocalories != nil
        }
    }

    var days: [Day]

    nonisolated static let empty = ExperimentHealthSnapshot(days: [])
}

@MainActor
enum ExperimentHealthLoader {
    static func load(
        request: ExperimentComparisonRequest
    ) async throws -> ExperimentHealthSnapshot {
        let reference = try ExperimentComparisonEngine.resolvedReferenceWindow(for: request)
        async let currentDays = load(window: request.currentWindow)
        async let referenceDays = load(window: reference)
        let (current, referenceRows) = await (currentDays, referenceDays)
        return ExperimentHealthSnapshot(
            days: (current + referenceRows)
                .sorted { $0.timestamp < $1.timestamp }
        )
    }

    /// Converts already-fetched daily inputs into complete-day rows. Kept
    /// separate from HealthKit access so boundary and DST behavior is directly
    /// testable.
    static func makeDays(
        window: ExperimentWindow,
        recovery: [RecoveryEngine.DailyHealthMetric],
        activity: [DailyActivityMetric],
        bodyweight: [(date: Date, value: Double)]
    ) -> [ExperimentHealthSnapshot.Day] {
        let calendar = window.calendar
        let recoveryByDay = Dictionary(
            recovery.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let activityByDay = Dictionary(
            activity.map { (calendar.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, last in last }
        )
        let bodyweightByDay = Dictionary(
            bodyweight.map { (calendar.startOfDay(for: $0.date), $0.value) },
            uniquingKeysWith: { _, last in last }
        )

        return Set(recoveryByDay.keys)
            .union(activityByDay.keys)
            .union(bodyweightByDay.keys)
            .compactMap { day -> ExperimentHealthSnapshot.Day? in
                guard let interval = calendar.dateInterval(of: .day, for: day),
                      interval.start >= window.start,
                      interval.end <= window.end else {
                    return nil
                }
                let recovery = recoveryByDay[day]
                let activity = activityByDay[day]
                let isEstimated = recovery?.dataQualityFlags.isEmpty == false
                    || recovery?.sleepUserCorrected == true
                let row = ExperimentHealthSnapshot.Day(
                    timestamp: interval.start.addingTimeInterval(interval.duration / 2),
                    hrvMilliseconds: recovery?.bestHRV,
                    restingHeartRate: recovery?.bestRestingHR,
                    respiratoryRate: recovery?.respiratoryRate,
                    oxygenSaturationPercent: recovery?.oxygenSaturationPercent,
                    sleepTotalMinutes: recovery?.sleepIsTrustworthy == true
                        ? recovery?.sleepTotalMinutes
                        : nil,
                    sleepDeepMinutes: recovery?.sleepIsTrustworthy == true
                        ? recovery?.sleepDeepMinutes
                        : nil,
                    sleepREMMinutes: recovery?.sleepIsTrustworthy == true
                        ? recovery?.sleepREMMinutes
                        : nil,
                    bodyWeightKilograms: bodyweightByDay[day],
                    steps: activity?.steps,
                    exerciseMinutes: activity?.exerciseMinutes,
                    activeEnergyKilocalories: activity?.activeEnergyKcal,
                    provenance: isEstimated ? .estimated : .measured
                )
                return row.hasAnyValue ? row : nil
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func load(
        window: ExperimentWindow
    ) async -> [ExperimentHealthSnapshot.Day] {
        let calendar = window.calendar
        let startDay = calendar.startOfDay(for: window.start)
        let endDay = calendar.startOfDay(for: window.end)
        let calendarDays = calendar.dateComponents(
            [.day],
            from: startDay,
            to: endDay
        ).day ?? 1
        // Padding handles boundary fragments and samples whose source assigns
        // sleep to the day on which it ended.
        let queryDays = max(2, calendarDays + 2)

        async let rawRecovery = HealthService.shared.dailyMetrics(
            days: queryDays,
            endingAt: window.end,
            calendar: calendar
        )
        async let activity = HealthService.shared.dailyActivityMetrics(
            days: queryDays,
            endingAt: window.end,
            calendar: calendar
        )
        async let bodyweight = HealthService.shared.bodyMassSeries(
            days: queryDays,
            endingAt: window.end,
            calendar: calendar
        )
        let (rawRecoveryResult, activityResult, bodyweightResult) = await (
            rawRecovery,
            activity,
            bodyweight
        )
        let recovery = SleepOverrideStore.shared.process(rawRecoveryResult)
        return makeDays(
            window: window,
            recovery: recovery,
            activity: activityResult,
            bodyweight: bodyweightResult
        )
    }
}
