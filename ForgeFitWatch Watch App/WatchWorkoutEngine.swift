import Foundation
import HealthKit
import Observation
import ForgeCore
import WatchKit
import CoreLocation
import OSLog

/// Live health-metric collection on the wrist: one HKWorkoutSession +
/// HKLiveWorkoutBuilder per ForgeFit workout. Streams heart rate, energy, and
/// time-in-zone while the session runs (throttled to the phone via
/// `onMetrics`), and saves the HKWorkout to Apple Health when the workout is
/// finished from the watch.
@MainActor
@Observable
final class WatchWorkoutEngine: NSObject {
    static let shared = WatchWorkoutEngine()

    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "org.xpetsllc.ForgeFit.watchkitapp", category: "WorkoutSession")
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private var collectingRoute = false

    private(set) var isRunning = false
    private(set) var heartRate: Int?
    private(set) var heartRateSampleDate: Date?
    private(set) var avgHR: Int?
    private(set) var maxHR: Int?
    private(set) var activeEnergyKcal: Double?
    private(set) var distanceMeters: Double?
    private(set) var zoneSeconds = [0, 0, 0, 0, 0]

    /// Throttled live-metrics stream (WatchStore forwards these to the phone).
    var onMetrics: ((WatchLiveMetrics) -> Void)?

    /// The user's HR-zone model, synced from the phone via `WatchAppContext`.
    /// Drives live time-in-zone and (feature 4) the zone-adherence guard.
    var zoneConfig = HRZoneConfig()
    /// Active "zone lock" target (1...5); when set, the wrist buzzes on leaving
    /// and re-entering the zone. Synced from the phone via the snapshot.
    var zoneTarget: Int?

    private enum ZoneGuardState { case unknown, below, inZone, above }
    @ObservationIgnored private var zoneGuardState: ZoneGuardState = .unknown
    @ObservationIgnored private var lastZoneCueAt = Date.distantPast

    @ObservationIgnored private var lastZoneTick: Date?
    @ObservationIgnored private var lastSend = Date.distantPast
    @ObservationIgnored private var lastSentHR: Int?

    /// Includes HealthKit's asynchronous start/recovery windows. Callers use
    /// this instead of `isRunning` so they never create a second primary
    /// workout while the first is still transitioning to `.running`.
    var hasActiveSession: Bool {
        session != nil || isStarting || isRecovering
    }

    var hasReceivedHeartRate: Bool { heartRateSampleDate != nil }

    func liveHeartRate(at date: Date = Date()) -> Int? {
        guard let heartRate, let heartRateSampleDate else { return nil }
        let metrics = WatchLiveMetrics(heartRate: heartRate, asOf: heartRateSampleDate)
        return metrics.freshHeartRate(at: date)
    }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5
    }

    // MARK: - Authorization

    private var readTypes: Set<HKObjectType> {
        var t: Set<HKObjectType> = []
        for id: HKQuantityTypeIdentifier in [.heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling] {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { t.insert(type) }
        }
        return t
    }

    private var shareTypes: Set<HKSampleType> {
        var t: Set<HKSampleType> = [HKObjectType.workoutType()]
        for id: HKQuantityTypeIdentifier in [.activeEnergyBurned, .distanceWalkingRunning, .distanceCycling] {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { t.insert(type) }
        }
        t.insert(HKSeriesType.workoutRoute())
        return t
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
            return healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        } catch {
            logger.error("HealthKit authorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Session lifecycle

    func start(configuration: HKWorkoutConfiguration? = nil, startDate: Date = Date(), isYoga: Bool = false) {
        guard !hasActiveSession, HKHealthStore.isHealthDataAvailable() else { return }
        let requestID = UUID()
        startRequestID = requestID
        isStarting = true
        didAttemptFailureRestart = false
        // Authorization is requested lazily, right when the first session
        // starts — the prompt appears in context instead of at app launch.
        Task {
            defer {
                if startRequestID == requestID {
                    startRequestID = nil
                    isStarting = false
                }
            }
            let authorized = await requestAuthorization()
            guard startRequestID == requestID else { return }
            if authorized {
                // Yoga sessions record as .yoga so the Fitness app shows the
                // right rings and title (unless the phone handed a config).
                let resolved: HKWorkoutConfiguration?
                if configuration == nil, isYoga {
                    let c = HKWorkoutConfiguration()
                    c.activityType = .yoga
                    c.locationType = .indoor
                    resolved = c
                } else {
                    resolved = configuration
                }
                beginSession(configuration: resolved, startDate: startDate)
            } else {
                logger.error("Workout session not started because workout write access is unavailable")
            }
        }
    }

    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var isEndingSession = false
    @ObservationIgnored private var startRequestID: UUID?
    @ObservationIgnored private var recoveryRequestID: UUID?

    private func beginSession(configuration: HKWorkoutConfiguration?, startDate: Date, resetLiveMetrics: Bool = true) {
        guard session == nil else { return }
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .traditionalStrengthTraining
            c.locationType = .indoor
            return c
        }()
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            attach(session: session, builder: builder, configuration: config, startDate: startDate)
            if resetLiveMetrics {
                resetMetrics()
            } else {
                prepareMetricsForRestart()
            }
            session.startActivity(with: startDate)
            Task { [weak self] in
                do {
                    try await builder.beginCollection(at: startDate)
                } catch {
                    self?.handleSessionFailure(session, error: error)
                }
            }
            startRouteIfNeeded(for: config)
        } catch {
            logger.error("Unable to create workout session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shared wiring for both fresh sessions and recovered ones: delegates on
    /// both objects, data source, and the config kept for a restart after a
    /// mid-workout failure.
    private func attach(session: HKWorkoutSession, builder: HKLiveWorkoutBuilder, configuration: HKWorkoutConfiguration, startDate: Date) {
        session.delegate = self
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        builder.delegate = self
        self.session = session
        self.builder = builder
        activeConfiguration = configuration
        sessionStartDate = startDate
    }

    @ObservationIgnored private var activeConfiguration: HKWorkoutConfiguration?
    @ObservationIgnored private var sessionStartDate: Date?
    @ObservationIgnored private var didAttemptFailureRestart = false

    /// Reattach to a workout session that outlived the app process — watchOS
    /// relaunches us (workout-processing background mode) after a crash or
    /// jetsam, and without this the session would keep running headless with
    /// no metrics reaching the UI or the phone.
    func recoverSessionIfNeeded() async {
        guard session == nil, !isStarting, !isRecovering,
              HKHealthStore.isHealthDataAvailable() else { return }
        let requestID = UUID()
        recoveryRequestID = requestID
        isRecovering = true
        defer {
            if recoveryRequestID == requestID {
                recoveryRequestID = nil
                isRecovering = false
            }
        }
        do {
            let recoveredSession = try await healthStore.recoverActiveWorkoutSession()
            guard recoveryRequestID == requestID else {
                recoveredSession?.end()
                return
            }
            guard let recoveredSession, session == nil, !isStarting else { return }
            let recoveredBuilder = recoveredSession.associatedWorkoutBuilder()
            attach(
                session: recoveredSession,
                builder: recoveredBuilder,
                configuration: recoveredSession.workoutConfiguration,
                startDate: recoveredSession.startDate ?? Date()
            )

            // HealthKit restores both objects in their previous state. Calling
            // beginCollection again corrupts recovery; only delegates and the
            // data source are reattached here.
            restoreMetrics(from: recoveredBuilder)
            switch recoveredSession.state {
            case .running:
                isRunning = true
            case .paused:
                isRunning = false
                recoveredSession.resume()
            case .ended, .stopped:
                clearSession()
            default:
                isRunning = false
            }
        } catch {
            logger.error("Workout session recovery failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// End the session and save the HKWorkout to Apple Health.
    /// Returns the final metrics and whether the save succeeded.
    func finish() async -> (metrics: WatchLiveMetrics, savedToHealth: Bool) {
        let metrics = currentMetrics()
        cancelPendingTransitions()
        guard let session, let builder else { return (metrics, false) }
        isEndingSession = true
        isRunning = false
        session.end()
        var saved = false
        do {
            try await builder.endCollection(at: Date())
            if (try? await builder.finishWorkout()) != nil {
                saved = true
            }
        } catch {
            saved = false
        }
        clearSession()
        return (metrics, saved)
    }

    /// End the session without saving an HKWorkout (the phone finished the
    /// workout and owns the Health write, or the session was discarded).
    func cancel() {
        cancelPendingTransitions()
        guard let session, let builder else { return }
        isEndingSession = true
        isRunning = false
        session.end()
        builder.endCollection(withEnd: Date()) { _, _ in
            builder.discardWorkout()
        }
        stopRouteCollection()
        clearSession()
    }

    private func clearSession(resetRestartAttempt: Bool = true) {
        cancelPendingTransitions()
        locationManager.stopUpdatingLocation()
        session = nil
        builder = nil
        routeBuilder = nil
        collectingRoute = false
        activeConfiguration = nil
        sessionStartDate = nil
        isEndingSession = false
        if resetRestartAttempt {
            didAttemptFailureRestart = false
        }
    }

    private func cancelPendingTransitions() {
        startRequestID = nil
        isStarting = false
        recoveryRequestID = nil
        isRecovering = false
    }

    func currentMetrics(asOf date: Date = Date()) -> WatchLiveMetrics {
        WatchLiveMetrics(
            heartRate: liveHeartRate(at: date),
            avgHR: avgHR,
            maxHR: maxHR,
            activeEnergyKcal: activeEnergyKcal,
            distanceMeters: distanceMeters,
            hrZoneSeconds: zoneSeconds,
            asOf: heartRateSampleDate ?? date
        )
    }

    private func resetMetrics() {
        heartRate = nil
        heartRateSampleDate = nil
        avgHR = nil
        maxHR = nil
        activeEnergyKcal = nil
        distanceMeters = nil
        zoneSeconds = [0, 0, 0, 0, 0]
        lastZoneTick = nil
        lastSentHR = nil
        lastSend = .distantPast
    }

    private func prepareMetricsForRestart() {
        lastZoneTick = nil
        lastSentHR = nil
        lastSend = .distantPast
    }

    private func restoreMetrics(from builder: HKLiveWorkoutBuilder) {
        for type in readTypes.compactMap({ $0 as? HKQuantityType }) {
            ingest(statistics: builder.statistics(for: type), for: type)
        }
    }

    // MARK: - Metric ingestion

    private func ingest(statistics: HKStatistics?, for type: HKQuantityType) {
        guard let statistics else { return }
        switch HKQuantityTypeIdentifier(rawValue: type.identifier) {
        case .heartRate:
            let bpm = HKUnit.count().unitDivided(by: .minute())
            if let latest = statistics.mostRecentQuantity()?.doubleValue(for: bpm) {
                let sampledAt = statistics.mostRecentQuantityDateInterval()?.end ?? Date()
                guard sampledAt >= (heartRateSampleDate ?? .distantPast) else { break }
                tickZone(hr: latest)
                evaluateZoneGuard(hr: latest)
                heartRate = Int(latest.rounded())
                heartRateSampleDate = sampledAt
            }
            if let avg = statistics.averageQuantity()?.doubleValue(for: bpm) { avgHR = Int(avg) }
            if let mx = statistics.maximumQuantity()?.doubleValue(for: bpm) { maxHR = Int(mx) }
        case .activeEnergyBurned:
            if let sum = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                activeEnergyKcal = sum
            }
        case .distanceWalkingRunning, .distanceCycling:
            if let sum = statistics.sumQuantity()?.doubleValue(for: .meter()) {
                distanceMeters = sum
            }
        default:
            break
        }
        throttledSend()
    }

    /// Accumulate time-in-zone from the live heart-rate stream.
    private func tickZone(hr: Double) {
        let now = Date()
        if let last = lastZoneTick {
            let elapsed = Int(now.timeIntervalSince(last))
            if elapsed > 0 && elapsed < 120 {
                let zone = zoneConfig.zone(for: Int(hr)) - 1   // 1...5 -> 0...4
                if (0...4).contains(zone) { zoneSeconds[zone] += elapsed }
            }
        }
        lastZoneTick = now
    }

    /// Buzz the wrist when the athlete leaves or re-enters their zone-lock
    /// target. Distinct patterns: up = above, down = below, success = back in.
    private func evaluateZoneGuard(hr: Double) {
        guard let target = zoneTarget else { zoneGuardState = .unknown; return }
        let zone = zoneConfig.zone(for: Int(hr))
        let newState: ZoneGuardState = zone < target ? .below : (zone > target ? .above : .inZone)
        guard newState != zoneGuardState else { return }
        let previous = zoneGuardState
        zoneGuardState = newState
        // Skip the first classification and debounce boundary chatter.
        guard previous != .unknown else { return }
        let now = Date()
        guard now.timeIntervalSince(lastZoneCueAt) >= 4 else { return }
        lastZoneCueAt = now
        switch newState {
        case .above: WKInterfaceDevice.current().play(.directionUp)
        case .below: WKInterfaceDevice.current().play(.directionDown)
        case .inZone: WKInterfaceDevice.current().play(.success)
        case .unknown: break
        }
    }

    private func throttledSend() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSend)
        // Heart rate is the number the athlete watches most, so push it promptly
        // when it moves (capped at ~1s to bound WatchConnectivity traffic);
        // energy / distance / time-in-zone ride a steady ~5s heartbeat. This
        // takes the worst-case HR lag on the phone from ~5s down to ~1s — the
        // rest is inherent HealthKit batching + WC latency.
        let currentHeartRate = liveHeartRate(at: now)
        let hrMoved = currentHeartRate != lastSentHR
        let minInterval: TimeInterval = hrMoved ? 1.0 : 5.0
        guard elapsed >= minInterval else { return }
        lastSend = now
        lastSentHR = currentHeartRate
        onMetrics?(currentMetrics(asOf: now))
    }

    private func startRouteIfNeeded(for configuration: HKWorkoutConfiguration) {
        guard configuration.locationType == .outdoor,
              let builder,
              let route = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder else { return }
        routeBuilder = route
        collectingRoute = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    private func stopRouteCollection() {
        locationManager.stopUpdatingLocation()
        collectingRoute = false
        routeBuilder = nil
    }
}

extension WatchWorkoutEngine: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.collectingRoute, let routeBuilder = self.routeBuilder else { return }
            let usable = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100 }
            guard !usable.isEmpty else { return }
            try? await routeBuilder.insertRouteData(usable)
        }
    }
}

extension WatchWorkoutEngine: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let quantityTypes = collectedTypes.compactMap { $0 as? HKQuantityType }
        Task { @MainActor in
            guard workoutBuilder === self.builder else { return }
            for type in quantityTypes {
                self.ingest(statistics: workoutBuilder.statistics(for: type), for: type)
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Session state (keep-alive & recovery)

/// Metric collection lives or dies with the HKWorkoutSession, so state changes
/// the system makes on its own (pausing, stopping, failing) must be observed
/// and undone — otherwise heart rate silently stops streaming while the UI
/// still says the workout is live.
extension WatchWorkoutEngine: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.handleSessionState(workoutSession, state: toState)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.handleSessionFailure(workoutSession, error: error)
        }
    }

    private func handleSessionState(_ workoutSession: HKWorkoutSession, state: HKWorkoutSessionState) {
        // HealthKit can deliver `.ended` after `didFailWithError`. If a
        // replacement has already been installed, that late callback belongs
        // to the old object and must not tear down the live session.
        guard workoutSession === session else { return }
        switch state {
        case .running:
            isRunning = true
        case .paused:
            // ForgeFit has no user-facing pause — a pause here came from the
            // system (or water lock), and leaving it paused means no metrics.
            isRunning = false
            workoutSession.resume()
        case .ended, .stopped:
            isRunning = false
            guard !isEndingSession else { return }
            logger.error("Workout session ended unexpectedly; attempting one clean restart")
            restartSession(after: workoutSession)
        case .notStarted, .prepared:
            isRunning = false
        @unknown default:
            isRunning = false
        }
    }

    private func handleSessionFailure(_ workoutSession: HKWorkoutSession, error: Error) {
        guard workoutSession === session, !isEndingSession else { return }
        logger.error("Workout session failed: \(error.localizedDescription, privacy: .public)")

        let anotherWorkoutOwnsSensors: Bool
        if let healthError = error as? HKError {
            anotherWorkoutOwnsSensors = healthError.code == .errorAnotherWorkoutSessionStarted
        } else {
            anotherWorkoutOwnsSensors = false
        }
        restartSession(after: workoutSession, allowRestart: !anotherWorkoutOwnsSensors)
    }

    private func restartSession(after failedSession: HKWorkoutSession, allowRestart: Bool = true) {
        guard failedSession === session else { return }
        let config = activeConfiguration
        let startDate = sessionStartDate
        let failedBuilder = builder
        let shouldRestart = allowRestart && !didAttemptFailureRestart && config != nil
        didAttemptFailureRestart = true

        isRunning = false
        if failedSession.state != .ended && failedSession.state != .stopped {
            failedSession.end()
        }
        failedBuilder?.endCollection(withEnd: Date()) { _, _ in
            failedBuilder?.discardWorkout()
        }
        clearSession(resetRestartAttempt: false)

        // Preserve the last known metrics across the handoff. Freshness checks
        // hide the HR automatically if the replacement does not deliver a new
        // sample within 15 seconds.
        if shouldRestart, let config {
            beginSession(
                configuration: config,
                startDate: startDate ?? Date(),
                resetLiveMetrics: false
            )
        } else if !allowRestart {
            logger.error("Workout session not restarted because another app owns the watch sensors")
        } else {
            logger.error("Workout session restart limit reached")
        }
    }
}
