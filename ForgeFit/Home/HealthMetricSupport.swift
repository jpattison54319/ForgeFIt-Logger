import Foundation

/// A raw health reading interpreted only against this user's own recent
/// distribution. It intentionally does not invent a combined "health score."
struct PersonalRangeReading: Identifiable, Equatable {
    enum Status: Equatable {
        case typical
        case belowRange
        case aboveRange
        case building

        var isOutsideRange: Bool {
            self == .belowRange || self == .aboveRange
        }
    }

    let id: String
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
struct HealthMetricChannelSeries {
    let name: String
    let current: Double
    let values: [(date: Date, value: Double)]
    let baselineValues: [Double]

    static func hrv(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthMetricChannelSeries? {
        let selection = selectChannel(
            metrics: metrics,
            calendar: calendar,
            preferredName: "HRV",
            preferredValue: { metric in
                guard metric.sleepIsTrustworthy else { return nil }
                return metric.nocturnalHRV
            },
            fallbackName: "HRV",
            fallbackValue: { $0.hrvRMSSD ?? $0.hrvSDNN }
        )
        return selection
    }

    static func heartRate(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthMetricChannelSeries? {
        selectChannel(
            metrics: metrics,
            calendar: calendar,
            preferredName: "Sleeping HR",
            preferredValue: { metric in
                guard metric.sleepIsTrustworthy else { return nil }
                return metric.sleepingHR.map(Double.init)
            },
            fallbackName: "Resting HR",
            fallbackValue: { $0.restingHR.map(Double.init) }
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
            value: \RecoveryEngine.DailyHealthMetric.respiratoryRate
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
            value: \RecoveryEngine.DailyHealthMetric.oxygenSaturationPercent
        )
    }

    private static func dailyChannel(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar,
        name: String,
        value: KeyPath<RecoveryEngine.DailyHealthMetric, Double?>
    ) -> HealthMetricChannelSeries? {
        let ordered = metrics.sorted { $0.date < $1.date }
        guard let latest = ordered.last,
              let current = latest[keyPath: value] else { return nil }
        let latestDay = calendar.startOfDay(for: latest.date)
        let history = ordered
            .filter { calendar.startOfDay(for: $0.date) < latestDay }
            .suffix(45)
        let baseline = history.compactMap { $0[keyPath: value] }
        let values = ordered.suffix(45).compactMap { metric in
            metric[keyPath: value].map { (metric.date, $0) }
        }
        return HealthMetricChannelSeries(
            name: name,
            current: current,
            values: values,
            baselineValues: baseline
        )
    }

    private static func selectChannel(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar,
        preferredName: String,
        preferredValue: (RecoveryEngine.DailyHealthMetric) -> Double?,
        fallbackName: String,
        fallbackValue: (RecoveryEngine.DailyHealthMetric) -> Double?
    ) -> HealthMetricChannelSeries? {
        let ordered = metrics.sorted { $0.date < $1.date }
        guard let latest = ordered.last else { return nil }
        let latestDay = calendar.startOfDay(for: latest.date)
        let history = ordered.filter {
            calendar.startOfDay(for: $0.date) < latestDay && !$0.sleepUserCorrected
        }.suffix(45)
        let preferredBaseline = history.compactMap(preferredValue)

        if let current = preferredValue(latest), preferredBaseline.count >= 7 {
            return make(
                name: preferredName,
                current: current,
                metrics: ordered,
                baselineValues: preferredBaseline,
                value: preferredValue
            )
        }

        let fallbackBaseline = history.compactMap(fallbackValue)
        if let current = fallbackValue(latest) {
            return make(
                name: fallbackName,
                current: current,
                metrics: ordered,
                baselineValues: fallbackBaseline,
                value: fallbackValue
            )
        }

        guard let current = preferredValue(latest) else { return nil }
        return make(
            name: preferredName,
            current: current,
            metrics: ordered,
            baselineValues: preferredBaseline,
            value: preferredValue
        )
    }

    private static func make(
        name: String,
        current: Double,
        metrics: [RecoveryEngine.DailyHealthMetric],
        baselineValues: [Double],
        value: (RecoveryEngine.DailyHealthMetric) -> Double?
    ) -> HealthMetricChannelSeries {
        let values = metrics.suffix(45).compactMap { metric in
            value(metric).map { (metric.date, $0) }
        }
        return HealthMetricChannelSeries(
            name: name,
            current: current,
            values: values,
            baselineValues: baselineValues
        )
    }
}

/// Home's Health tile summary. Each reading is compared only with the same
/// channel in the user's own recent history; isolated readings remain
/// informational until at least seven prior samples establish a range.
struct HealthRangeAssessment: Equatable {
    let readings: [PersonalRangeReading]

    var evaluatedCount: Int {
        readings.count { $0.status != .building }
    }

    var outsideRangeCount: Int {
        readings.count { $0.status.isOutsideRange }
    }

    var headline: String {
        if readings.isEmpty { return "No readings" }
        if evaluatedCount == 0 { return "Building" }
        if outsideRangeCount == 0 { return "All in range" }
        return "\(outsideRangeCount) outside range"
    }

    var caption: String {
        if readings.isEmpty { return "Connect Apple Health" }
        if evaluatedCount == 0 { return "Personal ranges need 7 nights" }
        return "\(evaluatedCount) health signal\(evaluatedCount == 1 ? "" : "s") checked"
    }

    static func make(
        metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthRangeAssessment {
        var readings: [PersonalRangeReading] = []
        let hrvChannel = HealthMetricChannelSeries.hrv(metrics: metrics, calendar: calendar)
        if let hrvChannel {
            readings.append(reading(
                id: "hrv",
                name: "HRV",
                systemImage: "waveform.path.ecg",
                value: hrvChannel.current,
                unit: "ms",
                baseline: hrvChannel.baselineValues,
                minimumBand: max(3, average(hrvChannel.baselineValues) * 0.05)
            ))
        }

        let heartRateChannel = HealthMetricChannelSeries.heartRate(metrics: metrics, calendar: calendar)
        if let heartRateChannel {
            readings.append(reading(
                id: "resting-heart-rate",
                name: heartRateChannel.name,
                systemImage: "heart.fill",
                value: heartRateChannel.current,
                unit: "bpm",
                baseline: heartRateChannel.baselineValues,
                minimumBand: max(5, average(heartRateChannel.baselineValues) * 0.08)
            ))
        }
        let respiratoryChannel = HealthMetricChannelSeries.respiratoryRate(metrics: metrics, calendar: calendar)
        if let respiratoryChannel {
            readings.append(reading(
                id: "respiratory-rate",
                name: respiratoryChannel.name,
                systemImage: "lungs.fill",
                value: respiratoryChannel.current,
                unit: "br/min",
                baseline: respiratoryChannel.baselineValues,
                minimumBand: max(1, average(respiratoryChannel.baselineValues) * 0.05)
            ))
        }
        let oxygenChannel = HealthMetricChannelSeries.oxygenSaturation(metrics: metrics, calendar: calendar)
        if let oxygenChannel {
            readings.append(reading(
                id: "blood-oxygen",
                name: oxygenChannel.name,
                systemImage: "drop.degreesign.fill",
                value: oxygenChannel.current,
                unit: "%",
                baseline: oxygenChannel.baselineValues,
                minimumBand: max(1, average(oxygenChannel.baselineValues) * 0.01)
            ))
        }
        return HealthRangeAssessment(readings: readings)
    }

    private static func reading(
        id: String,
        name: String,
        systemImage: String,
        value: Double,
        unit: String,
        baseline: [Double],
        minimumBand: Double
    ) -> PersonalRangeReading {
        guard baseline.count >= 7 else {
            return PersonalRangeReading(
                id: id,
                name: name,
                systemImage: systemImage,
                value: value,
                unit: unit,
                mean: nil,
                lowerBound: nil,
                upperBound: nil,
                status: .building
            )
        }
        let mean = average(baseline)
        let variance = baseline.reduce(0) { $0 + pow($1 - mean, 2) } / Double(baseline.count)
        let halfBand = max(minimumBand, variance.squareRoot())
        let lower = mean - halfBand
        let upper = mean + halfBand
        let status: PersonalRangeReading.Status = value < lower
            ? .belowRange
            : value > upper ? .aboveRange : .typical
        return PersonalRangeReading(
            id: id,
            name: name,
            systemImage: systemImage,
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
}

struct MetricTrendSeries: Equatable {
    struct Point: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let value: Double
    }

    let points: [Point]
    let mean: Double
    let standardDeviation: Double

    var latest: Point? { points.last }

    static func make(
        values: [(date: Date, value: Double)],
        baselineValues: [Double]? = nil,
        minimumBaselineCount: Int = 7
    ) -> MetricTrendSeries? {
        let points = values
            .sorted { $0.date < $1.date }
            .map { Point(date: $0.date, value: $0.value) }
        let baseline = baselineValues ?? points.dropLast().map(\.value)
        guard points.count >= 2, baseline.count >= minimumBaselineCount else { return nil }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        let variance = baseline.reduce(0) { $0 + pow($1 - mean, 2) } / Double(baseline.count)
        return MetricTrendSeries(points: points, mean: mean, standardDeviation: variance.squareRoot())
    }
}

enum SleepMetricPresentation {
    static func duration(_ minutes: Int) -> String {
        "\(minutes / 60)h \(minutes % 60)m"
    }

    static func value(for metric: RecoveryEngine.DailyHealthMetric?) -> String {
        guard let metric else { return "No data" }
        if metric.sleepOverrideStatus == .notTracked { return "Not tracked" }
        guard let minutes = metric.sleepTotalMinutes else { return "No data" }
        return duration(minutes)
    }

    static func caption(for metric: RecoveryEngine.DailyHealthMetric?) -> String {
        guard let metric else { return "Connect Apple Health" }
        if let status = metric.sleepOverrideStatus {
            return status.detailPrefix
        }
        if metric.sleepLikelyPartial { return "Tracked night looks incomplete" }
        guard let minutes = metric.sleepTotalMinutes else { return "No sleep recorded" }
        let difference = minutes - metric.sleepNeedMinutes
        if difference >= 0 { return "Sleep need met" }
        return "\(duration(abs(difference))) short of need"
    }
}
