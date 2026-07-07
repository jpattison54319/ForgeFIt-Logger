import Foundation
import Observation
import WatchConnectivity
import WatchKit
import ForgeCore

/// The watch side of live sync: receives the phone's `WatchAppContext`
/// snapshot, sends `WatchCommand`s back, and drives the wrist workout session
/// so metrics collect whenever a workout is live on either device.
@MainActor
@Observable
final class WatchStore: NSObject {
    static let shared = WatchStore()

    private(set) var context: WatchAppContext?
    private(set) var isReachable = false

    /// Set after a workout ends so the summary screen can show final numbers.
    struct Summary {
        var durationSeconds: Int
        var completedSets: Int
        var metrics: WatchLiveMetrics
    }
    var summary: Summary?

    private let engine = WatchWorkoutEngine.shared
    @ObservationIgnored private var restHapticTask: Task<Void, Never>?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        engine.onMetrics = { [weak self] metrics in
            self?.send(.liveMetrics(metrics))
        }
        // If watchOS relaunched us mid-workout (crash/jetsam), the workout
        // session may still be running headless — reattach before the phone's
        // next snapshot arrives so metric collection resumes immediately.
        engine.recoverSessionIfNeeded()
    }

    var activeWorkout: WatchWorkoutSnapshot? { context?.workout }

    func ensureWorkoutSessionRunning() {
        guard let workout = activeWorkout, !engine.isRunning else { return }
        engine.start(startDate: workout.startedAt)
    }

    // MARK: - Commands (watch → phone)

    func send(_ command: WatchCommand) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = WatchWire.encode(command) else { return }
        let payload = [WatchWire.commandKey: data]
        // Live metrics are ephemeral — a heart-rate reading queued while the
        // phone is unreachable arrives minutes stale and shows up as a bogus
        // "current" HR, masking the actual gap. Drop those; everything else
        // (set toggles, finish, etc.) gets guaranteed delivery via the queue.
        if case .liveMetrics = command {
            guard WCSession.default.isReachable else { return }
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            return
        }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            // Guaranteed delivery once the phone is reachable again.
            WCSession.default.transferUserInfo(payload)
        }
    }

    // MARK: - User actions

    func startRoutine(_ routine: WatchRoutineSummary) {
        send(.startRoutine(routineID: routine.id))
        WKInterfaceDevice.current().play(.start)
    }

    func startEmpty() {
        send(.startEmpty)
        WKInterfaceDevice.current().play(.start)
    }

    /// Optimistically flips the set locally so the row responds instantly;
    /// the phone's next snapshot confirms it.
    func toggleSet(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot) {
        let newValue = !set.completed
        mutateWorkout { workout in
            guard let ei = workout.exercises.firstIndex(where: { $0.id == exercise.id }),
                  let si = workout.exercises[ei].sets.firstIndex(where: { $0.id == set.id }) else { return }
            workout.exercises[ei].sets[si].completed = newValue
        }
        send(.toggleSet(setID: set.id, completed: newValue))
        WKInterfaceDevice.current().play(newValue ? .success : .click)
    }

    /// Commit a weight/reps edit from the wrist. Optimistic locally; the
    /// phone recomputes and confirms via the next snapshot.
    func updateSet(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot, weightKg: Double?, reps: Int?) {
        mutateWorkout { workout in
            guard let ei = workout.exercises.firstIndex(where: { $0.id == exercise.id }),
                  let si = workout.exercises[ei].sets.firstIndex(where: { $0.id == set.id }) else { return }
            if let weightKg {
                workout.exercises[ei].sets[si].weightKg = weightKg
                // Mirror the display value so the row updates instantly.
                let suffix = workout.exercises[ei].sets[si].unitSuffix ?? "lb"
                let factor = suffix == "kg" ? 1.0 : 2.2046226218
                workout.exercises[ei].sets[si].weight = weightKg * factor
            }
            if let reps { workout.exercises[ei].sets[si].reps = reps }
        }
        send(.updateSet(setID: set.id, weightKg: weightKg, reps: reps))
        WKInterfaceDevice.current().play(.click)
    }

    func startCardio(_ exercise: WatchExerciseSnapshot) {
        mutateWorkout { workout in
            if let i = workout.exercises.firstIndex(where: { $0.id == exercise.id }) {
                workout.exercises[i].cardioState = .running
            }
        }
        send(.startCardio(workoutExerciseID: exercise.id))
        WKInterfaceDevice.current().play(.start)
    }

    func completeCardio(_ exercise: WatchExerciseSnapshot) {
        mutateWorkout { workout in
            if let i = workout.exercises.firstIndex(where: { $0.id == exercise.id }) {
                workout.exercises[i].cardioState = .completed
            }
        }
        send(.completeCardio(workoutExerciseID: exercise.id))
        WKInterfaceDevice.current().play(.stop)
    }

    /// Finish from the wrist: the watch saves the HKWorkout (richest data),
    /// the phone closes out the workout with the final metrics.
    func finishWorkout() {
        guard let workout = activeWorkout else { return }
        captureSummary(for: workout, metrics: engine.currentMetrics())
        Task {
            let result = await engine.finish()
            summary?.metrics = result.metrics
            send(.finishWorkout(metrics: result.metrics, savedToHealth: result.savedToHealth))
        }
        clearWorkoutLocally()
        WKInterfaceDevice.current().play(.success)
    }

    func discardWorkout() {
        engine.cancel()
        send(.discardWorkout)
        clearWorkoutLocally()
        summary = nil
        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: - Phone-initiated launch (HKWorkoutConfiguration handoff)

    func handleWorkoutConfiguration(_ configuration: Any) {
        guard let config = configuration as? HKWorkoutConfigurationBox else { return }
        showPhoneStartedWorkoutPlaceholder()
        engine.start(configuration: config.value)
    }

    // MARK: - Internals

    private func mutateWorkout(_ mutate: (inout WatchWorkoutSnapshot) -> Void) {
        guard var ctx = context, var workout = ctx.workout else { return }
        mutate(&workout)
        ctx.workout = workout
        context = ctx
    }

    private func clearWorkoutLocally() {
        guard var ctx = context else { return }
        ctx.workout = nil
        context = ctx
    }

    private func showPhoneStartedWorkoutPlaceholder() {
        guard activeWorkout == nil else { return }
        var ctx = context ?? WatchAppContext()
        ctx.workout = WatchWorkoutSnapshot(
            workoutID: UUID(),
            title: "Workout",
            startedAt: Date()
        )
        context = ctx
    }

    private func captureSummary(for workout: WatchWorkoutSnapshot, metrics: WatchLiveMetrics) {
        summary = Summary(
            durationSeconds: max(0, Int(Date().timeIntervalSince(workout.startedAt))),
            completedSets: workout.completedSets,
            metrics: metrics
        )
    }

    private func apply(context newContext: WatchAppContext) {
        let previous = context
        context = newContext

        // Keep the live engine on the user's synced HR-zone model so wrist-side
        // time-in-zone and zone-adherence alerts match the phone.
        engine.zoneConfig = newContext.effectiveHRZoneConfig
        engine.zoneTarget = newContext.workout?.hrZoneTarget

        // Session management: a workout live on the phone starts metric
        // collection here; a workout that vanished (finished/discarded on the
        // phone) ends it.
        if let workout = newContext.workout {
            if !engine.isRunning {
                engine.start(startDate: workout.startedAt)
            }
        } else if engine.isRunning {
            if let old = previous?.workout {
                captureSummary(for: old, metrics: engine.currentMetrics())
            }
            engine.cancel() // the phone owns the Health write in this path
        }

        scheduleRestHaptic(endsAt: newContext.workout?.restEndsAt)
    }

    /// Buzz the wrist when the phone's rest timer hits zero.
    private func scheduleRestHaptic(endsAt: Date?) {
        restHapticTask?.cancel()
        guard let endsAt, endsAt > Date() else { return }
        restHapticTask = Task {
            try? await Task.sleep(for: .seconds(endsAt.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.notification)
        }
    }

    private func handle(_ command: WatchCommand) {
        switch command {
        case .workoutFinished:
            if engine.isRunning {
                if let workout = activeWorkout {
                    captureSummary(for: workout, metrics: engine.currentMetrics())
                }
                engine.cancel()
            }
            clearWorkoutLocally()
        default:
            break // watch → phone commands
        }
    }
}

/// Wrapper so WatchStore's public API doesn't leak HealthKit types into views.
struct HKWorkoutConfigurationBox {
    let value: HKWorkoutConfiguration
}

import HealthKit

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            // Pick up whatever the phone last published.
            if let data = session.receivedApplicationContext[WatchWire.contextKey] as? Data,
               let ctx = WatchWire.decode(WatchAppContext.self, from: data) {
                self.apply(context: ctx)
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            // Any reconnection is a chance to notice "phone says a workout is
            // live but our engine is idle" (e.g. the engine died while we
            // were unreachable) and restart collection.
            if session.isReachable { self.ensureWorkoutSessionRunning() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchWire.contextKey] as? Data,
              let ctx = WatchWire.decode(WatchAppContext.self, from: data) else { return }
        Task { @MainActor in self.apply(context: ctx) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let data = message[WatchWire.contextKey] as? Data,
           let ctx = WatchWire.decode(WatchAppContext.self, from: data) {
            Task { @MainActor in self.apply(context: ctx) }
        }
        if let data = message[WatchWire.commandKey] as? Data,
           let command = WatchWire.decode(WatchCommand.self, from: data) {
            Task { @MainActor in self.handle(command) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchWire.commandKey] as? Data,
              let command = WatchWire.decode(WatchCommand.self, from: data) else { return }
        Task { @MainActor in self.handle(command) }
    }
}
