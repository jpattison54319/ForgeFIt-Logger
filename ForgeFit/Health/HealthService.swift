import Foundation
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

/// Reads and writes cardiovascular / workout data with Apple Health & Fitness
/// (populated by Apple Watch or any connected source). Reading auto-fills cardio
/// metrics for a segment's time window; writing saves finished workouts back to
/// Health. Degrades gracefully when Health is unavailable.
final class HealthService {
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
        t.insert(HKSeriesType.workoutRoute())
        return t
    }

    private var shareTypes: Set<HKSampleType> {
        var t: Set<HKSampleType> = [HKObjectType.workoutType()]
        for id: HKQuantityTypeIdentifier in [.activeEnergyBurned, .distanceWalkingRunning, .distanceCycling, .bodyMass] {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { t.insert(type) }
        }
        return t
    }
    #endif

    @discardableResult
    func requestAuthorization() async -> Bool {
        #if canImport(HealthKit)
        guard isAvailable else { return false }
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

    /// Per-day HRV / resting HR / sleep for the last `days` days — the series
    /// RecoveryEngine baselines against (60-day HRV/RHR baselines, 14-day
    /// sleep debt).
    func dailyMetrics(days: Int = 60) async -> [RecoveryEngine.DailyHealthMetric] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        let calendar = Calendar.current
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: end)) else { return [] }

        async let hrvSamples = quantitySamples(.heartRateVariabilitySDNN, from: start, to: end)
        async let rhrSamples = quantitySamples(.restingHeartRate, from: start, to: end)
        async let sleepSamples = sleepSamples(from: start, to: end)

        let msUnit = HKUnit.secondUnit(with: .milli)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        // Bucket by calendar day. Sleep is attributed to the day it ENDED
        // (last night's sleep belongs to today's readiness).
        var hrvByDay: [Date: [Double]] = [:]
        for sample in await hrvSamples {
            hrvByDay[calendar.startOfDay(for: sample.endDate), default: []].append(sample.quantity.doubleValue(for: msUnit))
        }
        var rhrByDay: [Date: [Double]] = [:]
        for sample in await rhrSamples {
            rhrByDay[calendar.startOfDay(for: sample.endDate), default: []].append(sample.quantity.doubleValue(for: bpmUnit))
        }
        var sleepByDay: [Date: Int] = [:]
        for sample in await sleepSamples {
            sleepByDay[calendar.startOfDay(for: sample.endDate), default: 0]
                += Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
        }

        let allDays = Set(hrvByDay.keys).union(rhrByDay.keys).union(sleepByDay.keys)
        return allDays.sorted().map { day in
            RecoveryEngine.DailyHealthMetric(
                date: day,
                hrvSDNN: hrvByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                restingHR: rhrByDay[day].map { Int(($0.reduce(0, +) / Double($0.count)).rounded()) },
                sleepTotalMinutes: sleepByDay[day],
                source: "healthkit",
                hrvSampleCount: hrvByDay[day]?.count
            )
        }
        #else
        return []
        #endif
    }

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
            signals.append(.init(name: "HR recovery", systemImage: "arrow.down.heart.fill",
                                 value: "\(Int(recovery.rounded())) bpm",
                                 detail: "1-min drop after workouts (30-day)", connected: true))
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

    /// Asleep-stage sleep samples only (excludes in-bed and awake time).
    private func sleepSamples(from start: Date, to end: Date) async -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                let asleep = (samples as? [HKCategorySample])?.filter {
                    HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: $0.value) ?? .inBed)
                } ?? []
                cont.resume(returning: asleep)
            }
            store.execute(query)
        }
    }
    #endif

    /// Body-mass history in kilograms — powers the Measures screen and
    /// bodyweight-mode volume math. Display units are applied at the UI edge.
    func bodyMassSeries(days: Int = 90) async -> [(date: Date, value: Double)] {
        #if canImport(HealthKit)
        guard isAvailable else { return [] }
        let end = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -days, to: end) else { return [] }
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

    func saveWorkout(from start: Date, to end: Date, isCardio: Bool, modality: CardioKind?, energyKcal: Double?, distanceMeters: Double?) async {
        #if canImport(HealthKit)
        guard isConnected, end > start else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = isCardio ? (modality?.hkActivityType ?? .other) : .traditionalStrengthTraining
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
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
            _ = try await builder.finishWorkout()
        } catch {
            // Non-fatal: writing is best-effort.
        }
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
    var hkActivityType: HKWorkoutActivityType {
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
