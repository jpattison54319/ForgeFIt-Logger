import ForgeData

extension ExerciseLibraryModel {
    var preferredWeightUnit: WeightUnit? {
        get {
            guard let preferredWeightUnitRaw else { return nil }
            return WeightUnit(rawValue: preferredWeightUnitRaw)
        }
        set {
            preferredWeightUnitRaw = newValue?.rawValue
        }
    }

    var effectiveWeightUnit: WeightUnit {
        preferredWeightUnit ?? Fmt.unit
    }
}
