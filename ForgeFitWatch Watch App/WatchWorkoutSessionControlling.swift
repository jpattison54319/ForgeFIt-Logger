import ForgeCore
import Foundation
import HealthKit

/// The store owns reconciliation; the adapter owns HealthKit objects. Tests
/// can delay recovery/teardown without manufacturing real health records.
@MainActor
protocol WatchWorkoutSessionControlling: AnyObject {
    var hasActiveSession: Bool { get }
    var activeSessionWorkoutID: UUID? { get }
    var isAwaitingSessionWorkoutID: Bool { get }
    var retryState: WatchEngineRetryState { get }
    var onMetrics: ((WatchLiveMetrics) -> Void)? { get set }
    var onRecoveryNeeded: (() -> Void)? { get set }
    var zoneConfig: HRZoneConfig { get set }
    var zoneTarget: Int? { get set }
    func recoverSessionIfNeeded() async -> WatchWorkoutEngine.RecoveryResult
    @discardableResult
    func start(configuration: HKWorkoutConfiguration?, startDate: Date, isYoga: Bool, workoutID: UUID?) -> Bool
    func cancel() async
    func finish(workoutName: String?) async -> (metrics: WatchLiveMetrics, savedToHealth: Bool)
    func currentMetrics(asOf date: Date) -> WatchLiveMetrics
    func flushMetrics()
    func rebindSessionWorkoutID(to workoutID: UUID)
    func retryRecordingExplicitly()
}

extension WatchWorkoutSessionControlling {
    func currentMetrics() -> WatchLiveMetrics { currentMetrics(asOf: Date()) }
}

extension WatchWorkoutEngine: WatchWorkoutSessionControlling {}
