import ForgeData

/// Materializes the activation values when a regular row becomes a structured
/// block. Explicit entries stay authoritative; otherwise the most recent block
/// of the target type wins, then the values that were visible on the old row.
enum BlockSetPrefillPolicy {
    static func apply(
        to set: SetModel,
        visibleWeight: Double?,
        visibleReps: Int?,
        previousBlock: SetModel?,
        preservesEnteredWeight: Bool,
        preservesEnteredReps: Bool
    ) {
        if !preservesEnteredWeight {
            set.setModeWeight(previousBlock?.modeWeight ?? visibleWeight)
        }
        if !preservesEnteredReps {
            set.reps = previousBlock?.reps ?? visibleReps
        }
        set.recomputeDerivedMetrics()
    }
}
