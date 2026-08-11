import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit
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

    /// True while the visible workout is only a phone-start placeholder
    /// awaiting the authoritative snapshot. The placeholder carries a
    /// fabricated `workoutID`; running a terminal command against it would
    /// write HealthKit and clear state the phone would refuse, so finish and
    /// discard refuse until a real context resolves the identity (FF-002).
    private(set) var isAwaitingWorkoutIdentity = false

    /// Set after a workout ends so the summary screen can show final numbers.
    struct Summary {
        var durationSeconds: Int
        var completedSets: Int
        var metrics: WatchLiveMetrics
    }
    var summary: Summary?

    private let engine = WatchWorkoutEngine.shared
    @ObservationIgnored private var restHapticTask: Task<Void, Never>?
    @ObservationIgnored private var intervalHapticTask: Task<Void, Never>?
    @ObservationIgnored private var lastIntervalStepEndsAt: Date?

    func activate() {
        #if DEBUG
        // App Store capture: an unpaired watch simulator never receives a
        // context, so every screen would render empty. Inject the snapshot a
        // paired phone would have sent, and skip session activation — the
        // engine would otherwise try to open a HealthKit workout the
        // simulator can't authorize.
        if WatchAppStoreDemo.isRequested {
            context = WatchAppStoreDemo.context()
            if WatchAppStoreDemo.wantsActiveWorkout {
                WatchAppStoreDemo.startHeartRateTicker(engine)
            }
            return
        }
        #endif
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
        Task { await recoverOrStartWorkoutSession() }
    }

    var activeWorkout: WatchWorkoutSnapshot? { context?.workout }

    var conditioningFinishBlocker: String? {
        guard let workout = activeWorkout else { return nil }
        if let plan = workout.conditioningPlan,
           let progress = workout.conditioningProgress,
           progress.status != .ready,
           let message = conditioningTargetMessage(progress: progress, plan: plan) {
            return message
        }
        for exercise in workout.exercises where exercise.workoutBlockKindRaw == "conditioning" {
            guard let plan = exercise.conditioningPlan,
                  let progress = exercise.conditioningProgress,
                  progress.status != .ready,
                  let message = conditioningTargetMessage(progress: progress, plan: plan) else { continue }
            return message
        }
        return nil
    }

    func ensureWorkoutSessionRunning() {
        guard let workout = activeWorkout, !engine.hasActiveSession else { return }
        engine.start(configuration: workoutConfiguration(for: workout), startDate: workout.startedAt, isYoga: workout.isYogaWorkout == true)
    }

    func recoverOrStartWorkoutSession() async {
        await engine.recoverSessionIfNeeded()
        ensureWorkoutSessionRunning()
    }

    // MARK: - Commands (watch → phone)

    func send(_ command: WatchCommand) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = WatchWire.encode(command) else { return }
        let payload = [WatchWire.commandKey: data]
        // Live metrics: `isReachable` tracks whether the watch screen is on,
        // not whether the workout session is still streaming (HKLiveWorkoutBuilder
        // keeps delivering HR the whole time the display is off). Gating the
        // only send path on `isReachable`, as this used to, silently dropped
        // every reading for the entire "wrist down" stretch of a workout — the
        // phone only caught up once the wrist was raised and reachability
        // flipped back, which is exactly the lag the user is seeing.
        //
        // `sendMessage` stays as the low-latency fast path while both sides
        // are awake. `updateApplicationContext` runs unconditionally as the
        // always-on fallback: it coalesces to a single latest value (no queue
        // to replay), so it can't reintroduce the stale-reading problem
        // `transferUserInfo` would — the phone just converges on the freshest
        // HR the instant reachability (or app launch) lets it through.
        if case .liveMetrics = command {
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            }
            try? WCSession.default.updateApplicationContext([WatchWire.liveMetricsKey: data])
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
            if newValue, workout.restOwnerID == set.id {
                workout.restEndsAt = nil
                workout.restTotalSeconds = nil
                workout.restIsMicro = nil
                workout.restLabel = nil
                workout.restOwnerID = nil
            }
        }
        if newValue { restHapticTask?.cancel() }
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

    /// Persist one activation, mini-set, or correction while immediately
    /// mirroring the full structured block on the wrist. Each performed step
    /// owns its micro-rest even when the phone is temporarily unreachable.
    func updateStructuredSet(
        _ set: WatchSetSnapshot,
        in exercise: WatchExerciseSnapshot,
        progress: WatchStructuredSetProgress,
        event: WatchStructuredSetEventKind,
        side: Int,
        weightKg: Double?
    ) {
        let occurredAt = Date.now
        let update = WatchStructuredSetUpdate(
            progress: progress,
            event: event,
            side: side,
            occurredAt: occurredAt,
            weightKg: weightKg
        )
        mutateWorkout { workout in
            guard let exerciseIndex = workout.exercises.firstIndex(where: { $0.id == exercise.id }),
                  let setIndex = workout.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == set.id }) else { return }
            var snapshot = workout.exercises[exerciseIndex].sets[setIndex]
            snapshot.reps = set.setType == .cluster
                ? progress.miniReps.reduce(0, +)
                : progress.activationReps
            snapshot.miniReps = progress.miniReps
            snapshot.side2Reps = set.setType == .cluster ? nil : progress.side2ActivationReps
            snapshot.side2MiniReps = progress.side2MiniReps
            if let weightKg {
                snapshot.weightKg = weightKg
                let suffix = snapshot.unitSuffix ?? "lb"
                snapshot.weight = weightKg * (suffix == "kg" ? 1 : 2.2046226218)
            }
            workout.exercises[exerciseIndex].sets[setIndex] = snapshot

            if event != .correction, !snapshot.completed {
                let seconds = snapshot.effectiveMicroRestSeconds
                let endsAt = occurredAt.addingTimeInterval(TimeInterval(seconds))
                workout.restEndsAt = endsAt
                workout.restTotalSeconds = seconds
                workout.restIsMicro = true
                workout.restLabel = "Mini-rest"
                workout.restOwnerID = snapshot.id
            }
        }
        if event != .correction {
            scheduleRestHaptic(endsAt: occurredAt.addingTimeInterval(TimeInterval(set.effectiveMicroRestSeconds)))
        }
        send(.updateStructuredSet(setID: set.id, update: update))
        WKInterfaceDevice.current().play(event == .correction ? .click : .success)
    }

    /// Start an AMRAP against an absolute end time so the wrist remains the
    /// accurate clock if WatchConnectivity delivery is delayed.
    func startSetTimer(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot, seconds: Int) {
        let duration = max(1, seconds)
        let endsAt = Date.now.addingTimeInterval(TimeInterval(duration))
        mutateWorkout { workout in
            guard let exerciseIndex = workout.exercises.firstIndex(where: { $0.id == exercise.id }),
                  let setIndex = workout.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == set.id }) else { return }
            workout.exercises[exerciseIndex].sets[setIndex].durationSeconds = duration
            workout.restEndsAt = endsAt
            workout.restTotalSeconds = duration
            workout.restIsMicro = false
            workout.restLabel = "AMRAP"
            workout.restOwnerID = set.id
        }
        scheduleRestHaptic(endsAt: endsAt)
        send(.startSetTimer(setID: set.id, durationSeconds: duration, endsAt: endsAt))
        WKInterfaceDevice.current().play(.start)
    }

    func stopSetTimer(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot) {
        let total = activeWorkout?.restTotalSeconds ?? set.durationSeconds ?? 1
        let remaining = activeWorkout?.restEndsAt.map {
            max(0, Int($0.timeIntervalSinceNow.rounded(.up)))
        } ?? 0
        let elapsed = max(1, total - remaining)
        mutateWorkout { workout in
            if let exerciseIndex = workout.exercises.firstIndex(where: { $0.id == exercise.id }),
               let setIndex = workout.exercises[exerciseIndex].sets.firstIndex(where: { $0.id == set.id }) {
                workout.exercises[exerciseIndex].sets[setIndex].durationSeconds = elapsed
            }
            if workout.restOwnerID == set.id {
                workout.restEndsAt = nil
                workout.restTotalSeconds = nil
                workout.restIsMicro = nil
                workout.restLabel = nil
                workout.restOwnerID = nil
            }
        }
        restHapticTask?.cancel()
        send(.stopSetTimer(setID: set.id, elapsedSeconds: elapsed))
        WKInterfaceDevice.current().play(.stop)
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

    func applyConditioning(_ action: ConditioningProgressEvent.Action, blockID: UUID? = nil) {
        guard let workout = activeWorkout else { return }
        let plan: ConditioningPlan?
        if let blockID {
            plan = workout.exercises.first { $0.id == blockID }?.conditioningPlan
        } else {
            plan = workout.conditioningPlan
        }
        guard let plan else { return }
        let event = ConditioningProgressEvent(timestamp: .now, action: action)
        mutateWorkout { workout in
            if let blockID,
               let index = workout.exercises.firstIndex(where: { $0.id == blockID }) {
                let current = workout.exercises[index].conditioningProgress ?? ConditioningProgress()
                workout.exercises[index].conditioningProgress = ConditioningProgressEngine.apply(event, to: current, plan: plan)
                workout.exercises[index].cardioState = .running
            } else {
                let current = workout.conditioningProgress ?? ConditioningProgress()
                workout.conditioningProgress = ConditioningProgressEngine.apply(event, to: current, plan: plan)
            }
        }
        if let blockID { send(.conditioningBlockEvent(blockID: blockID, event: event)) }
        else { send(.conditioningEvent(event)) }
        if case .completeRound = action {
            WKInterfaceDevice.current().play(.success)
        } else {
            WKInterfaceDevice.current().play(.click)
        }
    }

    func finishConditioningBlock(_ blockID: UUID) {
        guard let block = activeWorkout?.exercises.first(where: { $0.id == blockID }),
              let plan = block.conditioningPlan,
              let progress = block.conditioningProgress,
              ConditioningProgressEngine.requiredRoundsRemaining(for: progress, plan: plan) == 0 else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        applyConditioning(
            .setScore(
                rounds: progress.fullRounds,
                partialMovementID: nil,
                partialValue: 0,
                load: nil
            ),
            blockID: blockID
        )
        mutateWorkout { workout in
            if let index = workout.exercises.firstIndex(where: { $0.id == blockID }) {
                workout.exercises[index].cardioState = .completed
            }
        }
        WKInterfaceDevice.current().play(.success)
    }

    /// Finish from the wrist: the watch saves the HKWorkout (richest data),
    /// the phone closes out the workout with the final metrics.
    func finishWorkout() {
        guard let workout = activeWorkout else { return }
        // Refuse before touching the engine, HealthKit, the wire, or local
        // state: while identity is pending the visible workoutID is a
        // placeholder the phone would reject (FF-002).
        guard WatchTerminalCommandPolicy.mayRunTerminalCommand(isAwaitingIdentity: isAwaitingWorkoutIdentity) else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        guard conditioningFinishBlocker == nil else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        captureSummary(for: workout, metrics: engine.currentMetrics())
        Task {
            let result = await engine.finish(workoutName: workout.title)
            summary?.metrics = result.metrics
            // Bind the finish to the exact snapshot the wrist was showing when
            // the user tapped Finish. If that workout was superseded on the
            // phone before this command lands, the phone handler drops it
            // rather than terminating the newer session.
            send(.finishWorkout(workoutID: workout.workoutID, metrics: result.metrics, savedToHealth: result.savedToHealth))
        }
        clearWorkoutLocally()
        WKInterfaceDevice.current().play(.success)
    }

    private func conditioningTargetMessage(
        progress: ConditioningProgress,
        plan: ConditioningPlan
    ) -> String? {
        let remaining = ConditioningProgressEngine.requiredRoundsRemaining(for: progress, plan: plan)
        guard remaining > 0 else { return nil }
        return "\(remaining) conditioning round\(remaining == 1 ? "" : "s") left"
    }

    func discardWorkout() {
        // Refuse while identity is pending, before any engine/wire/local
        // mutation — see `finishWorkout` (FF-002).
        guard WatchTerminalCommandPolicy.mayRunTerminalCommand(isAwaitingIdentity: isAwaitingWorkoutIdentity) else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        engine.cancel()
        // Stamped before `clearWorkoutLocally()` clears the mirror, so the
        // phone can refuse the discard if a newer workout is now active there.
        send(.discardWorkout(workoutID: activeWorkout?.workoutID))
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
        isAwaitingWorkoutIdentity = false
        guard var ctx = context else { return }
        ctx.workout = nil
        context = ctx
    }

    private func showPhoneStartedWorkoutPlaceholder() {
        guard activeWorkout == nil else { return }
        isAwaitingWorkoutIdentity = true
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
        // Any authoritative phone snapshot — with or without a workout —
        // resolves a pending placeholder identity (FF-002).
        isAwaitingWorkoutIdentity = false
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
            if !engine.hasActiveSession {
                engine.start(configuration: workoutConfiguration(for: workout), startDate: workout.startedAt, isYoga: workout.isYogaWorkout == true)
            }
        } else if engine.hasActiveSession {
            if let old = previous?.workout {
                captureSummary(for: old, metrics: engine.currentMetrics())
            }
            engine.cancel() // the phone owns the Health write in this path
        }

        scheduleRestHaptic(endsAt: newContext.workout?.restEndsAt)
        scheduleIntervalHaptic(endsAt: newContext.workout?.intervalStepEndsAt)
        publishComplicationSnapshot(newContext)
    }

    /// Mirror the phone's state into the watch's shared app-group container so
    /// the watch-face complication (a separate widget-extension process) can
    /// read it, then nudge WidgetKit to refresh. Writes to the SAME
    /// `ForgeFitWidgetSnapshotStore` the iOS widget uses — on watchOS the
    /// suite name resolves to the watch's own group container, so the watch
    /// widget extension must join the `group.org.xpetsllc.ForgeFit` app group
    /// too. A no-op reload before the complication target exists is harmless.
    private func publishComplicationSnapshot(_ context: WatchAppContext) {
        let snapshot: ForgeFitWidgetSnapshot
        if let workout = context.workout {
            snapshot = ForgeFitWidgetSnapshot(
                mode: .activeWorkout,
                workoutTitle: workout.title,
                workoutStartedAt: workout.startedAt,
                currentExerciseName: workout.exercises.first(where: { ex in
                    ex.sets.contains { !$0.completed }
                })?.name,
                completedSets: workout.completedSets,
                totalSets: workout.totalSets,
                restEndsAt: workout.restEndsAt
            )
        } else {
            snapshot = ForgeFitWidgetSnapshot(
                mode: .idle,
                readinessScore: context.readiness,
                readinessAction: context.readinessAction,
                readinessDetail: context.readinessDetail
            )
        }
        ForgeFitWidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitWatchComplication")
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

    /// Buzz the wrist at each interval-step transition. The phone drives the
    /// steps and pushes a fresh snapshot per transition; scheduling against
    /// the step's own end time means the haptic still lands on time even if
    /// that push lags a pocketed phone.
    private func scheduleIntervalHaptic(endsAt: Date?) {
        guard endsAt != lastIntervalStepEndsAt else { return }
        lastIntervalStepEndsAt = endsAt
        intervalHapticTask?.cancel()
        guard let endsAt, endsAt > Date() else { return }
        intervalHapticTask = Task {
            try? await Task.sleep(for: .seconds(endsAt.timeIntervalSinceNow))
            guard !Task.isCancelled else { return }
            WKInterfaceDevice.current().play(.retry)
        }
    }

    private func handle(_ command: WatchCommand) {
        switch command {
        case .workoutFinished:
            if engine.hasActiveSession {
                if let workout = activeWorkout {
                    captureSummary(for: workout, metrics: engine.currentMetrics())
                }
                engine.cancel()
            }
            clearWorkoutLocally()
        case .discardWorkout(_):
            // Phone-initiated discards are authoritative: the phone already
            // deleted the workout, so the mirror clears unconditionally. The
            // carried `workoutID` (which gates the watch → phone direction on
            // the phone) is not a gate here.
            engine.cancel()
            clearWorkoutLocally()
            summary = nil
        default:
            break // watch → phone commands
        }
    }

    private func workoutConfiguration(for workout: WatchWorkoutSnapshot) -> HKWorkoutConfiguration? {
        if workout.isYogaWorkout == true {
            let config = HKWorkoutConfiguration()
            config.activityType = .yoga
            config.locationType = .indoor
            return config
        }
        let isConditioningWorkout = workout.conditioningPlan != nil
            || (!workout.exercises.isEmpty && workout.exercises.allSatisfy {
                $0.workoutBlockKindRaw == "conditioning"
            })
        if isConditioningWorkout {
            let config = HKWorkoutConfiguration()
            config.activityType = .crossTraining
            config.locationType = .indoor
            return config
        }
        let activeCardio = workout.exercises.first { $0.isCardio && $0.cardioState == .running }
        let pureCardio = !workout.exercises.isEmpty && workout.exercises.allSatisfy(\.isCardio)
        guard let exercise = activeCardio ?? (pureCardio ? workout.exercises.first : nil),
              let raw = exercise.cardioKindRaw else { return nil }
        let config = HKWorkoutConfiguration()
        config.activityType = hkActivityType(for: raw)
        config.locationType = exercise.supportsOutdoorRoute == true ? .outdoor : .indoor
        return config
    }

    private func hkActivityType(for raw: String) -> HKWorkoutActivityType {
        switch raw {
        case "run", "trailRun": return .running
        case "walk": return .walking
        case "cycle": return .cycling
        case "row": return .rowing
        case "elliptical": return .elliptical
        case "stair": return .stairClimbing
        case "jumpRope": return .jumpRope
        case "skate": return .skatingSports
        case "swim": return .swimming
        default: return .other
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
            if session.isReachable { await self.recoverOrStartWorkoutSession() }
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
