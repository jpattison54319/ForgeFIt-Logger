/// Keeps permission setup separate from the act of starting a workout.
///
/// HealthKit can report newly added read types as undecided even after the
/// user has already connected workouts. A live workout must not turn that
/// state into a surprise permission sheet; additional access belongs in an
/// explicit setup or Settings flow.
public enum WorkoutAuthorizationPromptPolicy {
    public static func shouldRequestAtWorkoutStart(
        hasWorkoutWriteAccess: Bool,
        hasUndecidedTypes: Bool
    ) -> Bool {
        !hasWorkoutWriteAccess && hasUndecidedTypes
    }
}
