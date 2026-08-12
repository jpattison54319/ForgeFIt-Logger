import Foundation
import os
import ForgeCore
#if canImport(HealthKit)
import HealthKit
#endif

/// Metrics pulled from HealthKit for a cardio segment's time window.
struct CardioSnapshot: Equatable, Sendable {
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

/// Pure, HealthKit-free safety bounds for the long-range recovery fetches in
/// `HealthService.dailyMetrics`.
///
/// The all-day channels are fetched in bounded date chunks — never a global
/// cap — so a legitimate 730-day history loads in full across chunks while
/// every single request stays small. Each channel has a deliberately generous
/// practical ceiling; a corrupted or unexpectedly dense dataset is surfaced
/// as `.truncated` instead of allowing several million HealthKit objects to be
/// materialized in one callback and risking an out-of-memory termination.
nonisolated enum HealthQueryBounds {
    /// Chunk width for low-frequency all-day channels (HRV, resting HR,
    /// respiratory rate, SpO₂, sleep). Thirty days keeps the 730-day insight
    /// path to 25 requests per channel instead of 105, while these channels
    /// still remain far below their per-request safety ceiling.
    static let allDayChunkWidth: TimeInterval = 30 * 24 * 60 * 60

    /// Per-channel 30-day caps. Their combined worst-case callback payload is
    /// bounded while remaining far above normal Apple Watch/ring density.
    static let hrvSamplesPerChunk = 20_000
    static let restingHRSamplesPerChunk = 5_000
    static let respiratorySamplesPerChunk = 50_000
    static let oxygenSamplesPerChunk = 250_000
    static let sleepSamplesPerChunk = 100_000

    /// Keep compound nocturnal-HR predicates and callback payloads bounded
    /// independently of total history length. Three ordinary sleep windows at
    /// 1 Hz from three overlapping sources remain below this cap.
    static let sleepWindowsPerQuery = 3
    static let nocturnalHRSamplesPerQuery = 300_000

    /// Whether a sample query hit its `limit` — the only honest "bounded"
    /// signal HealthKit can give. `count == limit` can only mean more samples
    /// exist than were requested; a false positive requires a dataset of
    /// exactly `limit` samples.
    static func isTruncated(_ count: Int, limit: Int) -> Bool {
        limit > 0 && count == limit
    }

    static func chunkRanges(totalCount: Int, maximumCount: Int) -> [Range<Int>] {
        guard totalCount > 0, maximumCount > 0 else { return [] }
        return stride(from: 0, to: totalCount, by: maximumCount).map {
            $0..<min($0 + maximumCount, totalCount)
        }
    }
}

/// Result of a bounded, cancellable HealthKit sample fetch.
nonisolated enum BoundedQueryOutcome<Value> {
    case value(Value)
    /// The enclosing task was cancelled before or during the fetch; the
    /// in-flight query was stopped and no data (partial or otherwise) is
    /// reported.
    case cancelled
    /// A query hit its physical ceiling — an anomaly (no wearable produces
    /// that much data), surfaced rather than silently truncating results.
    case truncated

    var samples: Value? {
        if case .value(let samples) = self { return samples }
        return nil
    }

    var isTruncated: Bool {
        if case .truncated = self { return true }
        return false
    }
}

/// Once-only delivery coordination between a HealthKit results handler and
/// the enclosing task's cancellation, which can arrive on any thread and at
/// any phase of a query's life:
///
/// - **before the query exists** — cancellation wins: `register` resumes the
///   cancellation immediately and the caller never starts the query;
/// - **while in flight** — cancellation resumes `.cancelled` exactly once and
///   stops the underlying query at most once (`markQueryStarted` makes the
///   query stoppable);
/// - **after the handler already delivered** — cancellation is a no-op; a
///   completed query does not need stopping.
///
/// Both the resume and the stop are invoked at most once, so a handler that
/// lands after a cancellation can neither double-resume the continuation nor
/// double-stop the query. The type is HealthKit-free so the phases can be
/// unit-driven with recording closures.
///
/// `@unchecked Sendable` is sound: every mutable property is read and written
/// exclusively under `lock`, and `cancelledValue` is immutable, so the gate is
/// safe to hand to `withTaskCancellationHandler`'s `@Sendable` closures.
nonisolated final class InFlightHealthQuery<Value>: @unchecked Sendable {
    private enum Settlement {
        case value(Value)
    }

    private let lock = NSLock()
    private let cancelledValue: Value
    private var resume: ((Value) -> Void)?
    private var stop: (() -> Void)?
    private var queryStarted = false
    private var finished = false
    private var cancellationWon = false
    private var settlementBeforeRegistration: Settlement?

    init(cancelledValue: Value) {
        self.cancelledValue = cancelledValue
    }

    /// Publishes the resume and stop actions. Returns false when a
    /// cancellation already won — in that case `resume(cancelledValue)` is
    /// called immediately and the caller must not start any work (there is
    /// nothing to stop).
    @discardableResult
    func register(resume: @escaping (Value) -> Void, stop: @escaping () -> Void) -> Bool {
        var cancelledEarly = false
        var earlySettlement: Settlement?
        lock.lock()
        if finished {
            cancelledEarly = true
            earlySettlement = settlementBeforeRegistration ?? .value(cancelledValue)
        } else {
            self.resume = resume
            self.stop = stop
        }
        lock.unlock()
        if case .value(let value) = earlySettlement {
            resume(value)
        }
        return !cancelledEarly
    }

    /// Claims the right to start the query. A cancellation that already won
    /// returns false, so the caller never calls `execute`.
    func beginQueryStart() -> Bool {
        lock.lock()
        let mayStart = !finished
        lock.unlock()
        return mayStart
    }

    /// Called immediately after `execute`. If cancellation landed in the tiny
    /// begin/execute window, it deliberately deferred `stop` until this point
    /// so we never stop an unstarted query and then accidentally execute it.
    func markQueryStarted() {
        lock.lock()
        queryStarted = true
        let shouldStop = cancellationWon
        lock.unlock()
        if shouldStop { attemptStop() }
    }

    /// The query's results handler delivered (any HealthKit thread).
    func finish(_ value: Value) {
        settle()?(value)
    }

    /// Enclosing task cancelled (any thread, any phase).
    func cancel() {
        cancel(returning: cancelledValue)
    }

    /// A lifecycle owner can settle with a distinct value while retaining the
    /// exact same once-only stop semantics as ordinary task cancellation.
    func cancel(returning value: Value) {
        var deliveredResume: ((Value) -> Void)?
        var shouldStop = false
        lock.lock()
        if !finished {
            finished = true
            deliveredResume = resume
            resume = nil
            if deliveredResume == nil {
                settlementBeforeRegistration = .value(value)
            }
            cancellationWon = true
            shouldStop = queryStarted
        }
        lock.unlock()
        if let deliveredResume {
            deliveredResume(value)
        }
        if shouldStop { attemptStop() }
    }

    private func settle() -> ((Value) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        finished = true
        let delivered = resume
        resume = nil
        return delivered
    }

    /// Invokes `stop` at most once, and only once the query target exists.
    private func attemptStop() {
        lock.lock()
        guard queryStarted else {
            lock.unlock()
            return
        }
        queryStarted = false
        let stopQuery = stop
        stop = nil
        lock.unlock()
        stopQuery?()
    }
}

#if canImport(HealthKit)
/// Process-wide ownership for read-only HealthKit queries. A live workout can
/// begin from the phone or Watch while any screen is still resident; this gate
/// stops every registered background read and lets its caller transparently
/// retry after the workout instead of publishing an empty cancellation value.
@MainActor
final class LiveWorkoutHealthQueryGate {
    static let shared = LiveWorkoutHealthQueryGate()

    private var isLiveWorkoutActive = false
    private var cancellers: [UUID: @Sendable () -> Void] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func setLiveWorkoutActive(_ isActive: Bool) {
        guard isLiveWorkoutActive != isActive else { return }
        isLiveWorkoutActive = isActive
        if isActive {
            let pending = Array(cancellers.values)
            cancellers.removeAll()
            pending.forEach { $0() }
        } else {
            let waiters = Array(idleWaiters.values)
            idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// Returns nil when a workout won the race before registration.
    func register(_ cancel: @escaping @Sendable () -> Void) -> UUID? {
        guard !isLiveWorkoutActive else { return nil }
        let id = UUID()
        cancellers[id] = cancel
        return id
    }

    func unregister(_ id: UUID) {
        cancellers[id] = nil
    }

    func waitUntilIdle() async {
        guard isLiveWorkoutActive else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !isLiveWorkoutActive {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                LiveWorkoutHealthQueryGate.shared.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }
}

private enum HealthQueryRunOutcome<Value> {
    case value(Value)
    case liveWorkoutPause
    case taskCancellation
}
#endif

/// Reads and writes cardiovascular / workout data with Apple Health & Fitness
/// (populated by Apple Watch or any connected source). Reading auto-fills cardio
/// metrics for a segment's time window; writing saves finished workouts back to
/// Health. Degrades gracefully when Health is unavailable.
/// HealthKit is thread-safe, and all values returned from this service are
/// immutable projections. Keep the service nonisolated so HealthKit reads
/// never hop back to the app target's default MainActor; the heavy per-day
/// bucketing, binning, and source-dominance pass runs behind the explicit
/// `CancellableDetachedWork` boundary inside `dailyMetrics`, so no caller —
/// including `@MainActor` ones like `InsightDataCoordinator` — can inherit
/// that CPU work onto the main actor.
nonisolated final class HealthService: @unchecked Sendable {
    static let shared = HealthService()

    /// Anomaly channel for safety-bound hits: a bounded query reaching a
    /// physical ceiling is surfaced here and the refresh is dropped — never
    /// silently truncated into seemingly-real metrics.
    private static let queryBoundsLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForgeFit",
        category: "HealthQueryBounds"
    )

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

    var authorizationState: HealthAuthorizationState {
        #if canImport(HealthKit)
        guard isAvailable else { return .unavailable }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return .connected
        case .sharingDenied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .failed("Apple Health returned an unknown permission state.")
        }
        #else
        return .unavailable
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
        let outcome = await requestAuthorizationOutcome()
        await HealthAuthorizationStore.shared.apply(outcome)
        return outcome.isConnected
    }

    func requestAuthorizationOutcome(
        timeout: Duration = .seconds(45)
    ) async -> HealthAuthorizationState {
        #if canImport(HealthKit)
        let current = authorizationState
        guard current != .unavailable else { return .unavailable }
        guard current != .connected else { return .connected }
        // HealthKit will not present the system sheet a second time after
        // workout write access was denied. Return an explicit recovery state
        // so callers show the Health-app affordance instead of silently no-op.
        guard current != .denied else { return .denied }
        // UI test automation reinstalls the app fresh, so HealthKit
        // authorization has never been decided; requesting it would pop the
        // real system permission sheet full-screen over whatever the test is
        // driving, and no test drives through that sheet (it covers dozens of
        // data-type toggles, not a one-tap "Allow"). --reset-store is already
        // this codebase's signal for an automation launch; real users never
        // pass it, so this only ever short-circuits test runs.
        guard !ProcessInfo.processInfo.arguments.contains("--reset-store") else { return .notDetermined }
        return await HealthAuthorizationRequestRunner.run(timeout: timeout) { [self] complete in
            store.requestAuthorization(toShare: shareTypes, read: readTypes) { success, error in
                if let error {
                    complete(.failed(error.localizedDescription))
                    return
                }
                guard success else {
                    complete(.failed("The system did not complete the permission request."))
                    return
                }
                let resolved = self.authorizationState
                // Completion means the sheet resolved, not that access was
                // granted. A still-undetermined write type is not success.
                complete(resolved == .notDetermined ? .denied : resolved)
            }
        }
        #else
        return .unavailable
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

        // Five bounded, cancellable channel fetches. Each channel loads the
        // whole range in 30-day date chunks deduplicated at chunk seams by
        // sample UUID, so there is NO global cap — a legitimate 730-day
        // history is fetched in full across chunks while every single request
        // stays small and cancellable. A chunk's per-request limit is the
        // practical per-channel safety ceiling; a hit surfaces as `.truncated`
        // (logged, refresh dropped) instead of silently shortening results or
        // materializing an unbounded callback payload.
        let chunkWidth = HealthQueryBounds.allDayChunkWidth

        async let hrvOutcome = chunkedQuantitySamples(.heartRateVariabilitySDNN, from: start, to: end, chunkWidth: chunkWidth, limitPerChunk: HealthQueryBounds.hrvSamplesPerChunk)
        async let rhrOutcome = chunkedQuantitySamples(.restingHeartRate, from: start, to: end, chunkWidth: chunkWidth, limitPerChunk: HealthQueryBounds.restingHRSamplesPerChunk)
        async let respiratoryOutcome = chunkedQuantitySamples(.respiratoryRate, from: start, to: end, chunkWidth: chunkWidth, limitPerChunk: HealthQueryBounds.respiratorySamplesPerChunk)
        async let oxygenOutcome = chunkedQuantitySamples(.oxygenSaturation, from: start, to: end, chunkWidth: chunkWidth, limitPerChunk: HealthQueryBounds.oxygenSamplesPerChunk)
        async let sleepOutcome = chunkedSleepSamples(from: start, to: end, chunkWidth: chunkWidth, limitPerChunk: HealthQueryBounds.sleepSamplesPerChunk)

        let (hrvResult, rhrResult, respiratoryResult, oxygenResult, sleepResult) = await (
            hrvOutcome, rhrOutcome, respiratoryOutcome, oxygenOutcome, sleepOutcome
        )

        // A channel reached its physical ceiling — impossible for wearable
        // data, so surface the anomaly and drop the refresh rather than serve
        // partial or truncated metrics. (.cancelled channels are folded into
        // the guard below, matching the pre-FF-009 behaviour on cancellation.)
        guard !hrvResult.isTruncated, !rhrResult.isTruncated, !respiratoryResult.isTruncated,
              !oxygenResult.isTruncated, !sleepResult.isTruncated else {
            Self.queryBoundsLogger.critical("An all-day HealthKit channel exceeded its physical ceiling for days=\(days, privacy: .public); dropping this refresh instead of returning truncated metrics")
            return []
        }
        guard !Task.isCancelled else { return [] }

        let hrvSamples = hrvResult.samples ?? []
        let rhrSamples = rhrResult.samples ?? []
        let respiratorySamples = respiratoryResult.samples ?? []
        let oxygenSamples = oxygenResult.samples ?? []
        let allSleepSegments = sleepResult.samples ?? []
        let sleepSegments = allSleepSegments.filter(isAsleep)

        // Nocturnal window: restrict HRV to sleep and derive sleeping HR — the
        // validated overnight measurement window (Plews 2013, Buchheit 2014),
        // preferred over Apple's all-day HRV mean and daytime resting HR.
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: sleepSegments.map { ($0.startDate, $0.endDate) },
            calendar: calendar
        )
        let nocturnalHROutcome = await heartRateSamplesDuringSleep(windows: windows)
        guard !Task.isCancelled else { return [] }
        guard case .value(let nocturnalHR) = nocturnalHROutcome else {
            if nocturnalHROutcome.isTruncated {
                Self.queryBoundsLogger.critical("Nocturnal HR fetch exceeded its physical ceiling across \(windows.count, privacy: .public) sleep windows; dropping this refresh instead of returning truncated metrics")
            }
            return []
        }
        // Pure, HealthKit-free Sendable inputs cross the detached boundary; the
        // heavy bucketing, binning, and source-dominance math lives in
        // `RecoveryDailyAggregator` and runs on a detached executor so it
        // never inherits a MainActor caller, with the caller's cancellation
        // forwarded into the work.
        let msUnit = HKUnit.secondUnit(with: .milli)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        let inputs = RecoveryDailyAggregator.SampleInputs(
            calendar: calendar,
            hrv: hrvSamples.map { (start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: msUnit), sourceBundleID: $0.sourceRevision.source.bundleIdentifier) },
            restingHR: rhrSamples.map { (start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: bpmUnit), sourceBundleID: $0.sourceRevision.source.bundleIdentifier) },
            respiratory: respiratorySamples.map { (start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: bpmUnit), sourceBundleID: $0.sourceRevision.source.bundleIdentifier) },
            oxygen: oxygenSamples.map { (start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: .percent()) * 100, sourceBundleID: $0.sourceRevision.source.bundleIdentifier) },
            asleepSegments: sleepSegments.map { (start: $0.startDate, end: $0.endDate, sourceBundleID: $0.sourceRevision.source.bundleIdentifier) },
            allSleepSegments: allSleepSegments.map { (start: $0.startDate, end: $0.endDate, rawValue: $0.value) },
            windows: windows,
            nocturnalHR: nocturnalHR
        )
        return await CancellableDetachedWork.run {
            RecoveryDailyAggregator.daily(inputs)
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

        return await Self.runCancellableQuery(store: store, cancelledValue: [:]) { finish in
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
                finish(values)
            }
            return query
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

        return await Self.runCancellableQuery(store: store, cancelledValue: [:]) { finish in
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
                finish(values)
            }
            return query
        }
    }

    /// Mutable slot for the in-flight `HKQuery` so the cancellation path can
    /// stop it the moment it exists, even when cancellation and construction
    /// race. Lock-guarded: the writer (query construction) and the reader (the
    /// cancel path on another thread) must not race.
    private final class InFlightQueryTarget: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HKQuery?
        var query: HKQuery? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                stored = newValue
                lock.unlock()
            }
        }
    }

    /// Executes one HealthKit query with real lifecycle cancellation. Cancelling
    /// only the surrounding Swift task is insufficient for callback-based
    /// HealthKit APIs: without `store.stop`, the database query keeps consuming
    /// resources behind the live logger until its callback eventually arrives.
    ///
    /// Internal so the automatic workout importer can use the identical
    /// once-only continuation/stop gate for its own HealthKit reads.
    static func runCancellableQuery<Value>(
        store: HKHealthStore,
        cancelledValue: Value,
        makeQuery: (_ finish: @escaping (Value) -> Void) -> HKQuery
    ) async -> Value {
        while !Task.isCancelled {
            await LiveWorkoutHealthQueryGate.shared.waitUntilIdle()
            guard !Task.isCancelled else { return cancelledValue }

            let target = InFlightQueryTarget()
            let queryGate = InFlightHealthQuery<HealthQueryRunOutcome<Value>>(
                cancelledValue: .taskCancellation
            )
            guard let registrationID = await LiveWorkoutHealthQueryGate.shared.register({
                queryGate.cancel(returning: .liveWorkoutPause)
            }) else {
                continue
            }

            let outcome = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard queryGate.register(
                        resume: { continuation.resume(returning: $0) },
                        stop: {
                            if let query = target.query { store.stop(query) }
                        }
                    ) else {
                        return
                    }
                    let query = makeQuery { queryGate.finish(.value($0)) }
                    target.query = query
                    guard queryGate.beginQueryStart() else { return }
                    store.execute(query)
                    queryGate.markQueryStarted()
                }
            } onCancel: {
                queryGate.cancel()
            }
            await LiveWorkoutHealthQueryGate.shared.unregister(registrationID)

            switch outcome {
            case .value(let value):
                return value
            case .liveWorkoutPause:
                continue
            case .taskCancellation:
                return cancelledValue
            }
        }
        return cancelledValue
    }

    /// Runs one bounded, cancellable `HKSampleQuery`, coordinating the results
    /// handler and the enclosing task's cancellation through
    /// `InFlightHealthQuery` so the continuation resumes exactly once and the
    /// underlying query is stopped at most once. A result at exactly `limit`
    /// is reported as `.truncated` — HealthKit offers no cursor, so that can
    /// only mean more samples exist than were requested.
    private func runSampleQuery<Sample: HKSample>(
        type: HKSampleType,
        predicate: NSPredicate?,
        limit: Int,
        sortDescriptors: [NSSortDescriptor]?
    ) async -> BoundedQueryOutcome<[Sample]> {
        await Self.runCancellableQuery(store: store, cancelledValue: .cancelled) { finish in
            HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: limit,
                sortDescriptors: sortDescriptors
            ) { _, samples, _ in
                let typed = (samples as? [Sample]) ?? []
                let outcome: BoundedQueryOutcome<[Sample]> =
                    HealthQueryBounds.isTruncated(typed.count, limit: limit) ? .truncated : .value(typed)
                finish(outcome)
            }
        }
    }

    /// Fetches every sample of `type` within `range` using bounded date
    /// chunks, unions them, and deduplicates at chunk seams by sample UUID.
    /// Chunk predicates mirror the range predicate's options (`[]`), so
    /// membership semantics are unchanged; HealthKit returns a sample for
    /// every chunk its dates overlap, so a seam sample or a long multi-chunk
    /// sample can appear more than once — the UUID set collapses those to the
    /// single sample the old all-at-once query returned. There is no global
    /// cap: a legitimate 730-day history is fetched in full across chunks.
    /// Returns `.truncated` when one chunk reached its practical safety cap —
    /// the caller surfaces it rather than serving partial results.
    private func chunkedSamples<Sample: HKSample>(
        of type: HKSampleType,
        range: (start: Date, end: Date),
        chunkWidth: TimeInterval,
        limitPerChunk: Int,
        sortDescriptors: [NSSortDescriptor]?
    ) async -> BoundedQueryOutcome<[Sample]> {
        var cursor = range.start
        var chunks: [(start: Date, end: Date)] = []
        while cursor < range.end {
            let chunkEnd = min(cursor.addingTimeInterval(chunkWidth), range.end)
            chunks.append((cursor, chunkEnd))
            cursor = chunkEnd
        }
        guard !chunks.isEmpty else { return .value([]) }

        var collected: [Sample] = []
        var seen = Set<UUID>()
        for chunk in chunks {
            guard !Task.isCancelled else { return .cancelled }
            let predicate = HKQuery.predicateForSamples(withStart: chunk.start, end: chunk.end, options: [])
            let outcome: BoundedQueryOutcome<[Sample]> = await runSampleQuery(
                type: type,
                predicate: predicate,
                limit: limitPerChunk,
                sortDescriptors: sortDescriptors
            )
            switch outcome {
            case .value(let samples):
                for sample in samples where seen.insert(sample.uuid).inserted {
                    collected.append(sample)
                }
            case .cancelled:
                return .cancelled
            case .truncated:
                return .truncated
            }
        }
        return .value(collected)
    }

    private func chunkedQuantitySamples(
        _ id: HKQuantityTypeIdentifier,
        from start: Date,
        to end: Date,
        chunkWidth: TimeInterval,
        limitPerChunk: Int
    ) async -> BoundedQueryOutcome<[HKQuantitySample]> {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return .value([]) }
        return await chunkedSamples(of: type, range: (start, end), chunkWidth: chunkWidth, limitPerChunk: limitPerChunk, sortDescriptors: nil)
    }

    private func chunkedSleepSamples(
        from start: Date,
        to end: Date,
        chunkWidth: TimeInterval,
        limitPerChunk: Int
    ) async -> BoundedQueryOutcome<[HKCategorySample]> {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return .value([]) }
        return await chunkedSamples(of: type, range: (start, end), chunkWidth: chunkWidth, limitPerChunk: limitPerChunk, sortDescriptors: nil)
    }

    /// Heart-rate samples that fall within the given sleep windows. Long
    /// histories are split into bounded groups so HealthKit never receives a
    /// 730-clause predicate or materializes the entire result in one callback.
    /// UUID deduplication preserves the old inclusive-window semantics at
    /// boundaries. Each three-window group has a fixed practical cap, and an
    /// anomalous hit drops the whole refresh.
    private func heartRateSamplesDuringSleep(
        windows: [NocturnalAggregator.SleepWindow]
    ) async -> BoundedQueryOutcome<[(date: Date, bpm: Int, sourceBundleID: String)]> {
        guard !windows.isEmpty, let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return .value([])
        }
        let unit = HKUnit.count().unitDivided(by: .minute())
        var values: [(date: Date, bpm: Int, sourceBundleID: String)] = []
        var seen = Set<UUID>()
        for range in HealthQueryBounds.chunkRanges(
            totalCount: windows.count,
            maximumCount: HealthQueryBounds.sleepWindowsPerQuery
        ) {
            guard !Task.isCancelled else { return .cancelled }
            let group = Array(windows[range])
            let predicate = NSCompoundPredicate(orPredicateWithSubpredicates:
                group.map { HKQuery.predicateForSamples(withStart: $0.start, end: $0.end, options: []) })
            let outcome: BoundedQueryOutcome<[HKQuantitySample]> = await runSampleQuery(
                type: type,
                predicate: predicate,
                limit: HealthQueryBounds.nocturnalHRSamplesPerQuery,
                sortDescriptors: nil
            )
            switch outcome {
            case .value(let samples):
                for sample in samples where seen.insert(sample.uuid).inserted {
                    values.append((
                        sample.startDate,
                        Int(sample.quantity.doubleValue(for: unit).rounded()),
                        sample.sourceRevision.source.bundleIdentifier
                    ))
                }
            case .cancelled: return .cancelled
            case .truncated: return .truncated
            }
        }
        return .value(values)
    }

    /// Most frequently reported source, used by the untouched full-history
    /// `sleepHistory` path. The `dailyMetrics` path uses the moved copy inside
    /// `RecoveryDailyAggregator`; the two share identical semantics.
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
        return await Self.runCancellableQuery(store: store, cancelledValue: []) { finish in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                          sortDescriptors: nil) { _, samples, _ in
                finish((samples as? [HKQuantitySample]) ?? [])
            }
        }
    }

    /// Every sleep-analysis sample in the window — asleep stages, awake, and
    /// in-bed. Callers that only want time asleep filter with `isAsleep`.
    private func sleepSamples(from start: Date?, to end: Date) async -> [HKCategorySample] {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        return await Self.runCancellableQuery(store: store, cancelledValue: []) { finish in
            HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                          sortDescriptors: nil) { _, samples, _ in
                finish((samples as? [HKCategorySample]) ?? [])
            }
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
        let workouts: [HKWorkout] = await Self.runCancellableQuery(
            store: store,
            cancelledValue: []
        ) { finish in
            HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                          limit: 10, sortDescriptors: nil) { _, samples, _ in
                finish((samples as? [HKWorkout]) ?? [])
            }
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
        return await Self.runCancellableQuery(store: store, cancelledValue: nil) { finish in
            HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let value = (samples as? [HKQuantitySample])?.first?.quantity.doubleValue(for: unit)
                finish(value)
            }
        }
    }

    private func stat(_ id: HKQuantityTypeIdentifier, _ option: HKStatisticsOptions, _ predicate: NSPredicate, unit: HKUnit) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        return await Self.runCancellableQuery(store: store, cancelledValue: nil) { finish in
            HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: option) { _, stats, _ in
                let qty: HKQuantity?
                switch option {
                case .discreteAverage: qty = stats?.averageQuantity()
                case .discreteMax: qty = stats?.maximumQuantity()
                default: qty = stats?.sumQuantity()
                }
                finish(qty?.doubleValue(for: unit))
            }
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
