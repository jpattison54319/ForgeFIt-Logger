import AudioToolbox
import ForgeCore
import ForgeData
import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

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
        runner.start(at: startIndex)
    }

    func runner(for sessionID: UUID) -> YogaFlowRunner? {
        runner?.sessionID == sessionID ? runner : nil
    }

    func stop(for sessionID: UUID? = nil) {
        if let sessionID, runner?.sessionID != sessionID { return }
        runner?.stop()
        runner = nil
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
        isPaused = true
        pausedRemaining = max(1, Int(stepEndsAt.timeIntervalSinceNow.rounded()))
        advanceTask?.cancel()
        advanceTask = nil
        YogaGuidanceAudio.shared.stop()
        WatchLink.shared.publishState()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        // Re-anchor the wall clock to the captured remainder.
        stepStartedAt = Date().addingTimeInterval(TimeInterval(pausedRemaining - currentSeconds))
        stepEndsAt = Date().addingTimeInterval(TimeInterval(pausedRemaining))
        scheduleAdvance()
        WatchLink.shared.publishState()
    }

    func stop() {
        advanceTask?.cancel()
        advanceTask = nil
        YogaGuidanceAudio.shared.stop(clearCaption: true)
    }

    private var currentSeconds: Int {
        currentStep?.seconds ?? 0
    }

    private func currentElapsedSeconds() -> Int {
        if isPaused {
            max(0, currentSeconds - pausedRemaining)
        } else {
            max(0, Int(Date.now.timeIntervalSince(stepStartedAt)))
        }
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
        session.posesCompleted = steps.count
        try? context.save()
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
    private func recordSplit(upTo end: Date, durationSeconds overrideDuration: Int? = nil) {
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
        try? context.save()
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
