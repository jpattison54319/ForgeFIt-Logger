import Foundation
import ForgeCore
import ForgeData

/// Versioned personalized product indices, not measured physiological
/// recovery percentages. The headline score uses source-consistent HRV or
/// heart-rate history plus sleep-target attainment, identifies adverse
/// deviations only, and withholds when coverage is inadequate. Muscle and
/// cardio numbers are explicitly recency-weighted exposure/freshness models.
/// Their launch constants are transparent product settings to be calibrated
/// prospectively against ForgeFit performance and subjective outcomes.
nonisolated extension RecoveryEngine {

    // MARK: - Types

    enum ScoreState: Equatable {
        case ready(Double)            // 0...1
        case building(String)         // what's still needed, user-facing

        var value: Double? {
            if case .ready(let value) = self { return value }
            return nil
        }
    }

    struct ScorePart: Identifiable {
        var id: String { name }
        let name: String
        let state: ScoreState
        /// Headline value, e.g. "44 ms" or "7.2 h".
        let valueText: String
        /// Context, e.g. "7-day avg vs 48 ms baseline" or what data is needed.
        let detailText: String
        /// Present only when the user resolved this specific value by hand.
        let sleepOverrideStatus: SleepOverrideStatus?

        init(
            name: String,
            state: ScoreState,
            valueText: String,
            detailText: String,
            sleepOverrideStatus: SleepOverrideStatus? = nil
        ) {
            self.name = name
            self.state = state
            self.valueText = valueText
            self.detailText = detailText
            self.sleepOverrideStatus = sleepOverrideStatus
        }
    }

    struct SystemicRecovery {
        var state: ScoreState
        var parts: [ScorePart]
        var guidance: String
        var coverage: Double = 0
        var methodID: String = RecoveryIndexV2.analyticsVersion
        var provenance: AnalyticsProvenance? = nil
    }

    /// The acute, today-only readiness score — nocturnal autonomic state plus
    /// last night's sleep, judged against the individual's own baseline. Built
    /// to move with the day (like Athlytic/WHOOP) so the headline number always
    /// agrees with the guidance shown beside it. Training load is deliberately
    /// excluded from every recovery score and shown separately as context.
    struct DailyReadiness {
        var state: ScoreState
        var parts: [ScorePart]
        /// Short, user-facing reasons that also drove the score, e.g.
        /// "HRV low today" — the copy and the number share one source of truth.
        var flags: [String]
        var guidance: String
        var coverage: Double = 0
        var methodID: String = RecoveryIndexV2.analyticsVersion
        var provenance: AnalyticsProvenance? = nil
    }

    struct MuscleRecoveryScore: Identifiable {
        static let analyticsVersion = "muscle_exposure_v3"

        var id: String { muscle }
        let muscle: String
        let state: ScoreState         // building = never logged for this muscle
        let lastTrainedDaysAgo: Int?
        /// Retained for decoding/UI migration only. V3 never presents this as
        /// time until physiological recovery.
        let readyInHours: Int?
        let isProvisional: Bool
        /// Current recency-weighted set-equivalent exposure. Exposed so the
        /// UI can explain why two muscle rows differ without reverse-
        /// engineering the score.
        let recentExposure: Double?
        /// The row's personal typical session dose. Region and child rows use
        /// separate references so one low-volume muscle cannot distort another.
        let referenceDose: Double?
        let methodID: String

        init(
            muscle: String,
            state: ScoreState,
            lastTrainedDaysAgo: Int?,
            readyInHours: Int?,
            isProvisional: Bool = false,
            recentExposure: Double? = nil,
            referenceDose: Double? = nil,
            methodID: String = Self.analyticsVersion
        ) {
            self.muscle = muscle
            self.state = state
            self.lastTrainedDaysAgo = lastTrainedDaysAgo
            self.readyInHours = readyInHours
            self.isProvisional = isProvisional
            self.recentExposure = recentExposure
            self.referenceDose = referenceDose
            self.methodID = methodID
        }

        var statusLabel: String {
            guard let value = state.value else { return "No data" }
            switch value {
            case 0.75...: return "Low load"
            case 0.4..<0.75: return "Moderate load"
            default: return "High load"
            }
        }
    }

    enum CardioEvidence: String, Hashable {
        case measuredHeartRate
        case perceivedEffort
        case mixedHistory

        var coachDescription: String {
            switch self {
            case .measuredHeartRate: "measured heart-rate zones"
            case .perceivedEffort: "cardio or conditioning session effort"
            case .mixedHistory: "measured heart-rate zones and session effort"
            }
        }
    }

    struct CardioRecovery {
        static let analyticsVersion = "cardio_exposure_v3"

        var state: ScoreState
        var lastSessionText: String?
        var readyInHours: Int?
        var isProvisional: Bool = false
        var evidence: CardioEvidence? = nil
        var methodID: String = Self.analyticsVersion

        init(
            state: ScoreState,
            lastSessionText: String?,
            readyInHours: Int?,
            isProvisional: Bool = false,
            evidence: CardioEvidence? = nil,
            methodID: String = Self.analyticsVersion
        ) {
            self.state = state
            self.lastSessionText = lastSessionText
            self.readyInHours = readyInHours
            self.isProvisional = isProvisional
            self.evidence = evidence
            self.methodID = methodID
        }
    }

    struct RecoverySnapshot {
        var daily: DailyReadiness
        var systemic: SystemicRecovery
        var muscles: [MuscleRecoveryScore]
        var cardio: CardioRecovery
    }

    func recoverySnapshot() -> RecoverySnapshot {
        RecoverySnapshot(
            daily: dailyReadiness(),
            systemic: systemicRecovery(),
            muscles: muscleRecoveryScores(),
            cardio: cardioRecovery()
        )
    }

    // MARK: - Systemic

    private func systemicRecovery() -> SystemicRecovery {
        let recent = recentHealthMetrics(days: 7)
        let target = personalizedSleepNeedMinutes()
        let latest = latestHealthMetric()
        let hrvKind = latest.flatMap { selectedHRVChannel(for: $0, excludingRecentDays: 7) }
        let hrKind = latest.flatMap { selectedHRChannel(for: $0, excludingRecentDays: 7) }

        let hrvAssessments = recent.compactMap {
            hrvAssessment(for: $0, excludingRecentDays: 7, forcedChannel: hrvKind)
        }
        let hrAssessments = recent.compactMap {
            heartRateAssessment(for: $0, excludingRecentDays: 7, forcedChannel: hrKind)
        }
        let sleepAssessments = recent.compactMap { sleepAssessment(for: $0, targetMinutes: target) }

        let hrv = trendPart(
            name: "HRV trend",
            assessments: hrvAssessments,
            minimumDays: 4,
            valueText: hrvAssessments.last.map { "\(Int($0.observed.rounded())) ms" } ?? "—"
        )
        let hr = trendPart(
            name: "Heart-rate trend",
            assessments: hrAssessments,
            minimumDays: 5,
            valueText: hrAssessments.last.map { "\(Int($0.observed.rounded())) bpm" } ?? "—"
        )
        let observedShortfall = recent.reduce(0) { total, metric in
            guard metric.sleepIsTrustworthy, let sleep = metric.sleepTotalMinutes else { return total }
            return total + max(0, target - sleep)
        }
        let sleep = trendPart(
            name: "Sleep trend",
            assessments: sleepAssessments,
            minimumDays: 5,
            valueText: sleepAssessments.isEmpty
                ? "—"
                : "\((sleepAssessments.map(\.observed).reduce(0, +) / Double(sleepAssessments.count) / 60).formatted(.number.precision(.fractionLength(1)))) h avg",
            detailOverride: "Observed shortfall: \(formatMinutes(observedShortfall)) across \(sleepAssessments.count) of 7 recorded nights"
        )
        let parts = [hrv.part, sleep.part, hr.part]
        let inputs = [hrv.input, sleep.input, hr.input].compactMap { $0 }

        guard let combined = RecoveryIndexV2.combine(inputs) else {
            return SystemicRecovery(
                state: .building("Needs comparable readings in at least two domains across the last seven days."),
                parts: parts,
                guidance: "The seven-day recovery trend appears once enough source-consistent HRV or heart-rate data and sleep are available.",
                coverage: inputs.reduce(0) { $0 + min(1, $1.quality) / 3 }
            )
        }
        let score = combined.score / 100
        return SystemicRecovery(
            state: .ready(score),
            parts: parts,
            guidance: systemicGuidance(score),
            coverage: combined.coverage,
            provenance: recoveryProvenance(
                analyticsID: "seven-day-recovery-trend",
                coverage: combined.coverage,
                baseline: baselineMetrics(days: 90)
            )
        )
    }

    private func systemicGuidance(_ score: Double) -> String {
        switch score {
        case 0.85...: "No major adverse recovery signals were detected across the available seven-day data."
        case 0.65..<0.85: "Most available recovery signals are close to your recent comparable pattern."
        case 0.5..<0.65: "The available seven-day signals are mixed."
        default: "Multiple available recovery signals are below your recent comparable pattern."
        }
    }

    // MARK: - Daily readiness (acute)

    /// Today's autonomic state vs the individual's baseline, plus last night's
    /// sleep. Reactive by design — one genuinely bad night should move it.
    private func dailyReadiness() -> DailyReadiness {
        guard let current = latestHealthMetric() else {
            return DailyReadiness(
                state: .building("No comparable recovery data is available yet."),
                parts: [],
                flags: [],
                guidance: "The recovery-signal index needs at least two domains, including HRV or heart rate."
            )
        }

        let hrv = hrvAssessment(for: current, excludingRecentDays: 0)
        let hr = heartRateAssessment(for: current, excludingRecentDays: 0)
        let sleep = sleepAssessment(for: current, targetMinutes: personalizedSleepNeedMinutes())
        let parts = [
            hrv?.part ?? unavailableHRVPart(for: current),
            sleep?.part ?? unavailableSleepPart(for: current),
            hr?.part ?? unavailableHeartRatePart(for: current)
        ]
        let inputs = [hrv?.input, hr?.input, sleep?.input].compactMap { $0 }
        let provisionalCoverage = inputs.reduce(0) { $0 + min(1, $1.quality) / 3 }

        // An unresolved partial overnight record means the relevant episode
        // may still be incomplete. Even mature daytime HRV/HR channels must
        // not turn that ambiguous recording window into a headline score.
        if current.sleepLikelyPartial && !current.sleepUserCorrected {
            return DailyReadiness(
                state: .building("Possible incomplete overnight recording — confirm or correct it before scoring."),
                parts: parts,
                flags: [],
                guidance: "Available signals remain visible, but an unresolved partial night cannot produce a headline recovery score.",
                coverage: provisionalCoverage
            )
        }

        guard let combined = RecoveryIndexV2.combine(inputs) else {
            let hasMatureChannel = hrv != nil || hr != nil
            return DailyReadiness(
                state: .building(hasMatureChannel
                    ? "Needs a second complete recovery domain before showing a score."
                    : "Baseline building — needs 21 comparable readings spanning at least 28 days."),
                parts: parts,
                flags: [],
                guidance: "Missing data lowers coverage; one signal can never create a headline recovery score.",
                coverage: provisionalCoverage
            )
        }

        var flags: [String] = []
        if hrv.map({ $0.adverseUnits >= 1 }) == true { flags.append("HRV low today") }
        if hr.map({ $0.adverseUnits >= 1 }) == true {
            flags.append(hr?.channelLabel == "Sleeping HR" ? "Sleeping HR elevated" : "Resting HR elevated")
        }
        if sleep.map({ $0.adverseUnits >= 1 }) == true { flags.append("Short sleep") }

        let score = combined.score / 100
        return DailyReadiness(
            state: .ready(score),
            parts: parts,
            flags: flags,
            guidance: dailyGuidance(score, flags: flags),
            coverage: combined.coverage,
            provenance: recoveryProvenance(
                analyticsID: "recovery-signal-index",
                coverage: combined.coverage,
                baseline: baselineMetrics(days: 60)
            )
        )
    }

    private func dailyGuidance(_ score: Double, flags: [String]) -> String {
        let base = switch score {
        case 0.85...: "No major adverse recovery signals were detected in the available data."
        case 0.65..<0.85: "Today’s available recovery signals are mostly typical for you."
        case 0.5..<0.65: "Today’s available recovery signals are mixed."
        default: "Today’s available recovery signals show marked adverse deviations."
        }
        guard !flags.isEmpty else { return base }
        let reasons = flags.compactMap { Self.acuteReasonClause($0) }
        guard !reasons.isEmpty else { return base }
        let joined = reasons.count == 1
            ? reasons[0]
            : reasons.dropLast().joined(separator: ", ") + " and " + reasons.last!
        let sentence = joined.prefix(1).uppercased() + joined.dropFirst()
        return "\(base) \(sentence)."
    }

    private struct DomainAssessment {
        let input: RecoveryComponentInput
        let part: ScorePart
        let adverseUnits: Double
        let observed: Double
        let channelLabel: String
    }

    private struct TrendAssessment {
        let input: RecoveryComponentInput?
        let part: ScorePart
    }

    private enum HRVChannel: CaseIterable {
        case nocturnalSDNN
        case restingRMSSD
        case opportunisticSDNN

        var label: String {
            switch self {
            case .nocturnalSDNN: "Overnight SDNN"
            case .restingRMSSD: "Resting RMSSD"
            case .opportunisticSDNN: "HealthKit SDNN"
            }
        }

        var repeatabilityFloor: Double {
            switch self {
            case .nocturnalSDNN: 0.12
            case .restingRMSSD: 0.08
            case .opportunisticSDNN: 0.12
            }
        }
    }

    private enum HeartRateChannel: CaseIterable {
        case sleeping
        case daytimeResting

        var label: String { self == .sleeping ? "Sleeping HR" : "Resting HR" }
    }

    private func selectedHRVChannel(
        for current: DailyHealthMetric,
        excludingRecentDays: Int
    ) -> HRVChannel? {
        let history = comparableHistory(for: current, excludingRecentDays: excludingRecentDays)
        if let locked = HRVChannel.allCases.first(where: { channel in
            let currentSource = hrvSource(current, channel: channel)
            let dated = history.filter { hrvSource($0, channel: channel) == currentSource }.compactMap { metric in
                hrvValue(metric, channel: channel).map { (metric.date, $0) }
            }
            return baselineIsMature(dated.map(\.0))
        }) {
            return locked
        }
        return HRVChannel.allCases.first { hrvValue(current, channel: $0) != nil }
    }

    private func selectedHRChannel(
        for current: DailyHealthMetric,
        excludingRecentDays: Int
    ) -> HeartRateChannel? {
        let history = comparableHistory(for: current, excludingRecentDays: excludingRecentDays)
        if let locked = HeartRateChannel.allCases.first(where: { channel in
            let currentSource = heartRateSource(current, channel: channel)
            let dates = history.filter { heartRateSource($0, channel: channel) == currentSource }.compactMap { metric in
                heartRateValue(metric, channel: channel).map { _ in metric.date }
            }
            return baselineIsMature(dates)
        }) {
            return locked
        }
        return HeartRateChannel.allCases.first { heartRateValue(current, channel: $0) != nil }
    }

    private func hrvAssessment(
        for current: DailyHealthMetric,
        excludingRecentDays: Int,
        forcedChannel: HRVChannel? = nil
    ) -> DomainAssessment? {
        guard let channel = forcedChannel ?? selectedHRVChannel(
            for: current,
            excludingRecentDays: excludingRecentDays
        ), let today = hrvValue(current, channel: channel), today > 0 else { return nil }

        let currentSource = hrvSource(current, channel: channel)
        let dated = comparableHistory(for: current, excludingRecentDays: excludingRecentDays)
            .filter { hrvSource($0, channel: channel) == currentSource }
            .compactMap { metric in hrvValue(metric, channel: channel).map { (metric.date, log($0)) } }
        guard baselineIsMature(dated.map(\.0)) else { return nil }
        let values = dated.map(\.1)
        guard let baseline = robustMedian(values) else { return nil }
        let scale = max(1.4826 * medianAbsoluteDeviation(values, around: baseline), channel.repeatabilityFloor)
        let adverse = max(0, (baseline - log(today)) / scale)
        let quality = RecoveryIndexV2.historyQuality(count: values.count, spanDays: historySpanDays(dated.map(\.0)))
            * hrvMeasurementQuality(current, channel: channel)
        let input = RecoveryComponentInput(domain: .hrv, adverseUnits: adverse, quality: quality)
        return DomainAssessment(
            input: input,
            part: ScorePart(
                name: "HRV (today)",
                state: .ready(input.score / 100),
                valueText: "\(Int(today.rounded())) ms",
                detailText: adverse > 0
                    ? "\(channel.label), below your comparable median of \(Int(exp(baseline).rounded())) ms"
                    : "\(channel.label), at or above your comparable median of \(Int(exp(baseline).rounded())) ms"
            ),
            adverseUnits: adverse,
            observed: today,
            channelLabel: channel.label
        )
    }

    private func heartRateAssessment(
        for current: DailyHealthMetric,
        excludingRecentDays: Int,
        forcedChannel: HeartRateChannel? = nil
    ) -> DomainAssessment? {
        guard let channel = forcedChannel ?? selectedHRChannel(
            for: current,
            excludingRecentDays: excludingRecentDays
        ), let today = heartRateValue(current, channel: channel) else { return nil }

        let currentSource = heartRateSource(current, channel: channel)
        let dated = comparableHistory(for: current, excludingRecentDays: excludingRecentDays)
            .filter { heartRateSource($0, channel: channel) == currentSource }
            .compactMap { metric in heartRateValue(metric, channel: channel).map { (metric.date, $0) } }
        guard baselineIsMature(dated.map(\.0)), let baseline = robustMedian(dated.map(\.1)) else { return nil }
        let scale = max(
            1.4826 * medianAbsoluteDeviation(dated.map(\.1), around: baseline),
            max(4, 0.05 * baseline)
        )
        let adverse = max(0, (today - baseline) / scale)
        let quality = RecoveryIndexV2.historyQuality(
            count: dated.count,
            spanDays: historySpanDays(dated.map(\.0))
        ) * heartRateMeasurementQuality(current, channel: channel)
        let input = RecoveryComponentInput(domain: .heartRate, adverseUnits: adverse, quality: quality)
        return DomainAssessment(
            input: input,
            part: ScorePart(
                name: channel.label,
                state: .ready(input.score / 100),
                valueText: "\(Int(today.rounded())) bpm",
                detailText: adverse > 0
                    ? "Above your comparable median of \(Int(baseline.rounded())) bpm"
                    : "At or below your comparable median of \(Int(baseline.rounded())) bpm"
            ),
            adverseUnits: adverse,
            observed: today,
            channelLabel: channel.label
        )
    }

    private func sleepAssessment(
        for current: DailyHealthMetric,
        targetMinutes: Int
    ) -> DomainAssessment? {
        guard current.sleepOverrideStatus != .notTracked,
              current.sleepIsTrustworthy,
              let sleep = current.sleepTotalMinutes,
              sleep >= 0 else { return nil }
        let quality = sleepMeasurementQuality(current)
        guard quality > 0 else { return nil }
        let adverse = max(0, Double(targetMinutes - sleep) / 90)
        let input = RecoveryComponentInput(domain: .sleep, adverseUnits: adverse, quality: quality)
        let targetText = "target \(formatMinutes(targetMinutes))"
        let correctionPrefix = current.sleepOverrideStatus.map { "\($0.detailPrefix) · " } ?? ""
        return DomainAssessment(
            input: input,
            part: ScorePart(
                name: "Sleep (last night)",
                state: .ready(input.score / 100),
                valueText: formatMinutes(sleep),
                detailText: correctionPrefix + (sleep < targetMinutes
                    ? "\(formatMinutes(targetMinutes - sleep)) below your editable \(targetText)"
                    : "Met your editable \(targetText)"),
                sleepOverrideStatus: current.sleepOverrideStatus
            ),
            adverseUnits: adverse,
            observed: Double(sleep),
            channelLabel: "Sleep duration"
        )
    }

    private func trendPart(
        name: String,
        assessments: [DomainAssessment],
        minimumDays: Int,
        valueText: String,
        detailOverride: String? = nil
    ) -> TrendAssessment {
        guard assessments.count >= minimumDays else {
            return TrendAssessment(
                input: nil,
                part: ScorePart(
                    name: name,
                    state: .building("Needs \(minimumDays - assessments.count) more comparable day\(minimumDays - assessments.count == 1 ? "" : "s")"),
                    valueText: valueText,
                    detailText: "\(assessments.count) of 7 valid days"
                )
            )
        }
        let meanScore = assessments.map { $0.input.score }.reduce(0, +) / Double(assessments.count)
        let adverse = max(0, (100 - meanScore) / 30)
        let meanQuality = assessments.map { $0.input.quality }.reduce(0, +) / Double(assessments.count)
        let quality = Double(assessments.count) / 7 * meanQuality
        guard let domain = assessments.first?.input.domain else {
            return TrendAssessment(input: nil, part: assessments[0].part)
        }
        let input = RecoveryComponentInput(domain: domain, adverseUnits: adverse, quality: quality)
        return TrendAssessment(
            input: input,
            part: ScorePart(
                name: name,
                state: .ready(input.score / 100),
                valueText: valueText,
                detailText: detailOverride ?? "Mean component score across \(assessments.count) of 7 valid days"
            )
        )
    }

    private func unavailableHRVPart(for current: DailyHealthMetric) -> ScorePart {
        ScorePart(
            name: "HRV (today)",
            state: .building(hrvValue(current, channel: selectedHRVChannel(for: current, excludingRecentDays: 0) ?? .nocturnalSDNN) == nil
                ? "Primary HRV channel unavailable — no source substitution"
                : "Baseline building — needs 21 readings over 28 days"),
            valueText: "—",
            detailText: "SDNN and RMSSD maintain separate baselines"
        )
    }

    private func unavailableHeartRatePart(for current: DailyHealthMetric) -> ScorePart {
        ScorePart(
            name: "Heart rate",
            state: .building("Comparable heart-rate channel unavailable or baseline building"),
            valueText: current.bestRestingHR.map { "\($0) bpm" } ?? "—",
            detailText: "Sleeping and daytime resting heart rate maintain separate baselines"
        )
    }

    private func unavailableSleepPart(for current: DailyHealthMetric) -> ScorePart {
        ScorePart(
            name: "Sleep (last night)",
            state: .building(current.sleepOverrideStatus == .notTracked
                ? "Excluded at your request"
                : current.sleepLikelyPartial ? "Possible incomplete recording" : "No complete sleep duration"),
            valueText: current.sleepTotalMinutes.map(formatMinutes) ?? "—",
            detailText: current.sleepOverrideStatus == .notTracked
                ? "Not tracked for this night at your request"
                : "Sleep must be complete before it can affect the score",
            sleepOverrideStatus: current.sleepOverrideStatus
        )
    }

    private func comparableHistory(
        for current: DailyHealthMetric,
        excludingRecentDays: Int
    ) -> [DailyHealthMetric] {
        baselineMetrics(days: 60).filter { metric in
            calendarDaysBetween(metric.date, and: now) > excludingRecentDays
        }
    }

    private func hrvValue(_ metric: DailyHealthMetric, channel: HRVChannel) -> Double? {
        switch channel {
        case .nocturnalSDNN:
            guard metric.sleepIsTrustworthy else { return nil }
            return metric.nocturnalHRV
        case .restingRMSSD: return metric.hrvRMSSD
        case .opportunisticSDNN: return metric.hrvSDNN
        }
    }

    private func heartRateValue(_ metric: DailyHealthMetric, channel: HeartRateChannel) -> Double? {
        switch channel {
        case .sleeping:
            guard metric.sleepIsTrustworthy else { return nil }
            return metric.sleepingHR.map(Double.init)
        case .daytimeResting: return metric.restingHR.map(Double.init)
        }
    }

    private func hrvSource(_ metric: DailyHealthMetric, channel: HRVChannel) -> String? {
        switch channel {
        case .nocturnalSDNN: metric.hrvSourceBundleID ?? metric.source
        case .restingRMSSD, .opportunisticSDNN: metric.hrvSourceBundleID ?? metric.source
        }
    }

    private func heartRateSource(_ metric: DailyHealthMetric, channel: HeartRateChannel) -> String? {
        switch channel {
        case .sleeping: metric.sleepingHRSourceBundleID ?? metric.source
        case .daytimeResting: metric.restingHRSourceBundleID ?? metric.source
        }
    }

    private func hrvMeasurementQuality(_ metric: DailyHealthMetric, channel: HRVChannel) -> Double {
        guard channel == .nocturnalSDNN, metric.source == "healthkit" else { return 1 }
        guard let bins = metric.nocturnalHRVOccupiedBinCount,
              let span = metric.nocturnalHRVSampleSpanMinutes else { return 0 }
        return min(1, Double(bins) / Double(NocturnalAggregator.minHRVBins))
            * min(1, Double(span) / Double(NocturnalAggregator.minimumSpanMinutes))
    }

    private func heartRateMeasurementQuality(_ metric: DailyHealthMetric, channel: HeartRateChannel) -> Double {
        guard channel == .sleeping, metric.source == "healthkit" else { return 1 }
        guard let bins = metric.sleepingHROccupiedBinCount,
              let span = metric.sleepingHRSampleSpanMinutes else { return 0 }
        return min(1, Double(bins) / Double(NocturnalAggregator.minSleepingHRBins))
            * min(1, Double(span) / Double(NocturnalAggregator.minimumSpanMinutes))
    }

    private func sleepMeasurementQuality(_ metric: DailyHealthMetric) -> Double {
        guard metric.source == "healthkit" else { return 1 }
        guard let end = metric.sleepEnd, end <= now, metric.sleepStart != nil else { return 0 }
        return metric.sleepLikelyPartial && !metric.sleepUserCorrected ? 0 : 1
    }

    private func baselineIsMature(_ dates: [Date]) -> Bool {
        dates.count >= 21 && historySpanDays(dates) >= 28
    }

    private func historySpanDays(_ dates: [Date]) -> Int {
        guard let first = dates.min(), let last = dates.max() else { return 0 }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: first),
            to: calendar.startOfDay(for: last)
        ).day ?? 0
    }

    private func robustMedian(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func medianAbsoluteDeviation(_ values: [Double], around median: Double) -> Double {
        robustMedian(values.map { abs($0 - median) }) ?? 0
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    private func recoveryProvenance(
        analyticsID: String,
        coverage: Double,
        baseline: [DailyHealthMetric]
    ) -> AnalyticsProvenance {
        AnalyticsProvenance(
            analyticsID: analyticsID,
            analyticsVersion: RecoveryIndexV2.analyticsVersion,
            formulaHash: RecoveryIndexV2.formulaHash,
            baselineStart: baseline.map(\.date).min(),
            baselineEnd: baseline.map(\.date).max(),
            baselineCount: baseline.count,
            coverage: coverage,
            measurementClass: .productHeuristic,
            generatedAt: now
        )
    }

    /// User-facing clause per acute flag, phrased to read naturally alone or
    /// joined with others. Shared by the daily score and its evidence rows.
    static func acuteReasonClause(_ flag: String) -> String? {
        switch flag {
        case "HRV low today": return "HRV dipped below your usual observed range this morning"
        case "Sleeping HR elevated": return "your sleeping heart rate was elevated overnight"
        case "Resting HR elevated": return "your resting heart rate is running above your usual"
        case "Short sleep": return "you came up short on sleep last night"
        default: return nil
        }
    }

    // These mirror the acute parts' internal decisions so the flags match the
    // exact thresholds that shaped each sub-score.
    private var acuteHRVBelowRange: Bool { acuteHRVAssessment()?.belowRange ?? false }
    private var lastNightSleepShort: Bool {
        guard let current = latestHealthMetric(), let sleep = current.sleepTotalMinutes,
              current.sleepIsTrustworthy else { return false }
        return Double(sleep) / Double(personalizedSleepNeedMinutes()) < 0.85
    }

    private struct AcuteHRV { let score: Double; let todayMs: Double; let baselineMs: Double; let belowRange: Bool }

    /// Last night's nocturnal HRV vs a 14–60 day baseline, in ln space (HRV is
    /// log-normal; ln-HRV is the standard for baseline/SWC math — Plews 2013).
    private func acuteHRVAssessment() -> AcuteHRV? {
        // Channel-pure via `acuteComparableHRV`: nocturnal readings against
        // nocturnal nights only. An awake spot sample taken just past
        // midnight must never stand in for a night that hasn't happened —
        // it scored "awake at 1am" as a crashed HRV.
        guard let current = latestHealthMetric(),
              let today = acuteComparableHRV(for: current), today > 0 else { return nil }
        let baseline = baselineMetrics(days: 60)
            .filter { calendarDaysBetween($0.date, and: now) >= 1 && !$0.sleepUserCorrected }
            .compactMap { acuteComparableHRV(for: $0) }.filter { $0 > 0 }.map { log($0) }
        guard baseline.count >= 14 else { return nil }
        let lnToday = log(today)
        let mean = average(baseline) ?? lnToday
        // Noise floor at 5% CV: day-to-day lnRMSSD variability is typically
        // 5–10% (Buchheit 2014) — a tighter floor over-reacts to normal nights.
        let sd = max(standardDeviation(baseline), 0.05)
        let z = (lnToday - mean) / sd
        // Steeper than the chronic trend (0.28 vs 0.20 per SD): the acute score
        // is meant to react to a single off morning.
        let score = min(1, max(0, 0.9 + 0.28 * min(0.4, max(-3.0, z))))
        let swc = 0.5 * sd                                // smallest worthwhile change (Plews 2013)
        let belowRange = (lnToday - mean) < -max(swc, 0.02)
        return AcuteHRV(score: score, todayMs: today, baselineMs: exp(mean), belowRange: belowRange)
    }

    private func acuteHRVPart() -> ScorePart {
        guard let assessment = acuteHRVAssessment() else {
            // A nocturnal user past midnight has a healthy baseline — the
            // night just isn't in yet. Say that, not "baseline building".
            if usesNocturnalHRV,
               let latest = latestHealthMetric(),
               acuteComparableHRV(for: latest) == nil {
                let partial = latest.sleepLikelyPartial && !latest.sleepUserCorrected
                return ScorePart(
                    name: "HRV (today)",
                    state: .building(partial
                        ? "Overnight HRV excluded because sleep looks incomplete"
                        : "Last night's HRV isn't in yet"),
                    valueText: "—",
                    detailText: partial
                        ? "Confirm or correct the sleep record on Home"
                        : "Updates when tonight's sleep syncs"
                )
            }
            let todayValue = latestHealthMetric().flatMap { acuteComparableHRV(for: $0) }
            return ScorePart(
                name: "HRV (today)",
                state: .building(todayValue != nil ? "Baseline building — needs ~2 weeks of nights" : "No HRV from last night"),
                valueText: todayValue.map { "\(Int($0.rounded())) ms" } ?? "—",
                detailText: todayValue != nil ? "Nocturnal HRV; baseline still forming" : "Wear a watch overnight to capture HRV"
            )
        }
        return ScorePart(
            name: "HRV (today)",
            state: .ready(assessment.score),
            valueText: "\(Int(assessment.todayMs.rounded())) ms",
            detailText: assessment.belowRange
                ? "Last night, below your usual observed range (baseline \(Int(assessment.baselineMs.rounded())) ms)"
                : "Last night, within your usual observed range (baseline \(Int(assessment.baselineMs.rounded())) ms)"
        )
    }

    private struct SleepingHR {
        let score: Double
        let today: Int
        let baseline: Double
        let elevated: Bool
        /// True when today's value is Apple's daytime resting-HR estimate,
        /// not a captured sleeping HR — labeled differently and judged
        /// against the daytime baseline.
        let isDaytimeFallback: Bool
    }

    /// Compares like with like. A true sleeping HR is judged against the
    /// sleeping-HR baseline; when tonight hasn't been captured yet (e.g.
    /// it's 1am, the user is still awake, and Apple has already published an
    /// early resting-HR estimate for the new calendar day), that daytime
    /// value is judged against the daytime resting-HR baseline instead.
    /// Mixing kinds was a real bug: awake HR always reads "elevated" against
    /// a sleeping baseline, so the card claimed an elevated *sleeping* HR
    /// for a user who hadn't slept yet.
    private func sleepingHRAssessment() -> SleepingHR? {
        guard let current = latestHealthMetric() else { return nil }
        let priorDays = baselineMetrics(days: 60)
            .filter { calendarDaysBetween($0.date, and: now) >= 1 && !$0.sleepUserCorrected }
        if current.sleepIsTrustworthy, let today = current.sleepingHR {
            let baseline = priorDays
                .filter(\.sleepIsTrustworthy)
                .compactMap { $0.sleepingHR.map(Double.init) }
            guard baseline.count >= 14 else { return nil }
            return assessRestingHR(today: today, baseline: baseline, isDaytimeFallback: false)
        }
        if let today = current.restingHR {
            let baseline = priorDays.compactMap { $0.restingHR.map(Double.init) }
            guard baseline.count >= 14 else { return nil }
            return assessRestingHR(today: today, baseline: baseline, isDaytimeFallback: true)
        }
        return nil
    }

    private func assessRestingHR(today: Int, baseline: [Double], isDaytimeFallback: Bool) -> SleepingHR {
        let mean = average(baseline) ?? Double(today)
        let sd = max(standardDeviation(baseline), max(2, mean * 0.03))
        let z = (Double(today) - mean) / sd             // elevated = worse
        let score = min(1, max(0, 0.9 - 0.25 * min(3.0, max(-0.5, z))))
        let elevated = Double(today) > mean + max(3, sd)
        return SleepingHR(score: score, today: today, baseline: mean, elevated: elevated, isDaytimeFallback: isDaytimeFallback)
    }

    private func sleepingHRPart() -> ScorePart {
        guard let assessment = sleepingHRAssessment() else {
            return ScorePart(name: "Sleeping HR", state: .building("No overnight heart rate yet"),
                             valueText: latestHealthMetric()?.bestRestingHR.map { "\($0) bpm" } ?? "—",
                             detailText: "Wear a watch to bed to capture sleeping heart rate")
        }
        let comparison = "\(Int(assessment.baseline.rounded())) bpm baseline"
        let suffix = assessment.isDaytimeFallback ? " (daytime — overnight sample unavailable)" : ""
        return ScorePart(
            name: assessment.isDaytimeFallback ? "Resting HR" : "Sleeping HR",
            state: .ready(assessment.score),
            valueText: "\(assessment.today) bpm",
            detailText: (assessment.elevated ? "Elevated vs \(comparison)" : "vs \(comparison)") + suffix
        )
    }

    private func lastNightSleepPart() -> ScorePart {
        guard let current = latestHealthMetric() else {
            return ScorePart(name: "Sleep (last night)", state: .building("No sleep data from last night"),
                             valueText: "—", detailText: "Wear a watch to bed or log sleep in Health")
        }
        if current.sleepOverrideStatus == .notTracked {
            return ScorePart(
                name: "Sleep (last night)",
                state: .building("Excluded at your request"),
                valueText: "—",
                detailText: "This night is not used in readiness or sleep debt",
                sleepOverrideStatus: .notTracked
            )
        }
        guard let sleep = current.sleepTotalMinutes else {
            return ScorePart(
                name: "Sleep (last night)",
                state: .building("No sleep duration is available"),
                valueText: "—",
                detailText: "Wear a watch to bed or log sleep in Health",
                sleepOverrideStatus: current.sleepOverrideStatus
            )
        }
        // A partial-wear fragment isn't scorable sleep — report it as an
        // untrustworthy gap, not a low score (matches the daily engine).
        guard current.sleepIsTrustworthy else {
            return ScorePart(name: "Sleep (last night)", state: .building("Only part of the night tracked"),
                             valueText: "~\((Double(sleep) / 60).formatted(.number.precision(.fractionLength(1)))) h",
                             detailText: "Confirm or correct it on Home")
        }
        let need = personalizedSleepNeedMinutes()
        let ratio = Double(sleep) / Double(need)
        let score = ratio >= 0.95 ? 1.0 : max(0.3, 1.0 - (0.95 - ratio) * 2.0)
        let hours = Double(sleep) / 60
        let needDetail = "Need \(String(format: "%.1f", Double(need) / 60)) h"
        let detail = current.sleepOverrideStatus.map { "\($0.detailPrefix) · \(needDetail.lowercased())" }
            ?? needDetail
        return ScorePart(
            name: "Sleep (last night)",
            state: .ready(min(1, max(0, score))),
            valueText: "\(hours.formatted(.number.precision(.fractionLength(1)))) h",
            detailText: detail,
            sleepOverrideStatus: current.sleepOverrideStatus
        )
    }

    /// Explicit, editable sleep target. Observed sleep duration is not used to
    /// infer biological need; habitual short or long sleep must not silently
    /// redefine the target.
    func personalizedSleepNeedMinutes() -> Int {
        max(1, latestHealthMetric()?.sleepNeedMinutes ?? 480)
    }

    /// 7-day rolling HRV vs a 14–60 day baseline (last 7 days excluded from
    /// the baseline so the acute window can't drag its own reference).
    ///
    /// All math runs in ln space: HRV is log-normally distributed, and the
    /// baseline / SWC / z-score literature is built on lnRMSSD (Plews 2013).
    /// Signals come via `acuteComparableHRV` — nocturnal readings for
    /// nocturnal users, awake RMSSD/SDNN only for users with no overnight
    /// history, never mixed. HealthKit only exposes SDNN, whose absolute ms
    /// differ from RMSSD, but ln-space z-scores against the *user's own*
    /// baseline are scale-free, so the same constants apply to either metric.
    private func hrvPart() -> ScorePart {
        let recent = recentHealthMetrics(days: 7).compactMap { acuteComparableHRV(for: $0) }.filter { $0 > 0 }
        guard recent.count >= 4 else {
            return ScorePart(name: "HRV trend", state: .building("Needs \(4 - recent.count) more morning\(4 - recent.count == 1 ? "" : "s") of HRV"),
                             valueText: "—", detailText: "Wear a watch overnight to capture HRV")
        }
        let baseline = baselineMetrics(days: 60)
            .filter { calendarDaysBetween($0.date, and: now) > 7 && !$0.sleepUserCorrected }
            .compactMap { acuteComparableHRV(for: $0) }.filter { $0 > 0 }.map { log($0) }
        guard baseline.count >= 14 else {
            return ScorePart(name: "HRV trend", state: .building("Baseline building — \(14 - baseline.count) more days"),
                             valueText: "\(Int((average(recent) ?? 0).rounded())) ms", detailText: "7-day average; baseline needs ~2 weeks more")
        }

        let lnAvg7 = average(recent.map { log($0) }) ?? 0
        let mean = average(baseline) ?? lnAvg7
        let sd = max(standardDeviation(baseline), 0.05)  // ≥5% CV noise floor (Buchheit 2014)
        let z = (lnAvg7 - mean) / sd
        // At baseline → 0.9; each SD below baseline costs 0.2 (Buchheit 2014:
        // deviations beyond the baseline's own noise are the signal).
        let score = min(1, max(0, 0.9 + 0.2 * min(0.5, max(-3.5, z))))
        let swc = 0.5 * sd                               // smallest worthwhile change (Plews 2013)
        let within = abs(lnAvg7 - mean) <= max(swc, 0.02)
        let displayAvg = exp(lnAvg7)
        let displayMean = exp(mean)
        return ScorePart(
            name: "HRV trend",
            state: .ready(score),
            valueText: "\(Int(displayAvg.rounded())) ms",
            detailText: within
                ? "7-day avg, within your usual observed range (baseline \(Int(displayMean.rounded())) ms)"
                : "7-day avg vs \(Int(displayMean.rounded())) ms baseline"
        )
    }

    /// 7-day resting/sleeping HR trend vs baseline (sleeping HR preferred — the
    /// overnight signal is the cleaner autonomic corroborator; Buchheit 2014).
    private func rhrPart() -> ScorePart {
        let recent = recentHealthMetrics(days: 7).compactMap { $0.bestRestingHR.map(Double.init) }
        guard let avg7 = average(recent) else {
            return ScorePart(name: "Resting HR", state: .building("No recent resting heart rate"),
                             valueText: "—", detailText: "Connect Apple Health or wear a watch")
        }
        let baseline = baselineMetrics(days: 60)
            .filter { calendarDaysBetween($0.date, and: now) > 7 && !$0.sleepUserCorrected }
            .compactMap { $0.bestRestingHR.map(Double.init) }
        guard baseline.count >= 14 else {
            return ScorePart(name: "Resting HR", state: .building("Baseline building — \(14 - baseline.count) more days"),
                             valueText: "\(Int(avg7.rounded())) bpm", detailText: "Needs ~2 weeks for a fair baseline")
        }
        let mean = average(baseline) ?? avg7
        let sd = max(standardDeviation(baseline), max(2, mean * 0.03))
        let z = (avg7 - mean) / sd                  // elevated = worse
        let score = min(1, max(0, 0.9 - 0.2 * min(3.5, max(-0.5, z))))
        return ScorePart(
            name: "Resting HR",
            state: .ready(score),
            valueText: "\(Int(avg7.rounded())) bpm",
            detailText: "7-day avg vs \(Int(mean.rounded())) bpm baseline"
        )
    }

    /// 7-day sleep adequacy: average nightly sleep vs the personalized need,
    /// plus accumulated debt. Last night's sleep is deliberately NOT judged
    /// here — the acute daily score owns it — so one short night isn't
    /// double-penalized in both scores (dose-response: Fullagar 2015).
    private func sleepPart() -> ScorePart {
        let need = personalizedSleepNeedMinutes()
        // Partial-wear nights are holes, not short nights — excluded so the
        // 7-day trend isn't dragged down by forgotten-watch fragments.
        let nights = recentHealthMetrics(days: 7).filter(\.sleepIsTrustworthy).compactMap { $0.sleepTotalMinutes }
        guard nights.count >= 3 else {
            return ScorePart(name: "Sleep trend", state: .building("Needs \(3 - nights.count) more night\(3 - nights.count == 1 ? "" : "s") of sleep data"),
                             valueText: "—", detailText: "Wear a watch to bed or log sleep in Health")
        }
        let avgMinutes = Double(nights.reduce(0, +)) / Double(nights.count)
        let ratio = avgMinutes / Double(need)
        var score = ratio >= 0.95 ? 1.0 : max(0.3, 1.0 - (0.95 - ratio) * 2.0)
        let debt = nights.reduce(0.0) { $0 + Double(max(0, need - $1)) / 60 }
        score -= min(0.25, max(0, debt - 1) * 0.05)
        score = min(1, max(0, score))
        let hours = avgMinutes / 60
        return ScorePart(
            name: "Sleep trend",
            state: .ready(score),
            valueText: "\(hours.formatted(.number.precision(.fractionLength(1)))) h avg",
            detailText: debt > 1
                ? "7-day debt \(debt.formatted(.number.precision(.fractionLength(1)))) h vs \(String(format: "%.1f", Double(need) / 60)) h need"
                : "Meeting your \(String(format: "%.1f", Double(need) / 60)) h need"
        )
    }

    // MARK: - Per-muscle

    private static let trackedMuscles = MuscleTaxonomy.freshnessGroups.flatMap { group in
        [group.name] + group.children
    }

    private func muscleRecoveryScores() -> [MuscleRecoveryScore] {
        let byID = exerciseByID
        struct SessionExposure { let endedAt: Date; let dose: Double }
        var perMuscle: [String: [SessionExposure]] = [:]

        for workout in completed {
            let endedAt = workout.endedAt ?? workout.startedAt
            guard endedAt <= now, now.timeIntervalSince(endedAt) <= 56 * 86_400 else { continue }
            var sessionDose: [String: Double] = [:]
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                let done = we.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !done.isEmpty else { continue }
                for set in done {
                    let effort = TrainingEffortMath.resolved(
                        rpe: set.rpe,
                        rir: set.rir,
                        defaultEffort: 8
                    )
                    let setDose = VolumeMath.effectiveSetCount(set.domainEntry)
                        * TrainingEffortMath.weight(for: effort)
                    guard setDose > 0 else { continue }

                    // Exact muscles and freshness regions are credited once
                    // per set at their strongest role. A squat tagged for both
                    // quads and glutes therefore contributes one Legs set,
                    // while both child rows retain their exact exposure.
                    var credited: [String: Double] = [:]
                    for muscle in exercise.secondaryMuscles {
                        credited[MuscleTaxonomy.canonical(muscle)] = 0.5
                    }
                    for muscle in exercise.primaryMuscles {
                        credited[MuscleTaxonomy.canonical(muscle)] = 1
                    }
                    var groupCredits: [String: Double] = [:]
                    for (muscle, weight) in credited {
                        for group in MuscleTaxonomy.freshnessGroups
                        where group.name == muscle || group.children.contains(muscle) {
                            groupCredits[group.name] = max(groupCredits[group.name] ?? 0, weight)
                        }
                    }
                    for (group, weight) in groupCredits {
                        credited[group] = max(credited[group] ?? 0, weight)
                    }
                    for (muscle, weight) in credited {
                        sessionDose[muscle, default: 0] += weight * setDose
                    }
                }
            }
            for (muscle, dose) in sessionDose where dose > 0 {
                perMuscle[muscle, default: []].append(SessionExposure(endedAt: endedAt, dose: dose))
            }
        }

        return Self.trackedMuscles.map { muscle in
            guard let sessions = perMuscle[muscle],
                  let lastTrained = sessions.map(\.endedAt).max() else {
                return MuscleRecoveryScore(
                    muscle: muscle,
                    state: .building("No sets logged yet"),
                    lastTrainedDaysAgo: nil,
                    readyInHours: nil
                )
            }
            let ordered = sessions.sorted { $0.endedAt < $1.endedAt }
            let referenceSessions = ordered.count >= 7 ? Array(ordered.dropLast()) : ordered
            let reference = robustMedian(referenceSessions.map(\.dose)) ?? 1
            let decayedExposure = ordered.reduce(0.0) { total, session in
                let hoursAgo = max(0, now.timeIntervalSince(session.endedAt) / 3600)
                return total + session.dose * pow(2, -hoursAgo / 36)
            }
            let score = min(1, max(0, pow(2, -decayedExposure / max(reference, 0.001))))
            return MuscleRecoveryScore(
                muscle: muscle,
                state: .ready(score),
                lastTrainedDaysAgo: calendarDaysBetween(lastTrained, and: now),
                readyInHours: nil,
                isProvisional: ordered.count < 7,
                recentExposure: decayedExposure,
                referenceDose: reference
            )
        }
    }

    // MARK: - Cardio

    private func cardioRecovery() -> CardioRecovery {
        struct Exposure {
            let endedAt: Date
            let minutes: Double
            let load: Double
            let evidence: CardioEvidence
        }

        var exposures: [Exposure] = []
        var everEligible = false
        for workout in completed {
            let endedAt = workout.endedAt ?? workout.startedAt
            guard endedAt <= now, now.timeIntervalSince(endedAt) <= 56 * 86_400 else { continue }

            let duration = durationMinutes(workout)
            if let measuredLoad = measuredCardioLoad(
                zones: workout.hrZoneSeconds,
                durationMinutes: duration
            ) {
                everEligible = true
                exposures.append(Exposure(
                    endedAt: endedAt,
                    minutes: duration,
                    load: measuredLoad,
                    evidence: .measuredHeartRate
                ))
                continue
            }

            let explicitSessions = workout.cardioSessions.filter { !$0.isYogaSession }
            let importedCardio = workout.hkWorkoutUUID != nil
                && workout.cardioSessions.isEmpty
                && workout.exercises.flatMap(\.sets).isEmpty
                && !healthWorkoutLooksStrengthLike(workout)
            guard !explicitSessions.isEmpty || importedCardio else { continue }
            everEligible = true

            var sessionMinutes = 0.0
            var sessionLoad = 0.0
            var evidenceKinds = Set<CardioEvidence>()
            for session in explicitSessions {
                let minutes = max(0, Double(session.durationSeconds ?? 0) / 60)
                guard minutes > 0 else { continue }
                if session.sampleSeriesJSON != nil,
                   let measuredLoad = measuredCardioLoad(zones: session.hrZoneSeconds, durationMinutes: minutes) {
                    sessionMinutes += minutes
                    sessionLoad += measuredLoad
                    evidenceKinds.insert(.measuredHeartRate)
                } else if let effort = session.effort.map(Double.init) ?? workout.wholeSessionRPE {
                    sessionMinutes += minutes
                    sessionLoad += minutes * TrainingEffortMath.clamped(effort) / 2
                    evidenceKinds.insert(.perceivedEffort)
                }
            }
            if explicitSessions.isEmpty, importedCardio,
               let rpe = workout.wholeSessionRPE, duration > 0 {
                sessionMinutes = duration
                sessionLoad = duration * TrainingEffortMath.clamped(rpe) / 2
                evidenceKinds.insert(.perceivedEffort)
            }
            guard sessionLoad > 0 else { continue }
            let scale = duration > 0 && sessionMinutes > duration ? duration / sessionMinutes : 1
            exposures.append(Exposure(
                endedAt: endedAt,
                minutes: sessionMinutes * scale,
                load: sessionLoad * scale,
                evidence: evidenceKinds.count > 1 ? .mixedHistory : (evidenceKinds.first ?? .perceivedEffort)
            ))
        }

        guard everEligible else {
            return CardioRecovery(
                state: .building("Record cardio, conditioning, or workout heart rate to build this score."),
                lastSessionText: nil,
                readyInHours: nil
            )
        }

        guard !exposures.isEmpty else {
            return CardioRecovery(
                state: .building("Record measured heart-rate zones or rate cardio or conditioning effort."),
                lastSessionText: nil,
                readyInHours: nil
            )
        }

        let ordered = exposures.sorted { $0.endedAt < $1.endedAt }
        guard let last = ordered.last else {
            return CardioRecovery(
                state: .building("No cardiovascular load is available."),
                lastSessionText: nil,
                readyInHours: nil
            )
        }
        let referenceSessions = ordered.count >= 7 ? Array(ordered.dropLast()) : ordered
        let reference = robustMedian(referenceSessions.map(\.load)) ?? 1
        let decayed = ordered.reduce(0.0) { total, exposure in
            let hoursAgo = max(0, now.timeIntervalSince(exposure.endedAt) / 3600)
            return total + exposure.load * pow(2, -hoursAgo / 24)
        }
        let score = min(1, max(0, pow(2, -decayed / max(reference, 0.001))))
        let days = calendarDaysBetween(last.endedAt, and: now)
        let when = days == 0 ? "today" : (days == 1 ? "yesterday" : "\(days)d ago")
        let lastText = "\(Int(last.minutes.rounded()))min · \(when)"
        let evidenceKinds = Set(ordered.map(\.evidence))
        let evidence: CardioEvidence = evidenceKinds.count > 1
            ? .mixedHistory
            : (evidenceKinds.first ?? .perceivedEffort)
        return CardioRecovery(
            state: .ready(score),
            lastSessionText: lastText,
            readyInHours: nil,
            isProvisional: ordered.count < 7,
            evidence: evidence
        )
    }

    /// Returns a common zone-minute dose only when measured coverage is dense
    /// enough to represent the session. Average HR never reconstructs zones.
    private func measuredCardioLoad(
        zones: [Int],
        durationMinutes: Double
    ) -> Double? {
        guard zones.count == 5, durationMinutes > 0 else { return nil }
        let observedSeconds = zones.reduce(0) { $0 + max(0, $1) }
        guard observedSeconds > 0,
              Double(observedSeconds) / (durationMinutes * 60) >= 0.5 else { return nil }
        let load = zones.enumerated().reduce(0.0) { total, pair in
            total + Double(max(0, pair.element)) / 60 * Double(pair.offset + 1)
        }
        guard load > 0 else { return nil }
        return load
    }

    // MARK: - Small math helpers

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1, let mean = average(values) else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }
}
