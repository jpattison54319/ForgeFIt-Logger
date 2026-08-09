import ForgeCore
import Foundation
import UIKit

/// Session-scoped owner of cardio goal completion feedback. Every live source
/// (the visible card, phone GPS, and Watch metrics) feeds this one tracker so a
/// target is spoken once even when updates arrive through several paths.
@MainActor
final class CardioGoalAnnouncer {
    static let shared = CardioGoalAnnouncer { phrase in
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        PaceAnnouncer.shared.announceGoal(phrase)
    }

    private struct ActiveGoal {
        var tracker: CardioSessionGoalAchievementTracker
        let startedAt: Date
        let cardioKind: CardioKind
        let distanceUnit: DistanceUnit
        var liveEnergyBaseline: Double?

        func matches(
            goal: IntervalPlan.SessionGoal,
            startedAt: Date,
            cardioKind: CardioKind,
            distanceUnit: DistanceUnit
        ) -> Bool {
            tracker.goal == goal
                && self.startedAt == startedAt
                && self.cardioKind == cardioKind
                && self.distanceUnit == distanceUnit
        }
    }

    private var activeGoals: [UUID: ActiveGoal] = [:]
    private var durationTasks: [UUID: Task<Void, Never>] = [:]
    private let deliver: (String) -> Void

    init(deliver: @escaping (String) -> Void) {
        self.deliver = deliver
    }

    func activate(
        sessionID: UUID,
        goal: IntervalPlan.SessionGoal?,
        startedAt: Date,
        cardioKind: CardioKind,
        distanceUnit requestedDistanceUnit: DistanceUnit? = nil,
        liveEnergyBaseline: Double? = nil
    ) {
        guard let goal, goal.isMeaningful else {
            cancel(sessionID: sessionID)
            return
        }
        let distanceUnit = requestedDistanceUnit ?? Fmt.distanceUnit
        if activeGoals[sessionID]?.matches(
            goal: goal,
            startedAt: startedAt,
            cardioKind: cardioKind,
            distanceUnit: distanceUnit
        ) == true {
            return
        }

        durationTasks.removeValue(forKey: sessionID)?.cancel()
        activeGoals[sessionID] = ActiveGoal(
            tracker: CardioSessionGoalAchievementTracker(goal: goal),
            startedAt: startedAt,
            cardioKind: cardioKind,
            distanceUnit: distanceUnit,
            liveEnergyBaseline: (
                liveEnergyBaseline
                    ?? LiveMetricsHub.shared.liveMetrics?.activeEnergyKcal
            ).map { max(0, $0) }
        )
        scheduleDurationWakeIfNeeded(sessionID: sessionID, goal: goal, startedAt: startedAt)
    }

    /// Feed live readings. Watch energy is cumulative for the whole workout,
    /// so it is reduced by the value captured when this segment started.
    func evaluate(
        sessionID: UUID,
        distanceMeters: Double? = nil,
        elapsedSeconds: Int? = nil,
        liveActiveEnergyTotalKcal: Double? = nil,
        elevationGainMeters: Double? = nil,
        at date: Date = .now
    ) {
        guard let activeGoal = activeGoals[sessionID] else { return }
        let current: Double?
        switch activeGoal.tracker.goal.kind {
        case .distance:
            current = distanceMeters
        case .duration:
            current = elapsedSeconds.map(Double.init)
                ?? Double(max(0, Int(date.timeIntervalSince(activeGoal.startedAt))))
        case .calories:
            current = segmentActiveEnergy(
                sessionID: sessionID,
                cumulativeTotal: liveActiveEnergyTotalKcal
            )
        case .elevation:
            current = elevationGainMeters
        }
        consume(sessionID: sessionID, current: current)
    }

    /// Feed a value already normalized into the goal's own unit. The visible
    /// progress banner uses this after applying the same segment baselines it
    /// displays, while source-specific paths use `evaluate` above.
    func evaluateCurrent(sessionID: UUID, current: Double?) {
        consume(sessionID: sessionID, current: current)
    }

    /// Convert the Watch's whole-workout energy total into this cardio
    /// segment's live value for both progress UI and threshold evaluation.
    func segmentActiveEnergy(sessionID: UUID, cumulativeTotal: Double?) -> Double? {
        guard let cumulativeTotal, cumulativeTotal.isFinite else { return nil }
        guard var activeGoal = activeGoals[sessionID] else { return nil }
        guard let baseline = activeGoal.liveEnergyBaseline else {
            // The first Watch packet after activation establishes the segment
            // zero when no pre-start packet was available. This avoids
            // counting earlier mixed-workout energy toward a new goal.
            activeGoal.liveEnergyBaseline = max(0, cumulativeTotal)
            activeGoals[sessionID] = activeGoal
            return 0
        }
        return max(0, cumulativeTotal - baseline)
    }

    /// Final segment measurements are already windowed to this session, so
    /// they bypass the Watch baseline before the runtime state is released.
    func finish(
        sessionID: UUID,
        distanceMeters: Double?,
        durationSeconds: Int?,
        activeEnergyKcal: Double?,
        elevationGainMeters: Double?
    ) {
        guard let activeGoal = activeGoals[sessionID] else { return }
        let finalValue: Double?
        switch activeGoal.tracker.goal.kind {
        case .distance: finalValue = distanceMeters
        case .duration: finalValue = durationSeconds.map(Double.init)
        case .calories: finalValue = activeEnergyKcal
        case .elevation: finalValue = elevationGainMeters
        }
        consume(sessionID: sessionID, current: finalValue)
        cancel(sessionID: sessionID)
    }

    /// The segment clock has stopped, but a short Health import may still
    /// provide its final calories/elevation. Cancel only the live duration
    /// wake while retaining the one-shot tracker for that final measurement.
    func stopLiveUpdates(sessionID: UUID) {
        durationTasks.removeValue(forKey: sessionID)?.cancel()
    }

    func cancel(sessionID: UUID) {
        durationTasks.removeValue(forKey: sessionID)?.cancel()
        activeGoals.removeValue(forKey: sessionID)
    }

    func cancelAll() {
        for task in durationTasks.values { task.cancel() }
        durationTasks.removeAll()
        activeGoals.removeAll()
    }

    func isTracking(sessionID: UUID) -> Bool {
        activeGoals[sessionID] != nil
    }

    private func consume(sessionID: UUID, current: Double?) {
        guard var activeGoal = activeGoals[sessionID],
              activeGoal.tracker.consume(current: current) else { return }
        activeGoals[sessionID] = activeGoal
        durationTasks.removeValue(forKey: sessionID)?.cancel()
        deliver(CardioSessionGoalAnnouncement.phrase(
            for: activeGoal.tracker.goal,
            distanceUnit: activeGoal.distanceUnit,
            usesFixedMeters: activeGoal.cardioKind.usesFixedMeters
        ))
    }

    private func scheduleDurationWakeIfNeeded(
        sessionID: UUID,
        goal: IntervalPlan.SessionGoal,
        startedAt: Date
    ) {
        guard goal.kind == .duration else { return }
        let delay = max(0, startedAt.addingTimeInterval(goal.value).timeIntervalSinceNow)
        durationTasks[sessionID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.evaluate(sessionID: sessionID)
        }
    }
}
