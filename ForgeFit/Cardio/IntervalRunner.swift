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
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
        }
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

    /// Haptic + time-sensitive notification when a step changes, so the cue
    /// lands even with the phone locked / pocketed.
    private func cue() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
        if let upcoming = nextStep {
            NotificationScheduler.shared.scheduleIntervalCue(stepLabel: upcoming.label)
        }
    }
}

// MARK: - Live guidance strip (inside CardioExerciseCard while recording)

import SwiftUI

extension IntervalPlan.Step.Kind {
    var tint: Color {
        let t = AppTheme.sage
        switch self {
        case .warmup, .cooldown: return t.warmup
        case .work: return t.secondaryAccent
        case .recover: return t.accent
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
                        Text(step.label.uppercased())
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(step.kind.tint)
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
                        .foregroundStyle(step.kind.tint)
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
                                  ? planStep.kind.tint
                                  : (index == runner.currentIndex ? planStep.kind.tint.opacity(0.9) : theme.surfaceElevated))
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
        .background((runner.currentStep?.kind.tint ?? theme.success).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
