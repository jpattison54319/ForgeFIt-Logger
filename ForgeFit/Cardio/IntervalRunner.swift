import AudioToolbox
import ForgeCore
import ForgeData
import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Drives a structured cardio interval session: wall-clock-anchored step
/// countdowns, auto-advance with a haptic + notification cue at each
/// transition, and one `CardioSplitModel` written per completed step. The
/// phone is the execution authority; the watch mirrors the current step.
/// App-wide handle to the (single) running interval session so the watch
/// snapshot, Live Activity, and the cardio card all see the same step state.
@MainActor
@Observable
final class IntervalRunnerHub {
    static let shared = IntervalRunnerHub()

    private(set) var runner: IntervalRunner?

    func start(planJSON: String?, session: CardioSessionModel, context: ModelContext) {
        runner?.stop()
        // One timed runner at a time: intervals and a guided yoga class can't
        // both own the clock, cues, and watch mirroring.
        YogaFlowRunnerHub.shared.stop()
        guard let runner = IntervalRunner(planJSON: planJSON, session: session, context: context) else { return }
        self.runner = runner
        runner.start()
    }

    func runner(for sessionID: UUID) -> IntervalRunner? {
        runner?.sessionID == sessionID ? runner : nil
    }

    func stop(for sessionID: UUID? = nil) {
        if let sessionID, runner?.sessionID != sessionID { return }
        runner?.stop()
        runner = nil
    }
}

@MainActor
@Observable
final class IntervalRunner {
    let plan: IntervalPlan
    let sessionID: UUID
    private let session: CardioSessionModel
    private let context: ModelContext

    /// Index of the currently running step; == plan.steps.count when finished.
    private(set) var currentIndex: Int = 0
    /// Wall-clock end of the current step.
    private(set) var stepEndsAt: Date
    private(set) var isFinished = false

    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var stepStartedAt: Date

    init?(planJSON: String?, session: CardioSessionModel, context: ModelContext) {
        guard let plan = IntervalPlan.decode(from: planJSON), !plan.steps.isEmpty else { return nil }
        self.plan = plan
        self.sessionID = session.id
        self.session = session
        self.context = context
        let now = Date()
        self.stepStartedAt = now
        self.stepEndsAt = now.addingTimeInterval(TimeInterval(plan.steps[0].seconds))
    }

    var currentStep: IntervalPlan.Step? {
        currentIndex < plan.steps.count ? plan.steps[currentIndex] : nil
    }

    var nextStep: IntervalPlan.Step? {
        currentIndex + 1 < plan.steps.count ? plan.steps[currentIndex + 1] : nil
    }

    /// "Round 3 of 10" while inside the work/recover blocks; nil during
    /// warm-up (before any work) or plans with no work steps.
    var roundInfo: (round: Int, total: Int)? {
        plan.roundInfo(at: min(currentIndex, plan.steps.count - 1))
    }

    /// The zone the athlete should hold right now: the step's own target,
    /// else the plan-wide lock.
    var currentZoneTarget: Int? {
        (currentStep?.hrZone) ?? plan.hrZoneTarget
    }

    func start() {
        beginStep(at: 0)
    }

    /// Manually skip to the next step (writes the current split short).
    func skip() {
        recordSplit(upTo: Date())
        advance()
    }

    func stop() {
        advanceTask?.cancel()
        advanceTask = nil
    }

    private func beginStep(at index: Int) {
        advanceTask?.cancel()
        guard index < plan.steps.count else {
            isFinished = true
            return
        }
        currentIndex = index
        stepStartedAt = Date()
        stepEndsAt = stepStartedAt.addingTimeInterval(TimeInterval(plan.steps[index].seconds))
        applyZoneGuard(for: plan.steps[index])
        // The watch mirrors step state from the phone snapshot — push every
        // transition so its countdown and haptics stay anchored.
        WatchLink.shared.publishState()

        let interval = stepEndsAt.timeIntervalSinceNow
        advanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, interval)))
            guard !Task.isCancelled, let self else { return }
            self.recordSplit(upTo: self.stepEndsAt)
            self.cue()
            self.advance()
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next < plan.steps.count {
            beginStep(at: next)
        } else {
            advanceTask?.cancel()
            currentIndex = plan.steps.count
            isFinished = true
            // Back to the plan-wide lock (or off) once the steps are done.
            if let zone = plan.hrZoneTarget {
                HRZoneGuard.shared.activate(targetZone: zone, speak: zoneVoiceEnabled)
            } else {
                HRZoneGuard.shared.deactivate()
            }
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            playSoundCue()
            WatchLink.shared.publishState()
        }
    }

    /// Follow the step's HR target: activate/retune the zone guard when this
    /// step (or the plan) has one, silence it when neither does.
    private func applyZoneGuard(for step: IntervalPlan.Step) {
        let guardian = HRZoneGuard.shared
        if let zone = step.hrZone ?? plan.hrZoneTarget {
            if !guardian.isActive || guardian.targetZone != zone {
                guardian.activate(targetZone: zone, speak: zoneVoiceEnabled)
            }
        } else if guardian.isActive {
            guardian.deactivate()
        }
    }

    private var zoneVoiceEnabled: Bool {
        UserDefaults.standard.object(forKey: "zoneVoiceCues") as? Bool ?? true
    }

    /// Persist the completed step as a split on the session.
    private func recordSplit(upTo end: Date) {
        guard currentIndex < plan.steps.count else { return }
        let step = plan.steps[currentIndex]
        let duration = max(1, Int(end.timeIntervalSince(stepStartedAt)))
        let split = CardioSplitModel(
            userID: session.userID,
            cardioSessionID: session.id,
            index: session.splits.count,
            distanceMeters: 0,
            durationSeconds: duration,
            paceSecondsPerKm: 0,
            label: step.label,
            startedAt: stepStartedAt,
            endedAt: end
        )
        split.cardioSession = session
        context.insert(split)
        session.splits.append(split)
        try? context.save()
    }

    /// Haptic + sound + time-sensitive notification when a step changes, so
    /// the cue lands even with the phone locked / pocketed.
    private func cue() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
        playSoundCue()
        if let upcoming = nextStep {
            NotificationScheduler.shared.scheduleIntervalCue(stepLabel: upcoming.label)
        }
    }

    /// Short audible ping on interval transitions (defaults on; toggleable via
    /// the "intervalSoundCues" setting). Distinct from the zone guard's voice.
    private func playSoundCue() {
        let enabled = UserDefaults.standard.object(forKey: "intervalSoundCues") as? Bool ?? true
        guard enabled else { return }
        AudioServicesPlaySystemSound(1057)   // short "tink" timer tick
    }
}

// MARK: - Live guidance strip (inside CardioExerciseCard while recording)

import SwiftUI

// Theme-injected (see RecoveryDetailView's tint note): hardcoding
// `AppTheme.sage` drew dark-tuned hues on light-mode cards.
extension IntervalPlan.Step.Kind {
    func tint(in theme: AppTheme) -> Color {
        switch self {
        case .warmup, .cooldown: return theme.warmup
        case .work: return theme.secondaryAccent
        case .recover: return theme.accent
        }
    }
}

/// Current interval step, big auto-updating countdown, next-step preview,
/// per-step progress, and skip — the lifter never has to think about the
/// clock.
struct IntervalRunnerStrip: View {
    @Environment(\.theme) private var theme
    let runner: IntervalRunner

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let step = runner.currentStep {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(step.label.uppercased())
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(step.kind.tint(in: theme))
                            if let zone = step.hrZone {
                                Text("Z\(zone)")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(theme.zoneColor(zone))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(theme.zoneColor(zone).opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        if let info = runner.roundInfo {
                            Text("Round \(info.round) of \(info.total)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                        if let next = runner.nextStep {
                            Text("Next: \(next.label)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        } else {
                            Text("Last step")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer()
                    Text(timerInterval: Date.now...max(Date.now, runner.stepEndsAt), countsDown: true)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(step.kind.tint(in: theme))
                    Button {
                        runner.skip()
                    } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)   // HIG minimum touch target
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                // One segment per step; done = filled, current = glowing.
                HStack(spacing: 3) {
                    ForEach(Array(runner.plan.steps.enumerated()), id: \.element.id) { index, planStep in
                        Capsule()
                            .fill(index < runner.currentIndex
                                  ? planStep.kind.tint(in: theme)
                                  : (index == runner.currentIndex ? planStep.kind.tint(in: theme).opacity(0.9) : theme.surfaceElevated))
                            .frame(height: index == runner.currentIndex ? 7 : 5)
                    }
                }
            } else if runner.isFinished {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(theme.success)
                    Text("Intervals complete — cool down and tap Complete.")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                }
            }
        }
        .padding(Space.sm)
        .background((runner.currentStep?.kind.tint(in: theme) ?? theme.success).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
