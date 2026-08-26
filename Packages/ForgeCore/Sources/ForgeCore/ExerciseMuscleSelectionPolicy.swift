import Foundation

/// Keeps primary and secondary exercise targets mutually exclusive, including
/// broad taxonomy parents such as Back and their specific children such as Lats.
public enum ExerciseMuscleSelectionPolicy {
    public static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        let left = MuscleTaxonomy.canonical(lhs)
        let right = MuscleTaxonomy.canonical(rhs)
        return left == right
            || MuscleTaxonomy.parent(of: left) == right
            || MuscleTaxonomy.parent(of: right) == left
    }

    public static func secondaryMuscles(
        from muscles: [String],
        excluding primaryMuscle: String
    ) -> [String] {
        var seen = Set<String>()
        return muscles.compactMap { muscle in
            let canonical = MuscleTaxonomy.canonical(muscle)
            guard !overlaps(canonical, primaryMuscle),
                  seen.insert(canonical).inserted else { return nil }
            return canonical
        }
    }
}
