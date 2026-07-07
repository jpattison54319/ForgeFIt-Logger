import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One-tap "coach's version" of a routine for days when readiness says to back
/// off. Adjustments are applied to the *started workout only* — the saved
/// routine is never touched, so tomorrow starts from the normal plan.
///
/// The dose adjustments follow the same evidence the readiness engine cites:
///  - Reduce volume: drop ~one working set per exercise and cap effort at
///    RPE 8 (≥2 RIR). Stopping short of failure preserves the stimulus while
///    cutting the recovery cost (Morán-Navarro 2017; Helms 2016 RIR-based
///    autoregulation).
///  - Deload/recover: roughly halve working sets and take ~10% off the load,
///    capping at RPE 7 — the volume-first deload structure practitioners
///    converge on (Bell et al. 2023 deload survey; Schoenfeld 2016 dose
///    guidance).
enum CoachAdjustments {

    struct Plan {
        let action: RecoveryEngine.Action
        /// Button-length summary, e.g. "1 set less per lift, cap at RPE 8".
        let summary: String
        /// Bullet detail of what will change, for the confirmation UI.
        let changes: [String]
    }

    /// The coach's proposed modification for today's action — nil when the plan
    /// should run as written (push / train-as-planned).
    static func plan(for action: RecoveryEngine.Action) -> Plan? {
        switch action {
        case .push, .trainAsPlanned:
            return nil
        case .reduceVolume:
            return Plan(
                action: action,
                summary: "1 working set less per lift · cap RPE 8",
                changes: [
                    "Removes the last working set of each exercise that has 3+",
                    "Caps set targets at RPE 8 (≈2 reps in reserve)",
                    "Your saved routine is not changed",
                ]
            )
        case .deloadRecover:
            return Plan(
                action: action,
                summary: "Half the working sets · −10% load · cap RPE 7",
                changes: [
                    "Halves the working sets of each exercise (minimum 1)",
                    "Reduces target weights by 10%",
                    "Caps set targets at RPE 7 (≈3 reps in reserve)",
                    "Your saved routine is not changed",
                ]
            )
        }
    }

    /// Apply the plan to a freshly started workout. Returns a short description
    /// stamped into the workout notes so the session records why it was lighter.
    @MainActor
    static func apply(_ plan: Plan, to workout: WorkoutModel, in context: ModelContext) {
        for exercise in workout.exercises {
            let ordered = exercise.sets.sorted { $0.position < $1.position }
            let working = ordered.filter { $0.setType.countsAsWorkingVolume }
            guard !working.isEmpty else { continue }

            let toRemove: [SetModel]
            switch plan.action {
            case .reduceVolume:
                // Drop the final working set, but never below 2.
                toRemove = working.count >= 3 ? [working[working.count - 1]] : []
            case .deloadRecover:
                let keep = max(1, working.count / 2)
                toRemove = Array(working.dropFirst(keep))
            case .push, .trainAsPlanned:
                toRemove = []
            }

            let removedIDs = Set(toRemove.map(\.id))
            exercise.sets.removeAll { removedIDs.contains($0.id) }
            toRemove.forEach { context.delete($0) }

            for set in exercise.sets {
                if plan.action == .deloadRecover, let weight = set.weight {
                    set.weight = (weight * 0.9).rounded(.toNearestOrAwayFromZero)
                }
                let cap: Double = plan.action == .deloadRecover ? 7 : 8
                if let rpe = set.rpe { set.rpe = min(rpe, cap) }
                if let rir = set.rir { set.rir = max(rir, plan.action == .deloadRecover ? 3 : 2) }
                set.recomputeDerivedMetrics()
            }
        }

        let stamp = "Coach-adjusted (\(plan.action.title.lowercased())): \(plan.summary)"
        workout.notes = [workout.notes, stamp].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: "\n")
        workout.updatedAt = Date()
        try? context.save()
    }
}
