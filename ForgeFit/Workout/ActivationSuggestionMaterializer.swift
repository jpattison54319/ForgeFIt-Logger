import ForgeData

/// Materializes the values visible in an activation row before it is logged.
///
/// Weight belongs to the primary activation and must be adopted independently
/// of whether its reps were typed or adopted from history.
enum ActivationSuggestionMaterializer {
    static func materialize(
        set: SetModel,
        previous: SetModel?,
        side: Int,
        showsWeight: Bool
    ) -> Bool {
        materialize(
            set: set,
            previousReps: previous?.reps,
            previousWeight: previous?.modeWeight,
            side: side,
            showsWeight: showsWeight
        )
    }

    static func materialize(
        set: SetModel,
        previous: LivePreviousSetSnapshot?,
        side: Int,
        showsWeight: Bool
    ) -> Bool {
        materialize(
            set: set,
            previousReps: previous?.reps,
            previousWeight: previous?.modeWeight,
            side: side,
            showsWeight: showsWeight
        )
    }

    private static func materialize(
        set: SetModel,
        previousReps: Int?,
        previousWeight: Double?,
        side: Int,
        showsWeight: Bool
    ) -> Bool {
        let enteredReps = side == 2 ? set.side2Reps : set.reps
        let suggestedReps = side == 2 ? set.reps : previousReps

        guard let resolvedReps = enteredReps ?? suggestedReps else {
            return false
        }

        if enteredReps == nil {
            if side == 2 {
                set.side2Reps = resolvedReps
            } else {
                set.reps = resolvedReps
            }
        }

        if side == 1, showsWeight, set.modeWeight == nil {
            set.setModeWeight(previousWeight)
        }

        return true
    }
}
