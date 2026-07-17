import ForgeCore
import ForgeData
import Foundation

/// One source of truth for whether a live workout may persist per-set effort.
/// Hidden effort is semantically absent, not merely visually hidden. Failure
/// training is an explicit opt-in that supplies RPE 10 / RIR 0 only when a
/// completed non-warm-up set has no manually logged effort.
enum WorkoutEffortPolicy {
    static let loggingEnabledKey = "showRPEInLogger"
    static let failureTrainingKey = "failureTrainingEnabled"

    struct Preferences: Equatable {
        var logsEffort: Bool
        var defaultsToFailure: Bool
    }

    static func current(defaults: UserDefaults = .standard) -> Preferences {
        let logsEffort = defaults.bool(forKey: loggingEnabledKey)
        return Preferences(
            logsEffort: logsEffort,
            defaultsToFailure: logsEffort && defaults.bool(forKey: failureTrainingKey)
        )
    }

    /// Routine targets are live-workout suggestions, not permission to log a
    /// hidden field. Failure-mode working sets start empty so their RPE 10 /
    /// RIR 0 default remains overridable until completion.
    static func initialEffort(
        setType: SetType,
        targetRPE: Double?,
        targetRIR: Int?,
        preferences: Preferences
    ) -> (rpe: Double?, rir: Int?) {
        guard preferences.logsEffort else { return (nil, nil) }
        if preferences.defaultsToFailure, setType != .warmup {
            return (nil, nil)
        }
        return (targetRPE, targetRIR)
    }

    /// Final invariant applied by every finish path, including Watch-initiated
    /// finishes. Returns whether any set changed.
    @discardableResult
    static func prepareForFinish(
        _ workout: WorkoutModel,
        preferences: Preferences = current()
    ) -> Bool {
        if !preferences.logsEffort {
            return removeEffort(from: workout)
        }
        guard preferences.defaultsToFailure else { return false }

        var changed = false
        for set in workout.exercises.flatMap(\.sets)
        where set.completedAt != nil && set.setType != .warmup && set.rpe == nil && set.rir == nil {
            set.rpe = 10
            set.rir = 0
            changed = true
        }
        return changed
    }

    /// Clears both representations, including values entered earlier in the
    /// same workout before the user disabled the effort column.
    @discardableResult
    static func removeEffort(from workout: WorkoutModel) -> Bool {
        var changed = false
        for set in workout.exercises.flatMap(\.sets) where set.rpe != nil || set.rir != nil {
            set.rpe = nil
            set.rir = nil
            changed = true
        }
        return changed
    }
}
