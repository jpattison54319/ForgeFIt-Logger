import Foundation

/// Set-count ("fractional set") volume per muscle group.
///
/// Convention (product decision):
///   - A working set contributes **1.0 set** to each *primary* muscle.
///   - A working set contributes **0.5 set** to each *secondary* (supporting)
///     muscle.
///   - Warm-up sets contribute nothing.
///   - Both are scaled by `VolumeMath.effectiveSetCount` — a myo-rep block
///     with 4 mini-sets is 3 sets of dose for its muscles, a drop row is
///     half a set (see the convention doc on `effectiveSetCount`).
///
/// This is distinct from tonnage (weight × reps). It powers weekly "volume by
/// muscle group" landmarks (e.g. 10–20 sets/week per muscle). Even a custom
/// exercise rolls up correctly because it carries primary/secondary muscles
/// (mapped to the global taxonomy via `mapped_global_id`).
public enum MuscleVolume {

    public static let primaryWeight: Double = 1.0
    public static let secondaryWeight: Double = 0.5

    /// Fractional-set contribution of a single set, keyed by muscle.
    /// A muscle that is listed as both primary and secondary counts as primary
    /// (the larger weight wins; no double counting).
    public static func fractionalSets(
        for set: SetEntry,
        exercise: ExerciseInfo
    ) -> [String: Double] {
        let setCount = VolumeMath.effectiveSetCount(set)
        guard setCount > 0 else { return [:] }

        var result: [String: Double] = [:]
        for muscle in exercise.secondaryMuscles {
            result[muscle] = secondaryWeight * setCount
        }
        // Primary applied second so it overrides any secondary listing.
        for muscle in exercise.primaryMuscles {
            result[muscle] = primaryWeight * setCount
        }
        return result
    }

    /// Aggregate fractional-set volume across many (set, exercise) pairs —
    /// e.g. a week of training — summed per muscle.
    public static func weeklyVolume(
        _ entries: [(set: SetEntry, exercise: ExerciseInfo)]
    ) -> [String: Double] {
        var totals: [String: Double] = [:]
        for entry in entries {
            for (muscle, value) in fractionalSets(for: entry.set, exercise: entry.exercise) {
                totals[muscle, default: 0] += value
            }
        }
        return totals
    }
}
