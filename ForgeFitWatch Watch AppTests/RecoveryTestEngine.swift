import ForgeCore
import Foundation
import HealthKit
@testable import ForgeFitWatch_Watch_App

@MainActor
final class RecoveryTestEngine: WatchWorkoutSessionControlling {
    var hasActiveSession = false
    var activeSessionWorkoutID: UUID?
    var isAwaitingSessionWorkoutID = false
    var retryState = WatchEngineRetryState()
    var onMetrics: ((WatchLiveMetrics) -> Void)?
    var onRecoveryNeeded: (() -> Void)?
    var zoneConfig = HRZoneConfig()
    var zoneTarget: Int?
    var starts = 0
    var flushes = 0
    var heartRate: Int?
    var cancellations = 0
    var recoveries = 0
    var recoveryFailures = 0
    var suspendFinish = false
    var finishContinuation: CheckedContinuation<Bool, Never>?
    var finishes = 0
    var suspendRecovery = false
    var recoveryContinuation: CheckedContinuation<WatchWorkoutEngine.RecoveryResult, Never>?

    func recoverSessionIfNeeded() async -> WatchWorkoutEngine.RecoveryResult {
        recoveries += 1
        if suspendRecovery {
            return await withCheckedContinuation { recoveryContinuation = $0 }
        }
        if recoveryFailures > 0 { recoveryFailures -= 1; return .retryNeeded }
        return hasActiveSession ? .sessionAvailable : .noSession
    }

    func start(configuration: HKWorkoutConfiguration?, startDate: Date, isYoga: Bool, workoutID: UUID?) -> Bool {
        guard !hasActiveSession, retryState.mayStart(workoutID, at: Date()) else { return false }
        hasActiveSession = true
        activeSessionWorkoutID = workoutID
        isAwaitingSessionWorkoutID = workoutID == nil
        retryState.started()
        starts += 1
        return true
    }

    func cancel() async {
        cancellations += 1
        hasActiveSession = false
        activeSessionWorkoutID = nil
        isAwaitingSessionWorkoutID = false
    }

    func finish(workoutName: String?) async -> (metrics: WatchLiveMetrics, savedToHealth: Bool) {
        finishes += 1
        let metrics = currentMetrics(asOf: Date())
        let saved = suspendFinish ? await withCheckedContinuation { finishContinuation = $0 } : false
        await cancel()
        return (metrics, saved)
    }

    func currentMetrics(asOf date: Date) -> WatchLiveMetrics {
        WatchLiveMetrics(workoutID: activeSessionWorkoutID, heartRate: heartRate, asOf: date)
    }
    func flushMetrics() {
        flushes += 1
        if heartRate != nil { onMetrics?(currentMetrics(asOf: Date())) }
    }
    func rebindSessionWorkoutID(to workoutID: UUID) {
        activeSessionWorkoutID = workoutID
        isAwaitingSessionWorkoutID = false
        retryState.bind(workoutID)
    }
    func retryRecordingExplicitly() { retryState.retryExplicitly() }
}
