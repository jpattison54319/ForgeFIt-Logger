import Foundation
import ForgeCore
import ForgeData

/// Pure readiness math for the Today and Recovery screens. The score is
/// action-oriented: load math, biometrics, and per-muscle freshness explain
/// what to do today instead of pretending any one metric predicts injury.
struct RecoveryEngine {
    let workouts: [WorkoutModel]
    var exercises: [ExerciseLibraryModel] = []
    var healthMetrics: [DailyHealthMetric] = []
    /// Extra full-day signals (respiratory, SpO₂, VO₂max…) appended to the
    /// report's signal list — informational, not scored.
    var supplementalSignals: [Signal] = []
    /// Today's morning check-in tag ids (slept-badly, sore, stressed,
    /// alcohol, sick, feeling-great). Surfaced as reason chips beside the
    /// biometrics — deliberately NOT scored: subjective context explains the
    /// number, it doesn't move it.
    var todayCheckinTags: [String] = []
    var targetMuscles: [String] = []
    var calendar = Calendar.current
    var now = Date()

    enum Action: String, Equatable {
        case push
        case trainAsPlanned
        case reduceVolume
        case deloadRecover

        var title: String {
            switch self {
            case .push: "Push"
            case .trainAsPlanned: "Train as planned"
            case .reduceVolume: "Reduce volume"
            case .deloadRecover: "Deload/recover"
            }
        }

        var systemImage: String {
            switch self {
            case .push: "bolt.fill"
            case .trainAsPlanned: "checkmark.circle.fill"
            case .reduceVolume: "dial.low.fill"
            case .deloadRecover: "moon.zzz.fill"
            }
        }
    }

    enum ReasonTone: Equatable {
        case positive, caution, neutral
    }

    /// User-visible provenance for a night resolved through Home's sleep
    /// integrity affordance. This stays separate from data-quality flags so
    /// Recovery can distinguish an edit from a confirmation or exclusion.
    enum SleepOverrideStatus: Equatable {
        case confirmed
        case edited
        case notTracked

        var label: String {
            switch self {
            case .confirmed: "Confirmed"
            case .edited: "Edited"
            case .notTracked: "Not tracked"
            }
        }

        var systemImage: String {
            switch self {
            case .confirmed: "checkmark"
            case .edited: "pencil"
            case .notTracked: "eye.slash"
            }
        }

        var detailPrefix: String {
            switch self {
            case .confirmed: "Confirmed by you"
            case .edited: "Edited by you"
            case .notTracked: "Excluded by you"
            }
        }
    }

    struct DailyHealthMetric {
        var date: Date
        var hrvSDNN: Double?
        var hrvRMSSD: Double?
        var restingHR: Int?
        var respiratoryRate: Double?
        /// Stored as percentage points (for example, 97.0), rather than
        /// HealthKit's fractional percent representation.
        var oxygenSaturationPercent: Double?
        var sleepTotalMinutes: Int?
        var sleepNeedMinutes: Int = 480
        var source: String?
        var hrvSampleCount: Int?
        var dataQualityFlags: [String] = []
        /// HRV averaged over the sleep window only — the validated nocturnal
        /// measurement window (supine, stable, no daytime confounds; Plews 2013,
        /// Buchheit 2014). Preferred over the all-day `hrvSDNN`/`hrvRMSSD` mean
        /// when present.
        var nocturnalHRV: Double?
        /// Mean heart rate during sleep — a cleaner overnight autonomic signal
        /// than Apple's daytime-derived resting heart rate. Preferred over
        /// `restingHR` when present.
        var sleepingHR: Int?
        /// Nocturnal heart-rate sample count — coverage of the sleep window.
        /// A partial-wear night yields far fewer than a full night, and a
        /// short fragment can't be trusted for a mean sleeping HR (see
        /// `SleepIntegrity`).
        var sleepingHRSampleCount: Int?
        /// Merged sleep-window bounds for the night. Their deviation from the
        /// user's habitual bed/wake anchors is what separates a true short
        /// night (normal anchors, dense samples) from a partial-wear gap
        /// (window starts hours late or ends hours early).
        var sleepStart: Date?
        var sleepEnd: Date?
        /// Sleep-stage breakdown (Apple Watch and most modern wearables write
        /// staged samples). Informational — total minutes drive the score;
        /// stages explain the quality of that total. Nil when the source only
        /// writes unstaged "asleep" samples.
        var sleepDeepMinutes: Int?
        var sleepREMMinutes: Int?
        var sleepAwakeMinutes: Int?
        /// The exact Home action applied to this night. Unlike
        /// `sleepUserCorrected`, this preserves which correction was chosen so
        /// Recovery can explain the resulting value honestly.
        var sleepOverride: SleepNightOverride?
        /// Data-integrity markers stamped by `SleepIntegrity.annotate` and the
        /// user's own corrections (`SleepOverrideStore`). Read by the sleep
        /// scoring, the sleep-debt sum, and the baseline filters so a
        /// low-integrity or manually-corrected night can't masquerade as a
        /// measured recovery deficit or contaminate the baselines.
        var integrityFlags: Set<String> = []

        /// A night the app has flagged as probable partial-wear capture —
        /// present-but-untrustworthy sleep data (see `SleepIntegrity`).
        var sleepLikelyPartial: Bool { integrityFlags.contains(SleepIntegrity.Flag.partialWear) }
        /// The user resolved this night by hand: confirmed the data, entered a
        /// duration, or marked it untracked. Corrected nights are trusted for
        /// today's score but never feed the rolling baselines.
        var sleepUserCorrected: Bool { integrityFlags.contains(SleepIntegrity.Flag.userCorrected) }
        var sleepOverrideStatus: SleepOverrideStatus? {
            switch sleepOverride {
            case .confirmed: .confirmed
            case .manual: .edited
            case .untracked: .notTracked
            case nil: nil
            }
        }
        /// Whether this night's sleep may drive scoring, debt, and baselines.
        /// Partial-wear nights that the user hasn't corrected are excluded.
        var sleepIsTrustworthy: Bool { !sleepLikelyPartial || sleepUserCorrected }

        /// Best HRV signal: nocturnal window first, then all-day RMSSD/SDNN.
        /// On a partial-wear night the short nocturnal fragment is circadian-
        /// biased (a 5am window reads a flatteringly high HRV), so it's skipped
        /// in favor of the all-day mean.
        var bestHRV: Double? {
            (sleepIsTrustworthy ? nocturnalHRV : nil) ?? hrvRMSSD ?? hrvSDNN
        }
        /// Best overnight-cardiac signal: sleeping HR first, then all-day
        /// resting HR. A partial-wear fragment is dropped in favor of Apple's
        /// all-day resting HR, which is computed independently of the fragment.
        var bestRestingHR: Int? {
            (sleepIsTrustworthy ? sleepingHR : nil) ?? restingHR
        }
    }

    struct ReasonChip: Identifiable, Equatable {
        var id: String { text }
        let text: String
        let tone: ReasonTone
    }

    struct Signal: Identifiable {
        var id: String { name }
        let name: String
        let systemImage: String
        let value: String
        let detail: String
        let connected: Bool
    }

    struct SubScore: Identifiable {
        var id: String { name }
        let name: String
        let value: String
        let score: Double        // 0...1 for the ring
        let caption: String
    }

    struct MuscleFreshness: Identifiable {
        var id: String { muscle }
        let muscle: String
        let daysAgo: Int?        // nil = not trained in window
    }

    struct Report {
        var score: Double            // 0...1 overall readiness
        var confidence: Double       // 0...1 data completeness
        var verdict: TodayVerdict
        var trainingLoad: TrainingLoadComparison
        var monotony: Double?
        var strain: Double?
        var daysSinceLast: Int?
        var usedRMSSD: Bool
        var missingInputs: [String]
        var reasonChips: [ReasonChip]
        var subScores: [SubScore]
        var muscleFreshness: [MuscleFreshness]
        var insights: [String]
        var signals: [Signal]
        /// Evidence-based recovery scores (see RecoveryScores.swift for the model
        /// and citations): an acute daily-readiness score, a chronic recovery
        /// trend, and per-muscle / cardio scores.
        var recovery: RecoverySnapshot

        /// The headline the user acts on: the acute **daily readiness** (today's
        /// nocturnal autonomic state + last night's sleep) when enough data backs
        /// it, then the chronic trend, then the legacy composite. Acute-first so
        /// the number always moves with — and agrees with — the day's guidance.
        var displayScore: Double {
            recovery.daily.state.value ?? recovery.systemic.state.value ?? score
        }

        var action: Action { verdict.action }
        var headline: String { verdict.action.title }
        var recommendation: String { verdict.recommendation }
        var preWorkoutAdjustment: String { verdict.preWorkoutAdjustment }
        var acuteLoad: Double { trainingLoad.recentLoad }
        var chronicLoad: Double { trainingLoad.baselineWeeklyLoad }
        var strengthLoad: Double { trainingLoad.recentStrengthLoad }
        var cardioLoad: Double { trainingLoad.recentCardioLoad }
        var loadRatio: Double? { trainingLoad.ratio }

        /// The slow-moving chronic recovery trend (7-day), shown as context
        /// beside the daily number. Nil until it has enough history.
        var trendScore: Double? { recovery.systemic.state.value }

        /// True once an evidence-based score backs `displayScore` (the acute
        /// daily readiness or the chronic trend). Surfaces gate the score on
        /// this, never on `confidence` — confidence also dips when today's
        /// inputs are incomplete (sleep not yet synced at 1am), which is not
        /// the same as a baseline still being built, and gating on it made
        /// Home claim "building" while the Recovery screen showed a score.
        var baselineReady: Bool {
            recovery.daily.state.value != nil || recovery.systemic.state.value != nil
        }
    }

    private struct LoadAssessment {
        var status: String
        var score: Double
        var isAboveBaseline: Bool
        var isBelowBaseline: Bool
    }

    private struct MuscleAssessment {
        var score: Double
        var adjustment: Double
        var hasRecentTarget: Bool
        var hasTrainableTarget: Bool
        var chips: [ReasonChip]
    }

    private struct BiometricAssessment {
        var status: String
        var score: Double
        var adjustment: Double
        var confidence: Double
        /// 0...1 completeness across the three expected morning signals
        /// (HRV, resting HR, sleep). A fully missing signal counts as 0 —
        /// unlike `confidence`, which only graded the signals that were
        /// present and so read 100% even when sleep was absent.
        var completeness: Double
        var usedRMSSD: Bool
        var sustainedLowHRV: Bool
        var singleLowHRV: Bool
        var elevatedRHR: Bool
        var poorSleep: Bool
        var missing: [String]
        var chips: [ReasonChip]
        var signals: [Signal]
    }

    private var trainingLoadCalculator: TrainingLoadCalculator {
        TrainingLoadCalculator(workouts: workouts, calendar: calendar, now: now)
    }

    var completed: [WorkoutModel] {
        trainingLoadCalculator.completedWorkouts
    }

    var exerciseByID: [UUID: ExerciseLibraryModel] {
        Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Calendar-day difference (yesterday evening → this morning = 1 day).
    /// `dateComponents([.day], from:to:)` on raw dates counts full 24-hour
    /// periods, which made a workout logged yesterday at 8pm read as
    /// "trained today" the next morning.
    func calendarDaysBetween(_ date: Date, and reference: Date) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: reference)
        ).day ?? 0
    }

    func sessionLoad(_ workout: WorkoutModel) -> Double {
        trainingLoadCalculator.sessionEstimate(workout).total
    }

    func report() -> Report {
        let trainingLoad = trainingLoadCalculator.comparison()

        let daily = dailyLoads(days: 7)
        let monotony = monotony(daily)
        let strain = monotony.map { $0 * daily.reduce(0, +) }

        let daysSinceLast = completed
            .map { calendarDaysBetween($0.startedAt, and: now) }
            .min()

        let muscles = muscleFreshness()
        let load = loadAssessment(trainingLoad)
        let muscle = muscleAssessment(freshness: muscles, daysSinceLast: daysSinceLast)
        let biometric = biometricAssessment()

        var score = 0.62 + muscle.adjustment + biometric.adjustment
        if completed.isEmpty { score = 0.64 + biometric.adjustment }
        score = min(1, max(0, score))

        // The action must agree with the number the user actually sees: the
        // acute daily readiness drives the ring AND the recommendation (then
        // the chronic trend, then the legacy composite — same chain as
        // `displayScore`). A green 72 must never caption itself "Deload"
        // unless the user explicitly reports being sick.
        let snapshot = recoverySnapshot()
        let effectiveScore = snapshot.daily.state.value ?? snapshot.systemic.state.value ?? score
        let verdict = TodayVerdict.make(score: effectiveScore, checkinTags: todayCheckinTags)
        let chips = reasonChips(
            muscle: muscle,
            biometric: biometric,
            daysSinceLast: daysSinceLast,
            acuteFlags: snapshot.daily.flags
        )

        // Training load is now descriptive context and cannot inflate the
        // confidence of a readiness recommendation. Confidence follows the
        // completeness of the health signals that actually drive that call.
        let confidence = min(1, max(0.1, biometric.completeness))

        return Report(
            score: score,
            confidence: confidence,
            verdict: verdict,
            trainingLoad: trainingLoad,
            monotony: monotony,
            strain: strain,
            daysSinceLast: daysSinceLast,
            usedRMSSD: biometric.usedRMSSD,
            missingInputs: biometric.missing,
            reasonChips: chips,
            subScores: subScores(load: load, muscle: muscle, biometric: biometric),
            muscleFreshness: muscles,
            insights: insights(load: load, muscle: muscle, biometric: biometric, daysSinceLast: daysSinceLast),
            signals: biometric.signals + supplementalSignals,
            recovery: snapshot
        )
    }

    func durationMinutes(_ workout: WorkoutModel) -> Double {
        trainingLoadCalculator.durationMinutes(workout)
    }

    func healthWorkoutLooksStrengthLike(_ workout: WorkoutModel) -> Bool {
        trainingLoadCalculator.looksStrengthLike(workout)
            || trainingLoadCalculator.looksMindBodyLike(workout)
    }

    func dailyLoads(days: Int) -> [Double] {
        trainingLoadCalculator.dailyLoads(days: days)
    }

    func monotony(_ daily: [Double]) -> Double? {
        let mean = daily.reduce(0, +) / Double(daily.count)
        guard mean > 0 else { return nil }
        let variance = daily.map { pow($0 - mean, 2) }.reduce(0, +) / Double(daily.count)
        let sd = sqrt(variance)
        guard sd > 0 else { return nil }
        return mean / sd
    }

    private func loadAssessment(_ comparison: TrainingLoadComparison) -> LoadAssessment {
        guard let ratio = comparison.ratio else {
            let status = switch comparison.state {
            case .noRecentLoad: "No prior load"
            case .sparseBaseline: "Baseline too light"
            case .building, .ready: "\(comparison.baselineDaysAvailable)/28 days"
            }
            return LoadAssessment(
                status: status,
                score: 0.5,
                isAboveBaseline: false,
                isBelowBaseline: false
            )
        }

        let isAbove = ratio > 1.10
        let isBelow = ratio < 0.90
        let status = isAbove ? "Above baseline" : (isBelow ? "Below baseline" : "Near baseline")
        let closeness = max(0, 1 - abs(ratio - 1) / 2)
        return LoadAssessment(
            status: status,
            score: closeness,
            isAboveBaseline: isAbove,
            isBelowBaseline: isBelow
        )
    }

    /// Days since each major muscle was last trained.
    private func muscleFreshness() -> [MuscleFreshness] {
        let byID = exerciseByID
        var lastTrained: [String: Date] = [:]
        for w in completed {
            for we in w.exercises {
                guard let ex = byID[we.exerciseID], we.sets.contains(where: { $0.completedAt != nil }) else { continue }
                for muscle in ex.primaryMuscles {
                    if let existing = lastTrained[muscle] { lastTrained[muscle] = max(existing, w.startedAt) }
                    else { lastTrained[muscle] = w.startedAt }
                }
            }
        }
        let tracked = ["chest", "lats", "shoulders", "quadriceps", "hamstrings", "glutes", "biceps", "triceps"]
        return tracked.map { muscle in
            let days = lastTrained[muscle].map { calendarDaysBetween($0, and: now) }
            return MuscleFreshness(muscle: muscle, daysAgo: days)
        }
    }

    private func muscleAssessment(freshness: [MuscleFreshness], daysSinceLast: Int?) -> MuscleAssessment {
        let targetSet = Set(targetMuscles.map { $0.lowercased() })
        let relevant = targetSet.isEmpty ? freshness : freshness.filter { targetSet.contains($0.muscle.lowercased()) }

        let recent = relevant.filter { ($0.daysAgo ?? 99) < 2 }
        let trainable = relevant.filter { ($0.daysAgo ?? 99) >= 2 }
        var chips: [ReasonChip] = []
        var adjustment = 0.0
        var score = 0.62

        if let daysSinceLast {
            if daysSinceLast >= 2 {
                adjustment += 0.06
                score = 0.82
                chips.append(ReasonChip(text: "48h recovered", tone: .positive))
            } else if daysSinceLast == 0 {
                adjustment -= 0.05
                chips.append(ReasonChip(text: "Trained today", tone: .caution))
            }
            if daysSinceLast >= 4 {
                adjustment -= 0.03
                chips.append(ReasonChip(text: "\(daysSinceLast)d since workout", tone: .neutral))
            }
        } else {
            chips.append(ReasonChip(text: "Start easy", tone: .neutral))
        }

        if let firstRecent = recent.sorted(by: { ($0.daysAgo ?? 99) < ($1.daysAgo ?? 99) }).first {
            adjustment -= targetSet.isEmpty ? 0.02 : 0.10
            score = min(score, targetSet.isEmpty ? 0.65 : 0.45)
            chips.append(ReasonChip(text: "\(firstRecent.muscle.capitalized) trained \(firstRecent.daysAgo == 0 ? "today" : "yesterday")", tone: .caution))
        }

        if let freshest = trainable.sorted(by: { ($0.daysAgo ?? -1) > ($1.daysAgo ?? -1) }).first,
           let days = freshest.daysAgo, days >= 3 {
            adjustment += targetSet.isEmpty ? 0.03 : 0.07
            score = max(score, 0.78)
            // Naming one muscle only makes sense when the picture is mixed —
            // when everything trained is recovered, singling out the
            // longest-rested one ("Triceps fresh") reads as arbitrary.
            let trained = relevant.filter { $0.daysAgo != nil }
            let allFresh = recent.isEmpty && trained.allSatisfy { ($0.daysAgo ?? 0) >= 3 }
            if allFresh, trained.count > 1 {
                chips.append(ReasonChip(text: "All muscles fresh", tone: .positive))
            } else {
                chips.append(ReasonChip(text: "\(freshest.muscle.capitalized) fresh", tone: .positive))
            }
        }

        return MuscleAssessment(
            score: min(1, max(0, score)),
            adjustment: adjustment,
            hasRecentTarget: !recent.isEmpty,
            hasTrainableTarget: !trainable.isEmpty,
            chips: chips
        )
    }

    private func biometricAssessment() -> BiometricAssessment {
        let current = latestHealthMetric()
        var missing: [String] = []
        var chips: [ReasonChip] = []
        var signals: [Signal] = []
        var adjustment = 0.0
        var score = 0.74
        var status = "Missing"
        var usedRMSSD = false
        var sustainedLowHRV = false
        var singleLowHRV = false
        var elevatedRHR = false
        var poorSleep = false
        var confidenceParts = 0.0
        var availableParts = 0.0
        // Completeness points over a fixed denominator of 3 signals: a present
        // signal with a usable baseline earns 1, present-but-baseline-building
        // earns 0.5, a fully missing signal earns 0.
        var completenessPoints = 0.0

        if let current {
            let hrvValue = acuteComparableHRV(for: current)
            usedRMSSD = current.hrvRMSSD != nil
            if let hrvValue {
                availableParts += 1
                let baseline = baselineHRVValues(preferRMSSD: usedRMSSD)
                if baseline.count >= 7 {
                    confidenceParts += 1
                    completenessPoints += 1
                    let mean = average(baseline) ?? hrvValue
                    let lowCutoff = mean * 0.90
                    let recent = recentHealthMetrics(days: 3)
                    let lowRecent = recent.compactMap { metric -> Bool? in
                        acuteComparableHRV(for: metric).map { $0 < lowCutoff }
                    }.filter { $0 }.count
                    singleLowHRV = hrvValue < lowCutoff
                    sustainedLowHRV = singleLowHRV && lowRecent >= 2
                    if sustainedLowHRV {
                        adjustment -= 0.16
                        score = min(score, 0.46)
                        chips.append(ReasonChip(text: "HRV low trend", tone: .caution))
                    } else if singleLowHRV {
                        adjustment -= 0.05
                        score = min(score, 0.66)
                        chips.append(ReasonChip(text: "HRV low today", tone: .caution))
                    } else {
                        adjustment += 0.04
                        chips.append(ReasonChip(text: "HRV normal", tone: .positive))
                    }
                    // Trend beats a single reading: show the 7-day rolling
                    // average against the longer baseline (Plews et al. 2013).
                    let rolling = recentHealthMetrics(days: 7).compactMap { acuteComparableHRV(for: $0) }
                    let avg7 = average(rolling) ?? hrvValue
                    signals.append(Signal(
                        name: "HRV",
                        systemImage: "waveform.path.ecg",
                        value: "\(Int(hrvValue.rounded())) ms",
                        detail: "7-day avg \(Int(avg7.rounded())) ms vs \(Int(mean.rounded())) ms baseline (\(usedRMSSD ? "RMSSD" : "SDNN"))",
                        connected: true
                    ))
                } else {
                    missing.append("HRV baseline")
                    completenessPoints += 0.5
                    chips.append(ReasonChip(text: "HRV baseline building", tone: .neutral))
                    signals.append(Signal(name: "HRV", systemImage: "waveform.path.ecg",
                                          value: "\(Int(hrvValue.rounded())) ms", detail: "Need more mornings for baseline", connected: true))
                }
            } else {
                missing.append("HRV")
                // A nocturnal user past midnight is connected — the night
                // just isn't in yet.
                signals.append(Signal(
                    name: "HRV", systemImage: "waveform.path.ecg", value: "-",
                    detail: usesNocturnalHRV ? "No overnight HRV yet" : "Connect Apple Health",
                    connected: usesNocturnalHRV
                ))
            }

            if let heartRate = restingHRChannel(for: current) {
                let restingHR = heartRate.value
                availableParts += 1
                let baseline = heartRate.baseline
                if baseline.count >= 7 {
                    confidenceParts += 1
                    completenessPoints += 1
                    let mean = average(baseline) ?? Double(restingHR)
                    let highCutoff = mean + max(5, mean * 0.08)
                    elevatedRHR = Double(restingHR) > highCutoff
                    if elevatedRHR {
                        adjustment -= 0.12
                        score = min(score, 0.55)
                        chips.append(ReasonChip(text: "RHR elevated", tone: .caution))
                    } else {
                        chips.append(ReasonChip(text: "RHR normal", tone: .positive))
                    }
                    signals.append(Signal(name: "Resting HR", systemImage: "heart.fill",
                                          value: "\(restingHR)", detail: "Baseline \(Int(mean.rounded())) bpm", connected: true))
                } else {
                    missing.append("RHR baseline")
                    completenessPoints += 0.5
                    signals.append(Signal(name: "Resting HR", systemImage: "heart.fill",
                                          value: "\(restingHR)", detail: "Need more mornings for baseline", connected: true))
                }
            } else {
                missing.append("Resting HR")
                signals.append(Signal(name: "Resting HR", systemImage: "heart.fill", value: "-", detail: "Connect Apple Health", connected: false))
            }

            if current.sleepOverrideStatus == .notTracked {
                // The absence is intentional, not a sync failure or partial
                // capture. Keep it out of scoring while reflecting the user's
                // decision everywhere Recovery explains today's inputs.
                missing.append("Sleep (excluded by you)")
                chips.append(ReasonChip(text: "Sleep excluded by you", tone: .neutral))
                signals.append(Signal(
                    name: "Sleep",
                    systemImage: "bed.double.fill",
                    value: "-",
                    detail: "Not tracked for this night at your request",
                    connected: true
                ))
            } else if let sleep = current.sleepTotalMinutes, !current.sleepIsTrustworthy {
                // Partial-wear capture: a fragment, not last night's real sleep.
                // Degrade to a labeled gap — no penalty, no cap, no debt — so a
                // data hole never masquerades as a recovery deficit. Confidence
                // falls (sleep is absent from the blend) and the user gets a
                // one-tap correction on Home (see SleepIntegrityCard).
                missing.append("Sleep (partial)")
                chips.append(ReasonChip(text: "Sleep data looks partial", tone: .neutral))
                signals.append(Signal(name: "Sleep", systemImage: "bed.double.fill",
                                      value: "~\(minutesLabel(sleep))",
                                      detail: "Only part of the night tracked", connected: false))
            } else if let sleep = current.sleepTotalMinutes {
                availableParts += 1
                confidenceParts += 1
                completenessPoints += 1
                let need = max(300, current.sleepNeedMinutes)
                let debt = sleepDebtHours()
                poorSleep = sleep < need - 90 || debt >= 5
                if poorSleep {
                    adjustment -= 0.14
                    score = min(score, 0.52)
                    chips.append(ReasonChip(text: "Sleep debt", tone: .caution))
                } else if sleep < need - 45 || debt >= 2 {
                    adjustment -= 0.06
                    chips.append(ReasonChip(text: "Sleep slightly short", tone: .caution))
                } else {
                    adjustment += 0.03
                    chips.append(ReasonChip(text: "Sleep okay", tone: .positive))
                }
                var sleepDetail = "Debt \(debt.formatted(.number.precision(.fractionLength(1))))h"
                if let deep = current.sleepDeepMinutes, let rem = current.sleepREMMinutes, deep + rem > 0 {
                    sleepDetail = "\(minutesLabel(deep)) deep · \(minutesLabel(rem)) REM · " + sleepDetail.lowercased()
                }
                if let status = current.sleepOverrideStatus {
                    sleepDetail = "\(status.detailPrefix) · \(sleepDetail.lowercased())"
                }
                signals.append(Signal(name: "Sleep", systemImage: "bed.double.fill",
                                      value: minutesLabel(sleep), detail: sleepDetail, connected: true))
            } else {
                missing.append("Sleep")
                signals.append(Signal(name: "Sleep", systemImage: "bed.double.fill", value: "-", detail: "Connect Apple Health", connected: false))
            }
        } else {
            missing = ["HRV", "Resting HR", "Sleep"]
            signals.append(Signal(name: "HRV", systemImage: "waveform.path.ecg", value: "-", detail: "Connect Apple Health", connected: false))
            signals.append(Signal(name: "Resting HR", systemImage: "heart.fill", value: "-", detail: "Connect Apple Health", connected: false))
            signals.append(Signal(name: "Sleep", systemImage: "bed.double.fill", value: "-", detail: "Connect Apple Health", connected: false))
            chips.append(ReasonChip(text: "Biometrics missing", tone: .neutral))
        }

        if availableParts > 0 {
            status = score >= 0.68 ? "Normal" : (score >= 0.52 ? "Caution" : "Low")
        }
        let confidence = availableParts == 0 ? 0 : confidenceParts / max(availableParts, 1)
        return BiometricAssessment(
            status: status,
            score: min(1, max(0, score)),
            adjustment: adjustment,
            confidence: confidence,
            completeness: completenessPoints / 3,
            usedRMSSD: usedRMSSD,
            sustainedLowHRV: sustainedLowHRV,
            singleLowHRV: singleLowHRV,
            elevatedRHR: elevatedRHR,
            poorSleep: poorSleep,
            missing: missing,
            chips: chips,
            signals: signals
        )
    }

    private func reasonChips(
        muscle: MuscleAssessment,
        biometric: BiometricAssessment,
        daysSinceLast: Int?,
        acuteFlags: [String] = []
    ) -> [ReasonChip] {
        // Acute daily-readiness flags lead: they use the same banding as the
        // headline score, so the chips can't disagree with the number. The
        // legacy "HRV normal" chip is dropped when the acute read says low.
        let acute = acuteFlags.map { ReasonChip(text: $0, tone: .caution) }
        var biometricChips = biometric.chips
        if acuteFlags.contains("HRV low today") {
            biometricChips.removeAll { $0.text == "HRV normal" }
        }
        if acuteFlags.contains("Sleeping HR elevated") {
            biometricChips.removeAll { $0.text == "RHR normal" }
        }
        let checkin = todayCheckinTags.compactMap(Self.checkinChip(for:))
        var chips = acute + checkin + muscle.chips + biometricChips
        if chips.isEmpty, let daysSinceLast, daysSinceLast >= 2 {
            chips.append(ReasonChip(text: "48h recovered", tone: .positive))
        }
        chips = removeRedundantTodayTrainingChips(chips)
        var seen = Set<String>()
        return chips.filter { seen.insert($0.text).inserted }.prefix(6).map { $0 }
    }

    /// Chip text/tone for a morning check-in tag id; nil for unknown ids.
    static func checkinChip(for tag: String) -> ReasonChip? {
        switch tag {
        case "feeling-great": ReasonChip(text: "Feeling great", tone: .positive)
        case "slept-badly": ReasonChip(text: "Felt: slept badly", tone: .caution)
        case "sore": ReasonChip(text: "Felt: sore", tone: .caution)
        case "stressed": ReasonChip(text: "Felt: stressed", tone: .caution)
        case "alcohol": ReasonChip(text: "Alcohol last night", tone: .caution)
        case "sick": ReasonChip(text: "Feeling sick", tone: .caution)
        default: nil
        }
    }

    private func removeRedundantTodayTrainingChips(_ chips: [ReasonChip]) -> [ReasonChip] {
        let hasSpecificToday = chips.contains { chip in
            let text = chip.text.lowercased()
            return text.hasSuffix(" trained today") && text != "trained today"
        }
        let hasGenericToday = chips.contains { $0.text.caseInsensitiveCompare("Trained today") == .orderedSame }

        guard hasSpecificToday || hasGenericToday else { return chips }
        return chips.filter { chip in
            let text = chip.text.lowercased()
            if hasSpecificToday, text == "trained today" { return false }
            if text == "last trained today" { return false }
            return true
        }
    }

    private func subScores(load: LoadAssessment, muscle: MuscleAssessment, biometric: BiometricAssessment) -> [SubScore] {
        [
            SubScore(name: "Load context", value: load.status, score: load.score, caption: "Descriptive only"),
            SubScore(name: "Body signals", value: biometric.status, score: biometric.score, caption: biometric.missing.isEmpty ? "Baseline read" : "Partial data"),
            SubScore(name: "Muscles", value: muscle.hasTrainableTarget ? "48h+" : "Check", score: muscle.score, caption: muscle.hasRecentTarget ? "Recently trained" : "Local recovery")
        ]
    }

    private func insights(load: LoadAssessment, muscle: MuscleAssessment, biometric: BiometricAssessment, daysSinceLast: Int?) -> [String] {
        var out: [String] = []
        if load.isAboveBaseline {
            out.append("The last 7 days are above your prior 4-week average. This is context only and does not change readiness.")
        } else if load.isBelowBaseline {
            out.append("The last 7 days are below your prior 4-week average. This is context only and does not change readiness.")
        }
        if biometric.sustainedLowHRV {
            out.append("HRV has been below baseline across multiple readings; it is one input to today’s verdict.")
        } else if biometric.singleLowHRV, daysSinceLast.map({ $0 >= 2 }) == true {
            out.append("A single low HRV reading after 48h off is a caution flag, not an automatic rest day.")
        }
        if biometric.elevatedRHR { out.append("Resting heart rate is elevated versus baseline, so keep an eye on warmup feel.") }
        if biometric.poorSleep { out.append("Sleep debt is elevated and contributes context to today’s verdict.") }
        if muscle.hasRecentTarget {
            out.append("At least one relevant muscle was trained within 48h; see its local recovery and weekly-set context above.")
        }
        let trained = muscleFreshness().filter { $0.daysAgo != nil }
        if !trained.isEmpty, trained.allSatisfy({ ($0.daysAgo ?? 0) >= 3 }), trained.count > 1 {
            out.append("Every tracked muscle has had 3+ days since direct work.")
        } else if let fresh = trained.max(by: { ($0.daysAgo ?? 0) < ($1.daysAgo ?? 0) }),
                  let d = fresh.daysAgo, d >= 3 {
            out.append("\(fresh.muscle.capitalized) has had \(d) days since direct work.")
        }
        if let d = daysSinceLast, d >= 4 { out.append("It has been \(d) days since your last workout.") }
        if out.isEmpty { out.append("Everything looks balanced. Keep logging to sharpen these insights.") }
        return out
    }

    func latestHealthMetric() -> DailyHealthMetric? {
        let today = calendar.startOfDay(for: now)
        return healthMetrics
            .filter { metric in
                let day = calendar.startOfDay(for: metric.date)
                guard day <= today else { return false }
                let age = calendar.dateComponents([.day], from: day, to: today).day ?? 99
                return age <= 2
            }
            .sorted { $0.date > $1.date }
            .first
    }

    func recentHealthMetrics(days: Int) -> [DailyHealthMetric] {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return [] }
        return healthMetrics.filter { $0.date >= cutoff && $0.date <= now }.sorted { $0.date > $1.date }
    }

    /// True when this user's HRV history is overnight readings — the channel
    /// every today-vs-baseline comparison must stick to. Awake readings only
    /// stand in for users with no nocturnal history at all (no sleep
    /// tracking), where awake-vs-awake is apples-to-apples.
    var usesNocturnalHRV: Bool {
        baselineMetrics(days: 60)
            .filter { $0.sleepIsTrustworthy && !$0.sleepUserCorrected && $0.nocturnalHRV != nil }
            .count >= 14
    }

    /// A day's HRV for baseline comparisons, channel-pure. Apple samples
    /// awake HRV around the clock, so just past midnight the new day already
    /// holds an awake spot reading while nocturnal HRV doesn't exist yet —
    /// and "awake at 1am" scored against a sleeping baseline reads as a
    /// crashed HRV (the 1am bug, HRV edition).
    func acuteComparableHRV(for metric: DailyHealthMetric) -> Double? {
        if usesNocturnalHRV {
            guard metric.sleepIsTrustworthy else { return nil }
            return metric.nocturnalHRV
        }
        return metric.hrvRMSSD ?? metric.hrvSDNN
    }

    private func baselineHRVValues(preferRMSSD: Bool) -> [Double] {
        _ = preferRMSSD
        return baselineMetrics(days: 60)
            .filter { !$0.sleepUserCorrected }
            .compactMap { acuteComparableHRV(for: $0) }
    }

    private func restingHRChannel(
        for current: DailyHealthMetric
    ) -> (value: Int, baseline: [Double])? {
        let history = baselineMetrics(days: 60).filter { !$0.sleepUserCorrected }
        let sleepingBaseline = history
            .filter(\.sleepIsTrustworthy)
            .compactMap { $0.sleepingHR.map(Double.init) }
        if current.sleepIsTrustworthy,
           let value = current.sleepingHR,
           sleepingBaseline.count >= 7 {
            return (value, sleepingBaseline)
        }

        let restingBaseline = history.compactMap { $0.restingHR.map(Double.init) }
        if let value = current.restingHR {
            return (value, restingBaseline)
        }
        if current.sleepIsTrustworthy, let value = current.sleepingHR {
            return (value, sleepingBaseline)
        }
        return nil
    }

    func baselineMetrics(days: Int) -> [DailyHealthMetric] {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: today) else { return [] }
        return healthMetrics.filter { metric in
            let day = calendar.startOfDay(for: metric.date)
            return day < today && day >= cutoff
        }
    }

    func sleepDebtHours() -> Double {
        let recent = recentHealthMetrics(days: 14)
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0) { total, metric in
            // A partial-wear night is a hole in the record, not zero sleep and
            // not a full 8 h — skip it so one forgotten watch can't inject days
            // of phantom debt (Fable 5: exclude the night, shrink the divisor).
            guard let sleep = metric.sleepTotalMinutes, metric.sleepIsTrustworthy else { return total }
            return total + Double(max(0, metric.sleepNeedMinutes - sleep)) / 60
        }
    }

    func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func minutesLabel(_ minutes: Int) -> String {
        "\(minutes / 60)h \(minutes % 60)m"
    }
}
