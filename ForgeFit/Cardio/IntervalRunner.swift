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
    /// The session's modality string, for vocabulary (rpm vs spm) at
    /// display sites that only hold the runner.
    let modality: String
    private let session: CardioSessionModel
    private let context: ModelContext

    /// Index of the currently running step; == plan.steps.count when finished.
    private(set) var currentIndex: Int = 0
    /// Wall-clock end of the current TIMED step. Distance steps park it at
    /// `.distantFuture`; their end is a place, not a time.
    private(set) var stepEndsAt: Date
    private(set) var isFinished = false
    /// Meters covered inside the current distance step, refreshed by the
    /// poll loop. nil while no live distance source is flowing — the strip
    /// says so and the skip button stays the manual advance.
    private(set) var stepDistanceCovered: Double?

    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var stepStartedAt: Date
    /// Session-cumulative feed reading when the current step began; the
    /// step's own covered distance is the delta from here.
    @ObservationIgnored private var stepStartMeters: Double?
    @ObservationIgnored private var paceWindow = RollingPaceWindow()
    /// Injected in tests; live builds read the watch stream first (it also
    /// covers treadmills via wrist estimation), then phone GPS.
    @ObservationIgnored var liveDistanceMeters: () -> Double?

    init?(planJSON: String?, session: CardioSessionModel, context: ModelContext) {
        guard let plan = IntervalPlan.decode(from: planJSON), !plan.steps.isEmpty else { return nil }
        self.plan = plan
        self.sessionID = session.id
        self.modality = session.modality
        self.session = session
        self.context = context
        let now = Date()
        self.stepStartedAt = now
        let first = plan.steps[0]
        self.stepEndsAt = first.isDistanceBased
            ? .distantFuture
            : now.addingTimeInterval(TimeInterval(first.seconds))
        let sessionID = session.id
        self.liveDistanceMeters = {
            if let watch = LiveMetricsHub.shared.liveMetrics?.distanceMeters, watch > 0 { return watch }
            return CardioRouteRecorder.shared.liveDistanceMeters(for: sessionID)
        }
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

    /// The metric band in force right now: the step's own target wins, the
    /// plan-wide band covers steady stretches between targeted steps.
    var currentTarget: IntervalPlan.Target? {
        let candidate = currentStep?.target ?? plan.target
        return candidate?.isMeaningful == true ? candidate : nil
    }

    /// (covered, target) for the active distance step; nil for timed steps
    /// or before any feed sample lands.
    var distanceProgress: (covered: Double, target: Double)? {
        guard let step = currentStep, step.isDistanceBased,
              let target = step.distanceMeters, let covered = stepDistanceCovered else { return nil }
        return (min(covered, target), target)
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
        pollTask?.cancel()
        pollTask = nil
        PaceGuard.shared.deactivate()
    }

    private func beginStep(at index: Int) {
        advanceTask?.cancel()
        guard index < plan.steps.count else {
            isFinished = true
            return
        }
        currentIndex = index
        let step = plan.steps[index]
        stepStartedAt = Date()
        stepStartMeters = liveDistanceMeters()
        stepDistanceCovered = stepStartMeters != nil && step.isDistanceBased ? 0 : nil
        stepEndsAt = step.isDistanceBased
            ? .distantFuture
            : stepStartedAt.addingTimeInterval(TimeInterval(step.seconds))
        applyZoneGuard(for: step)
        applyPaceGuard()
        // The watch mirrors step state from the phone snapshot — push every
        // transition so its countdown and haptics stay anchored.
        WatchLink.shared.publishState()

        if !step.isDistanceBased {
            let interval = stepEndsAt.timeIntervalSinceNow
            advanceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(max(0, interval)))
                guard !Task.isCancelled, let self else { return }
                self.recordSplit(upTo: self.stepEndsAt)
                self.cue()
                self.advance()
            }
        }
        ensurePollTaskIfNeeded()
    }

    /// One-second poll while anything needs a live feed: a distance step's
    /// progress, or a pace band to grade. Timed steps without targets keep
    /// the zero-cost sleep-until-end path.
    private func ensurePollTaskIfNeeded() {
        let needsPolling = currentStep?.isDistanceBased == true || currentTarget?.metric == .pace
        guard needsPolling else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.isFinished else { return }
                self.pollTick()
            }
        }
    }

    /// Internal (not private) so tests can drive ticks deterministically
    /// with an injected feed instead of sleeping through real seconds.
    func pollTick() {
        guard let step = currentStep else { return }
        let feed = liveDistanceMeters()

        if let feed {
            paceWindow.add(meters: feed, at: Date())
            // A step that began before the feed woke up anchors to the first
            // reading it sees — better a slightly generous rep than none.
            if stepStartMeters == nil { stepStartMeters = feed }
            if step.isDistanceBased, let start = stepStartMeters {
                stepDistanceCovered = max(0, feed - start)
            }
        }

        if currentTarget?.metric == .pace {
            PaceGuard.shared.evaluate(paceSecondsPerKm: paceWindow.paceSecondsPerKm())
        }

        if step.isDistanceBased,
           let target = step.distanceMeters,
           let covered = stepDistanceCovered,
           covered >= target {
            recordSplit(upTo: Date())
            cue()
            advance()
        }
    }

    private func advance() {
        let next = currentIndex + 1
        if next < plan.steps.count {
            beginStep(at: next)
        } else {
            advanceTask?.cancel()
            pollTask?.cancel()
            pollTask = nil
            currentIndex = plan.steps.count
            isFinished = true
            // Back to the plan-wide lock (or off) once the steps are done.
            if let zone = plan.hrZoneTarget {
                HRZoneGuard.shared.activate(targetZone: zone, speak: zoneVoiceEnabled)
            } else {
                HRZoneGuard.shared.deactivate()
            }
            PaceGuard.shared.deactivate()
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

    /// Pace bands get a live guard; power/cadence bands render as guidance
    /// chips only — there is no live sensor to grade them against, and a
    /// silent "monitor" would be a lie.
    private func applyPaceGuard() {
        if let target = currentTarget, target.metric == .pace {
            PaceGuard.shared.activate(band: target, speak: paceVoiceEnabled)
        } else {
            PaceGuard.shared.deactivate()
        }
    }

    private var zoneVoiceEnabled: Bool {
        UserDefaults.standard.object(forKey: "zoneVoiceCues") as? Bool ?? true
    }

    private var paceVoiceEnabled: Bool {
        UserDefaults.standard.object(forKey: "paceVoiceCues") as? Bool ?? true
    }

    /// Persist the completed step as a split on the session. Timed and
    /// distance steps both record whatever real distance the feed saw —
    /// zero stays the honest floor when no source was flowing.
    private func recordSplit(upTo end: Date) {
        guard currentIndex < plan.steps.count else { return }
        let step = plan.steps[currentIndex]
        let duration = max(1, Int(end.timeIntervalSince(stepStartedAt)))
        let covered: Double = {
            if step.isDistanceBased, let progress = stepDistanceCovered { return progress }
            if let start = stepStartMeters, let now = liveDistanceMeters(), now > start { return now - start }
            return 0
        }()
        let pace = covered > 0 ? Double(duration) / (covered / 1000) : 0
        let split = CardioSplitModel(
            userID: session.userID,
            cardioSessionID: session.id,
            index: session.splits.count,
            distanceMeters: covered,
            durationSeconds: duration,
            paceSecondsPerKm: pace,
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

/// Formats a target band for chips and rows — pace in the user's distance
/// unit, power in watts, cadence in the modality's own vocabulary.
enum IntervalTargetFormatting {
    static func text(for target: IntervalPlan.Target, cadenceUnit: String = "spm", unit: DistanceUnit = Fmt.distanceUnit) -> String {
        switch target.metric {
        case .pace:
            let low = target.low.map { paceBound($0, unit: unit) }
            let high = target.high.map { paceBound($0, unit: unit) }
            switch (low, high) {
            case let (l?, h?): return "\(l)–\(h) \(unit.paceSuffix)"
            case let (l?, nil): return "≥ \(l) \(unit.paceSuffix)"   // no slower floor
            case let (nil, h?): return "≤ \(h) \(unit.paceSuffix)"
            default: return ""
            }
        case .power:
            return bounds(target, suffix: " W")
        case .cadence:
            return bounds(target, suffix: " \(cadenceUnit)")
        }
    }

    private static func bounds(_ target: IntervalPlan.Target, suffix: String) -> String {
        switch (target.low, target.high) {
        case let (l?, h?): return "\(Int(l))–\(Int(h))\(suffix)"
        case let (l?, nil): return "≥ \(Int(l))\(suffix)"
        case let (nil, h?): return "≤ \(Int(h))\(suffix)"
        default: return ""
        }
    }

    private static func paceBound(_ secPerKm: Double, unit: DistanceUnit) -> String {
        let secPerUnit = secPerKm * (unit.metersPerUnit / 1000)
        return String(format: "%d:%02d", Int(secPerUnit) / 60, Int(secPerUnit) % 60)
    }
}

/// Current interval step, big auto-updating countdown (or distance progress
/// for distance steps), next-step preview, per-step progress, and skip —
/// the lifter never has to think about the clock.
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
                            if let target = runner.currentTarget {
                                targetChip(target)
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
                    if step.isDistanceBased {
                        distanceReadout(step)
                    } else {
                        Text(timerInterval: Date.now...max(Date.now, runner.stepEndsAt), countsDown: true)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(step.kind.tint(in: theme))
                    }
                    if step.isDistanceBased, runner.distanceProgress == nil {
                        Button("Complete step", systemImage: "checkmark", action: runner.skip)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, Space.sm)
                            .frame(height: 44)
                            .background(theme.surfaceElevated)
                            .clipShape(Capsule())
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityIdentifier("interval-complete-distance-step")
                    } else {
                        Button("Skip step", systemImage: "forward.end.fill", action: runner.skip)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                            .buttonStyle(PressableButtonStyle())
                            .accessibilityIdentifier("interval-skip-step")
                    }
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
                    Text("Intervals complete")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                }
            }
        }
        .padding(Space.sm)
        .background((runner.currentStep?.kind.tint(in: theme) ?? theme.success).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// Distance steps count UP toward a place: covered over target, with a
    /// thin progress bar under the number.
    @ViewBuilder
    private func distanceReadout(_ step: IntervalPlan.Step) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let progress = runner.distanceProgress {
                Text(Fmt.cardioDistance(progress.covered, kind: .run))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(step.kind.tint(in: theme))
                Text("of \(IntervalPlan.metricDistance(step.distanceMeters ?? 0))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                ProgressView(value: min(1, progress.covered / max(1, progress.target)))
                    .tint(step.kind.tint(in: theme))
                    .frame(width: 84)
            } else {
                Text(IntervalPlan.metricDistance(step.distanceMeters ?? 0))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(step.kind.tint(in: theme))
            }
        }
    }

    /// The band this step asks for. Pace bands are live-graded (PaceGuard);
    /// power/cadence read as targets to hold against the console.
    private func targetChip(_ target: IntervalPlan.Target) -> some View {
        Text(IntervalTargetFormatting.text(for: target, cadenceUnit: cadenceUnit))
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(theme.secondaryAccent)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(theme.secondaryAccent.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("Target \(IntervalTargetFormatting.text(for: target, cadenceUnit: cadenceUnit))")
    }

    private var cadenceUnit: String {
        CardioKind.from(modality: runner.modality).cadenceUnit
    }
}
