import Foundation
import HealthKit
import Observation
import ForgeCore

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
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private(set) var isRunning = false
    private(set) var heartRate: Int?
    private(set) var avgHR: Int?
    private(set) var maxHR: Int?
    private(set) var activeEnergyKcal: Double?
    private(set) var zoneSeconds = [0, 0, 0, 0, 0]

    /// Throttled live-metrics stream (WatchStore forwards these to the phone).
    var onMetrics: ((WatchLiveMetrics) -> Void)?

    @ObservationIgnored private var lastZoneTick: Date?
    @ObservationIgnored private var lastSend = Date.distantPast

    private static let zoneMaxHR = 190.0

    // MARK: - Authorization

    private var readTypes: Set<HKObjectType> {
        var t: Set<HKObjectType> = []
        for id: HKQuantityTypeIdentifier in [.heartRate, .activeEnergyBurned, .distanceWalkingRunning] {
            if let type = HKQuantityType.quantityType(forIdentifier: id) { t.insert(type) }
        }
        return t
    }

    private var shareTypes: Set<HKSampleType> {
        var t: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            t.insert(activeEnergy)
        }
        return t
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
            return healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
        } catch {
            return false
        }
    }

    // MARK: - Session lifecycle

    func start(configuration: HKWorkoutConfiguration? = nil, startDate: Date = Date()) {
        guard !isRunning, !isStarting, HKHealthStore.isHealthDataAvailable() else { return }
        isStarting = true
        // Authorization is requested lazily, right when the first session
        // starts — the prompt appears in context instead of at app launch.
        Task {
            let authorized = await requestAuthorization()
            if authorized {
                beginSession(configuration: configuration, startDate: startDate)
            }
            isStarting = false
        }
    }

    @ObservationIgnored private var isStarting = false

    private func beginSession(configuration: HKWorkoutConfiguration?, startDate: Date) {
        guard !isRunning else { return }
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .traditionalStrengthTraining
            c.locationType = .indoor
            return c
        }()
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            builder.delegate = self
            self.session = session
            self.builder = builder
            resetMetrics()
            session.startActivity(with: startDate)
            builder.beginCollection(withStart: startDate) { _, _ in }
            isRunning = true
        } catch {
            // No session (e.g. permissions declined) — the workout still logs
            // normally, just without live metrics.
        }
    }

    /// End the session and save the HKWorkout to Apple Health.
    /// Returns the final metrics and whether the save succeeded.
    func finish() async -> (metrics: WatchLiveMetrics, savedToHealth: Bool) {
        let metrics = currentMetrics()
        guard isRunning, let session, let builder else { return (metrics, false) }
        isRunning = false
        session.end()
        var saved = false
        do {
            try await builder.endCollection(at: Date())
            saved = (try? await builder.finishWorkout()) != nil
        } catch {
            saved = false
        }
        self.session = nil
        self.builder = nil
        return (metrics, saved)
    }

    /// End the session without saving an HKWorkout (the phone finished the
    /// workout and owns the Health write, or the session was discarded).
    func cancel() {
        guard isRunning, let session, let builder else { return }
        isRunning = false
        session.end()
        builder.endCollection(withEnd: Date()) { _, _ in
            builder.discardWorkout()
        }
        self.session = nil
        self.builder = nil
    }

    func currentMetrics() -> WatchLiveMetrics {
        WatchLiveMetrics(
            heartRate: heartRate,
            avgHR: avgHR,
            maxHR: maxHR,
            activeEnergyKcal: activeEnergyKcal,
            hrZoneSeconds: zoneSeconds
        )
    }

    private func resetMetrics() {
        heartRate = nil
        avgHR = nil
        maxHR = nil
        activeEnergyKcal = nil
        zoneSeconds = [0, 0, 0, 0, 0]
        lastZoneTick = nil
    }

    // MARK: - Metric ingestion

    private func ingest(statistics: HKStatistics?, for type: HKQuantityType) {
        guard let statistics else { return }
        switch HKQuantityTypeIdentifier(rawValue: type.identifier) {
        case .heartRate:
            let bpm = HKUnit.count().unitDivided(by: .minute())
            if let latest = statistics.mostRecentQuantity()?.doubleValue(for: bpm) {
                tickZone(hr: latest)
                heartRate = Int(latest)
            }
            if let avg = statistics.averageQuantity()?.doubleValue(for: bpm) { avgHR = Int(avg) }
            if let mx = statistics.maximumQuantity()?.doubleValue(for: bpm) { maxHR = Int(mx) }
        case .activeEnergyBurned:
            if let sum = statistics.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                activeEnergyKcal = sum
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
                let percent = hr / Self.zoneMaxHR
                let zone: Int = percent < 0.6 ? 0 : percent < 0.7 ? 1 : percent < 0.8 ? 2 : percent < 0.9 ? 3 : 4
                zoneSeconds[zone] += elapsed
            }
        }
        lastZoneTick = now
    }

    private func throttledSend() {
        let now = Date()
        guard now.timeIntervalSince(lastSend) >= 5 else { return }
        lastSend = now
        onMetrics?(currentMetrics())
    }
}

extension WatchWorkoutEngine: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let quantityTypes = collectedTypes.compactMap { $0 as? HKQuantityType }
        Task { @MainActor in
            for type in quantityTypes {
                self.ingest(statistics: workoutBuilder.statistics(for: type), for: type)
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
