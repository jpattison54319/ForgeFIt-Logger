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
        var systemic: SystemicRecovery
        var muscles: [MuscleRecoveryScore]
        var cardio: CardioRecovery
    }

    func recoverySnapshot() -> RecoverySnapshot {
        RecoverySnapshot(
            systemic: systemicRecovery(),
            muscles: muscleRecoveryScores(),
            cardio: cardioRecovery()
        )
    }

    // MARK: - Systemic

    private enum SystemicWeight {
        static let hrv = 0.35, sleep = 0.25, rhr = 0.15, load = 0.25
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
        case 0.8...: "Recovered — full intensity is available today."
        case 0.65..<0.8: "Mostly recovered — train as planned."
        case 0.5..<0.65: "Partially recovered — keep volume moderate and stop short of failure."
        default: "Under-recovered — favor easy movement, Zone 2, or rest."
        }
    }

    /// 7-day rolling HRV vs a 14–60 day baseline (last 7 days excluded from
    /// the baseline so the acute window can't drag its own reference).
    private func hrvPart() -> ScorePart {
        func value(_ metric: DailyHealthMetric, preferRMSSD: Bool) -> Double? {
            preferRMSSD ? (metric.hrvRMSSD ?? metric.hrvSDNN) : (metric.hrvSDNN ?? metric.hrvRMSSD)
        }
        let preferRMSSD = recentHealthMetrics(days: 7).contains { $0.hrvRMSSD != nil }
        let recent = recentHealthMetrics(days: 7).compactMap { value($0, preferRMSSD: preferRMSSD) }
        guard recent.count >= 4 else {
            return ScorePart(name: "HRV", state: .building("Needs \(4 - recent.count) more morning\(4 - recent.count == 1 ? "" : "s") of HRV"),
                             valueText: "—", detailText: "Wear your watch overnight to capture HRV")
        }
        let baselineWindow = baselineMetrics(days: 60).filter {
            calendarDaysBetween($0.date, and: now) > 7
        }
        let baseline = baselineWindow.compactMap { value($0, preferRMSSD: preferRMSSD) }
        guard baseline.count >= 14 else {
            return ScorePart(name: "HRV", state: .building("Baseline building — \(14 - baseline.count) more days"),
                             valueText: "\(Int((average(recent) ?? 0).rounded())) ms", detailText: "7-day average; baseline needs ~2 weeks more")
        }

        let avg7 = average(recent) ?? 0
        let mean = average(baseline) ?? avg7
        let sd = standardDeviation(baseline)
        let effectiveSD = max(sd, mean * 0.03)
        let z = (avg7 - mean) / effectiveSD
        // At baseline → 0.9; each SD below baseline costs 0.2 (Buchheit 2014:
        // deviations beyond the baseline's own noise are the signal).
        let score = min(1, max(0, 0.9 + 0.2 * min(0.5, max(-3.5, z))))
        let swc = 0.5 * (sd / max(mean, 1)) * mean   // smallest worthwhile change (Plews 2013)
        let within = abs(avg7 - mean) <= max(swc, 0.5)
        return ScorePart(
            name: "HRV",
            state: .ready(score),
            valueText: "\(Int(avg7.rounded())) ms",
            detailText: within
                ? "7-day avg, within your normal range (baseline \(Int(mean.rounded())) ms)"
                : "7-day avg vs \(Int(mean.rounded())) ms baseline"
        )
    }

    private func rhrPart() -> ScorePart {
        guard let current = latestHealthMetric(), let restingHR = current.restingHR else {
            return ScorePart(name: "Resting HR", state: .building("No recent resting heart rate"),
                             valueText: "—", detailText: "Connect Apple Health or wear your watch")
        }
        let baseline = baselineMetrics(days: 60)
            .filter { calendarDaysBetween($0.date, and: now) > 7 }
            .compactMap { $0.restingHR.map(Double.init) }
        guard baseline.count >= 14 else {
            return ScorePart(name: "Resting HR", state: .building("Baseline building — \(14 - baseline.count) more days"),
                             valueText: "\(restingHR) bpm", detailText: "Needs ~2 weeks for a fair baseline")
        }
        let mean = average(baseline) ?? Double(restingHR)
        let sd = max(standardDeviation(baseline), max(2, mean * 0.03))
        let z = (Double(restingHR) - mean) / sd     // elevated = worse
        let score = min(1, max(0, 0.9 - 0.2 * min(3.5, max(-0.5, z))))
        return ScorePart(
            name: "Resting HR",
            state: .ready(score),
            valueText: "\(restingHR) bpm",
            detailText: "Baseline \(Int(mean.rounded())) bpm"
        )
    }

    private func sleepPart() -> ScorePart {
        guard let current = latestHealthMetric(), let sleep = current.sleepTotalMinutes else {
            return ScorePart(name: "Sleep", state: .building("No sleep data from last night"),
                             valueText: "—", detailText: "Wear your watch to bed or log sleep in Health")
        }
        let need = max(300, current.sleepNeedMinutes)
        let ratio = Double(sleep) / Double(need)
        // ≥95% of need scores full marks; each missing hour below that costs
        // steeply (dose-response between sleep restriction and performance,
        // Fullagar 2015).
        var score = ratio >= 0.95 ? 1.0 : max(0.3, 1.0 - (0.95 - ratio) * 2.0)
        let debt = recentHealthMetrics(days: 7).reduce(0.0) { total, metric in
            guard let s = metric.sleepTotalMinutes else { return total }
            return total + Double(max(0, metric.sleepNeedMinutes - s)) / 60
        }
        score -= min(0.25, max(0, debt - 1) * 0.05)
        score = min(1, max(0, score))
        let hours = Double(sleep) / 60
        return ScorePart(
            name: "Sleep",
            state: .ready(score),
            valueText: "\(hours.formatted(.number.precision(.fractionLength(1)))) h",
            detailText: debt > 1
                ? "7-day debt \(debt.formatted(.number.precision(.fractionLength(1)))) h"
                : "Meeting your sleep need"
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
        let ratio = acute / chronic
        var score: Double = switch ratio {
        case ..<0.8: 0.95        // fresh / tapered
        case ..<1.3: 0.85        // balanced
        case ..<1.5: 0.65        // elevated
        case ..<2.0: 0.65 - (ratio - 1.5) * 0.6   // 1.5→0.65 … 2.0→0.35
        default: 0.3
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
                ? "Recovered from recent intervals — another quality session is on the table."
                : "High-intensity work suppresses the nervous system for 48–72 h. Zone 2 is fine; wait on the next hard interval day."
        case .threshold:
            return score >= 0.8
                ? "Threshold work has cleared — train as planned."
                : "Threshold sessions need about a day or two. Easy cardio today keeps the engine warm."
        case .easy:
            return "Low-intensity cardio clears within a day and can be done near-daily."
        case nil:
            return "No cardio in the last week — fully fresh on this front."
        }
    }

    // MARK: - Small math helpers

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1, let mean = average(values) else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }
}
