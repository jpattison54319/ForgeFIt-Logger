import ForgeData
import Foundation

/// The shallow invalidation boundary for authored workout changes.
///
/// Home, history, and analytics deliberately fingerprint completed workout
/// parents without faulting their exercise/set/block relationships. Every
/// nested authored mutation on a completed workout must therefore advance
/// this clock in the same in-memory transaction as the nested change.
@MainActor
enum WorkoutMutationContract {
    /// Returns whether the parent clock changed. In-progress workouts stay
    /// untouched: ContentView owns an active-workout root query and terminal
    /// analytics explicitly ignore live rows. `WorkoutFinisher` supplies the
    /// one parent stamp when that row becomes completed.
    @discardableResult
    static func stampParentForNestedMutation(
        _ workout: WorkoutModel,
        at date: Date = .now
    ) -> Bool {
        guard workout.endedAt != nil else { return false }
        workout.updatedAt = date
        return true
    }
}
