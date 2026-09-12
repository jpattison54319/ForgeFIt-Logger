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
    /// Live set progress is worth a reload, but not one per completed set.
    /// WidgetKit budgets a widget to roughly 40-70 reloads a day and only
    /// exempts them while the CONTAINING app is foregrounded — which the
    /// watch app is not, mid-set. Spacing mid-workout reloads keeps a long
    /// session from spending the budget that tomorrow's readiness needs.
    private static let activeWorkoutReloadInterval: TimeInterval = 60

    static let shared = WatchStore()

    private(set) var context: WatchAppContext?
    private(set) var isReachable = false

    /// Whether the phone has EVER published an authoritative snapshot to this
    /// watch process. Distinct from `context?.workout == nil`: the mirror can
    /// be absent simply because WCSession delivery is slow, which must not be
    /// mistaken for the phone declaring the workout over. A live engine
    /// session with no authoritative context yet is quarantined (kept, not
    /// streamed, not cancelled) until the first snapshot resolves it (FF-003).
    private(set) var hasReceivedAuthoritativeContext = false

    /// True while the visible workout is only a phone-start placeholder
    /// awaiting the authoritative snapshot. The placeholder carries a
    /// fabricated `workoutID`; running a terminal command against it would
    /// write HealthKit and clear state the phone would refuse, so finish and
    /// discard refuse until a real context resolves the identity (FF-002).
    private(set) var isAwaitingWorkoutIdentity = false

    /// Set after a workout ends so the summary screen can show final numbers.
    struct Summary {
        var workoutID: UUID
        var durationSeconds: Int
        var completedSets: Int
        var metrics: WatchLiveMetrics
    }
    var summary: Summary?
    private(set) var finishingWorkoutID: UUID?
    private(set) var finishIsDelayed = false
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var finishDelayTask: Task<Void, Never>?

    let engine: any WatchWorkoutSessionControlling
    @ObservationIgnored let recoveryRequestSender: ((WatchSyncRequest) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let startRequestSender: ((WatchStartRequest) -> Void)?
    @ObservationIgnored private let metricsSender: ((WatchLiveMetrics) -> Void)?
    @ObservationIgnored private let metricsStreamID = UUID()
    @ObservationIgnored private var metricsSequence: UInt64 = 0
    var pendingStartID: UUID?
    var isWaitingForStartSnapshot = false
    var startIssue: String?
    @ObservationIgnored var startContinuation: CheckedContinuation<WatchImmediateStartResult, Never>?
    @ObservationIgnored var startTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var startSnapshotTask: Task<Void, Never>?
    var syncRecovery = WatchSyncRecoveryState()
    @ObservationIgnored var syncRecoveryTask: Task<Void, Never>?
    @ObservationIgnored var syncHealthCheckTask: Task<Void, Never>?
    @ObservationIgnored var lastSnapshotReceivedAt: Date?
    @ObservationIgnored var engineRetryTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0
    private var recoveryBootstrapFailed = false
    private var workoutSuppression: WatchWorkoutSuppression
    @ObservationIgnored private var restHapticTask: Task<Void, Never>?
    @ObservationIgnored private var intervalHapticTask: Task<Void, Never>?
    @ObservationIgnored private var lastIntervalStepEndsAt: Date?
    @ObservationIgnored private var lastComplicationReloadAt: Date?
    @ObservationIgnored private var recoveryBootstrapTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryBootstrapComplete = false
    @ObservationIgnored private var deferredSummaryWorkout: WatchWorkoutSnapshot?
    @ObservationIgnored private var engineReconciliationTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored var recoveryDemoContext: WatchAppContext?
    #endif

    init(
        engine: (any WatchWorkoutSessionControlling)? = nil,
        defaults: UserDefaults = .standard,
        recoveryRequestSender: ((WatchSyncRequest) -> Void)? = nil,
        startRequestSender: ((WatchStartRequest) -> Void)? = nil,
        metricsSender: ((WatchLiveMetrics) -> Void)? = nil
    ) {
        self.engine = engine ?? WatchWorkoutEngine.shared
        self.defaults = defaults
        self.recoveryRequestSender = recoveryRequestSender
        self.startRequestSender = startRequestSender
        self.metricsSender = metricsSender
        workoutSuppression = defaults.data(forKey: "watch.workout.suppression.v1")
            .flatMap { WatchWire.decode(WatchWorkoutSuppression.self, from: $0) } ?? WatchWorkoutSuppression()
        super.init()
        self.engine.onRecoveryNeeded = { [weak self] in self?.scheduleEngineRecovery() }
        self.engine.onMetrics = { [weak self] in self?.forwardMetrics($0) }
    }

    func activate() {
        #if DEBUG
        // App Store capture: an unpaired watch simulator never receives a
        // context, so every screen would render empty. Inject the snapshot a
        // paired phone would have sent, and skip session activation — the
        // engine would otherwise try to open a HealthKit workout the
        // simulator can't authorize.
        if WatchAppStoreDemo.isRequested {
            workoutSuppression = WatchWorkoutSuppression()
            if WatchAppStoreDemo.wantsSyncRecovery {
                if WatchAppStoreDemo.wantsActiveWorkout { showPhoneStartedWorkoutPlaceholder() }
                syncRecovery.requireVerification(at: Date())
                syncRecovery.failed(.unreachable)
                return
            }
            if WatchAppStoreDemo.wantsSupersededSummary {
                summary = Summary(
                    workoutID: UUID(),
                    durationSeconds: 3_600,
                    completedSets: 8,
                    metrics: WatchLiveMetrics()
                )
            }
            let demo = WatchAppStoreDemo.context()
            syncRecovery.refresh(at: Date(), force: true)
            let request = syncRecovery.nextRequest(at: Date())!
            _ = syncRecovery.accept(WatchSyncMetadata(epoch: UUID(), revision: 1, workoutID: demo.workout?.workoutID), replyTo: request.id)
            apply(context: demo)
            if WatchAppStoreDemo.wantsActiveWorkout {
                WatchAppStoreDemo.startHeartRateTicker(WatchWorkoutEngine.shared)
            }
            return
        }
        #endif
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // If watchOS relaunched us mid-workout (crash/jetsam), the workout
        // session may still be running headless — reattach before the phone's
        // next snapshot arrives so metric collection resumes immediately.
        Task {
            await recoverOrStartWorkoutSession()
        }
    }

    var activeWorkout: WatchWorkoutSnapshot? { context?.workout }

    var isFinishingWorkout: Bool { finishingWorkoutID != nil }
    var isRecordingStopped: Bool { workoutSuppression.isSuppressed(activeWorkout?.workoutID) }
    var canStopRecordingOnWatch: Bool {
        !isFinishingWorkout && !isRecordingStopped && (activeWorkout != nil || engine.hasActiveSession || isAwaitingWorkoutIdentity)
    }
    var needsBootstrapRecovery: Bool { !recoveryBootstrapComplete && recoveryBootstrapFailed }

    var recoveryMessage: String? {
        if isFinishingWorkout { return finishIsDelayed ? "Health save is taking longer…" : "Finishing workout…" }
        if isRecordingStopped { return "Stopped on Watch" }
        if let issue = syncRecovery.issue { return issue.message }
        if isAwaitingWorkoutIdentity { return "Syncing workout…" }
        if let issue = engine.retryState.issue { return issue.message }
        if recoveryBootstrapFailed { return "Workout recording could not be restored" }
        return nil
    }

    func retryWorkoutRecovery() {
        guard !isFinishingWorkout else { return }
        clearStartPresentation()
        workoutSuppression.resume(activeWorkout?.workoutID)
        saveWorkoutSuppression()
        engine.retryRecordingExplicitly()
        recoveryBootstrapFailed = false
        syncRecovery.requireVerification(at: Date())
        hasReceivedAuthoritativeContext = false
        isAwaitingWorkoutIdentity = activeWorkout != nil
        #if DEBUG
        if WatchAppStoreDemo.wantsSyncRecovery || WatchAppStoreDemo.wantsStartRecovery {
            completeRecoveryDemo()
            return
        }
        #endif
        requestFreshContext()
    }

    /// Stop only the recorder on this device. No fabricated identity or
    /// phone-side discard is emitted, and late recovery cannot undo the stop.
    func stopRecordingOnWatch() {
        guard canStopRecordingOnWatch else { return }
        stopSyncRecovery()
        let id = hasReceivedAuthoritativeContext && !isAwaitingWorkoutIdentity ? activeWorkout?.workoutID : nil
        workoutSuppression.stop(id)
        saveWorkoutSuppression()
        lifecycleGeneration &+= 1
        recoveryBootstrapTask?.cancel()
        recoveryBootstrapTask = nil
        engineRetryTask?.cancel()
        engineRetryTask = nil
        cancelEngineThenReconcile()
        WKInterfaceDevice.current().play(.stop)
    }

    /// A queued reset may clear only the phone epoch it invalidated. A notice
    /// arriving after a newer verified workout merely requests current state.
    func receiveReset(invalidatedEpoch: UUID) {
        WatchSyncDiagnostics.clear(defaults: defaults)
        guard syncRecovery.epoch == invalidatedEpoch else {
            requestFreshContext()
            return
        }
        stopSyncRecovery()
        cancelImmediateStart()
        clearStartPresentation()
        clearFinishingState(cancelTask: true)
        lifecycleGeneration &+= 1
        recoveryBootstrapTask?.cancel()
        recoveryBootstrapTask = nil
        engineRetryTask?.cancel()
        engineRetryTask = nil
        deferredSummaryWorkout = nil
        recoveryBootstrapComplete = true
        recoveryBootstrapFailed = false
        workoutSuppression = WatchWorkoutSuppression()
        saveWorkoutSuppression()
        WatchSyncDiagnostics.clear(defaults: defaults)
        context = nil
        summary = nil
        isAwaitingWorkoutIdentity = false
        hasReceivedAuthoritativeContext = false
        restHapticTask?.cancel()
        intervalHapticTask?.cancel()
        publishComplicationSnapshot(WatchAppContext(), force: true)
        syncRecovery = WatchSyncRecoveryState()
        cancelEngineThenReconcile()
        requestFreshContext()
    }

    private func saveWorkoutSuppression() {
        #if DEBUG
        if WatchAppStoreDemo.isRequested { return }
        #endif
        defaults.set(WatchWire.encode(workoutSuppression), forKey: "watch.workout.suppression.v1")
    }

    private func markTerminal(_ id: UUID) {
        workoutSuppression.finish(id)
        saveWorkoutSuppression()
    }

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
        guard recoveryBootstrapComplete else { return }
        reconcileEngineSession(previousWorkout: nil)
    }

    private func reconcileEngineSession(previousWorkout: WatchWorkoutSnapshot?) {
        // A new graph cannot transfer Health save ownership mid-commit.
        // The finishing task reconciles the latest graph after it resolves.
        if isFinishingWorkout { return }
        if isRecordingStopped {
            if engine.hasActiveSession { cancelEngineThenReconcile() }
            return
        }
        let resolution = WatchEngineIdentityPolicy.resolve(
            engineHasSession: engine.hasActiveSession,
            sessionWorkoutID: engine.activeSessionWorkoutID,
            hasAuthoritativeContext: hasReceivedAuthoritativeContext,
            contextWorkoutID: activeWorkout?.workoutID
        )
        switch resolution {
        case .awaitContext, .keepStreaming, .idle:
            break
        case .startSession:
            if let workout = activeWorkout {
                startEngineSession(for: workout)
            }
        case .endSession:
            // An authoritative context declared no workout; a recovered
            // session must not keep running headless.
            if let previousWorkout,
               engine.activeSessionWorkoutID == previousWorkout.workoutID {
                captureSummary(for: previousWorkout, metrics: engine.currentMetrics())
            }
            cancelEngineThenReconcile()
        case .endSessionAndStartCurrent:
            if WatchEngineIdentityPolicy.mayBindPendingHandoff(
                sessionWorkoutID: engine.activeSessionWorkoutID,
                isPendingHandoff: engine.isAwaitingSessionWorkoutID,
                contextWorkoutID: activeWorkout?.workoutID
            ),
               let workout = activeWorkout,
               engine.hasActiveSession {
                engine.rebindSessionWorkoutID(to: workout.workoutID)
            } else {
                // A recovered session bound to an older workout must never
                // resume under the current one: end it without saving and
                // start fresh for the snapshot.
                cancelEngineThenReconcile()
            }
        }
    }

    func recoverOrStartWorkoutSession() async {
        #if DEBUG
        // Deterministic Watch demos render a phone-provided snapshot without
        // starting HealthKit. Scene activation also calls this recovery path,
        // so keep the fixture isolated from the system authorization sheet.
        if WatchAppStoreDemo.isRequested { return }
        #endif
        if recoveryBootstrapComplete {
            ensureWorkoutSessionRunning()
            return
        }
        if let recoveryBootstrapTask {
            await recoveryBootstrapTask.value
            return
        }

        let generation = lifecycleGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // A transient HealthKit recovery failure is not evidence that no
            // session exists. Retry briefly, and leave bootstrap unresolved
            // if all attempts fail so no duplicate primary session can start.
            var recoveryResult: WatchWorkoutEngine.RecoveryResult = .retryNeeded
            for attempt in 0..<3 {
                recoveryResult = await self.engine.recoverSessionIfNeeded()
                guard !Task.isCancelled, self.lifecycleGeneration == generation else { return }
                guard recoveryResult == .retryNeeded else { break }
                guard attempt < 2 else { break }
                try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 3))
                guard !Task.isCancelled else { return }
            }
            guard recoveryResult != .retryNeeded else {
                self.recoveryBootstrapFailed = true
                self.scheduleEngineRecovery()
                return
            }
            self.recoveryBootstrapFailed = false
            if recoveryResult == .sessionAvailable, !self.hasReceivedAuthoritativeContext, self.activeWorkout == nil {
                self.showPhoneStartedWorkoutPlaceholder()
            }
            self.recoveryBootstrapComplete = true
            let previousWorkout = self.deferredSummaryWorkout
            self.deferredSummaryWorkout = nil
            self.reconcileEngineSession(previousWorkout: previousWorkout)
            self.engine.flushMetrics()
        }
        recoveryBootstrapTask = task
        await task.value
        if lifecycleGeneration == generation { recoveryBootstrapTask = nil }
    }

    /// HealthKit teardown is asynchronous. Keep the old engine session alive
    /// until its builder has actually ended, then reconcile against the latest
    /// authoritative snapshot. This prevents a rapid A-to-B transition (or a
    /// discard immediately followed by Start) from colliding two primary
    /// workout sessions on the watch.
    private func cancelEngineThenReconcile() {
        guard !isFinishingWorkout, engineReconciliationTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.engine.cancel()
            self.engineReconciliationTask = nil
            self.reconcileEngineSession(previousWorkout: nil)
        }
        engineReconciliationTask = task
    }

    /// Start metric collection bound to the exact workout the snapshot names,
    /// so the engine can later verify a recovered session against the current
    /// context instead of streaming under a newer workout (FF-003).
    private func startEngineSession(for workout: WatchWorkoutSnapshot) {
        #if DEBUG
        if WatchAppStoreDemo.isRequested { return }
        #endif
        engine.start(
            configuration: workoutConfiguration(for: workout),
            startDate: workout.startedAt,
            isYoga: workout.isYogaWorkout == true,
            workoutID: workout.workoutID
        )
    }

    // MARK: - Commands (watch → phone)

    func send(_ command: WatchCommand) {
        guard !command.startsWorkout, WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = WatchWire.encode(command) else { return }
        let payload = [WatchWire.commandKey: data]
        // A running workout can remain reachable in the background. Send
        // immediately when available and retain one latest fallback packet;
        // background context delivery has no real-time latency guarantee.
        if case .liveMetrics = command {
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(payload, replyHandler: nil) { error in
                    WatchSyncDiagnostics.record("metrics-message-failed", error: error)
                }
            }
            do {
                try WCSession.default.updateApplicationContext([WatchWire.liveMetricsKey: data])
            } catch {
                WatchSyncDiagnostics.record("metrics-context-failed", error: error)
            }
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

    /// Every delivery lane carries the same identity and sequence. Readings
    /// collected before verification are released only after exact binding.
    private func forwardMetrics(_ metrics: WatchLiveMetrics) {
        guard hasReceivedAuthoritativeContext, syncRecovery.hasVerifiedContext,
              !isRecordingStopped, !isFinishingWorkout,
              WatchEngineIdentityPolicy.mayStreamMetrics(
                sessionWorkoutID: engine.activeSessionWorkoutID,
                isAwaitingAuthoritativeIdentity: engine.isAwaitingSessionWorkoutID || isAwaitingWorkoutIdentity,
                contextWorkoutID: activeWorkout?.workoutID
              ) else { return }
        var packet = metrics
        packet.workoutID = engine.activeSessionWorkoutID
        metricsSequence &+= 1
        packet.streamID = metricsStreamID
        packet.sequence = metricsSequence
        packet.sentAt = Date()
        if let metricsSender { metricsSender(packet) }
        else { send(.liveMetrics(packet)) }
    }

    private func cancelQueuedStarts() {
        for transfer in WCSession.default.outstandingUserInfoTransfers {
            guard let data = transfer.userInfo[WatchWire.commandKey] as? Data,
                  let command = WatchWire.decode(WatchCommand.self, from: data),
                  command.startsWorkout else { continue }
            transfer.cancel()
        }
    }

    // MARK: - User actions

    /// Optimistically flips the set locally so the row responds instantly;
    /// the phone's next snapshot confirms it.
    func toggleSet(_ set: WatchSetSnapshot, in exercise: WatchExerciseSnapshot) {
        guard set.completed || !set.requiresConcreteRepsBeforeCompletion else { return }
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
    func updateSet(
        _ set: WatchSetSnapshot,
        in exercise: WatchExerciseSnapshot,
        weightKg: Double?,
        reps: Int?,
        partialReps: Int? = nil
    ) {
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
            if let partialReps { workout.exercises[ei].sets[si].partialReps = partialReps }
        }
        send(.updateSet(setID: set.id, weightKg: weightKg, reps: reps, partialReps: partialReps))
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
        guard !isFinishingWorkout, let workout = activeWorkout else { return }
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
        finishingWorkoutID = workout.workoutID
        finishIsDelayed = false
        finishDelayTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.finishingWorkoutID == workout.workoutID else { return }
            self.finishIsDelayed = true
            WatchSyncDiagnostics.record("engine-finish-delayed")
        }
        finishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            #if DEBUG
            if WatchAppStoreDemo.wantsDelayedFinish { try? await Task.sleep(for: .seconds(8)) }
            #endif
            if let reconciliation = self.engineReconciliationTask { await reconciliation.value }
            guard !Task.isCancelled else { return }
            let result = await self.engine.finish(workoutName: workout.title)
            guard !Task.isCancelled else { return }
            let sameWorkout = result.metrics.workoutID == workout.workoutID
            let metrics = sameWorkout ? result.metrics : WatchLiveMetrics(workoutID: workout.workoutID)
            self.markTerminal(workout.workoutID)
            // Health save ownership is known only at actual completion. A
            // timeout must not trigger a second, competing phone Health write.
            self.send(.finishWorkout(workoutID: workout.workoutID, metrics: metrics, savedToHealth: sameWorkout && result.savedToHealth))
            guard self.finishingWorkoutID == workout.workoutID else { return }
            self.clearFinishingState(cancelTask: false)
            if self.activeWorkout?.workoutID == workout.workoutID {
                self.captureSummary(for: workout, metrics: metrics)
                self.clearWorkoutLocally()
                self.stopSyncRecovery()
            } else {
                self.reconcileEngineSession(previousWorkout: nil)
            }
            WKInterfaceDevice.current().play(.success)
        }
    }

    private func clearFinishingState(cancelTask: Bool) {
        if cancelTask { finishTask?.cancel() }
        finishTask = nil
        finishDelayTask?.cancel()
        finishDelayTask = nil
        finishingWorkoutID = nil
        finishIsDelayed = false
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
        guard !isFinishingWorkout else { return }
        // Refuse while identity is pending, before any engine/wire/local
        // mutation — see `finishWorkout` (FF-002).
        guard WatchTerminalCommandPolicy.mayRunTerminalCommand(isAwaitingIdentity: isAwaitingWorkoutIdentity) else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        if let id = activeWorkout?.workoutID { markTerminal(id) }
        cancelEngineThenReconcile()
        // Stamped before `clearWorkoutLocally()` clears the mirror, so the
        // phone can refuse the discard if a newer workout is now active there.
        send(.discardWorkout(workoutID: activeWorkout?.workoutID))
        clearWorkoutLocally()
        summary = nil
        WKInterfaceDevice.current().play(.failure)
    }

    // MARK: - Phone-initiated launch (HKWorkoutConfiguration handoff)

    func handleWorkoutConfiguration(_ configuration: Any) {
        guard configuration is HKWorkoutConfigurationBox else { return }
        // HealthKit wake-ups carry no workout identity and may arrive late.
        // Only a fresh correlated phone snapshot can start a new recorder.
        // An old wake-up must not interrupt an already verified live stream.
        if hasReceivedAuthoritativeContext, syncRecovery.hasVerifiedContext,
           engine.hasActiveSession, let id = activeWorkout?.workoutID,
           engine.activeSessionWorkoutID == id, !engine.isAwaitingSessionWorkoutID {
            requestFreshContext()
            return
        }
        // Keep an existing graph visible while checking the current state.
        if !hasReceivedAuthoritativeContext { showPhoneStartedWorkoutPlaceholder() }
        hasReceivedAuthoritativeContext = false
        syncRecovery.requireVerification(at: Date())
        requestFreshContext()
        Task { await recoverOrStartWorkoutSession() }
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
        isAwaitingWorkoutIdentity = true
        // Preserve a visible exercise graph if the phone's matching context
        // won the race and arrived just before the HealthKit handoff. It is
        // still treated as provisional until the explicit refresh resolves it.
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
            workoutID: workout.workoutID,
            durationSeconds: max(0, Int(Date().timeIntervalSince(workout.startedAt))),
            completedSets: workout.completedSets,
            metrics: metrics
        )
    }

    func apply(context incomingContext: WatchAppContext) {
        guard syncRecovery.hasVerifiedContext else { return }
        let wasVerified = hasReceivedAuthoritativeContext && !isAwaitingWorkoutIdentity
        var newContext = incomingContext
        let previousSuppression = workoutSuppression
        workoutSuppression.resolve(newContext.workout?.workoutID)
        if let id = newContext.workout?.workoutID, workoutSuppression.terminalIDs.contains(id) {
            newContext.workout = nil
        }
        if previousSuppression != workoutSuppression { saveWorkoutSuppression() }
        // Any authoritative phone snapshot — with or without a workout —
        // resolves the visible placeholder identity (FF-002). Engine-session
        // binding uses its separate durable pending marker below; the UI flag
        // alone is never authority to relabel an existing HK session.
        isAwaitingWorkoutIdentity = false
        hasReceivedAuthoritativeContext = true
        let previous = context
        if WatchSummaryPresentationPolicy.shouldDismissSummary(
            summaryWorkoutID: summary?.workoutID,
            incomingWorkoutID: newContext.workout?.workoutID
        ) {
            summary = nil
        }
        WTheme.configure(family: newContext.effectiveThemeFamily)
        ForgeThemePreferenceStore.save(ForgeThemePreference(
            family: newContext.effectiveThemeFamily,
            mode: newContext.effectiveThemeMode
        ))
        context = newContext
        if newContext.workout != nil { clearStartPresentation() }

        // Keep the live engine on the user's synced HR-zone model so wrist-side
        // time-in-zone and zone-adherence alerts match the phone.
        engine.zoneConfig = newContext.effectiveHRZoneConfig
        engine.zoneTarget = newContext.workout?.hrZoneTarget

        // Never start/cancel while the asynchronous headless-session recovery
        // is unresolved. The latest authoritative context is retained above;
        // bootstrap reconciles it exactly once recovery completes.
        if recoveryBootstrapComplete {
            reconcileEngineSession(previousWorkout: previous?.workout)
        } else if newContext.workout == nil, let old = previous?.workout {
            deferredSummaryWorkout = old
        }
        if !recoveryBootstrapComplete {
            Task { await recoverOrStartWorkoutSession() }
        }

        if !wasVerified || previous?.workout?.workoutID != newContext.workout?.workoutID {
            engine.flushMetrics()
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
    private func publishComplicationSnapshot(_ context: WatchAppContext, force: Bool = false) {
        let snapshot: ForgeFitWidgetSnapshot
        if let workout = context.workout {
            snapshot = ForgeFitWidgetSnapshot(
                mode: .activeWorkout,
                updatedAt: context.updatedAt,
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
            // Day-gated: a context retained from yesterday must publish an
            // empty readiness, not yesterday's score with yesterday's stamp.
            snapshot = ForgeFitWidgetSnapshot(
                mode: .idle,
                updatedAt: context.updatedAt,
                readinessScore: context.currentReadiness(),
                readinessBasis: context.currentReadinessBasis(),
                readinessAction: context.currentReadinessAction(),
                readinessDetail: context.currentReadinessDetail()
            )
        }
        let previous = ForgeFitWidgetSnapshotStore.load()
        // The write is cheap and keeps `updatedAt` — which the complication's
        // own day gate reads — accurate for whenever WidgetKit next asks.
        // Only the reload request is budgeted, so only the reload is rationed.
        ForgeFitWidgetSnapshotStore.save(snapshot)
        guard shouldReloadComplication(for: snapshot, previous: previous, force: force) else { return }
        lastComplicationReloadAt = Date()
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitWatchComplication")
    }

    /// Whether this snapshot has earned one of the day's reload requests.
    ///
    /// The phone's publish path fires up to ~3x/s while a workout is being
    /// logged, and every one of those lands here. Reloading for each spent an
    /// entire day's budget inside one session, after which WidgetKit stopped
    /// honouring reloads at all — including the next morning's readiness.
    private func shouldReloadComplication(
        for snapshot: ForgeFitWidgetSnapshot,
        previous: ForgeFitWidgetSnapshot?,
        force: Bool,
        now: Date = Date()
    ) -> Bool {
        // Foregrounding asks for a reload the system may have deferred while
        // the app was in the background, so it must not be content-gated.
        if force { return true }
        guard let previous else { return true }
        guard !snapshot.rendersSameContent(as: previous) else { return false }
        // Readiness changes and mode transitions are rare and always shown;
        // only set-by-set progress within a live workout waits out the floor.
        guard snapshot.mode == .activeWorkout, previous.mode == .activeWorkout else { return true }
        guard let lastComplicationReloadAt else { return true }
        return now.timeIntervalSince(lastComplicationReloadAt) >= Self.activeWorkoutReloadInterval
    }

    /// Reassert the latest received state whenever the watch app becomes
    /// active. WatchConnectivity can update this process while it is in the
    /// background, where WidgetKit may defer the accompanying reload request;
    /// foregrounding must therefore give the complication another explicit
    /// chance to consume the already-current context.
    func refreshComplication() {
        guard let context else { return }
        publishComplicationSnapshot(context, force: true)
    }

    /// Ask the phone to publish a fresh context.
    ///
    /// Republishing what we already hold can't fix day-scoped data: WCSession
    /// hands us the last application context the phone sent — possibly
    /// yesterday's, since the phone only publishes while its own app runs.
    /// Without this the watch shows yesterday's readiness until the user
    /// opens the phone app. `sendMessage` also background-launches the phone
    /// app to answer, so it works with the phone in a pocket.
    func requestFreshContext() {
        startSyncRecovery()
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

    func handle(_ command: WatchCommand) {
        switch command {
        case .workoutFinished(let workoutID):
            // transferUserInfo may deliver A's queued finish only after a new
            // phone-started workout B wakes the Watch. Never let that stale
            // command tear down B or put A's Done screen over B's live UI.
            guard WatchTerminalCommandPolicy.mayRunTerminalCommand(
                      isAwaitingIdentity: isAwaitingWorkoutIdentity
                  ),
                  let workout = activeWorkout,
                  WatchTerminalCommandPolicy.shouldExecute(
                      carriedWorkoutID: workoutID,
                      activeWorkoutID: workout.workoutID
                  ) else { requestFreshContext(); return }
            markTerminal(workout.workoutID)
            if engine.hasActiveSession {
                captureSummary(for: workout, metrics: engine.currentMetrics())
                cancelEngineThenReconcile()
            }
            clearWorkoutLocally()
        case .discardWorkout(let id):
            guard !isAwaitingWorkoutIdentity,
                  WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: id, activeWorkoutID: activeWorkout?.workoutID),
                  let id else { requestFreshContext(); return }
            markTerminal(id)
            cancelEngineThenReconcile()
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
            if activationState == .activated {
                self.cancelQueuedStarts()
                self.engine.flushMetrics()
            }
            // Retained state is never session authority, including a cold
            // recovery whose in-memory pending flag has not been restored.
            if let error { WatchSyncDiagnostics.record("activation-failed", error: error) }
            self.requestFreshContext()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            // Any reconnection is a chance to notice "phone says a workout is
            // live but our engine is idle" (e.g. the engine died while we
            // were unreachable), refresh a missed workout graph, and restart
            // collection under the exact authoritative identity.
            if session.isReachable {
                self.engine.flushMetrics()
                self.requestFreshContext()
                await self.recoverOrStartWorkoutSession()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchWire.contextKey] as? Data else { return }
        let metadata = applicationContext[WatchWire.syncMetadataKey] as? Data
        Task { @MainActor in self.receiveSnapshot(data, metadataData: metadata) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let rawEpoch = message[WatchWire.syncResetKey] as? String, let epoch = UUID(uuidString: rawEpoch) {
            Task { @MainActor in self.receiveReset(invalidatedEpoch: epoch) }
            return
        }
        if let data = message[WatchWire.contextKey] as? Data {
            let metadata = message[WatchWire.syncMetadataKey] as? Data
            Task { @MainActor in self.receiveSnapshot(data, metadataData: metadata) }
        }
        if let data = message[WatchWire.commandKey] as? Data,
           let command = WatchWire.decode(WatchCommand.self, from: data) {
            Task { @MainActor in self.handle(command) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let rawEpoch = userInfo[WatchWire.syncResetKey] as? String, let epoch = UUID(uuidString: rawEpoch) {
            Task { @MainActor in self.receiveReset(invalidatedEpoch: epoch) }
            return
        }
        if let data = userInfo[WatchWire.contextKey] as? Data {
            let metadata = userInfo[WatchWire.syncMetadataKey] as? Data
            Task { @MainActor in self.receiveSnapshot(data, metadataData: metadata) }
        }
        if let data = userInfo[WatchWire.commandKey] as? Data,
           let command = WatchWire.decode(WatchCommand.self, from: data) {
            Task { @MainActor in self.handle(command) }
        }
    }
}
