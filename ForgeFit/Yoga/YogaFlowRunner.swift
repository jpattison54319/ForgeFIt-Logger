import AudioToolbox
import ForgeCore
import ForgeData
import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Durable, local execution state for one guided hold. This is deliberately
/// transient app state rather than workout history: it exists only so an app
/// relaunch or a Watch-initiated finish can distinguish time actually held
/// from time spent paused or with another timed segment active.
nonisolated struct YogaRuntimeCheckpoint: Codable, Equatable, Sendable {
    let stepIndex: Int
    let elapsedSeconds: Int
    let isPaused: Bool
    let capturedAt: Date

    func elapsed(at date: Date, cappedAt maximum: Int) -> Int {
        let runningDelta = isPaused ? 0 : max(0, Int(date.timeIntervalSince(capturedAt)))
        return min(maximum, max(0, elapsedSeconds + runningDelta))
    }
}

/// Per-session UserDefaults storage survives process death without adding a
/// CloudKit/SwiftData schema field for runtime-only state. Completion and
/// discard clear it; stopping a runner to switch timed segments freezes it.
nonisolated enum YogaRuntimeCheckpointStore {
    static let keyPrefix = "forgefit.yoga.runtime.v1."

    static func load(
        sessionID: UUID,
        defaults: UserDefaults = .standard
    ) -> YogaRuntimeCheckpoint? {
        guard let data = defaults.data(forKey: keyPrefix + sessionID.uuidString) else { return nil }
        return try? JSONDecoder().decode(YogaRuntimeCheckpoint.self, from: data)
    }

    static func save(
        _ checkpoint: YogaRuntimeCheckpoint,
        sessionID: UUID,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        defaults.set(data, forKey: keyPrefix + sessionID.uuidString)
    }

    static func clear(sessionID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: keyPrefix + sessionID.uuidString)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// App-wide handle to the (single) running guided yoga class so the watch
/// snapshot, Live Activity, the logger card, and the full-screen player all
/// see the same pose state. Mutually exclusive with a running interval
/// session — starting one stops the other (a workout can contain both cardio
/// and yoga exercises, but only one timed runner makes sense at a time).
@MainActor
@Observable
final class YogaFlowRunnerHub {
    static let shared = YogaFlowRunnerHub()

    private(set) var runner: YogaFlowRunner?

    func start(plan: YogaFlowPlan, session: CardioSessionModel, context: ModelContext) {
        runner?.stop()
        IntervalRunnerHub.shared.stop()
        guard let runner = YogaFlowRunner(plan: plan, session: session, context: context) else { return }
        self.runner = runner
        // Resuming a session that already recorded holds (app relaunched
        // mid-class, or restarted from the wrist) picks up where it left off
        // instead of replaying — and re-crediting — the whole flow.
        let completedIndexes = Set(
            session.splits
                .filter { $0.label != nil }
                .map(\.index)
                .filter { 0..<runner.steps.count ~= $0 }
        )
        let startIndex = (0..<runner.steps.count).first { !completedIndexes.contains($0) } ?? runner.steps.count
        if startIndex == runner.steps.count {
            // Every persisted hold already exists. Reopening this uncommitted
            // session must not replay the completion clip or write guidance
            // history a second time (FF-014).
            runner.restoreFinishedSilently()
        } else {
            runner.restoreOrStart(at: startIndex, completedIndexes: completedIndexes)
        }
    }

    func runner(for sessionID: UUID) -> YogaFlowRunner? {
        runner?.sessionID == sessionID ? runner : nil
    }

    func stop(for sessionID: UUID? = nil, clearCheckpoint: Bool = false) {
        if let sessionID, runner?.sessionID != sessionID { return }
        let resolvedSessionID = sessionID ?? runner?.sessionID
        runner?.stop()
        runner = nil
        if clearCheckpoint, let resolvedSessionID {
            YogaRuntimeCheckpointStore.clear(sessionID: resolvedSessionID)
        }
    }

    /// Complete a running class mid-hold: record the current partial hold with
    /// the same credit Skip applies, then stop the runner without issuing
    /// guidance. Completion callers follow up with
    /// `YogaSessionCompletion.complete`, which derives pose count, exposure,
    /// and history from the recorded split, and reconciles the interrupted
    /// hold itself when no runner exists (app terminated mid-class). Deletion
    /// and discard paths keep using `stop(for:)`, which never credits.
    func complete(for sessionID: UUID, persist: Bool = true) {
        guard let runner, runner.sessionID == sessionID else { return }
        runner.complete(persist: persist)
        self.runner = nil
    }
}

/// Drives a guided yoga class: wall-clock-anchored pose holds, modular spoken
/// guidance, auto-advance with haptics, and one
/// `CardioSplitModel` written per completed hold. The phone is the execution
/// authority; the watch mirrors the current pose. Patterned on
/// `IntervalRunner`, not shared with it — the narration and
/// side expansion are yoga-specific.
@MainActor
@Observable
final class YogaFlowRunner {

    /// One runnable hold: a plan step after L/R side expansion.
    struct RuntimeStep: Identifiable, Equatable {
        let id: Int                      // stable index in the expanded list
        let poseStep: YogaFlowPlan.PoseStep
        /// Concrete side for this hold (.left/.right), nil for bilateral.
        let side: YogaFlowPlan.Side?
        var seconds: Int { poseStep.holdSeconds }

        var displayName: String {
            switch side {
            case .left: "\(poseStep.name) — Left"
            case .right: "\(poseStep.name) — Right"
            default: poseStep.name
            }
        }
    }

    let plan: YogaFlowPlan
    let steps: [RuntimeStep]
    let sessionID: UUID
    private let session: CardioSessionModel
    private let context: ModelContext

    /// Index of the currently running hold; == steps.count when finished.
    private(set) var currentIndex: Int = 0
    /// Wall-clock end of the current hold (undefined while paused).
    private(set) var stepEndsAt: Date
    private(set) var isFinished = false
    private(set) var isPaused = false
    /// Seconds left in the current hold, captured at pause.
    private(set) var pausedRemaining: Int = 0

    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var stepStartedAt: Date
    @ObservationIgnored private var guidancePlans: [Int: YogaGuidancePlan] = [:]
    @ObservationIgnored private var plannedGuidanceIDs: Set<String> = []
    @ObservationIgnored private var playedGuidanceIDs: Set<String> = []
    @ObservationIgnored private var recordedGuidanceHistory = false
    @ObservationIgnored private let guidanceSeed: UInt64

    init?(plan: YogaFlowPlan, session: CardioSessionModel, context: ModelContext) {
        guard plan.hasSteps else { return nil }
        self.plan = plan
        self.steps = Self.expand(plan)
        self.sessionID = session.id
        self.session = session
        self.context = context
        self.guidanceSeed = Self.stableSeed(for: session.id)
        let now = Date()
        self.stepStartedAt = now
        self.stepEndsAt = now.addingTimeInterval(TimeInterval(steps[0].seconds))
    }

    /// `.bothSides` poses become two holds (left, then right); everything
    /// else passes through as one.
    static func expand(_ plan: YogaFlowPlan) -> [RuntimeStep] {
        var result: [RuntimeStep] = []
        for step in plan.steps {
            if step.side == .bothSides {
                result.append(RuntimeStep(id: result.count, poseStep: step, side: .left))
                result.append(RuntimeStep(id: result.count, poseStep: step, side: .right))
            } else {
                result.append(RuntimeStep(id: result.count, poseStep: step, side: step.side))
            }
        }
        return result
    }

    var currentStep: RuntimeStep? {
        currentIndex < steps.count ? steps[currentIndex] : nil
    }

    var nextStep: RuntimeStep? {
        currentIndex + 1 < steps.count ? steps[currentIndex + 1] : nil
    }

    /// The catalog entry behind the current hold (cues, Sanskrit, art), nil
    /// for custom poses.
    var currentPose: YogaPoseSeed? {
        YogaPoseCatalog.pose(forSlug: currentStep?.poseStep.poseSlug)
    }

    func start() {
        start(at: 0)
    }

    func start(at index: Int) {
        beginStep(at: max(0, index), announceEntry: true)
    }

    /// Restore the exact current hold after process death. Running time since
    /// the last checkpoint counts; paused time does not. If the hold elapsed
    /// while the app was gone, credit that one hold at its plan cap and start
    /// the next at zero rather than pretending guidance advanced off-process.
    func restoreOrStart(at fallbackIndex: Int, completedIndexes: Set<Int>) {
        guard let checkpoint = YogaRuntimeCheckpointStore.load(sessionID: sessionID),
              steps.indices.contains(checkpoint.stepIndex),
              !completedIndexes.contains(checkpoint.stepIndex) else {
            beginStep(at: fallbackIndex, announceEntry: true)
            return
        }

        let step = steps[checkpoint.stepIndex]
        let now = Date.now
        let elapsed = checkpoint.elapsed(at: now, cappedAt: step.seconds)
        currentIndex = checkpoint.stepIndex
        if elapsed >= step.seconds {
            let endedAt = checkpoint.capturedAt.addingTimeInterval(
                TimeInterval(max(0, step.seconds - checkpoint.elapsedSeconds))
            )
            stepStartedAt = endedAt.addingTimeInterval(-TimeInterval(step.seconds))
            recordSplit(upTo: endedAt, durationSeconds: step.seconds)
            beginStep(at: checkpoint.stepIndex + 1, announceEntry: true)
        } else if checkpoint.isPaused {
            isPaused = true
            pausedRemaining = max(1, step.seconds - elapsed)
            stepStartedAt = now.addingTimeInterval(-TimeInterval(elapsed))
            stepEndsAt = now.addingTimeInterval(TimeInterval(pausedRemaining))
            persistCheckpoint(at: now)
            _ = guidancePlan(for: step, index: checkpoint.stepIndex)
            WatchLink.shared.publishState()
        } else {
            isPaused = false
            stepStartedAt = now.addingTimeInterval(-TimeInterval(elapsed))
            stepEndsAt = now.addingTimeInterval(TimeInterval(step.seconds - elapsed))
            persistCheckpoint(at: now)
            WatchLink.shared.publishState()
            scheduleAdvance(playFromStart: false)
        }
    }

    /// All holds were already persisted before this runner was constructed.
    /// Restore terminal presentation state without terminal side effects.
    func restoreFinishedSilently() {
        advanceTask?.cancel()
        advanceTask = nil
        currentIndex = steps.count
        isFinished = true
        isPaused = false
        YogaRuntimeCheckpointStore.clear(sessionID: sessionID)
    }

    /// Skip forward to the next hold (records the current split short).
    func skip() {
        guard !isFinished else { return }
        let wasPaused = isPaused
        YogaGuidanceAudio.shared.stop()
        recordSplit(upTo: Date.now, durationSeconds: wasPaused ? currentElapsedSeconds() : nil)
        transitionHaptic(sideSwitch: false)
        if wasPaused {
            beginPausedStep(at: currentIndex + 1)
        } else {
            beginStep(at: currentIndex + 1, announceEntry: true)
        }
    }

    /// Complete the class now instead of advancing: the hold in progress is
    /// credited with the seconds actually held — identical partial-credit
    /// semantics to `skip()` — then guidance stops and no further hold
    /// begins. The session-completion pipeline that every caller runs
    /// afterwards derives pose count, exposure, and history from the recorded
    /// split. Distinct from `finishFlow()`, which runs only when every planned
    /// hold actually completed.
    func complete(persist: Bool = true) {
        guard !isFinished else { return }
        advanceTask?.cancel()
        advanceTask = nil
        let now = Date.now
        // `recordSplit` guarantees at least one credited second. Freeze the
        // same value in the checkpoint so a failed outer transaction can
        // roll the split back and reconstruct it exactly on retry.
        let creditedSeconds = max(1, currentElapsedSeconds(at: now))
        let completedStepIndex = currentIndex
        YogaGuidanceAudio.shared.stop(clearCaption: true)
        recordSplit(
            upTo: now,
            durationSeconds: creditedSeconds,
            persist: persist
        )
        currentIndex = steps.count
        isFinished = true
        if persist {
            YogaRuntimeCheckpointStore.clear(sessionID: sessionID)
        } else {
            YogaRuntimeCheckpointStore.save(
                YogaRuntimeCheckpoint(
                    stepIndex: completedStepIndex,
                    elapsedSeconds: creditedSeconds,
                    isPaused: true,
                    capturedAt: now
                ),
                sessionID: sessionID
            )
        }
        WatchLink.shared.publishState()
    }

    /// Go back to the start of the current hold, or the previous one when
    /// tapped within its first few seconds (music-player convention).
    func back() {
        guard !isFinished else { return }
        let wasPaused = isPaused
        YogaGuidanceAudio.shared.stop()
        let elapsed = currentElapsedSeconds()
        let target = elapsed < 4 ? max(0, currentIndex - 1) : currentIndex
        if wasPaused {
            beginPausedStep(at: target)
        } else {
            beginStep(at: target, announceEntry: true)
        }
    }

    func pause() {
        guard !isPaused, !isFinished else { return }
        let now = Date.now
        let elapsed = currentElapsedSeconds(at: now)
        isPaused = true
        pausedRemaining = max(1, currentSeconds - elapsed)
        advanceTask?.cancel()
        advanceTask = nil
        YogaGuidanceAudio.shared.stop()
        persistCheckpoint(at: now)
        WatchLink.shared.publishState()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        // Re-anchor the wall clock to the captured remainder.
        stepStartedAt = Date().addingTimeInterval(TimeInterval(pausedRemaining - currentSeconds))
        stepEndsAt = Date().addingTimeInterval(TimeInterval(pausedRemaining))
        persistCheckpoint()
        scheduleAdvance()
        WatchLink.shared.publishState()
    }

    func stop() {
        // A stopped runner may be resumed later (for example after switching
        // to an interval block). Freeze the checkpoint so that off-runner wall
        // time cannot become yoga hold credit.
        if !isFinished, !isPaused {
            let now = Date.now
            let elapsed = currentElapsedSeconds(at: now)
            isPaused = true
            pausedRemaining = max(1, currentSeconds - elapsed)
            persistCheckpoint(at: now)
        }
        advanceTask?.cancel()
        advanceTask = nil
        YogaGuidanceAudio.shared.stop(clearCaption: true)
    }

    private var currentSeconds: Int {
        currentStep?.seconds ?? 0
    }

    private func currentElapsedSeconds(at date: Date = .now) -> Int {
        if isPaused {
            max(0, currentSeconds - pausedRemaining)
        } else {
            min(currentSeconds, max(0, Int(date.timeIntervalSince(stepStartedAt))))
        }
    }

    private func persistCheckpoint(at date: Date = .now) {
        guard !isFinished, steps.indices.contains(currentIndex) else {
            YogaRuntimeCheckpointStore.clear(sessionID: sessionID)
            return
        }
        YogaRuntimeCheckpointStore.save(
            YogaRuntimeCheckpoint(
                stepIndex: currentIndex,
                elapsedSeconds: currentElapsedSeconds(at: date),
                isPaused: isPaused,
                capturedAt: date
            ),
            sessionID: sessionID
        )
    }

    private func beginStep(at index: Int, announceEntry: Bool) {
        advanceTask?.cancel()
        isPaused = false
        guard index < steps.count else {
            finishFlow()
            return
        }
        currentIndex = index
        let step = steps[index]
        stepStartedAt = Date()
        stepEndsAt = stepStartedAt.addingTimeInterval(TimeInterval(step.seconds))
        persistCheckpoint(at: stepStartedAt)

        let guidancePlan = guidancePlan(for: step, index: index)
        // The watch mirrors pose state from the phone snapshot — push every
        // transition so its countdown and haptics stay anchored.
        WatchLink.shared.publishState()
        scheduleAdvance(plan: guidancePlan, playFromStart: announceEntry)
    }

    private func beginPausedStep(at index: Int) {
        advanceTask?.cancel()
        guard index < steps.count else {
            finishFlow()
            return
        }
        currentIndex = index
        let step = steps[index]
        let now = Date.now
        stepStartedAt = now
        stepEndsAt = now.addingTimeInterval(TimeInterval(step.seconds))
        pausedRemaining = step.seconds
        isPaused = true
        persistCheckpoint(at: now)
        _ = guidancePlan(for: step, index: index)
        WatchLink.shared.publishState()
    }

    /// One task per hold walks a precomputed modular guidance timeline and
    /// then advances on the same wall-clock boundary. Measured MP3 durations
    /// keep clips from colliding; a paused-and-resumed hold skips checkpoints
    /// that have already passed instead of replaying a burst of old cues.
    private func scheduleAdvance(
        plan guidancePlan: YogaGuidancePlan? = nil,
        playFromStart: Bool = false
    ) {
        let step = steps[currentIndex]
        let index = currentIndex
        let guidancePlan = guidancePlan ?? self.guidancePlan(for: step, index: index)
        advanceTask = Task { @MainActor [weak self] in
            for cue in guidancePlan.cues {
                guard let self else { return }
                let cueAt = self.stepStartedAt.addingTimeInterval(cue.offset)
                let wait = cueAt.timeIntervalSinceNow
                if wait <= 0, !playFromStart || cue.offset > 0 {
                    continue
                }
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
                guard !Task.isCancelled, self.currentIndex == index, !self.isPaused else { return }
                YogaGuidanceAudio.shared.play(
                    cue.clip,
                    voiceEnabled: self.plan.voiceGuidanceEnabled
                )
                self.playedGuidanceIDs.insert(cue.clip.id)
            }
            guard let endsAt = self?.stepEndsAt else { return }
            try? await Task.sleep(for: .seconds(max(0, endsAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.currentIndex == index, !self.isPaused else { return }
            self.recordSplit(upTo: self.stepEndsAt)
            self.transitionHaptic(sideSwitch: self.nextStep?.poseStep.id == step.poseStep.id)
            self.scheduleBackstopNotification()
            self.beginStep(at: index + 1, announceEntry: true)
        }
    }

    private func finishFlow() {
        advanceTask?.cancel()
        advanceTask = nil
        currentIndex = steps.count
        isFinished = true
        // Keep a full final-hold checkpoint until the surrounding session's
        // terminal save commits. If the last split save failed and the app is
        // terminated, relaunch can reconstruct that final hold instead of
        // silently losing it.
        if let finalStep = steps.last {
            YogaRuntimeCheckpointStore.save(
                YogaRuntimeCheckpoint(
                    stepIndex: finalStep.id,
                    elapsedSeconds: finalStep.seconds,
                    isPaused: true,
                    capturedAt: .now
                ),
                sessionID: sessionID
            )
        }
        session.posesCompleted = plan.steps.count
        context.saveUserChanges()
        let completion = YogaGuidancePlanner.completionClip(
            sessionSeed: guidanceSeed,
            excludedClipIDs: YogaGuidanceHistory.recentClipIDs.union(plannedGuidanceIDs)
        )
        YogaGuidanceAudio.shared.play(
            completion,
            voiceEnabled: plan.voiceGuidanceEnabled
        )
        playedGuidanceIDs.insert(completion.id)
        if !recordedGuidanceHistory {
            YogaGuidanceHistory.record(Array(playedGuidanceIDs))
            recordedGuidanceHistory = true
        }
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        WatchLink.shared.publishState()
    }

    private func guidancePlan(for step: RuntimeStep, index: Int) -> YogaGuidancePlan {
        if let existing = guidancePlans[index] { return existing }
        let context = YogaGuidancePlanningContext(
            poseSlug: step.poseStep.poseSlug,
            poseName: step.poseStep.name,
            side: step.side,
            holdSeconds: step.seconds,
            style: plan.style,
            customTransitionCue: step.poseStep.transitionCue,
            isFirstStep: index == 0
        )
        let excluded = YogaGuidanceHistory.recentClipIDs.union(plannedGuidanceIDs)
        let created = YogaGuidancePlanner.plan(
            context: context,
            sessionSeed: guidanceSeed,
            stepIndex: index,
            excludedClipIDs: excluded,
            measuredDurations: YogaAudioLibrary.measuredDurations
        )
        guidancePlans[index] = created
        plannedGuidanceIDs.formUnion(created.clipIDs)
        return created
    }

    nonisolated private static func stableSeed(for id: UUID) -> UInt64 {
        id.uuidString.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    /// Persist the completed hold as a split on the session — the raw
    /// material for per-region flexibility analytics.
    private func recordSplit(
        upTo end: Date,
        durationSeconds overrideDuration: Int? = nil,
        persist: Bool = true
    ) {
        guard currentIndex < steps.count else { return }
        let step = steps[currentIndex]
        let duration = max(1, overrideDuration ?? Int(end.timeIntervalSince(stepStartedAt)))
        let split = CardioSplitModel(
            userID: session.userID,
            cardioSessionID: session.id,
            index: step.id,
            distanceMeters: 0,
            durationSeconds: duration,
            paceSecondsPerKm: 0,
            label: step.displayName,
            startedAt: stepStartedAt,
            endedAt: end
        )
        split.cardioSession = session
        context.insert(split)
        session.splits.append(split)
        if persist { context.saveUserChanges() }
    }

    /// Distinct patterns: light tap for switching sides of the same pose,
    /// firmer notification for a genuinely new pose.
    private func transitionHaptic(sideSwitch: Bool) {
        #if canImport(UIKit)
        if sideSwitch {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        #endif
    }

    /// The wall-clock schedule of every remaining pose transition: at each
    /// hold's end, the notification names the pose that begins. Used to
    /// pre-schedule the locked-phone backstop when the app backgrounds.
    func upcomingTransitions() -> [(label: String, fireAt: Date)] {
        guard !isPaused, !isFinished, currentIndex < steps.count else { return [] }
        var entries: [(label: String, fireAt: Date)] = []
        var boundary = stepEndsAt
        for index in (currentIndex + 1)..<steps.count {
            entries.append((label: steps[index].displayName, fireAt: boundary))
            boundary = boundary.addingTimeInterval(TimeInterval(steps[index].seconds))
        }
        entries.append((label: "Practice complete", fireAt: boundary))
        return entries
    }

    /// Backstop for a backgrounded app whose audio was killed: a
    /// time-sensitive notification names the next pose.
    private func scheduleBackstopNotification() {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .active, let next = nextStep else { return }
        NotificationScheduler.shared.scheduleIntervalCue(stepLabel: next.displayName)
        #endif
    }
}
