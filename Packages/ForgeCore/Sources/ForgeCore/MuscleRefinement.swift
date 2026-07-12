import Foundation

/// Refines broad muscle tags on seeded exercises into taxonomy sub-muscles
/// using the exercise name — "Side Lateral Raise" is side delts, not generic
/// shoulders; "Incline Dumbbell Press" is upper chest.
///
/// Deterministic and conservative: an exercise whose name doesn't clearly
/// name a region keeps its parent tag, which is first-class in the taxonomy.
/// Applied at seed time (the seeders re-run each launch and update
/// non-user-modified exercises), so refinements reach existing installs
/// without a data migration. Rules were validated against every
/// shoulder/chest-tagged exercise in the bundled library.
///
/// Two traps the rules encode:
/// - "Bent Over ... Lateral" raises are REAR delts despite "lateral".
/// - Push-up incline/decline is INVERTED vs a bench: hands-elevated
///   ("incline push-up") hits lower chest; feet-elevated ("decline
///   push-up") hits upper chest.
public enum MuscleRefinement {
    /// Refine an exercise's muscle tags. Only broad "shoulders"/"chest"
    /// entries are ever rewritten; everything else passes through untouched.
    public static func refine(
        name: String,
        primaryMuscles: [String],
        secondaryMuscles: [String]
    ) -> (primary: [String], secondary: [String]) {
        let n = normalized(name)

        let primary = dedupe(primaryMuscles.map { muscle in
            switch MuscleTaxonomy.canonical(muscle) {
            case "shoulders": shoulderRegion(for: n) ?? muscle
            case "chest": chestRegion(for: n) ?? muscle
            default: muscle
            }
        })

        // Secondary "shoulders": pressing movements load the front delts,
        // rowing/pulling movements the rear delts. Anything ambiguous
        // (cleans, carries, windmills...) keeps the parent tag.
        let primaryParents = Set(primaryMuscles.map { MuscleTaxonomy.parent(of: $0) })
        let isPush = !primaryParents.isDisjoint(with: ["chest", "triceps"])
        let isPull = !primaryParents.isDisjoint(with: ["back"])
        let secondary = dedupe(secondaryMuscles.map { muscle in
            guard MuscleTaxonomy.canonical(muscle) == "shoulders" else { return muscle }
            if let region = shoulderRegion(for: n) { return region }
            if isPush { return "front delts" }
            if isPull, isPullingMovement(n) { return "rear delts" }
            return muscle
        })

        return (primary, secondary)
    }

    // MARK: - Region rules

    private static func shoulderRegion(for n: String) -> String? {
        // Rear first: "bent over side lateral" is rear-delt work.
        if contains(n, anyOf: ["rear delt", "rear lateral", "face pull", "pull apart", "back fly"])
            || (hasWord(n, "reverse") && n.contains("fly"))
            || (n.contains("bent over") && n.contains("lateral")) {
            return "rear delts"
        }
        if contains(n, anyOf: ["lateral raise", "side lateral", "scaption"])
            || (hasWord(n, "upright") && (hasWord(n, "row") || hasWord(n, "rows"))) {
            return "side delts"
        }
        if n.contains("front delt")
            || (hasWord(n, "front") && n.contains("raise"))
            || n.contains("handstand") {
            return "front delts"
        }
        // Overhead pressing = front delts; Cuban and anti-gravity presses are
        // rotator/rear work wearing a press name.
        if n.contains("press"), !n.contains("cuban"), !n.contains("anti gravity") {
            return "front delts"
        }
        return nil
    }

    private static func chestRegion(for n: String) -> String? {
        let isPushUp = n.contains("push up") || n.contains("pushup")
        if isPushUp {
            if n.contains("decline") || n.contains("feet elevated") || n.contains("feet on") {
                return "upper chest"
            }
            if n.contains("incline") { return "lower chest" }
            return nil
        }
        if n.contains("incline") { return "upper chest" }
        if n.contains("decline") { return "lower chest" }
        if n.contains("dip") { return "lower chest" }
        return nil
    }

    /// Rows / pulldowns / pull-ups — but not pullovers (front-delt/lat
    /// stretch) and not names that merely contain "row" inside a word
    /// ("overhead thROW").
    private static func isPullingMovement(_ n: String) -> Bool {
        if hasWord(n, "row") || hasWord(n, "rows") { return true }
        return n.contains("pull") && !n.contains("pullover")
    }

    // MARK: - String helpers

    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: " ")
    }

    private static func contains(_ n: String, anyOf keys: [String]) -> Bool {
        keys.contains { n.contains($0) }
    }

    private static func hasWord(_ n: String, _ word: String) -> Bool {
        n.split(whereSeparator: { !$0.isLetter }).contains(Substring(word))
    }

    private static func dedupe(_ muscles: [String]) -> [String] {
        var seen = Set<String>()
        return muscles.filter { seen.insert(MuscleTaxonomy.canonical($0)).inserted }
    }
}
