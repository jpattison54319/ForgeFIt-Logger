import ForgeData

/// Keeps cached set metrics and the live workout total in sync after editing a
/// set, whether that set was just completed or was completed earlier.
enum LiveWorkoutMetrics {
    static func refresh(changedSet: SetModel, in workout: WorkoutModel) {
        changedSet.recomputeDerivedMetrics()
        workout.recomputeTotalVolume()
    }
}
