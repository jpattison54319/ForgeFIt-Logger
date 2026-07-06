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

    struct DailyHealthMetric {
        var date: Date
        var hrvSDNN: Double?
        var hrvRMSSD: Double?
        var restingHR: Int?
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

        /// Best HRV signal: nocturnal window first, then all-day RMSSD/SDNN.
        var bestHRV: Double? { nocturnalHRV ?? hrvRMSSD ?? hrvSDNN }
        /// Best overnight-cardiac signal: sleeping HR first, then resting HR.
        var bestRestingHR: Int? { sleepingHR ?? restingHR }
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
        var action: Action
        var headline: String
        var recommendation: String
        var preWorkoutAdjustment: String
        var acuteLoad: Double
        var chronicLoad: Double
        var strengthLoad: Double
        var cardioLoad: Double
        var acwr: Double?
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

        /// The slow-moving chronic recovery trend (7-day), shown as context
        /// beside the daily number. Nil until it has enough history.
        var trendScore: Double? { recovery.systemic.state.value }
    }

    private struct LoadAssessment {
        var status: String
        var score: Double
        var adjustment: Double
        var isSpike: Bool
        var isDetrained: Bool
        var chips: [ReasonChip]
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

    var completed: [WorkoutModel] {
        workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
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

    /// Universal fallback load via session-RPE: duration(min) x RPE.
    private func sessionRPELoad(_ workout: WorkoutModel) -> Double {
        let minutes = durationMinutes(workout)
        let rpes = workout.exercises.flatMap(\.sets).compactMap { $0.rpe }
        let cardioEffort = workout.cardioSessions.first?.effort.map(Double.init)
        let rpe = rpes.isEmpty ? (cardioEffort ?? 7) : rpes.reduce(0, +) / Double(rpes.count)
        return minutes * rpe
    }

    /// Strength-specific load proxy: volume work scaled by proximity to failure.
    /// It is tracked separately from cardio because HR-based load undercounts
    /// heavy lifting stress.
    private func strengthLoad(_ workout: WorkoutModel) -> Double {
        let workingSets = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        guard !workingSets.isEmpty else { return 0 }
        let tonnage = workingSets.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        let avgRPE = average(workingSets.compactMap(\.rpe)) ?? 7
        let avgRIR = average(workingSets.compactMap { $0.rir.map(Double.init) })
        let failurePressure = avgRIR.map { max(0.7, 1.15 - min($0, 5) * 0.08) } ?? max(0.7, avgRPE / 8)
        return sqrt(max(0, tonnage)) * avgRPE * failurePressure
    }

    /// Cardio load prefers stored TSS-like values, falling back to session RPE.
    private func cardioLoad(_ workout: WorkoutModel) -> Double {
        let cardio = workout.cardioSessions
        guard !cardio.isEmpty else { return 0 }
        return cardio.reduce(0) { total, session in
            if let tss = session.tss { return total + tss }
            let minutes = Double(session.durationSeconds ?? 0) / 60
            let effort = Double(session.effort ?? 7)
            return total + max(1, minutes) * effort
        }
    }

    /// Apple Health workouts can arrive without ForgeFit set details. Count
    /// them for overall load, but keep muscle-specific recovery tied to local
    /// exercise logs where we know what was trained.
    private func importedHealthFallbackLoad(_ workout: WorkoutModel) -> Double {
        guard workout.hkWorkoutUUID != nil,
              workout.cardioSessions.isEmpty,
              workout.exercises.flatMap(\.sets).isEmpty else { return 0 }
        return durationMinutes(workout) * estimatedHealthEffort(workout)
    }

    func sessionLoad(_ workout: WorkoutModel) -> Double {
        let strength = strengthLoad(workout)
        let cardio = cardioLoad(workout)
        let imported = importedHealthFallbackLoad(workout)
        if strength > 0 || cardio > 0 || imported > 0 { return strength + cardio + imported }
        return sessionRPELoad(workout)
    }

    /// Minimum chronic load before the acute:chronic ratio means anything —
    /// with a near-zero denominator (e.g. one light session in a month) the
    /// ratio is an artifact, not a spike.
    private static let minChronicLoadForACWR = 100.0

    func report() -> Report {
        let acute = load(days: 7)
        let chronic = load(days: 28) / 4
        let acwr: Double? = chronic >= Self.minChronicLoadForACWR ? acute / chronic : nil

        let daily = dailyLoads(days: 7)
        let monotony = monotony(daily)
        let strain = monotony.map { $0 * daily.reduce(0, +) }

        let daysSinceLast = completed
            .map { calendarDaysBetween($0.startedAt, and: now) }
            .min()

        let muscles = muscleFreshness()
        let load = loadAssessment(acwr: acwr, monotony: monotony)
        let muscle = muscleAssessment(freshness: muscles, daysSinceLast: daysSinceLast)
        let biometric = biometricAssessment()

        var score = 0.62 + load.adjustment + muscle.adjustment + biometric.adjustment
        if completed.isEmpty { score = 0.64 + biometric.adjustment }
        score = min(1, max(0, score))

        // The action must agree with the number the user actually sees: the
        // acute daily readiness drives the ring AND the recommendation (then
        // the chronic trend, then the legacy composite — same chain as
        // `displayScore`). A green 72 must never caption itself "Deload".
        let snapshot = recoverySnapshot()
        let effectiveScore = snapshot.daily.state.value ?? snapshot.systemic.state.value ?? score

        let action = recommendedAction(
            score: effectiveScore,
            load: load,
            muscle: muscle,
            biometric: biometric,
            daysSinceLast: daysSinceLast,
            acuteFlags: snapshot.daily.flags
        )
        let texts = interpretation(
            action: action,
            score: effectiveScore,
            daysSinceLast: daysSinceLast,
            biometric: biometric,
            acuteFlags: snapshot.daily.flags
        )
        let chips = reasonChips(
            load: load,
            muscle: muscle,
            biometric: biometric,
            daysSinceLast: daysSinceLast,
            acuteFlags: snapshot.daily.flags
        )

        // Confidence = how complete the data feeding the recommendation is, so
        // a missing input always lowers it. Two sources: the morning
        // biometrics (70%) and the training-load history the score leans on
        // (30%). The old formula floored at 65% and graded only the signals
        // that were present, so a missing sleep score still read 100%.
        let loadCompleteness: Double = {
            if completed.isEmpty { return 0 }   // no training history at all
            if acwr != nil { return 1 }         // enough history for a baseline ratio
            return 0.5                          // some sessions, baseline still building
        }()
        let confidence = min(1, max(0.1, biometric.completeness * 0.7 + loadCompleteness * 0.3))

        return Report(
            score: score,
            confidence: confidence,
            action: action,
            headline: action.title,
            recommendation: texts.recommendation,
            preWorkoutAdjustment: texts.preWorkoutAdjustment,
            acuteLoad: acute,
            chronicLoad: chronic,
            strengthLoad: loadBreakdown(days: 7).strength,
            cardioLoad: loadBreakdown(days: 7).cardio,
            acwr: acwr,
            monotony: monotony,
            strain: strain,
            daysSinceLast: daysSinceLast,
            usedRMSSD: biometric.usedRMSSD,
            missingInputs: biometric.missing,
            reasonChips: chips,
            subScores: subScores(load: load, muscle: muscle, biometric: biometric),
            muscleFreshness: muscles,
            insights: insights(load: load, muscle: muscle, biometric: biometric, daysSinceLast: daysSinceLast),
            signals: biometric.signals + trainingLoadSignals(acwr: acwr, monotony: monotony) + supplementalSignals,
            recovery: snapshot
        )
    }

    func durationMinutes(_ workout: WorkoutModel) -> Double {
        if let cardio = workout.cardioSessions.first, let d = cardio.durationSeconds {
            return max(1, Double(d) / 60)
        }
        if let ended = workout.endedAt {
            return max(1, ended.timeIntervalSince(workout.startedAt) / 60)
        }
        return 45
    }

    private func load(days: Int) -> Double {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return 0 }
        return completed.filter { $0.startedAt >= cutoff }.reduce(0) { $0 + sessionLoad($1) }
    }

    private func loadBreakdown(days: Int) -> (strength: Double, cardio: Double) {
        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return (0, 0) }
        return completed.filter { $0.startedAt >= cutoff }.reduce((0, 0)) { total, workout in
            let imported = importedHealthFallbackLoad(workout)
            if imported > 0, healthWorkoutLooksStrengthLike(workout) {
                return (total.0 + strengthLoad(workout) + imported, total.1 + cardioLoad(workout))
            }
            return (total.0 + strengthLoad(workout), total.1 + cardioLoad(workout) + imported)
        }
    }

    private func estimatedHealthEffort(_ workout: WorkoutModel) -> Double {
        if let avgHR = workout.avgHR {
            return switch HRZone.zone(forAvgHR: avgHR) {
            case 1: 3.0
            case 2: 4.0
            case 3: 6.0
            case 4: 8.0
            default: 9.0
            }
        }
        if let energy = workout.activeEnergyKcal {
            let kcalPerMinute = energy / durationMinutes(workout)
            switch kcalPerMinute {
            case 12...: return 8.0
            case 8..<12: return 7.0
            case 4..<8: return 5.0
            default: return 4.0
            }
        }
        return 5.0
    }

    func healthWorkoutLooksStrengthLike(_ workout: WorkoutModel) -> Bool {
        let title = (workout.title ?? "").lowercased()
        return title.contains("strength")
            || title.contains("core")
            || title.contains("yoga")
            || title.contains("pilates")
    }

    func dailyLoads(days: Int) -> [Double] {
        var buckets = [Double](repeating: 0, count: days)
        let today = calendar.startOfDay(for: now)
        for w in completed {
            let d = calendar.startOfDay(for: w.startedAt)
            if let diff = calendar.dateComponents([.day], from: d, to: today).day, diff >= 0, diff < days {
                buckets[diff] += sessionLoad(w)
            }
        }
        return buckets
    }

    func monotony(_ daily: [Double]) -> Double? {
        let mean = daily.reduce(0, +) / Double(daily.count)
        guard mean > 0 else { return nil }
        let variance = daily.map { pow($0 - mean, 2) }.reduce(0, +) / Double(daily.count)
        let sd = sqrt(variance)
        guard sd > 0 else { return nil }
        return mean / sd
    }

    private func loadAssessment(acwr: Double?, monotony: Double?) -> LoadAssessment {
        var chips: [ReasonChip] = []
        var adjustment = 0.0
        var status = "Building"
        var score = 0.62
        var isSpike = false
        var isDetrained = false

        if let acwr {
            switch acwr {
            case ..<0.8:
                status = "Light"
                score = 0.66
                adjustment += 0.02
                isDetrained = true
                chips.append(ReasonChip(text: "Lower recent load", tone: .neutral))
            case ...1.3:
                status = "Steady"
                score = 0.82
                adjustment += 0.08
                chips.append(ReasonChip(text: "Load steady", tone: .positive))
            case ...1.5:
                status = "Elevated"
                score = 0.58
                adjustment -= 0.07
                chips.append(ReasonChip(text: "Load elevated", tone: .caution))
            case ...1.8:
                status = "Spike"
                score = 0.42
                adjustment -= 0.18
                isSpike = true
                chips.append(ReasonChip(text: "Load spike", tone: .caution))
            default:
                status = "High spike"
                score = 0.30
                adjustment -= 0.28
                isSpike = true
                chips.append(ReasonChip(text: "Large load spike", tone: .caution))
            }
        } else {
            chips.append(ReasonChip(text: "Load baseline building", tone: .neutral))
        }

        if let monotony, monotony > 2 {
            adjustment -= monotony > 3 ? 0.14 : 0.08
            score = min(score, monotony > 3 ? 0.40 : 0.55)
            chips.append(ReasonChip(text: "Week lacks variation", tone: .caution))
        }

        return LoadAssessment(
            status: status,
            score: min(1, max(0, score)),
            adjustment: adjustment,
            isSpike: isSpike,
            isDetrained: isDetrained,
            chips: chips
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
            let hrvValue = current.bestHRV
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
                        metric.bestHRV.map { $0 < lowCutoff }
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
                    let rolling = recentHealthMetrics(days: 7).compactMap { $0.bestHRV }
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
                signals.append(Signal(name: "HRV", systemImage: "waveform.path.ecg", value: "-", detail: "Connect Apple Health", connected: false))
            }

            if let restingHR = current.bestRestingHR {
                availableParts += 1
                let baseline = baselineRHRValues()
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

            if let sleep = current.sleepTotalMinutes {
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
                signals.append(Signal(name: "Sleep", systemImage: "bed.double.fill",
                                      value: minutesLabel(sleep), detail: "Debt \(debt.formatted(.number.precision(.fractionLength(1))))h", connected: true))
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

    private func recommendedAction(
        score: Double,
        load: LoadAssessment,
        muscle: MuscleAssessment,
        biometric: BiometricAssessment,
        daysSinceLast: Int?,
        acuteFlags: [String] = []
    ) -> Action {
        // Acute flags come from the SAME daily-readiness parts that produced the
        // headline number, so the action can't contradict what the score shows.
        let acuteLowHRV = acuteFlags.contains("HRV low today")
        let biometricRedFlags = [biometric.sustainedLowHRV, biometric.elevatedRHR || acuteFlags.contains("Sleeping HR elevated"), biometric.poorSleep].filter { $0 }.count
        let cautionCount = biometricRedFlags + (load.isSpike ? 1 : 0) + (muscle.hasRecentTarget ? 1 : 0)

        if load.isSpike && score < 0.42 { return .deloadRecover }
        if biometric.sustainedLowHRV { return score < 0.42 ? .deloadRecover : .reduceVolume }
        if biometricRedFlags >= 2 && score < 0.55 { return .reduceVolume }
        if cautionCount >= 2 { return score < 0.45 ? .deloadRecover : .reduceVolume }

        if (acuteLowHRV || biometric.singleLowHRV), !biometric.sustainedLowHRV, daysSinceLast.map({ $0 >= 2 }) == true, !load.isSpike, score >= 0.55 {
            return .trainAsPlanned
        }

        if muscle.hasRecentTarget { return .reduceVolume }
        // Push wants the sweet spot: recovered (2–3 days) but not detrained —
        // after a longer layoff the right call is a normal ramp-in session,
        // however fresh the score looks.
        if score >= 0.84, daysSinceLast.map({ (2...3).contains($0) }) == true, !load.isDetrained { return .push }
        if score >= 0.55 { return .trainAsPlanned }
        return score < 0.38 ? .deloadRecover : .reduceVolume
    }

    private func interpretation(
        action: Action,
        score: Double,
        daysSinceLast: Int?,
        biometric: BiometricAssessment,
        acuteFlags: [String] = []
    ) -> (recommendation: String, preWorkoutAdjustment: String) {
        let acuteLowHRV = acuteFlags.contains("HRV low today")
        switch action {
        case .push:
            return (
                "Signals support a harder session. Push one priority lift or interval, and stop if bar speed or pace falls off.",
                "Green light: keep the plan and allow one hard top set."
            )
        case .trainAsPlanned:
            if acuteLowHRV || (biometric.singleLowHRV && !biometric.sustainedLowHRV) {
                return (
                    "You look trainable, but HRV is below your normal range this morning. Train as planned and skip PR attempts unless warmups feel unusually good.",
                    "Train as planned; cap top sets around RPE 8."
                )
            }
            if let daysSinceLast, daysSinceLast >= 4 {
                return (
                    "You are rested, but it has been a few days. Ease in with normal technique work before chasing load.",
                    "Train as planned; build through warmups gradually."
                )
            }
            return (
                "Solid day to train. Keep the planned work and let warmups decide whether to add load.",
                "Train as planned."
            )
        case .reduceVolume:
            return (
                "Fatigue signals are stacking up. Keep movement quality high, drop one or two sets, and avoid PR attempts.",
                "Reduce volume; drop 1-2 sets or cap hard work at RPE 8."
            )
        case .deloadRecover:
            return (
                "Recovery is not lining up with another hard session. Choose Zone 2, mobility, or a full rest day.",
                "Deload/recover; swap to Zone 2, mobility, or rest."
            )
        }
    }

    private func reasonChips(
        load: LoadAssessment,
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
        var chips = acute + muscle.chips + biometricChips + load.chips
        if chips.isEmpty, let daysSinceLast, daysSinceLast >= 2 {
            chips.append(ReasonChip(text: "48h recovered", tone: .positive))
        }
        chips = removeRedundantTodayTrainingChips(chips)
        var seen = Set<String>()
        return chips.filter { seen.insert($0.text).inserted }.prefix(6).map { $0 }
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
            SubScore(name: "Action load", value: load.status, score: load.score, caption: load.isSpike ? "Spike heuristic" : "Training trend"),
            SubScore(name: "Body signals", value: biometric.status, score: biometric.score, caption: biometric.missing.isEmpty ? "Baseline read" : "Partial data"),
            SubScore(name: "Muscles", value: muscle.hasTrainableTarget ? "48h+" : "Check", score: muscle.score, caption: muscle.hasRecentTarget ? "Recently trained" : "Local recovery")
        ]
    }

    private func insights(load: LoadAssessment, muscle: MuscleAssessment, biometric: BiometricAssessment, daysSinceLast: Int?) -> [String] {
        var out: [String] = []
        if load.isSpike {
            out.append("Recent load is well above your baseline. Treat ACWR as a spike flag, not an injury prediction.")
        } else if load.isDetrained {
            out.append("Recent load is low versus your baseline. You can train, but ramp the first hard session.")
        }
        if biometric.sustainedLowHRV {
            out.append("HRV has been below baseline across multiple readings. Favor quality work over extra volume.")
        } else if biometric.singleLowHRV, daysSinceLast.map({ $0 >= 2 }) == true {
            out.append("A single low HRV reading after 48h off is a caution flag, not an automatic rest day.")
        }
        if biometric.elevatedRHR { out.append("Resting heart rate is elevated versus baseline, so keep an eye on warmup feel.") }
        if biometric.poorSleep { out.append("Sleep debt is high enough to temper intensity today.") }
        if muscle.hasRecentTarget {
            out.append("At least one relevant muscle was trained within 48h. Rotate emphasis or reduce local volume.")
        }
        let trained = muscleFreshness().filter { $0.daysAgo != nil }
        if !trained.isEmpty, trained.allSatisfy({ ($0.daysAgo ?? 0) >= 3 }), trained.count > 1 {
            out.append("Every tracked muscle has had 3+ days since direct work — pick any focus today.")
        } else if let fresh = trained.max(by: { ($0.daysAgo ?? 0) < ($1.daysAgo ?? 0) }),
                  let d = fresh.daysAgo, d >= 3 {
            out.append("\(fresh.muscle.capitalized) has had \(d) days since direct work.")
        }
        if let d = daysSinceLast, d >= 4 { out.append("It has been \(d) days since your last workout. Start a little conservative.") }
        if out.isEmpty { out.append("Everything looks balanced. Keep logging to sharpen these insights.") }
        return out
    }

    private func trainingLoadSignals(acwr: Double?, monotony: Double?) -> [Signal] {
        var list: [Signal] = []
        if let acwr {
            let status = acwr <= 1.3 ? "Steady" : (acwr <= 1.5 ? "Elevated" : "Spike")
            list.append(Signal(name: "Load ratio", systemImage: "chart.line.uptrend.xyaxis",
                               value: acwr.formatted(.number.precision(.fractionLength(2))),
                               detail: "Acute:chronic heuristic - \(status)", connected: true))
        } else {
            list.append(Signal(name: "Load ratio", systemImage: "chart.line.uptrend.xyaxis",
                               value: "-", detail: "Log sessions to build a baseline", connected: true))
        }
        if let monotony {
            list.append(Signal(name: "Monotony", systemImage: "waveform.path",
                               value: monotony.formatted(.number.precision(.fractionLength(1))),
                               detail: "Lower means more day-to-day variation", connected: true))
        }
        return list
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

    private func baselineHRVValues(preferRMSSD: Bool) -> [Double] {
        _ = preferRMSSD
        return baselineMetrics(days: 60).compactMap { $0.bestHRV }
    }

    private func baselineRHRValues() -> [Double] {
        baselineMetrics(days: 60).compactMap { $0.bestRestingHR.map(Double.init) }
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
            guard let sleep = metric.sleepTotalMinutes else { return total }
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
