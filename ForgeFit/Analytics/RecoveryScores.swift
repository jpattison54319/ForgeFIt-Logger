import Foundation
import ForgeCore
import ForgeData

/// Evidence-based recovery scores: one systemic (whole-body) score, one score
/// per muscle, and one cardiovascular score. Each score gates on data
/// sufficiency and says what it still needs instead of guessing.
///
/// The model, with its literature anchors:
///
/// **Systemic** — a weighted blend of four components (weights renormalize
/// over whatever data exists):
///  - HRV (35%): 7-day rolling average compared against a 14–60 day baseline,
///    banded by the baseline's own variability. Rolling-average HRV tracks
///    training adaptation and fatigue better than single readings
///    (Plews et al. 2013, Sports Med; Buchheit 2014, Front Physiol).
///  - Sleep (25%): last night vs need, plus 7-day accumulated debt. Sleep is
///    the best-supported recovery behavior in athletes (Fullagar et al. 2015,
///    Sports Med).
///  - Resting HR (15%): today vs baseline; a slower-moving corroborator of
///    autonomic status (Buchheit 2014).
///  - Training-stress balance (25%): exponentially-weighted acute (7d) vs
///    chronic (28d) load — EWMA outperforms rolling averages for workload
///    monitoring (Williams et al. 2017, BJSM); flat weeks are penalized via
///    Foster's monotony (Foster 1998, MSSE). Treated as a fatigue flag, not
///    an injury predictor (Impellizzeri et al. 2020 critique acknowledged).
///
/// **Per muscle** — force capacity after a bout recovers roughly
/// exponentially over 24–72 h, slower with more volume, closer proximity to
/// failure, and for larger muscle groups (McLester et al. 2003, JSCR;
/// Korak et al. 2015; Morán-Navarro et al. 2017, Eur J Appl Physiol —
/// failure sets need 24–48 h+ vs non-failure). Each session deposits a
/// recovery deficit D = min(0.65, 0.12·(effectiveSets)^0.75) that decays with
/// muscle-specific time constants (18–34 h); the score is 1 − Σ remaining
/// deficits. ~48 h between hard sessions for the same muscle matches
/// meta-analytic frequency guidance (Schoenfeld et al. 2016, Sports Med).
///
/// **Cardio** — autonomic (parasympathetic) recovery depends on intensity
/// domain, not just duration: ≲24 h after low-intensity work, 24–48 h after
/// threshold work, 48 h+ after high-intensity intervals (Stanley, Peake &
/// Buchheit 2013, Sports Med). Sessions are dosed by Edwards-style
/// zone-weighted minutes and decay with a domain-specific time constant, so
/// Zone 2 and HIIT genuinely differ.
extension RecoveryEngine {

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
    }

    struct SystemicRecovery {
        var state: ScoreState
        var parts: [ScorePart]
        var guidance: String
    }

    /// The acute, today-only readiness score — nocturnal autonomic state plus
    /// last night's sleep, judged against the individual's own baseline. Built
    /// to move with the day (like Athlytic/WHOOP) so the headline number always
    /// agrees with the guidance shown beside it. Training-load balance is
    /// deliberately excluded here — it belongs to the chronic trend, not to
    /// "how stressed is my body this morning".
    struct DailyReadiness {
        var state: ScoreState
        var parts: [ScorePart]
        /// Short, user-facing reasons that also drove the score, e.g.
        /// "HRV low today" — the copy and the number share one source of truth.
        var flags: [String]
        var guidance: String
    }

    struct MuscleRecoveryScore: Identifiable {
        var id: String { muscle }
        let muscle: String
        let state: ScoreState         // building = never logged for this muscle
        let lastTrainedDaysAgo: Int?
        /// Hours until the muscle is back above ~90%, nil when already there.
        let readyInHours: Int?

        var statusLabel: String {
            guard let value = state.value else { return "No data" }
            switch value {
            case 0.9...: return "Ready"
            case 0.75..<0.9: return "Nearly ready"
            case 0.5..<0.75: return "Recovering"
            default: return "Fatigued"
            }
        }
    }

    enum CardioDomain: String {
        case easy = "Low intensity"
        case threshold = "Threshold"
        case severe = "High intensity"
    }

    struct CardioRecovery {
        var state: ScoreState
        var lastSessionText: String?
        var dominantDomain: CardioDomain?
        var readyInHours: Int?
        var guidance: String
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

    /// Chronic-trend weights. Load balance is capped at 15% — EWMA-ACWR is a
    /// training-management heuristic, not a recovery measure (Impellizzeri
    /// 2020), so it flavors the trend without being able to mask autonomic or
    /// sleep deterioration. HRV trend keeps the largest share (Plews 2013).
    private enum SystemicWeight {
        static let hrv = 0.40, sleep = 0.30, rhr = 0.15, load = 0.15
    }

    private func systemicRecovery() -> SystemicRecovery {
        let hrv = hrvPart()
        let sleep = sleepPart()
        let rhr = rhrPart()
        let load = loadBalancePart()
        let parts = [hrv, sleep, rhr, load]

        var weighted = 0.0
        var weightSum = 0.0
        for (part, weight) in [(hrv, SystemicWeight.hrv), (sleep, SystemicWeight.sleep),
                               (rhr, SystemicWeight.rhr), (load, SystemicWeight.load)] {
            if let value = part.state.value {
                weighted += value * weight
                weightSum += weight
            }
        }

        // Require at least one real component before claiming a score.
        guard weightSum >= 0.15 else {
            return SystemicRecovery(
                state: .building("Log workouts or connect Apple Health to build this score."),
                parts: parts,
                guidance: "Systemic recovery blends HRV, sleep, resting heart rate, and training-load balance once data is available."
            )
        }

        let score = min(1, max(0, weighted / weightSum))
        return SystemicRecovery(state: .ready(score), parts: parts, guidance: systemicGuidance(score))
    }

    private func systemicGuidance(_ score: Double) -> String {
        switch score {
        case 0.85...: "Strong recovery trend — adaptation is on track."
        case 0.7..<0.85: "Stable recovery trend — training load and recovery are in balance."
        case 0.4..<0.7: "Recovery trend is softening — recent load or sleep may be accumulating."
        default: "Downward recovery trend — accumulated fatigue is building."
        }
    }

    // MARK: - Daily readiness (acute)

    private enum DailyWeight {
        static let hrv = 0.55, sleepingHR = 0.20, sleep = 0.25
    }

    /// Today's autonomic state vs the individual's baseline, plus last night's
    /// sleep. Reactive by design — one genuinely bad night should move it.
    private func dailyReadiness() -> DailyReadiness {
        let hrv = acuteHRVPart()
        let hr = sleepingHRPart()
        let sleep = lastNightSleepPart()
        let parts = [hrv, sleep, hr]

        var weighted = 0.0, weightSum = 0.0
        for (part, weight) in [(hrv, DailyWeight.hrv), (hr, DailyWeight.sleepingHR), (sleep, DailyWeight.sleep)] {
            if let value = part.state.value { weighted += value * weight; weightSum += weight }
        }
        // An acute "last night" score needs evidence a night happened: HRV
        // (channel-pure — awake-only users' awake channel counts, it's all
        // they have), sleep, or genuinely sleeping HR. Apple's daytime
        // resting-HR estimate alone can't fabricate a night — before this
        // gate, being up past midnight scored the new day from awake data
        // and the score whipsawed until sleep synced.
        //
        // The gate only holds until mid-morning: before then, missing
        // overnight data almost always means the night isn't in yet (still
        // awake at 1am, or the watch hasn't synced). From mid-morning it
        // means the night was missed, and the score degrades honestly to
        // the daytime signals that exist (an elevated daytime resting HR
        // must still flag on a watch-died day).
        let hrMeasuredOvernight = sleepingHRAssessment().map { !$0.isDaytimeFallback } ?? false
        let overnightEvidence = hrv.state.value != nil || sleep.state.value != nil
            || (hr.state.value != nil && hrMeasuredOvernight)
        let nightStillPending = calendar.component(.hour, from: now) < 9
        guard weightSum >= 0.2, overnightEvidence || !nightStillPending else {
            let overnightHistory = usesNocturnalHRV
                || baselineMetrics(days: 60).contains { $0.sleepTotalMinutes != nil }
            return DailyReadiness(
                state: .building(overnightHistory
                    ? "Waiting on last night's data — the score updates once your sleep syncs."
                    : "Wear a watch to bed — Apple Watch, or a Garmin synced through Garmin Connect — to capture last night's HRV, heart rate, and sleep."),
                parts: parts, flags: [],
                guidance: "Daily readiness reads your nocturnal HRV, sleeping heart rate, and last night's sleep against your own baseline."
            )
        }
        let score = min(1, max(0, weighted / weightSum))

        // Flags are derived from the same parts that moved the score, so the
        // copy can never contradict the number.
        var flags: [String] = []
        if acuteHRVBelowRange { flags.append("HRV low today") }
        if let hrAssessment = sleepingHRAssessment(), hrAssessment.elevated {
            flags.append(hrAssessment.isDaytimeFallback ? "Resting HR elevated" : "Sleeping HR elevated")
        }
        if lastNightSleepShort { flags.append("Short sleep") }

        return DailyReadiness(state: .ready(score), parts: parts, flags: flags, guidance: dailyGuidance(score, flags: flags))
    }

    private func dailyGuidance(_ score: Double, flags: [String]) -> String {
        let base = switch score {
        case 0.85...: "Today’s overnight signals are exceptionally favorable."
        case 0.7..<0.85: "Today’s overnight signals are within your ready range."
        case 0.4..<0.7: "Today’s overnight signals show some recovery caution."
        default: "Today’s overnight signals are below your ready range."
        }
        guard !flags.isEmpty else { return base }
        let reasons = flags.compactMap(Self.acuteReasonClause)
        guard !reasons.isEmpty else { return base }
        let joined = reasons.count == 1
            ? reasons[0]
            : reasons.dropLast().joined(separator: ", ") + " and " + reasons.last!
        let sentence = joined.prefix(1).uppercased() + joined.dropFirst()
        return "\(base) \(sentence)."
    }

    /// User-facing clause per acute flag, phrased to read naturally alone or
    /// joined with others. Shared by the daily score and its evidence rows.
    static func acuteReasonClause(_ flag: String) -> String? {
        switch flag {
        case "HRV low today": return "HRV dipped below your normal range this morning"
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
        guard let current = latestHealthMetric(), let sleep = current.sleepTotalMinutes else { return false }
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
            .filter { calendarDaysBetween($0.date, and: now) >= 1 }   // exclude today only
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
            if usesNocturnalHRV, latestHealthMetric()?.nocturnalHRV == nil {
                return ScorePart(
                    name: "HRV (today)",
                    state: .building("Last night's HRV isn't in yet"),
                    valueText: "—",
                    detailText: "Updates when tonight's sleep syncs"
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
                ? "Last night, below your normal range (baseline \(Int(assessment.baselineMs.rounded())) ms)"
                : "Last night, within your normal range (baseline \(Int(assessment.baselineMs.rounded())) ms)"
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
            .filter { calendarDaysBetween($0.date, and: now) >= 1 }
        if let today = current.sleepingHR {
            let baseline = priorDays.compactMap { $0.sleepingHR.map(Double.init) }
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
        let suffix = assessment.isDaytimeFallback ? " (daytime — sleep not captured yet)" : ""
        return ScorePart(
            name: assessment.isDaytimeFallback ? "Resting HR" : "Sleeping HR",
            state: .ready(assessment.score),
            valueText: "\(assessment.today) bpm",
            detailText: (assessment.elevated ? "Elevated vs \(comparison)" : "vs \(comparison)") + suffix
        )
    }

    private func lastNightSleepPart() -> ScorePart {
        guard let current = latestHealthMetric(), let sleep = current.sleepTotalMinutes else {
            return ScorePart(name: "Sleep (last night)", state: .building("No sleep data from last night"),
                             valueText: "—", detailText: "Wear a watch to bed or log sleep in Health")
        }
        let need = personalizedSleepNeedMinutes()
        let ratio = Double(sleep) / Double(need)
        let score = ratio >= 0.95 ? 1.0 : max(0.3, 1.0 - (0.95 - ratio) * 2.0)
        let hours = Double(sleep) / 60
        return ScorePart(
            name: "Sleep (last night)",
            state: .ready(min(1, max(0, score))),
            valueText: "\(hours.formatted(.number.precision(.fractionLength(1)))) h",
            detailText: "Need \(String(format: "%.1f", Double(need) / 60)) h"
        )
    }

    /// Personalized nightly sleep need. Starts from an 8 h default (or a profile
    /// override via `sleepNeedMinutes`) and only raises it for habitual long
    /// sleepers — the 60th percentile of the last 30 nights — never lowering it
    /// below 8 h, so chronic short sleep is still flagged as debt rather than
    /// quietly redefined as sufficient.
    func personalizedSleepNeedMinutes() -> Int {
        let base = max(300, latestHealthMetric()?.sleepNeedMinutes ?? 480)
        let nights = baselineMetrics(days: 30).compactMap { $0.sleepTotalMinutes }.sorted()
        guard nights.count >= 10 else { return base }
        let p60 = nights[Int(Double(nights.count - 1) * 0.6)]
        return min(600, max(base, p60))   // cap at 10 h
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
            .filter { calendarDaysBetween($0.date, and: now) > 7 }
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
                ? "7-day avg, within your normal range (baseline \(Int(displayMean.rounded())) ms)"
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
            .filter { calendarDaysBetween($0.date, and: now) > 7 }
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
        let nights = recentHealthMetrics(days: 7).compactMap { $0.sleepTotalMinutes }
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

    /// EWMA acute (7d) vs chronic (28d) training-stress balance.
    private func loadBalancePart() -> ScorePart {
        let sessions = completed
        guard let earliest = sessions.map(\.startedAt).min() else {
            return ScorePart(name: "Load balance", state: .building("Log workouts to build this"),
                             valueText: "—", detailText: "Training-stress balance needs a history")
        }
        let historyDays = calendarDaysBetween(earliest, and: now)
        let recentCount = sessions.filter { calendarDaysBetween($0.startedAt, and: now) <= 28 }.count
        guard historyDays >= 14, recentCount >= 4 else {
            return ScorePart(name: "Load balance", state: .building("Needs ~2 more weeks of logging"),
                             valueText: "—", detailText: "\(recentCount) session\(recentCount == 1 ? "" : "s") in the last 4 weeks")
        }

        let daily = dailyLoads(days: 56)              // index 0 = today
        let lambdaAcute = 2.0 / (7 + 1)
        let lambdaChronic = 2.0 / (28 + 1)
        var acute = 0.0
        var chronic = 0.0
        for index in stride(from: daily.count - 1, through: 0, by: -1) {
            acute = lambdaAcute * daily[index] + (1 - lambdaAcute) * acute
            chronic = lambdaChronic * daily[index] + (1 - lambdaChronic) * chronic
        }
        guard chronic > 0.5 else {
            return ScorePart(name: "Load balance", state: .building("Chronic baseline still near zero"),
                             valueText: "—", detailText: "Keep logging sessions")
        }
        // Asymmetric by design: a spike pulls recovery down hard, but a tidy
        // ratio only reads slightly-positive — ACWR is a fatigue flag, not a
        // recovery credit (Impellizzeri 2020), so good load management can't
        // paper over poor sleep or a sagging HRV trend.
        let ratio = acute / chronic
        var score: Double = switch ratio {
        case ..<0.8: 0.85        // fresh / tapered
        case ..<1.3: 0.80        // balanced — neutral, not a bonus
        case ..<1.5: 0.60        // elevated
        case ..<2.0: 0.60 - (ratio - 1.5) * 0.6   // 1.5→0.60 … 2.0→0.30
        default: 0.25
        }
        if let monotonyValue = monotony(dailyLoads(days: 7)), monotonyValue > 2 {
            score -= monotonyValue > 3 ? 0.15 : 0.08  // flat weeks accumulate strain (Foster 1998)
        }
        score = min(1, max(0, score))
        return ScorePart(
            name: "Load balance",
            state: .ready(score),
            valueText: ratio.formatted(.number.precision(.fractionLength(2))),
            detailText: "7-day vs 28-day training stress (EWMA)"
        )
    }

    // MARK: - Per-muscle

    /// Exponential time constants (hours) per muscle group. Bigger movers and
    /// long-stretch-position muscles show slower force recovery.
    private static let muscleBaseTauHours: [String: Double] = [
        "quadriceps": 30, "hamstrings": 32, "glutes": 28,
        "lats": 28, "middle back": 28, "lower back": 34,
        "chest": 26, "shoulders": 22,
        "biceps": 20, "triceps": 20,
        "calves": 18, "abdominals": 18, "forearms": 16, "traps": 22,
    ]
    private static let trackedMuscles = ["chest", "lats", "shoulders", "biceps", "triceps", "quadriceps", "hamstrings", "glutes"]

    private func muscleRecoveryScores() -> [MuscleRecoveryScore] {
        let byID = exerciseByID
        struct Load {
            var remainingDeficit = 0.0
            var slowestTau = 24.0
            var lastTrained: Date?
        }
        var perMuscle: [String: Load] = [:]

        for workout in completed {
            let hoursAgo = max(0, now.timeIntervalSince(workout.endedAt ?? workout.startedAt) / 3600)

            // Fractional sets per muscle for this session (primary 1.0,
            // secondary 0.5 — same convention as weekly muscle volume).
            var sets: [String: Double] = [:]
            var rpeSum: [String: Double] = [:]
            var rpeCount: [String: Double] = [:]
            for we in workout.exercises {
                guard let exercise = byID[we.exerciseID], !exercise.isCardio else { continue }
                let done = we.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !done.isEmpty else { continue }
                let rpes = done.compactMap(\.rpe)
                for muscle in exercise.primaryMuscles {
                    sets[muscle, default: 0] += Double(done.count)
                    if !rpes.isEmpty {
                        rpeSum[muscle, default: 0] += rpes.reduce(0, +)
                        rpeCount[muscle, default: 0] += Double(rpes.count)
                    }
                }
                for muscle in exercise.secondaryMuscles {
                    sets[muscle, default: 0] += Double(done.count) * 0.5
                }
            }

            for (muscle, setCount) in sets {
                var load = perMuscle[muscle] ?? Load()
                if load.lastTrained.map({ workout.startedAt > $0 }) ?? true {
                    load.lastTrained = workout.startedAt
                }
                // Only the last 14 days meaningfully contribute to deficits.
                if hoursAgo <= 14 * 24 {
                    let avgRPE = rpeCount[muscle].flatMap { count -> Double? in
                        count > 0 ? (rpeSum[muscle] ?? 0) / count : nil
                    }
                    // Proximity to failure prolongs recovery, continuously:
                    // RPE 8 is the reference (1.0), each RPE point moves the
                    // dose ±0.15 — so RPE 6 costs 0.7× and RPE 10 costs 1.3×
                    // (Morán-Navarro 2017: failure sets need 24–48 h more than
                    // sets stopped 2+ reps short). No logged RPE assumes 8.
                    let effortFactor = avgRPE.map { min(1.3, max(0.55, 1.0 + ($0 - 8) * 0.15)) } ?? 1.0
                    let dose = setCount * effortFactor
                    let deficit = min(0.65, 0.12 * pow(dose, 0.75))
                    let baseTau = Self.muscleBaseTauHours[muscle.lowercased()] ?? 24
                    // True-failure sessions also *decay slower*, not just
                    // deeper: stretch the time constant near RPE 10.
                    let failureStretch = avgRPE.map { $0 >= 9.5 ? 1.2 : 1.0 } ?? 1.0
                    let tau = baseTau * (0.8 + 0.05 * min(setCount, 8)) * failureStretch
                    load.remainingDeficit += deficit * exp(-hoursAgo / tau)
                    load.slowestTau = max(load.slowestTau, tau)
                }
                perMuscle[muscle] = load
            }
        }

        return Self.trackedMuscles.map { muscle in
            guard let load = perMuscle[muscle], let lastTrained = load.lastTrained else {
                return MuscleRecoveryScore(
                    muscle: muscle,
                    state: .building("No sets logged yet"),
                    lastTrainedDaysAgo: nil,
                    readyInHours: nil
                )
            }
            let remaining = min(0.85, load.remainingDeficit)
            let score = min(1, max(0, 1 - remaining))
            // Hours until remaining deficit decays below 0.10 (≈ 90% ready).
            let readyIn: Int? = remaining > 0.10
                ? Int((load.slowestTau * log(remaining / 0.10)).rounded(.up))
                : nil
            return MuscleRecoveryScore(
                muscle: muscle,
                state: .ready(score),
                lastTrainedDaysAgo: calendarDaysBetween(lastTrained, and: now),
                readyInHours: readyIn
            )
        }
    }

    // MARK: - Cardio

    /// Edwards-style zone weights (minutes in zone × weight).
    private static let zoneWeights: [Double] = [0.4, 1.0, 1.8, 3.0, 5.0]

    private func cardioRecovery() -> CardioRecovery {
        struct Session {
            let date: Date
            let minutes: Double
            let domain: CardioDomain
            let weightedMinutes: Double
        }

        var sessions: [Session] = []
        var everLoggedCardio = false
        for workout in completed {
            for cardio in workout.cardioSessions {
                // Yoga: restorative practice is zero aerobic stress; active
                // practice counts only when a real HR was measured (matching
                // the training-load classifier in RecoveryEngine).
                if cardio.isYogaSession {
                    guard !cardio.resolvedYogaStyle.isRestorative, cardio.avgHR != nil else { continue }
                }
                everLoggedCardio = true
                guard calendarDaysBetween(workout.startedAt, and: now) <= 7 else { continue }
                let minutes = Double(cardio.durationSeconds ?? 0) / 60
                guard minutes > 0 else { continue }
                let zones = zoneMinutes(
                    zoneSeconds: cardio.hrZoneSeconds,
                    avgHR: cardio.avgHR,
                    durationSeconds: cardio.durationSeconds,
                    effort: cardio.effort
                )
                sessions.append(Session(
                    date: workout.startedAt,
                    minutes: minutes,
                    domain: dominantDomain(zones),
                    weightedMinutes: zip(zones, Self.zoneWeights).reduce(0) { $0 + $1.0 * $1.1 }
                ))
            }
            // Imported HR-only workouts (no local sets) still stress the system.
            if workout.hkWorkoutUUID != nil, workout.cardioSessions.isEmpty,
               workout.exercises.flatMap(\.sets).isEmpty, workout.avgHR != nil,
               !healthWorkoutLooksStrengthLike(workout) {
                everLoggedCardio = true
                guard calendarDaysBetween(workout.startedAt, and: now) <= 7 else { continue }
                let minutes = durationMinutes(workout)
                let zones = zoneMinutes(
                    zoneSeconds: workout.hrZoneSeconds,
                    avgHR: workout.avgHR,
                    durationSeconds: Int(minutes * 60),
                    effort: nil
                )
                sessions.append(Session(
                    date: workout.startedAt,
                    minutes: minutes,
                    domain: dominantDomain(zones),
                    weightedMinutes: zip(zones, Self.zoneWeights).reduce(0) { $0 + $1.0 * $1.1 }
                ))
            }
        }

        guard everLoggedCardio else {
            return CardioRecovery(
                state: .building("Log a cardio session to track this"),
                lastSessionText: nil,
                dominantDomain: nil,
                readyInHours: nil,
                guidance: "Cardio recovery tracks how hard recent sessions hit your system — Zone 2 clears in about a day; hard intervals take 2–3."
            )
        }

        var remaining = 0.0
        var slowestTau = 14.0
        for session in sessions {
            let hoursAgo = max(0, now.timeIntervalSince(session.date) / 3600)
            // Parasympathetic reactivation time constants by intensity domain
            // (Stanley, Peake & Buchheit 2013).
            let tau: Double = switch session.domain {
            case .easy: 14
            case .threshold: 26
            case .severe: 40
            }
            let deficit = min(0.6, 0.006 * session.weightedMinutes)
            remaining += deficit * exp(-hoursAgo / tau)
            if deficit > 0.05 { slowestTau = max(slowestTau, tau) }
        }
        remaining = min(0.85, remaining)
        let score = min(1, max(0, 1 - remaining))
        let readyIn: Int? = remaining > 0.10
            ? Int((slowestTau * log(remaining / 0.10)).rounded(.up))
            : nil

        let last = sessions.max { $0.date < $1.date }
        let lastText: String? = last.map { session in
            let days = calendarDaysBetween(session.date, and: now)
            let when = days == 0 ? "today" : (days == 1 ? "yesterday" : "\(days)d ago")
            return "\(Int(session.minutes.rounded()))min \(session.domain.rawValue.lowercased()) · \(when)"
        }
        return CardioRecovery(
            state: .ready(score),
            lastSessionText: lastText ?? "None in the last week",
            dominantDomain: last?.domain,
            readyInHours: readyIn,
            guidance: cardioGuidance(score: score, domain: last?.domain)
        )
    }

    /// Minutes per HR zone, best-available source first: measured zone
    /// seconds → estimate from average HR → estimate from logged effort.
    private func zoneMinutes(zoneSeconds: [Int], avgHR: Int?, durationSeconds: Int?, effort: Int?) -> [Double] {
        if zoneSeconds.count == 5, zoneSeconds.contains(where: { $0 > 0 }) {
            return zoneSeconds.map { Double($0) / 60 }
        }
        if avgHR != nil {
            let estimated = CardioMetrics.estimatedZoneSecondsArray(avgHR: avgHR, durationSeconds: durationSeconds)
            if estimated.contains(where: { $0 > 0 }) {
                return estimated.map { Double($0) / 60 }
            }
        }
        let minutes = Double(durationSeconds ?? 0) / 60
        var zones = [Double](repeating: 0, count: 5)
        let zone: Int = switch Double(effort ?? 6) {
        case 9...: 5
        case 7...: 4
        case 5.5...: 3
        case 4...: 2
        default: 1
        }
        zones[zone - 1] = minutes
        return zones
    }

    private func dominantDomain(_ zoneMinutes: [Double]) -> CardioDomain {
        guard zoneMinutes.count == 5 else { return .easy }
        let easy = (zoneMinutes[0] + zoneMinutes[1]) * 1.0
        let threshold = (zoneMinutes[2] + zoneMinutes[3]) * 2.4
        let severe = zoneMinutes[4] * 5.0
        // A meaningful chunk of Zone 5 defines the session even when most
        // minutes are easy — intervals live between recoveries.
        if zoneMinutes[4] >= 5 || severe >= max(easy, threshold) { return .severe }
        if threshold >= easy { return .threshold }
        return .easy
    }

    private func cardioGuidance(score: Double, domain: CardioDomain?) -> String {
        switch domain {
        case .severe:
            return score >= 0.8
                ? "Recent high-intensity work has largely cleared."
                : "Recent high-intensity work is still contributing to local cardiovascular fatigue."
        case .threshold:
            return score >= 0.8
                ? "Recent threshold work has largely cleared."
                : "Recent threshold work remains a meaningful part of your recovery context."
        case .easy:
            return "Recent cardio was low intensity and usually clears quickly."
        case nil:
            return "No cardio sessions were logged in the last week."
        }
    }

    // MARK: - Small math helpers

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1, let mean = average(values) else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }
}
