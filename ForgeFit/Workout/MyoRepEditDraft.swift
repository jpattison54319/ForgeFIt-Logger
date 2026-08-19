import ForgeData

struct MyoRepEditDraft: Equatable {
    var weightDisplay: Double
    var side1ActivationReps: Int
    var side1MiniReps: [Int]
    var side2ActivationReps: Int
    var side2MiniReps: [Int]

    init(set: SetModel, displayUnit: WeightUnit) {
        weightDisplay = set.modeWeight.map(displayUnit.displayValue(fromKilograms:)) ?? 0
        side1ActivationReps = max(1, set.reps ?? 1)
        side1MiniReps = set.miniReps
        side2ActivationReps = max(1, set.side2Reps ?? set.reps ?? 1)
        side2MiniReps = set.side2MiniReps
    }

    func apply(to set: SetModel, displayUnit: WeightUnit, showsWeight: Bool, isUnilateral: Bool) {
        if showsWeight {
            set.setModeWeight(displayUnit.kilograms(fromDisplayValue: weightDisplay))
        }
        set.reps = side1ActivationReps
        set.miniReps = side1MiniReps
        if isUnilateral {
            set.side2Reps = side2ActivationReps
            set.side2MiniReps = side2MiniReps
        } else {
            set.side2Reps = nil
            set.side2MiniReps = []
        }
        set.recomputeDerivedMetrics()
    }
}
