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

    enum RecoveryResult: Equatable {
        /// A live HealthKit session was already present or was reattached.
        case sessionAvailable
        /// HealthKit confirmed that there is no headless session to recover.
        case noSession
        /// Recovery could not establish either fact; callers must not start a
        /// replacement session because the original may still be running.
        case retryNeeded
    }

    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "org.xpetsllc.ForgeFit.watchkitapp", category: "WorkoutSession")
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var routeBuilder: HKWorkoutRouteBuilder?
    @ObservationIgnored private var collectingRoute = false
    @ObservationIgnored private var routeSegmentStartedAt: Date?

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
    var onRecoveryNeeded: (() -> Void)?
    private(set) var retryState = WatchEngineRetryState()
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0

    /// The user's HR-zone model, synced from the phone via `WatchAppContext`.
    /// Drives live time-in-zone and (feature 4) the zone-adherence guard.
    var zoneConfig = HRZoneConfig()
    /// Active "zone lock" target (1...5); when set, the wrist buzzes on leaving
    /// and re-entering the zone. Synced from the phone via the snapshot.
    var zoneTarget: Int? {
        didSet {
            guard oldValue != zoneTarget else { return }
            zoneGuardState = .unknown
            lastZoneCueAt = .distantPast
        }
    }

    @ObservationIgnored let mirroring = WatchWorkoutMirroring()

    private enum ZoneGuardState { case unknown, below, inZone, above }
    @ObservationIgnored private var zoneGuardState: ZoneGuardState = .unknown
    @ObservationIgnored private var lastZoneCueAt = Date.distantPast

    @ObservationIgnored private var lastZoneTick: Date?
    @ObservationIgnored private lazy var metricsCoalescer = WatchMetricsCoalescer { [weak self] metrics in
        self?.onMetrics?(metrics)
    }

    /// Includes HealthKit's asynchronous start/recovery windows. Callers use
    /// this instead of `isRunning` so they never create a second primary
    /// workout while the first is still transitioning to `.running`.
    var hasActiveSession: Bool {
        session != nil || isStarting || isRecovering
    }

    /// The workout this live (or just-recovered) session was started for; nil
    /// while no session is live or the identity is unverified. Persists
    /// across process relaunch so a recovered session can be checked against
    /// the current snapshot — WatchStore reconciles this against the mirror
    /// and live metrics only stream while it matches (FF-003).
    @ObservationIgnored private(set) var activeSessionWorkoutID: UUID?
    /// True only for an engine session accepted from the phone's
    /// HKWorkoutConfiguration handoff before its authoritative workoutID
    /// arrives. Persisted separately from the optional UUID so a relaunch can
    /// distinguish a safe-to-bind handoff from an unverifiable legacy session.
    @ObservationIgnored private(set) var isAwaitingSessionWorkoutID = false

    var hasReceivedHeartRate: Bool { heartRateSampleDate != nil }

    #if DEBUG
    /// App Store capture: the demo context never opens a HealthKit session, so
    /// the wrist would sit on "Starting HR…" — a first-second loading state,
    /// not what a wearer sees. Stamps a reading as if it had just arrived; the
    /// caller re-stamps it inside the freshness window.
    func seedAppStoreDemoHeartRate(_ bpm: Int, average: Int) {
        heartRate = bpm
        heartRateSampleDate = Date()
        avgHR = average
    }
    #endif

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

    /// A live session is never a reason to re-present HealthKit setup. This is
    /// especially important for indoor conditioning: Workout Routes is part
    /// of the Watch's full share set, but it must not prompt again once workout
    /// write access has already been granted.
    private func requestAuthorizationIfNeeded() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        let hasWorkoutWriteAccess = healthStore.authorizationStatus(
            for: HKObjectType.workoutType()
        ) == .sharingAuthorized
        guard !hasWorkoutWriteAccess else { return true }
        do {
            let status = try await healthStore.statusForAuthorizationRequest(
                toShare: shareTypes,
                read: readTypes
            )
            guard WorkoutAuthorizationPromptPolicy.shouldRequestAtWorkoutStart(
                hasWorkoutWriteAccess: hasWorkoutWriteAccess,
                hasUndecidedTypes: status == .shouldRequest
            ) else { return false }
            return await requestAuthorization()
        } catch {
            logger.error("Unable to inspect HealthKit authorization: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Session lifecycle

    @discardableResult
    func start(configuration: HKWorkoutConfiguration? = nil, startDate: Date = Date(), isYoga: Bool = false, workoutID: UUID? = nil) -> Bool {
        let resetLiveMetrics = retryState.workoutID != workoutID || retryState.failures == 0
        guard !hasActiveSession, HKHealthStore.isHealthDataAvailable(),
              retryState.mayStart(workoutID, at: Date()) else { return false }
        let requestID = UUID()
        startRequestID = requestID
        isStarting = true
        // Bind the identity synchronously so a snapshot applied while the
        // async authorization is in flight still sees whose session this is
        // (FF-003).
        activeSessionWorkoutID = workoutID
        isAwaitingSessionWorkoutID = workoutID == nil
        // Persist immediately, before authorization suspends. If watchOS
        // relaunches during that window, recovery can still distinguish a
        // pending handoff from an unverifiable legacy session; no recovered
        // HK session simply clears this marker.
        persistSessionIdentity()
        // First-time setup may request access here. An already-connected watch
        // starts immediately without reopening the full HealthKit sheet.
        Task {
            defer {
                if startRequestID == requestID {
                    startRequestID = nil
                    isStarting = false
                }
            }
            let authorized = await requestAuthorizationIfNeeded()
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
                beginSession(configuration: resolved, startDate: startDate, resetLiveMetrics: resetLiveMetrics)
            } else {
                logger.error("Workout session not started because workout write access is unavailable")
                retryState.failed(.permissionRequired, at: Date())
                clearSessionIdentity()
                onRecoveryNeeded?()
            }
        }
        return true
    }

    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isRecovering = false
    @ObservationIgnored private var isEndingSession = false
    @ObservationIgnored private var startRequestID: UUID?
    @ObservationIgnored private var recoveryRequestID: UUID?
    @ObservationIgnored private var teardownTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var sessionEndWaiters: [CheckedContinuation<Void, Never>] = []

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
            retryState.started()
            persistSessionIdentity()
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
            mirroring.connect(session)
            startRouteIfNeeded(for: config)
        } catch {
            logger.error("Unable to create workout session: \(error.localizedDescription, privacy: .public)")
            retryState.failed(recoveryIssue(for: error), at: Date())
            WatchSyncDiagnostics.record("engine-start-failed", error: error)
            onRecoveryNeeded?()
            // The start failed before a session existed, so no identity may
            // linger as if one were live (FF-003).
            clearSessionIdentity()
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

    /// Carry the originating workoutID with the session through interrupts:
    /// written whenever a session is attached, so a watchOS relaunch can
    /// re-read it during recovery and verify the reattached session instead
    /// of letting it stream under whatever snapshot is current (FF-003).
    private func persistSessionIdentity() {
        WatchSessionIdentityStore.save(activeSessionWorkoutID)
        WatchSessionIdentityStore.savePendingHandoff(isAwaitingSessionWorkoutID)
    }

    private func clearSessionIdentity() {
        activeSessionWorkoutID = nil
        isAwaitingSessionWorkoutID = false
        WatchSessionIdentityStore.clear()
    }

    @ObservationIgnored private var activeConfiguration: HKWorkoutConfiguration?
    @ObservationIgnored private var sessionStartDate: Date?

    func retryRecordingExplicitly() {
        retryState.retryExplicitly()
    }

    /// Reattach to a workout session that outlived the app process — watchOS
    /// relaunches us (workout-processing background mode) after a crash or
    /// jetsam, and without this the session would keep running headless with
    /// no metrics reaching the UI or the phone.
    func recoverSessionIfNeeded() async -> RecoveryResult {
        if session != nil || isStarting { return .sessionAvailable }
        guard !isRecovering, HKHealthStore.isHealthDataAvailable() else {
            return .retryNeeded
        }
        // The in-memory identity died with the process. Reread whose session
        // this was BEFORE the async HealthKit call so a snapshot applied
        // mid-recovery can still verify the session it will reattach (FF-003).
        activeSessionWorkoutID = WatchSessionIdentityStore.load()
        if let activeSessionWorkoutID { retryState.bind(activeSessionWorkoutID) }
        isAwaitingSessionWorkoutID = WatchSessionIdentityStore.isPendingHandoff()
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
                return .retryNeeded
            }
            guard let recoveredSession else {
                // Nothing running headless. A persisted identity whose session
                // no longer exists (it ended while we were dead) is stale —
                // but only clear it if no newer in-memory session or start
                // has claimed the engine while we waited.
                if session == nil, !isStarting {
                    clearSessionIdentity()
                }
                return .noSession
            }
            guard session == nil, !isStarting else { return .sessionAvailable }
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
                startRouteIfNeeded(for: recoveredSession.workoutConfiguration, segmentStartedAt: .now)
            case .paused:
                isRunning = false
                recoveredSession.resume()
                startRouteIfNeeded(for: recoveredSession.workoutConfiguration, segmentStartedAt: .now)
            case .ended, .stopped:
                clearSession()
                return .noSession
            default:
                isRunning = false
            }
            mirroring.connect(recoveredSession)
            return .sessionAvailable
        } catch {
            logger.error("Workout session recovery failed: \(error.localizedDescription, privacy: .public)")
            return .retryNeeded
        }
    }

    /// End the session and save the HKWorkout to Apple Health.
    /// Returns the final metrics and whether the save succeeded.
    func finish(workoutName: String? = nil) async -> (metrics: WatchLiveMetrics, savedToHealth: Bool) {
        lifecycleGeneration &+= 1
        let metrics = currentMetrics()
        if isEndingSession {
            await waitForSessionEnd()
            return (metrics, false)
        }
        cancelPendingTransitions()
        guard let session, let builder else {
            // No live HK objects (never attached, or already torn down); the
            // in-memory and durable identity still must not outlive the
            // finish (FF-003).
            clearSession()
            return (metrics, false)
        }
        isEndingSession = true
        isRunning = false
        session.end()
        var saved = false
        do {
            if let workoutName = workoutName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workoutName.isEmpty {
                // Keep the activity classification while giving Fitness the
                // ForgeFit routine title for the workout's displayed name.
                try? await builder.addMetadata([HKMetadataKeyWorkoutBrandName: workoutName])
            }
            try await builder.endCollection(at: Date())
            // HealthKit may successfully save while locked and return no
            // readable workout object. Only a thrown error means failure.
            _ = try await builder.finishWorkout()
            saved = true
        } catch {
            saved = false
        }
        if self.session === session { clearSession() }
        return (metrics, saved)
    }

    /// End the session without saving an HKWorkout (the phone finished the
    /// workout and owns the Health write, or the session was discarded).
    func cancel() async {
        lifecycleGeneration &+= 1
        cancelPendingTransitions()
        guard let session else {
            clearSession()
            return
        }
        if isEndingSession {
            scheduleTeardownTimeout(for: session)
            await waitForSessionEnd()
            return
        }
        isEndingSession = true
        isRunning = false
        session.end()
        stopRouteCollection()
        scheduleTeardownTimeout(for: session)
        let endingBuilder = builder
        Task { @MainActor [weak self] in
            if let endingBuilder {
                do {
                    try await endingBuilder.endCollection(at: Date())
                } catch {
                    WatchSyncDiagnostics.record("engine-discard-end-failed", error: error)
                }
                endingBuilder.discardWorkout()
            }
            // A late callback must not tear down a replacement session.
            guard let self, self.session === session else { return }
            self.clearSession()
        }
        await waitForSessionEnd()
    }

    /// A missing HealthKit collection callback must not strand local Stop or
    /// block reconciliation forever. Old builder callbacks retain object guards.
    private func scheduleTeardownTimeout(for endingSession: HKWorkoutSession, retryOnTimeout: Bool = false) {
        guard teardownTimeoutTask == nil else { return }
        let generation = lifecycleGeneration
        teardownTimeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.session === endingSession, self.isEndingSession else { return }
            WatchSyncDiagnostics.record("engine-teardown-timeout")
            self.builder?.discardWorkout()
            self.clearSession()
            if retryOnTimeout, self.lifecycleGeneration == generation { self.onRecoveryNeeded?() }
        }
    }

    private func waitForSessionEnd() async {
        guard isEndingSession else { return }
        await withCheckedContinuation { continuation in
            sessionEndWaiters.append(continuation)
        }
    }

    private func clearSession() {
        mirroring.clear()
        teardownTimeoutTask?.cancel()
        teardownTimeoutTask = nil
        cancelPendingTransitions()
        locationManager.stopUpdatingLocation()
        session = nil
        builder = nil
        routeBuilder = nil
        collectingRoute = false
        routeSegmentStartedAt = nil
        activeConfiguration = nil
        sessionStartDate = nil
        // Every teardown path clears the originating identity, in memory and
        // durably. Store reconciliation alone authorizes a replacement
        // session after checking its identity and local-stop state.
        clearSessionIdentity()
        isEndingSession = false
        let waiters = sessionEndWaiters
        sessionEndWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func cancelPendingTransitions() {
        metricsCoalescer.reset()
        startRequestID = nil
        isStarting = false
        recoveryRequestID = nil
        isRecovering = false
    }

    func currentMetrics(asOf date: Date = Date()) -> WatchLiveMetrics {
        WatchLiveMetrics(
            workoutID: activeSessionWorkoutID,
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
        metricsCoalescer.reset()
    }

    private func prepareMetricsForRestart() {
        lastZoneTick = nil
        metricsCoalescer.reset()
    }

    private func restoreMetrics(from builder: HKLiveWorkoutBuilder) {
        for type in readTypes.compactMap({ $0 as? HKQuantityType }) {
            ingest(statistics: builder.statistics(for: type), for: type)
        }
        flushMetrics()
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
        metricsCoalescer.submit(currentMetrics())
    }

    func flushMetrics() {
        guard hasActiveSession, !isEndingSession else { return }
        let metrics = currentMetrics()
        guard metrics.heartRate != nil || metrics.activeEnergyKcal != nil || metrics.distanceMeters != nil else { return }
        metricsCoalescer.submit(metrics, force: true)
    }

    private func startRouteIfNeeded(
        for configuration: HKWorkoutConfiguration,
        segmentStartedAt: Date? = nil
    ) {
        guard WatchRouteCollectionPolicy.shouldStart(
                  isOutdoor: configuration.locationType == .outdoor,
                  isSessionActive: session != nil && !isEndingSession,
                  isAlreadyCollecting: collectingRoute
              ),
              let builder,
              let route = builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder else { return }
        routeBuilder = route
        collectingRoute = true
        routeSegmentStartedAt = segmentStartedAt ?? sessionStartDate ?? .now
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
    }

    private func stopRouteCollection() {
        locationManager.stopUpdatingLocation()
        collectingRoute = false
        routeBuilder = nil
        routeSegmentStartedAt = nil
    }
}

extension WatchWorkoutEngine: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.collectingRoute,
                  let routeBuilder = self.routeBuilder,
                  let segmentStartedAt = self.routeSegmentStartedAt else { return }
            let usable = locations.filter {
                WatchRouteCollectionPolicy.shouldInsertLocation(
                    timestamp: $0.timestamp,
                    horizontalAccuracy: $0.horizontalAccuracy,
                    segmentStartedAt: segmentStartedAt
                )
            }
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
            let wasWaitingForHeartRate = self.heartRate == nil
            for type in quantityTypes {
                self.ingest(statistics: workoutBuilder.statistics(for: type), for: type)
            }
            if wasWaitingForHeartRate, self.heartRate != nil {
                self.flushMetrics()
            } else {
                self.throttledSend()
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
        _ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        Task { @MainActor in self.mirroring.receive(data, from: workoutSession) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        Task { @MainActor in
            guard self.session === workoutSession, !self.isEndingSession else { return }
            self.mirroring.disconnected(workoutSession)
            self.mirroring.connect(workoutSession)
        }
    }

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
            logger.error("Workout session ended unexpectedly; scheduling recovery")
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

        WatchSyncDiagnostics.record("engine-session-failed", error: error)
        restartSession(after: workoutSession, issue: recoveryIssue(for: error))
    }

    private func recoveryIssue(for error: Error) -> WatchEngineRetryState.Issue {
        guard let healthError = error as? HKError else { return .transient }
        switch healthError.code {
        case .errorAnotherWorkoutSessionStarted: return .anotherWorkout
        case .errorAuthorizationDenied, .errorAuthorizationNotDetermined: return .permissionRequired
        default: return .transient
        }
    }

    private func restartSession(after failedSession: HKWorkoutSession, issue: WatchEngineRetryState.Issue = .transient) {
        guard failedSession === session else { return }
        let generation = lifecycleGeneration
        let failedBuilder = builder
        retryState.failed(issue, at: Date())

        isRunning = false
        isEndingSession = true
        if failedSession.state != .ended && failedSession.state != .stopped {
            failedSession.end()
        }
        scheduleTeardownTimeout(for: failedSession, retryOnTimeout: true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let failedBuilder {
                do {
                    try await failedBuilder.endCollection(at: Date())
                } catch {
                    self.logger.error("Unable to close failed workout collection: \(error.localizedDescription, privacy: .public)")
                }
                failedBuilder.discardWorkout()
            }
            guard failedSession === self.session else { return }
            self.clearSession()
            // Store reconciliation owns retries and rechecks identity and a
            // durable local stop before creating any replacement session.
            guard self.lifecycleGeneration == generation else { return }
            self.onRecoveryNeeded?()
        }
    }

    /// Re-point the active session's identity after the phone resolves a
    /// phone-start handoff. The handoff session starts with no identity — the
    /// placeholder is fabricated locally and FF-002 blocks every terminal
    /// command while it is current, so nothing is recorded against it — and
    /// the first authoritative snapshot is the moment its data gains a real
    /// owner. Only ever called with a pending handoff session; a mismatched
    /// recovered session is ended and restarted instead (FF-003).
    func rebindSessionWorkoutID(to workoutID: UUID) {
        guard hasActiveSession,
              isAwaitingSessionWorkoutID,
              activeSessionWorkoutID == nil else { return }
        activeSessionWorkoutID = workoutID
        retryState.bind(workoutID)
        isAwaitingSessionWorkoutID = false
        persistSessionIdentity()
    }
}
