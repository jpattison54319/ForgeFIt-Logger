import Foundation

/// Keeps signals that already have a dedicated Health row or chart out of the
/// generic "Other readings" section. Names live at the presentation boundary,
/// so this centralizes the de-duplication contract and makes it testable.
nonisolated enum HealthDetailSignalFilter {
    private static let dedicatedSignalNames: Set<String> = [
        "HRV", "Resting HR", "Sleeping HR", "Heart rate", "Sleep",
        "Respiratory", "Blood O₂", "Steps", "Active energy",
    ]

    static func supplemental(
        from signals: [RecoveryEngine.Signal]
    ) -> [RecoveryEngine.Signal] {
        signals.filter { signal in
            signal.connected && !dedicatedSignalNames.contains(signal.name)
        }
    }
}

/// A raw health reading interpreted only against this user's own recent
/// distribution. It intentionally does not invent a combined "health score."
nonisolated struct PersonalRangeReading: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case typical
        case belowRange
        case aboveRange
        case building

        var isOutsideRange: Bool {
            self == .belowRange || self == .aboveRange
        }
    }

    var id: String { kind.id }
    let kind: VitalMetricKind
    let name: String
    let systemImage: String
    let value: Double
    let unit: String
    let mean: Double?
    let lowerBound: Double?
    let upperBound: Double?
    let status: Status
}

/// A single measurement channel selected consistently for both today's status
/// and the trend chart. Overnight and all-day readings have different sampling
/// contexts, so they must never share a baseline.
nonisolated struct HealthMetricChannelSeries {
    let name: String
    let current: Double
    let values: [(date: Date, value: Double)]
    let baselineValues: [Double]
    let baselineDates: [Date]

    static func hrv(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthMetricChannelSeries? {
        selectChannel(
            metrics: metrics,
            calendar: calendar,
            candidates: [
                ("Overnight SDNN", { metric in
                    guard metric.sleepIsTrustworthy else { return nil }
                    return metric.nocturnalHRV
                }, { $0.hrvSourceBundleID ?? $0.source }),
                ("Resting RMSSD", { $0.hrvRMSSD }, { $0.hrvSourceBundleID ?? $0.source }),
                ("HealthKit SDNN", { $0.hrvSDNN }, { $0.hrvSourceBundleID ?? $0.source })
            ]
        )
    }

    static func heartRate(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthMetricChannelSeries? {
        selectChannel(
            metrics: metrics,
            calendar: calendar,
            candidates: [
                ("Sleeping HR", { metric in
                    guard metric.sleepIsTrustworthy else { return nil }
                    return metric.sleepingHR.map(Double.init)
                }, { $0.sleepingHRSourceBundleID ?? $0.source }),
                ("Resting HR", { $0.restingHR.map(Double.init) }, { $0.restingHRSourceBundleID ?? $0.source })
            ]
        )
    }

    static func respiratoryRate(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthMetricChannelSeries? {
        dailyChannel(
            metrics: metrics,
            calendar: calendar,
            name: "Respiratory rate",
            value: \RecoveryEngine.DailyHealthMetric.respiratoryRate,
            source: { $0.respiratoryRateSourceBundleID ?? $0.source }
        )
    }

    static func oxygenSaturation(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthMetricChannelSeries? {
        dailyChannel(
            metrics: metrics,
            calendar: calendar,
            name: "Blood oxygen",
            value: \RecoveryEngine.DailyHealthMetric.oxygenSaturationPercent,
            source: { $0.oxygenSaturationSourceBundleID ?? $0.source }
        )
    }

    private static func dailyChannel(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar,
        name: String,
        value: KeyPath<RecoveryEngine.DailyHealthMetric, Double?>,
        source: (RecoveryEngine.DailyHealthMetric) -> String?
    ) -> HealthMetricChannelSeries? {
        let ordered = metrics.sorted { $0.date < $1.date }
        guard let latest = ordered.last,
              let current = latest[keyPath: value] else { return nil }
        let latestDay = calendar.startOfDay(for: latest.date)
        let currentSource = source(latest)
        let history = ordered
            .filter { calendar.startOfDay(for: $0.date) < latestDay && source($0) == currentSource }
            .suffix(60)
        let baselinePairs = history.compactMap { metric in
            metric[keyPath: value].map { (metric.date, $0) }
        }
        let values = ordered.suffix(60).compactMap { metric in
            metric[keyPath: value].map { (metric.date, $0) }
        }
        return HealthMetricChannelSeries(
            name: name,
            current: current,
            values: values,
            baselineValues: baselinePairs.map(\.1),
            baselineDates: baselinePairs.map(\.0)
        )
    }

    private typealias ChannelCandidate = (
        name: String,
        value: (RecoveryEngine.DailyHealthMetric) -> Double?,
        source: (RecoveryEngine.DailyHealthMetric) -> String?
    )

    private static func selectChannel(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar,
        candidates: [ChannelCandidate]
    ) -> HealthMetricChannelSeries? {
        let ordered = metrics.sorted { $0.date < $1.date }
        guard let latest = ordered.last else { return nil }
        let latestDay = calendar.startOfDay(for: latest.date)
        let history = ordered.filter {
            calendar.startOfDay(for: $0.date) < latestDay
        }.suffix(60)
        let locked = candidates.first { candidate in
            let currentSource = candidate.source(latest)
            let dates = history.filter { candidate.source($0) == currentSource }.compactMap { metric in
                candidate.value(metric).map { _ in metric.date }
            }
            return dates.count >= 28 && spanDays(dates, calendar: calendar) >= 42
        }
        let selected = locked ?? candidates.first { $0.value(latest) != nil }
        guard let selected, let current = selected.value(latest) else { return nil }
        let currentSource = selected.source(latest)
        let baselinePairs = history.filter { selected.source($0) == currentSource }.compactMap { metric in
            selected.value(metric).map { (metric.date, $0) }
        }
        return make(
            name: selected.name,
            current: current,
            metrics: ordered,
            baselinePairs: baselinePairs,
            value: selected.value
        )
    }

    private static func make(
        name: String,
        current: Double,
        metrics: [RecoveryEngine.DailyHealthMetric],
        baselinePairs: [(Date, Double)],
        value: (RecoveryEngine.DailyHealthMetric) -> Double?
    ) -> HealthMetricChannelSeries {
        let values = metrics.suffix(60).compactMap { metric in
            value(metric).map { (metric.date, $0) }
        }
        return HealthMetricChannelSeries(
            name: name,
            current: current,
            values: values,
            baselineValues: baselinePairs.map(\.1),
            baselineDates: baselinePairs.map(\.0)
        )
    }

    private static func spanDays(_ dates: [Date], calendar: Calendar) -> Int {
        guard let first = dates.min(), let last = dates.max() else { return 0 }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: first),
            to: calendar.startOfDay(for: last)
        ).day ?? 0
    }
}

/// Home's Vitals summary. Each reading is compared only with the same
/// channel in the user's own recent history; isolated readings remain
/// informational until at least 28 comparable readings spanning 42 days
/// establish a usual observed band.
nonisolated struct HealthRangeAssessment: Equatable, Sendable {
    let readings: [PersonalRangeReading]

    var evaluatedCount: Int {
        readings.count { $0.status != .building }
    }

    var outsideRangeCount: Int {
        readings.count { $0.status.isOutsideRange }
    }

    var favorableCount: Int {
        readings.count { $0.interpretation == .favorable }
    }

    var adverseCount: Int {
        readings.count { $0.interpretation == .adverse }
    }

    var headline: String {
        if readings.isEmpty { return "No readings" }
        if evaluatedCount == 0 { return "Building" }
        if adverseCount > 0 {
            return "Outside usual bands"
        }
        if favorableCount > 0 {
            return "\(favorableCount) favorable shift\(favorableCount == 1 ? "" : "s")"
        }
        return "Within usual bands"
    }

    var caption: String {
        if readings.isEmpty { return "Connect Apple Health" }
        if evaluatedCount == 0 { return "Usual bands need 28 readings over 42 days" }
        return "\(evaluatedCount) vital reading\(evaluatedCount == 1 ? "" : "s") checked"
    }

    static func make(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthRangeAssessment {
        var readings: [PersonalRangeReading] = []
        let heartRateChannel = HealthMetricChannelSeries.heartRate(metrics: metrics, calendar: calendar)
        if let heartRateChannel {
            readings.append(reading(
                kind: .heartRate,
                name: heartRateChannel.name,
                value: heartRateChannel.current,
                unit: "bpm",
                baseline: heartRateChannel.baselineValues,
                baselineDates: heartRateChannel.baselineDates,
                calendar: calendar
            ))
        }
        let respiratoryChannel = HealthMetricChannelSeries.respiratoryRate(metrics: metrics, calendar: calendar)
        if let respiratoryChannel {
            readings.append(reading(
                kind: .respiratoryRate,
                name: respiratoryChannel.name,
                value: respiratoryChannel.current,
                unit: "br/min",
                baseline: respiratoryChannel.baselineValues,
                baselineDates: respiratoryChannel.baselineDates,
                calendar: calendar
            ))
        }
        let oxygenChannel = HealthMetricChannelSeries.oxygenSaturation(metrics: metrics, calendar: calendar)
        if let oxygenChannel {
            readings.append(reading(
                kind: .bloodOxygen,
                name: oxygenChannel.name,
                value: oxygenChannel.current,
                unit: "%",
                baseline: oxygenChannel.baselineValues,
                baselineDates: oxygenChannel.baselineDates,
                calendar: calendar
            ))
        }
        let hrvChannel = HealthMetricChannelSeries.hrv(metrics: metrics, calendar: calendar)
        if let hrvChannel {
            readings.append(reading(
                kind: .hrv,
                name: "HRV",
                value: hrvChannel.current,
                unit: "ms",
                baseline: hrvChannel.baselineValues,
                baselineDates: hrvChannel.baselineDates,
                calendar: calendar
            ))
        }
        return HealthRangeAssessment(readings: readings)
    }

    private static func reading(
        kind: VitalMetricKind,
        name: String,
        value: Double,
        unit: String,
        baseline: [Double],
        baselineDates: [Date],
        calendar: Calendar
    ) -> PersonalRangeReading {
        guard baseline.count >= 28,
              let first = baselineDates.min(), let last = baselineDates.max(),
              (calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: last)).day ?? 0) >= 42 else {
            return PersonalRangeReading(
                kind: kind,
                name: name,
                systemImage: kind.systemImage,
                value: value,
                unit: unit,
                mean: nil,
                lowerBound: nil,
                upperBound: nil,
                status: .building
            )
        }
        let mean = average(baseline)
        let lower = quantile(baseline, probability: 0.10) ?? mean
        let upper = quantile(baseline, probability: 0.90) ?? mean
        let displayedValue = kind.valueAtDisplayPrecision(value)
        let displayedLower = kind.valueAtDisplayPrecision(lower)
        let displayedUpper = kind.valueAtDisplayPrecision(upper)
        let status: PersonalRangeReading.Status = displayedValue < displayedLower
            ? .belowRange
            : displayedValue > displayedUpper ? .aboveRange : .typical
        return PersonalRangeReading(
            kind: kind,
            name: name,
            systemImage: kind.systemImage,
            value: value,
            unit: unit,
            mean: mean,
            lowerBound: lower,
            upperBound: upper,
            status: status
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func quantile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(1, max(0, probability)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}

struct MetricTrendSeries: Equatable {
    struct Point: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let value: Double
    }

    let points: [Point]
    let median: Double
    let lowerBound: Double
    let upperBound: Double

    var latest: Point? { points.last }

    static func make(
        values: [(date: Date, value: Double)],
        baselineValues: [Double]? = nil,
        baselineDates: [Date]? = nil,
        minimumBaselineCount: Int = 28,
        minimumSpanDays: Int = 42,
        calendar: Calendar = .current
    ) -> MetricTrendSeries? {
        let points = values
            .sorted { $0.date < $1.date }
            .map { Point(date: $0.date, value: $0.value) }
        let baseline = baselineValues ?? points.dropLast().map(\.value)
        let dates = baselineDates ?? Array(points.dropLast().map(\.date))
        guard points.count >= 2,
              baseline.count >= minimumBaselineCount,
              let first = dates.min(), let last = dates.max(),
              (calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: first),
                to: calendar.startOfDay(for: last)
              ).day ?? 0) >= minimumSpanDays,
              let median = quantile(baseline, probability: 0.5),
              let lower = quantile(baseline, probability: 0.10),
              let upper = quantile(baseline, probability: 0.90) else { return nil }
        return MetricTrendSeries(
            points: points,
            median: median,
            lowerBound: lower,
            upperBound: upper
        )
    }

    private static func quantile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(1, max(0, probability)) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}

nonisolated enum SleepMetricPresentation {
    static func duration(_ minutes: Int) -> String {
        "\(minutes / 60)h \(minutes % 60)m"
    }

    static func value(for metric: RecoveryEngine.DailyHealthMetric?) -> String {
        guard let metric else { return "No data" }
        if metric.sleepOverrideStatus == .notTracked { return "Not tracked" }
        guard let minutes = metric.sleepTotalMinutes else { return "No data" }
        return duration(minutes)
    }

    /// Fraction of the editable sleep target met, for the tile's progress bar.
    /// Nil when the night is excluded, untracked, or the target is unknown.
    static func progress(for metric: RecoveryEngine.DailyHealthMetric?) -> Double? {
        guard let metric, metric.sleepOverrideStatus != .notTracked,
              let minutes = metric.sleepTotalMinutes, metric.sleepNeedMinutes > 0 else { return nil }
        return min(1, max(0, Double(minutes) / Double(metric.sleepNeedMinutes)))
    }

    static func caption(for metric: RecoveryEngine.DailyHealthMetric?) -> String {
        guard let metric else { return "Connect Apple Health" }
        if let status = metric.sleepOverrideStatus {
            return status.detailPrefix
        }
        if metric.sleepLikelyPartial { return "Tracked night looks incomplete" }
        guard let minutes = metric.sleepTotalMinutes else { return "No sleep recorded" }
        let difference = minutes - metric.sleepNeedMinutes
        if difference >= 0 { return "Sleep target met" }
        return "\(duration(abs(difference))) short of target"
    }
}
