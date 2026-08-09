import Foundation
import ForgeCore
#if canImport(HealthKit)
import HealthKit
#endif

/// Metrics pulled from HealthKit for a cardio segment's time window.
struct CardioSnapshot {
    var durationSeconds: Int?
    var avgHR: Int?
    var maxHR: Int?
    var activeEnergyKcal: Double?
    var distanceMeters: Double?
    var hasData: Bool { avgHR != nil || activeEnergyKcal != nil || distanceMeters != nil }
}

/// One calendar day's cumulative movement from Apple Health. This is an
/// in-memory input to daily strain only; it is never written to SwiftData,
/// CloudKit, or backup payloads.
struct DailyActivityMetric: Equatable, Sendable {
    var date: Date
    var steps: Double?
    var exerciseMinutes: Double?
    var activeEnergyKcal: Double?
    /// Steps accumulated through the same local time-of-day as the query.
    /// This prevents a 2 p.m. partial day being compared with prior full days.
    var comparableTimeSteps: Double? = nil
}

/// Reads and writes cardiovascular / workout data with Apple Health & Fitness
/// (populated by Apple Watch or any connected source). Reading auto-fills cardio
/// metrics for a segment's time window; writing saves finished workouts back to
/// Health. Degrades gracefully when Health is unavailable.
/// HealthKit is thread-safe, and all values returned from this service are
/// immutable projections. Keep the service nonisolated so callers that run on
/// a worker executor do not silently hop back to the app target's default
/// MainActor for sample sorting, bucketing, and nocturnal analysis.
nonisolated final class HealthService: @unchecked Sendable {
    static let shared = HealthService()

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    #endif

    var isAvailable: Bool {
        #if canImport(HealthKit)
        HKHealthStore.isHealthDataAvailable()
        #else
        false
        #endif
    }

    /// Whether the user has granted write access (the only status HealthKit
    /// exposes; read status is intentionally private). Used to show "Connected".
    var isConnected: Bool {
        #if canImport(HealthKit)
        guard isAvailable else { return false }
        return store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        #else
        return false
        #endif
    }

    #if canImport(HealthKit)
    /// Everything the scoring algorithms consume — intra-workout metrics
    /// (HR, energy, distance) plus the full-day recovery signals (HRV,
    /// resting HR, sleep, respiratory rate, SpO₂, VO₂max, HR recovery,
    /// exercise time, body mass for bodyweight-load math).
    private var readTypes: Set<HKObjectType> {
        var t: Set<HKObjectType> = [HKObjectType.workoutType()]
        let ids: [HKQuantityTypeIdentifier] = [
            // Intra-workout
            .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling,
            .distanceSwimming, .runningPower, .cyclingPower,
            // Daily activity / strain
            .stepCount, .appleExerciseTime, .basalEnergyBurned, .flightsClimbed,
            // Recovery biometrics
            .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate,
            .oxygenSaturation, .walkingHeartRateAverage, .heartRateRecoveryOneMinute,
            // Fitness & body
            .vo2Max, .bodyMass,
        ]
        for id in ids {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { t.insert(type) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { t.insert(sleep) }
        if let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) { t.insert(dob) }
        t.insert(HKSeriesType.workoutRoute())
        return t
    }

    private var shareTypes: Set<HKSampleType> {
        var t: Set<HKSampleType> = [HKObjectType.workoutType()]
        // heartRate: BLE-monitor readings captured during a workout are
        // written back so window queries and analytics see them like any
        // other source.
        for id: HKQuantityTypeIdentifier in [.activeEnergyBurned, .distanceWalkingRunning, .distanceCycling, .bodyMass, .heartRate] {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { t.insert(type) }
        }
        // Effort write-back (T3-6): the 1–10 score Fitness shows on the
        // workout card, derived from logged RPE — the number Apple's rings
        // guess at, ForgeFit actually knows.
        if let effort = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) { t.insert(effort) }
        return t
    }
    #endif

    @discardableResult
    func requestAuthorization() async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable else { return false }
        // UI test automation reinstalls the app fresh, so HealthKit
        // authorization has never been decided; requesting it would pop the
        // real system permission sheet full-screen over whatever the test is
        // driving, and no test drives through that sheet (it covers dozens of
        // data-type toggles, not a one-tap "Allow"). --reset-store is already
        // this codebase's signal for an automation launch; real users never
        // pass it, so this only ever short-circuits test runs.
        guard !ProcessInfo.processInfo.arguments.contains("--reset-store") else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            return isConnected
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Opportunistic call sites (for example, starting a cardio segment) must
    /// not present the complete Health authorization flow on every workout.
    /// HealthKit owns and persists the per-type decisions; this asks the store
    /// whether the current read/share set contains anything not yet decided.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable else { return false }
        guard !ProcessInfo.processInfo.arguments.contains("--reset-store") else { return false }
        // Starting a workout is not a permission-management surface. In
        // particular, a newly reported Workout Routes read type must not
        // reopen the full sheet for an already-connected user.
        guard !isConnected else { return true }
        do {
            let status = try await store.statusForAuthorizationRequest(
                toShare: shareTypes,
                read: readTypes
            )
            guard WorkoutAuthorizationPromptPolicy.shouldRequestAtWorkoutStart(
                hasWorkoutWriteAccess: isConnected,
                hasUndecidedTypes: status == .shouldRequest
            ) else { return false }
            return await requestAuthorization()
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Launch the watch app into a workout session so a phone-started workout
    /// starts live metric collection on the wrist automatically.
    func startWatchApp(cardioKind: CardioKind? = nil) {
        #if canImport(HealthKit)
        guard isAvailable else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = cardioKind?.hkActivityType ?? .traditionalStrengthTraining
        configuration.locationType = cardioKind?.supportsOutdoorRoute == true ? .outdoor : .indoor
        store.startWatchApp(with: configuration) { _, _ in }
        #endif
    }

    /// The user's age from their Apple Health date of birth, if shared — used
    /// to seed a max-HR estimate (220 − age). Returns nil when unavailable.
    func biologicalAge() -> Int? {
        #if canImport(HealthKit)
        guard isAvailable,
              let components = try? store.dateOfBirthComponents(),
              let birthYear = components.year else { return nil }
        let currentYear = Calendar.current.component(.year, from: Date())
        let age = currentYear - birthYear
        return (10...100).contains(age) ? age : nil
        #else
        return nil
        #endif
    }

    /// Most recent Apple Health resting heart-rate sample.
    func latestRestingHR() async -> Int? {
        #if canImport(HealthKit)
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await latestQuantity(.restingHeartRate, unit: unit).map { Int($0.rounded()) }
        #else
        return nil
        #endif
    }

    /// Most recent Apple Watch walking heart-rate average sample, useful as a
    /// fallback when resting HR has not been written yet.
    func latestWalkingAverageHR() async -> Int? {
        #if canImport(HealthKit)
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await latestQuantity(.walkingHeartRateAverage, unit: unit).map { Int($0.rounded()) }
        #else
        return nil
        #endif
    }

    /// Highest heart rate observed recently. This is not a formal max-HR test,
    /// but it is better than an age estimate when the user has workout data.
    func recentPeakHeartRate(days: Int = 90) async -> Int? {
        #if canImport(HealthKit)
        guard isAvailable,
              let start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: Date()) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await stat(.heartRate, .discreteMax, predicate, unit: unit).map { Int($0.rounded()) }
        #else
        return nil
        #endif
    }

    // MARK: - Reading (auto-fill)

    func importSnapshot(from start: Date, to end: Date, modality: CardioKind) async -> CardioSnapshot {
        let duration = max(0, Int(end.timeIntervalSince(start)))
        #if canImport(HealthKit)
        guard isAvailable, end > start else { return CardioSnapshot(durationSeconds: duration) }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let hrUnit = HKUnit.count().unitDivided(by: .minute())

        async let avg = stat(.heartRate, .discreteAverage, predicate, unit: hrUnit)
        async let peak = stat(.heartRate, .discreteMax, predicate, unit: hrUnit)
        async let energy = stat(.activeEnergyBurned, .cumulativeSum, predicate, unit: .kilocalorie())
        let distID: HKQuantityTypeIdentifier = switch modality {
        case .cycle: .distanceCycling
        case .swim: .distanceSwimming
        default: .distanceWalkingRunning
        }
        async let dist = stat(distID, .cumulativeSum, predicate, unit: .meter())

        return CardioSnapshot(
            durationSeconds: duration,
            avgHR: (await avg).map { Int($0.rounded()) },
            maxHR: (await peak).map { Int($0.rounded()) },
            activeEnergyKcal: await energy,
            distanceMeters: await dist
        )
        #else
        return CardioSnapshot(durationSeconds: duration)
        #endif
    }

    /// Per-sample heart-rate series (bpm) for a workout's time window, oldest
    /// first. Empty when Health is unavailable or nothing was recorded (e.g. a
    /// manually logged workout with no Apple Watch) — the caller hides the graph.
    func heartRateSamples(from start: Date, to end: Date) async -> [(date: Date, bpm: Int)] {
        #if canImport(HealthKit)
        guard isAvailable, end > start else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let samples = await quantitySamples(.heartRate, from: start, to: end)
        return samples
            .sorted { $0.startDate < $1.startDate }
            .map { ($0.startDate, Int($0.quantity.doubleValue(for: unit).rounded())) }
        #else
        return []
        #endif
    }

    // MARK: - Daily recovery metrics (feeds RecoveryEngine)

    /// Per-day recovery and vital-sign readings for the last `days` days — the
    /// series RecoveryEngine and Health personal ranges baseline against.
    func dailyMetrics(
        days: Int = 60,
        endingAt end: Date = Date(),
        calendar: Calendar = .current
    ) async -> [RecoveryEngine.DailyHealthMetric] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        guard let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: end)) else { return [] }

        async let hrvSamplesAsync = quantitySamples(.heartRateVariabilitySDNN, from: start, to: end)
        async let rhrSamplesAsync = quantitySamples(.restingHeartRate, from: start, to: end)
        async let respiratorySamplesAsync = quantitySamples(.respiratoryRate, from: start, to: end)
        async let oxygenSamplesAsync = quantitySamples(.oxygenSaturation, from: start, to: end)
        async let sleepSamplesAsync = sleepSamples(from: start, to: end)

        let msUnit = HKUnit.secondUnit(with: .milli)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        let hrvSamples = await hrvSamplesAsync
        let rhrSamples = await rhrSamplesAsync
        let respiratorySamples = await respiratorySamplesAsync
        let oxygenSamples = await oxygenSamplesAsync
        let allSleepSegments = await sleepSamplesAsync
        guard !Task.isCancelled else { return [] }
        let sleepSegments = allSleepSegments.filter(isAsleep)

        // Nocturnal window: restrict HRV to sleep and derive sleeping HR — the
        // validated overnight measurement window (Plews 2013, Buchheit 2014),
        // preferred over Apple's all-day HRV mean and daytime resting HR.
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: sleepSegments.map { ($0.startDate, $0.endDate) },
            calendar: calendar
        )
        let nocturnalHR = await heartRateSamplesDuringSleep(windows: windows)
        guard !Task.isCancelled else { return [] }
        let nightly = NocturnalAggregator.nightly(
            windows: windows,
            hrv: hrvSamples.map { ($0.startDate, $0.quantity.doubleValue(for: msUnit)) },
            hr: nocturnalHR.map { ($0.date, $0.bpm) }
        )

        func readinessDay(for sample: HKQuantitySample) -> Date {
            let midpoint = sample.startDate.addingTimeInterval(sample.endDate.timeIntervalSince(sample.startDate) / 2)
            if let window = windows.first(where: { midpoint >= $0.start && midpoint <= $0.end }) {
                return window.day
            }
            return calendar.startOfDay(for: sample.endDate)
        }

        // Bucket by calendar day. Sleep is attributed to the day it ENDED
        // (last night's sleep belongs to today's readiness). All-day HRV / RHR
        // remain as fallbacks when the nocturnal window is empty.
        var hrvByDay: [Date: [Double]] = [:]
        var hrvSourcesByDay: [Date: [String]] = [:]
        var nocturnalHRVSourcesByDay: [Date: [String]] = [:]
        for sample in hrvSamples {
            let day = calendar.startOfDay(for: sample.endDate)
            hrvByDay[day, default: []].append(sample.quantity.doubleValue(for: msUnit))
            hrvSourcesByDay[day, default: []].append(sample.sourceRevision.source.bundleIdentifier)
            if let window = windows.first(where: { sample.startDate >= $0.start && sample.startDate <= $0.end }) {
                nocturnalHRVSourcesByDay[window.day, default: []].append(sample.sourceRevision.source.bundleIdentifier)
            }
        }
        var rhrByDay: [Date: [Double]] = [:]
        var rhrSourcesByDay: [Date: [String]] = [:]
        for sample in rhrSamples {
            let day = calendar.startOfDay(for: sample.endDate)
            rhrByDay[day, default: []].append(sample.quantity.doubleValue(for: bpmUnit))
            rhrSourcesByDay[day, default: []].append(sample.sourceRevision.source.bundleIdentifier)
        }
        var respiratoryByDay: [Date: [Double]] = [:]
        var respiratorySourcesByDay: [Date: [String]] = [:]
        for sample in respiratorySamples {
            let day = readinessDay(for: sample)
            respiratoryByDay[day, default: []]
                .append(sample.quantity.doubleValue(for: bpmUnit))
            respiratorySourcesByDay[day, default: []]
                .append(sample.sourceRevision.source.bundleIdentifier)
        }
        var oxygenByDay: [Date: [Double]] = [:]
        var oxygenSourcesByDay: [Date: [String]] = [:]
        for sample in oxygenSamples {
            let day = readinessDay(for: sample)
            oxygenByDay[day, default: []]
                .append(sample.quantity.doubleValue(for: .percent()) * 100)
            oxygenSourcesByDay[day, default: []]
                .append(sample.sourceRevision.source.bundleIdentifier)
        }
        var sleepByDay: [Date: Int] = [:]
        var sleepSourcesByDay: [Date: [String]] = [:]
        for sample in sleepSegments {
            let day = calendar.startOfDay(for: sample.endDate)
            sleepByDay[day, default: 0]
                += Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            sleepSourcesByDay[day, default: []].append(sample.sourceRevision.source.bundleIdentifier)
        }
        // Stage breakdown (deep / REM / awake-in-bed). Sources that write
        // unstaged "asleep" samples leave these empty and the metric's stage
        // fields stay nil — total minutes drive the score either way.
        var deepByDay: [Date: Int] = [:]
        var remByDay: [Date: Int] = [:]
        var awakeByDay: [Date: Int] = [:]
        for sample in allSleepSegments {
            let day = calendar.startOfDay(for: sample.endDate)
            let minutes = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepDeep: deepByDay[day, default: 0] += minutes
            case .asleepREM: remByDay[day, default: 0] += minutes
            case .awake: awakeByDay[day, default: 0] += minutes
            default: break
            }
        }

        // Merged sleep-window bounds per readiness day (min start, max end over
        // the night's windows) — the bed/wake anchors integrity detection reads.
        var windowBoundsByDay: [Date: (start: Date, end: Date)] = [:]
        for window in windows {
            if let existing = windowBoundsByDay[window.day] {
                windowBoundsByDay[window.day] = (min(existing.start, window.start), max(existing.end, window.end))
            } else {
                windowBoundsByDay[window.day] = (window.start, window.end)
            }
        }

        let allDays = Set(hrvByDay.keys)
            .union(rhrByDay.keys)
            .union(respiratoryByDay.keys)
            .union(oxygenByDay.keys)
            .union(sleepByDay.keys)
            .union(nightly.keys)
        return allDays.sorted().map { day in
            RecoveryEngine.DailyHealthMetric(
                date: day,
                hrvSDNN: hrvByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                restingHR: rhrByDay[day].map { Int(($0.reduce(0, +) / Double($0.count)).rounded()) },
                respiratoryRate: respiratoryByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                oxygenSaturationPercent: oxygenByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                sleepTotalMinutes: sleepByDay[day],
                source: "healthkit",
                hrvSourceBundleID: dominantSource(nocturnalHRVSourcesByDay[day] ?? hrvSourcesByDay[day] ?? []),
                restingHRSourceBundleID: dominantSource(rhrSourcesByDay[day] ?? []),
                sleepingHRSourceBundleID: dominantSource(nocturnalHR.filter { sample in
                    windows.contains { $0.day == day && sample.date >= $0.start && sample.date <= $0.end }
                }.map(\.sourceBundleID)),
                sleepSourceBundleID: dominantSource(sleepSourcesByDay[day] ?? []),
                respiratoryRateSourceBundleID: dominantSource(respiratorySourcesByDay[day] ?? []),
                oxygenSaturationSourceBundleID: dominantSource(oxygenSourcesByDay[day] ?? []),
                hrvSampleCount: hrvByDay[day]?.count,
                nocturnalHRV: nightly[day]?.hrv,
                nocturnalHRVOccupiedBinCount: nightly[day]?.hrvOccupiedBinCount,
                nocturnalHRVSampleSpanMinutes: nightly[day]?.hrvSampleSpanMinutes,
                sleepingHR: nightly[day]?.sleepingHR,
                sleepingHRSampleCount: nightly[day]?.sleepingHRSampleCount,
                sleepingHROccupiedBinCount: nightly[day]?.sleepingHROccupiedBinCount,
                sleepingHRSampleSpanMinutes: nightly[day]?.sleepingHRSampleSpanMinutes,
                sleepStart: windowBoundsByDay[day]?.start,
                sleepEnd: windowBoundsByDay[day]?.end,
                sleepDeepMinutes: deepByDay[day],
                sleepREMMinutes: remByDay[day],
                sleepAwakeMinutes: awakeByDay[day]
            )
        }
        #else
        return []
        #endif
    }

    /// Every recorded sleep night through `end`, projected without the other
    /// recovery channels. Full sleep history is loaded only when its screen is
    /// opened, so Home's bounded daily refresh stays fast even for users with
    /// years of Apple Health data.
    func sleepHistory(
        endingAt end: Date = .now,
        calendar: Calendar = .current
    ) async -> [RecoveryEngine.DailyHealthMetric] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        let allSegments = await sleepSamples(from: nil, to: end)
        guard !Task.isCancelled else { return [] }
        let asleepSegments = allSegments.filter(isAsleep)
        guard !asleepSegments.isEmpty else { return [] }

        var totalByDay: [Date: Int] = [:]
        var deepByDay: [Date: Int] = [:]
        var remByDay: [Date: Int] = [:]
        var awakeByDay: [Date: Int] = [:]
        var sourcesByDay: [Date: [String]] = [:]
        var boundsByDay: [Date: (start: Date, end: Date)] = [:]

        for sample in asleepSegments {
            guard !Task.isCancelled else { return [] }
            let day = calendar.startOfDay(for: sample.endDate)
            totalByDay[day, default: 0] += Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            sourcesByDay[day, default: []].append(sample.sourceRevision.source.bundleIdentifier)
            if let existing = boundsByDay[day] {
                boundsByDay[day] = (min(existing.start, sample.startDate), max(existing.end, sample.endDate))
            } else {
                boundsByDay[day] = (sample.startDate, sample.endDate)
            }
        }

        for sample in allSegments {
            guard !Task.isCancelled else { return [] }
            let day = calendar.startOfDay(for: sample.endDate)
            let minutes = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepDeep: deepByDay[day, default: 0] += minutes
            case .asleepREM: remByDay[day, default: 0] += minutes
            case .awake: awakeByDay[day, default: 0] += minutes
            default: break
            }
        }

        return totalByDay.keys.sorted().map { day in
            RecoveryEngine.DailyHealthMetric(
                date: day,
                sleepTotalMinutes: totalByDay[day],
                source: "healthkit",
                sleepSourceBundleID: dominantSource(sourcesByDay[day] ?? []),
                sleepStart: boundsByDay[day]?.start,
                sleepEnd: boundsByDay[day]?.end,
                sleepDeepMinutes: deepByDay[day],
                sleepREMMinutes: remByDay[day],
                sleepAwakeMinutes: awakeByDay[day]
            )
        }
        #else
        return []
        #endif
    }

    /// Calendar-day movement for the rolling strain baseline. Statistics
    /// queries are used instead of summing raw samples so HealthKit resolves
    /// overlapping sources (for example, iPhone plus Apple Watch) correctly.
    func dailyActivityMetrics(
        days: Int = 90,
        endingAt endDate: Date = Date(),
        calendar: Calendar = .current
    ) async -> [DailyActivityMetric] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        let today = calendar.startOfDay(for: endDate)
        guard let start = calendar.date(byAdding: .day, value: -max(1, days), to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        async let steps = cumulativeDailyValues(
            .stepCount, from: start, to: end, unit: .count(), calendar: calendar)
        async let exercise = cumulativeDailyValues(
            .appleExerciseTime, from: start, to: end, unit: .minute(), calendar: calendar)
        async let energy = cumulativeDailyValues(
            .activeEnergyBurned, from: start, to: end, unit: .kilocalorie(), calendar: calendar)
        async let comparableSteps = cumulativeSameClockDailyValues(
            .stepCount, from: start, to: end, unit: .count(), calendar: calendar, now: endDate)

        let (stepsByDay, exerciseByDay, energyByDay, comparableStepsByDay) = await (steps, exercise, energy, comparableSteps)
        guard !stepsByDay.isEmpty || !exerciseByDay.isEmpty || !energyByDay.isEmpty else { return [] }
        var output: [DailyActivityMetric] = []
        var day = start
        while day <= today {
            output.append(DailyActivityMetric(
                date: day,
                steps: stepsByDay[day],
                exerciseMinutes: exerciseByDay[day],
                activeEnergyKcal: energyByDay[day],
                comparableTimeSteps: comparableStepsByDay[day] ?? (stepsByDay.isEmpty ? nil : 0)
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return output
        #else
        return []
        #endif
    }

    #if canImport(HealthKit)
    private func cumulativeDailyValues(
        _ id: HKQuantityTypeIdentifier,
        from start: Date,
        to end: Date,
        unit: HKUnit,
        calendar: Calendar
    ) async -> [Date: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        var interval = DateComponents()
        interval.day = 1

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                    guard let sum = statistics.sumQuantity() else { return }
                    values[calendar.startOfDay(for: statistics.startDate)] = sum.doubleValue(for: unit)
                }
                continuation.resume(returning: values)
            }
            self.store.execute(query)
        }
    }

    private func cumulativeSameClockDailyValues(
        _ id: HKQuantityTypeIdentifier,
        from start: Date,
        to end: Date,
        unit: HKUnit,
        calendar: Calendar,
        now: Date
    ) async -> [Date: Double] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [:] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        var interval = DateComponents()
        interval.minute = 15
        let elapsedToday = now.timeIntervalSince(calendar.startOfDay(for: now))

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: min(end, now)) { statistics, _ in
                    let day = calendar.startOfDay(for: statistics.startDate)
                    let offset = statistics.startDate.timeIntervalSince(day)
                    guard offset <= elapsedToday, let sum = statistics.sumQuantity() else { return }
                    values[day, default: 0] += sum.doubleValue(for: unit)
                }
                continuation.resume(returning: values)
            }
            self.store.execute(query)
        }
    }

    /// Heart-rate samples that fall within the given sleep windows, fetched in a
    /// single query (OR of per-window predicates) so sleeping HR costs one
    /// round-trip rather than one per night.
    private func heartRateSamplesDuringSleep(windows: [NocturnalAggregator.SleepWindow]) async -> [(date: Date, bpm: Int, sourceBundleID: String)] {
        guard !windows.isEmpty, let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates:
            windows.map { HKQuery.predicateForSamples(withStart: $0.start, end: $0.end, options: []) })
        let samples: [HKQuantitySample] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
        return samples.map {
            ($0.startDate, Int($0.quantity.doubleValue(for: unit).rounded()), $0.sourceRevision.source.bundleIdentifier)
        }
    }

    private func dominantSource(_ sources: [String]) -> String? {
        Dictionary(grouping: sources, by: { $0 })
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?.key
    }
    #endif

    /// Today's supplemental full-day signals shown alongside the readiness
    /// breakdown: respiratory rate, blood oxygen, cardio fitness, HR recovery,
    /// steps, and active energy.
    func todaySignals() async -> [RecoveryEngine.Signal] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        let calendar = Calendar.current
        let now = Date()
        let dayStart = calendar.startOfDay(for: now)
        let today = HKQuery.predicateForSamples(withStart: dayStart, end: now, options: [])
        guard let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) else { return [] }
        let month = HKQuery.predicateForSamples(withStart: monthAgo, end: now, options: [])

        let brUnit = HKUnit.count().unitDivided(by: .minute())
        let vo2Unit = HKUnit(from: "ml/kg*min")

        async let respiratory = stat(.respiratoryRate, .discreteAverage, today, unit: brUnit)
        async let spo2 = stat(.oxygenSaturation, .discreteAverage, today, unit: .percent())
        async let vo2 = stat(.vo2Max, .discreteAverage, month, unit: vo2Unit)
        async let recovery = stat(.heartRateRecoveryOneMinute, .discreteAverage, month, unit: brUnit)
        async let steps = stat(.stepCount, .cumulativeSum, today, unit: .count())
        async let energy = stat(.activeEnergyBurned, .cumulativeSum, today, unit: .kilocalorie())

        var signals: [RecoveryEngine.Signal] = []
        if let respiratory = await respiratory {
            signals.append(.init(name: "Respiratory", systemImage: "lungs.fill",
                                 value: "\(respiratory.formatted(.number.precision(.fractionLength(1)))) /min",
                                 detail: "Today's average breathing rate", connected: true))
        }
        if let spo2 = await spo2 {
            signals.append(.init(name: "Blood O₂", systemImage: "drop.degreesign.fill",
                                 value: "\(Int((spo2 * 100).rounded()))%",
                                 detail: "Today's average SpO₂", connected: true))
        }
        if let vo2 = await vo2 {
            signals.append(.init(name: "VO₂max", systemImage: "figure.run",
                                 value: vo2.formatted(.number.precision(.fractionLength(1))),
                                 detail: "Cardio fitness (30-day)", connected: true))
        }
        if let recovery = await recovery {
            signals.append(.init(name: "Post-workout HR drop", systemImage: "arrow.down.heart.fill",
                                 value: "\(Int(recovery.rounded())) bpm",
                                 detail: "Average first-minute decrease after exercise · 30 days", connected: true))
        }
        if let steps = await steps {
            signals.append(.init(name: "Steps", systemImage: "shoeprints.fill",
                                 value: "\(Int(steps))",
                                 detail: "Today", connected: true))
        }
        if let energy = await energy {
            signals.append(.init(name: "Active energy", systemImage: "flame.fill",
                                 value: "\(Int(energy)) kcal",
                                 detail: "Today", connected: true))
        }
        return signals
        #else
        return []
        #endif
    }

    #if canImport(HealthKit)
    private func quantitySamples(_ id: HKQuantityTypeIdentifier, from start: Date, to end: Date) async -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }

    /// Every sleep-analysis sample in the window — asleep stages, awake, and
    /// in-bed. Callers that only want time asleep filter with `isAsleep`.
    private func sleepSamples(from start: Date?, to end: Date) async -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private func isAsleep(_ sample: HKCategorySample) -> Bool {
        HKCategoryValueSleepAnalysis.allAsleepValues.contains(
            HKCategoryValueSleepAnalysis(rawValue: sample.value) ?? .inBed
        )
    }
    #endif

    /// True when a Garmin (synced through Garmin Connect) is supplying sleep
    /// to Apple Health but no HRV samples exist in the window. Garmin Connect
    /// doesn't sync HRV, so these users run readiness on sleeping HR + sleep;
    /// the recovery screen explains the gap instead of silently scoring less.
    func detectGarminHRVGap(days: Int = 7) async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable else { return false }
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return false }
        let hrv = await quantitySamples(.heartRateVariabilitySDNN, from: start, to: end)
        guard hrv.isEmpty else { return false }
        let sleep = await sleepSamples(from: start, to: end)
        return sleep.contains {
            let source = $0.sourceRevision.source
            return source.bundleIdentifier.lowercased().contains("garmin")
                || source.name.lowercased().contains("garmin")
        }
        #else
        return false
        #endif
    }

    /// used by backup restore to refill `bodyweightKg` on bodyweight sets.
    func bodyMassKg(near date: Date, toleranceDays: Int = 7) async -> Double? {
        #if canImport(HealthKit)
        guard isAvailable,
              let start = Calendar.current.date(byAdding: .day, value: -toleranceDays, to: date),
              let end = Calendar.current.date(byAdding: .day, value: toleranceDays, to: date) else { return nil }
        let unit = HKUnit.gramUnit(with: .kilo)
        let samples = await quantitySamples(.bodyMass, from: start, to: end)
        return samples
            .min { abs($0.endDate.timeIntervalSince(date)) < abs($1.endDate.timeIntervalSince(date)) }?
            .quantity.doubleValue(for: unit)
        #else
        return nil
        #endif
    }

    /// The HKWorkout whose window matches (±tolerance) — lets restore
    /// re-link `hkWorkoutUUID` so the Health importer's strong dedup key
    /// works again on the new device.
    func workoutUUID(matchingStart start: Date, end: Date, tolerance: TimeInterval = 120) async -> UUID? {
        #if canImport(HealthKit)
        guard isAvailable,
              let windowStart = Calendar.current.date(byAdding: .second, value: -Int(tolerance), to: start),
              let windowEnd = Calendar.current.date(byAdding: .second, value: Int(tolerance), to: end) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])
        let workouts: [HKWorkout] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                      limit: 10, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        return workouts.first {
            abs($0.startDate.timeIntervalSince(start)) <= tolerance
                && abs($0.endDate.timeIntervalSince(end)) <= tolerance
        }?.uuid
        #else
        return nil
        #endif
    }

    /// Body-mass history in kilograms — powers the Measures screen and
    /// bodyweight-mode volume math. Display units are applied at the UI edge.
    func bodyMassSeries(
        days: Int = 90,
        endingAt end: Date = Date(),
        calendar: Calendar = .current
    ) async -> [(date: Date, value: Double)] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        guard let start = calendar.date(byAdding: .day, value: -days, to: end) else { return [] }
        let unit = HKUnit.gramUnit(with: .kilo)
        let samples = await quantitySamples(.bodyMass, from: start, to: end)
        return samples
            .sorted { $0.endDate < $1.endDate }
            .map { ($0.endDate, $0.quantity.doubleValue(for: unit)) }
        #else
        return []
        #endif
    }

    // MARK: - Writing (save workout to Health)

    func saveWorkout(from start: Date, to end: Date, isCardio: Bool, isYoga: Bool = false, modality: CardioKind?, energyKcal: Double?, distanceMeters: Double?, effortScore: Double? = nil, workoutName: String? = nil) async {
        #if canImport(HealthKit)
        guard isConnected, end > start else { return }
        let config = HKWorkoutConfiguration()
        // Yoga wins over the cardio flag: yoga sessions ride the cardio
        // session model, and Apple Health renders `.yoga` natively.
        config.activityType = isYoga ? .yoga : (isCardio ? (modality?.hkActivityType ?? .other) : .traditionalStrengthTraining)
        config.locationType = modality?.supportsOutdoorRoute == true ? .outdoor : .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            if let workoutName = workoutName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workoutName.isEmpty {
                // Fitness keeps the HealthKit activity type for classification,
                // while presenting the ForgeFit routine title to the user.
                try? await builder.addMetadata([HKMetadataKeyWorkoutBrandName: workoutName])
            }
            var samples: [HKSample] = []
            if let energyKcal, let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                let qty = HKQuantity(unit: .kilocalorie(), doubleValue: energyKcal)
                samples.append(HKCumulativeQuantitySample(type: type, quantity: qty, start: start, end: end))
            }
            if let distanceMeters, isCardio, let type = HKQuantityType.quantityType(forIdentifier: modality == .cycle ? .distanceCycling : .distanceWalkingRunning) {
                let qty = HKQuantity(unit: .meter(), doubleValue: distanceMeters)
                samples.append(HKCumulativeQuantitySample(type: type, quantity: qty, start: start, end: end))
            }
            if !samples.isEmpty { try await builder.addSamples(samples) }
            try await builder.endCollection(at: end)
            let saved = try await builder.finishWorkout()
            // T3-6: relate the logged effort (1–10, from session RPE) to the
            // workout so Fitness/Smart Stack show ForgeFit's real number
            // instead of Apple's estimate. Best-effort like the rest.
            if let saved,
               let effortScore,
               let effortType = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore) {
                let clamped = min(10, max(1, effortScore.rounded()))
                let sample = HKQuantitySample(
                    type: effortType,
                    quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: clamped),
                    start: start,
                    end: end
                )
                _ = try? await store.relateWorkoutEffortSample(sample, with: saved, activity: nil)
            }
        } catch {
            // Non-fatal: writing is best-effort.
        }
        #endif
    }

    /// Write heart-rate readings captured from a BLE monitor during a workout.
    /// Downsampled to one sample per 5 s to keep write volume sane; tagged so
    /// ForgeFit's samples are identifiable next to watch/Garmin-synced data.
    func saveHeartRateSamples(_ samples: [(date: Date, bpm: Int)]) async {
        #if canImport(HealthKit)
        guard isAvailable, !samples.isEmpty,
              let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        var hkSamples: [HKQuantitySample] = []
        var lastWritten = Date.distantPast
        for sample in samples.sorted(by: { $0.date < $1.date }) where sample.date.timeIntervalSince(lastWritten) >= 5 {
            lastWritten = sample.date
            hkSamples.append(HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: Double(sample.bpm)),
                start: sample.date,
                end: sample.date,
                metadata: [HKMetadataKeyWasUserEntered: false, "ForgeFitSource": "bluetooth-hrm"]
            ))
        }
        try? await store.save(hkSamples)
        #endif
    }

    @discardableResult
    func logBodyMass(kilograms: Double, date: Date = Date()) async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: .bodyMass),
              kilograms > 0 else { return false }
        if store.authorizationStatus(for: type) != .sharingAuthorized {
            _ = await requestAuthorization()
        }
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kilograms),
            start: date,
            end: date
        )
        do {
            try await store.save(sample)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    #if canImport(HealthKit)
    private func latestQuantity(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard isAvailable,
              let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples as? [HKQuantitySample])?.first?.quantity.doubleValue(for: unit)
                cont.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func stat(_ id: HKQuantityTypeIdentifier, _ option: HKStatisticsOptions, _ predicate: NSPredicate, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await withCheckedContinuation { cont in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: option) { _, stats, _ in
                let qty: HKQuantity?
                switch option {
                case .discreteAverage: qty = stats?.averageQuantity()
                case .discreteMax: qty = stats?.maximumQuantity()
                default: qty = stats?.sumQuantity()
                }
                cont.resume(returning: qty?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
    #endif
}

#if canImport(HealthKit)
extension CardioKind {
    nonisolated var hkActivityType: HKWorkoutActivityType {
        switch self {
        case .run, .trailRun: .running
        case .walk: .walking
        case .cycle: .cycling
        case .row: .rowing
        case .elliptical: .elliptical
        case .stair: .stairClimbing
        case .jumpRope: .jumpRope
        case .skate: .skatingSports
        case .swim: .swimming
        case .other: .other
        }
    }
}
#endif
