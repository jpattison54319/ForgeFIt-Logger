import ForgeCore
import Foundation

/// Conservative boundary around free-form on-device model output. Imported
/// exercise suggestions should omit uncertain muscles instead of polluting
/// analytics with a long list of stabilizers or anatomically unrelated tags.
nonisolated enum ExerciseAISuggestionSanitizer {
    struct Result: Equatable, Sendable {
        let primary: [String]
        let secondary: [String]
    }

    static func sanitize(
        name: String,
        primary rawPrimary: [String],
        secondary rawSecondary: [String],
        isCardio: Bool
    ) -> Result {
        var primary = normalizedUnique(rawPrimary)
        primary = removingRedundantParents(from: primary)
        primary = preferringNamedMuscles(in: name, from: primary)
        primary = Array(primary.prefix(isCardio ? 3 : 2))

        let primaryParents = Set(primary.map { MuscleTaxonomy.parent(of: $0) })
        let allowedSecondary = primaryParents.reduce(into: Set<String>()) { result, parent in
            result.formUnion(compatibleSecondary[parent] ?? [])
        }
        var secondary = normalizedUnique(rawSecondary).filter { secondaryMuscle in
            !primary.contains(where: { primaryMuscle in
                ExerciseMuscleSelectionPolicy.overlaps(secondaryMuscle, primaryMuscle)
            })
                && allowedSecondary.contains(secondaryMuscle)
        }
        secondary = removingRedundantParents(from: secondary)
        secondary = Array(secondary.prefix(secondaryLimit(for: name)))
        return Result(primary: primary, secondary: secondary)
    }

    static func shouldAcceptSuggestedPrimary(
        _ suggested: [String],
        existing: [String],
        existingConfidence: Double
    ) -> Bool {
        guard !suggested.isEmpty else { return false }
        guard !existing.isEmpty,
              existingConfidence >= ExerciseClassifier.reviewConfidenceThreshold else { return true }
        let suggestedParents = Set(suggested.map { MuscleTaxonomy.parent(of: $0) })
        let existingParents = Set(existing.map { MuscleTaxonomy.parent(of: $0) })
        return !suggestedParents.isDisjoint(with: existingParents)
    }

    private static func normalizedUnique(_ muscles: [String]) -> [String] {
        var seen = Set<String>()
        return muscles.compactMap { raw in
            let muscle = MuscleTaxonomy.canonical(raw)
            guard allowedMuscles.contains(muscle), seen.insert(muscle).inserted else { return nil }
            return muscle
        }
    }

    private static func removingRedundantParents(from muscles: [String]) -> [String] {
        let present = Set(muscles)
        return muscles.filter { muscle in
            guard let children = MuscleTaxonomy.children[muscle] else { return true }
            return present.isDisjoint(with: children)
        }
    }

    private static func preferringNamedMuscles(in rawName: String, from muscles: [String]) -> [String] {
        let name = normalized(rawName)
        let tokens = Set(name.split(separator: " ").map(String.init))
        let named: [String]
        if tokens.contains("lats")
            || name.contains("lat prayer")
            || name.contains("lat pulldown")
            || name.contains("lat pullover")
            || name.contains("straight arm pulldown") {
            named = ["lats"]
        } else if name.contains("abduction") || name.contains("abductor") || name.contains("clamshell") {
            named = ["abductors"]
        } else if name.contains("adduction") || name.contains("adductor") {
            named = ["adductors"]
        } else if tokens.contains("bicep") || tokens.contains("biceps") {
            named = ["biceps"]
        } else if tokens.contains("tricep") || tokens.contains("triceps") {
            named = ["triceps"]
        } else if tokens.contains("wrist") || tokens.contains("forearm") || tokens.contains("forearms") {
            named = ["forearms"]
        } else if tokens.contains("calf") || tokens.contains("calves") {
            named = ["calves"]
        } else if tokens.contains("hamstring") || tokens.contains("hamstrings") {
            named = ["hamstrings"]
        } else if tokens.contains("glute") || tokens.contains("glutes") {
            named = ["glutes"]
        } else if tokens.contains("oblique") || tokens.contains("obliques") {
            named = ["obliques"]
        } else {
            return muscles
        }
        return named
    }

    private static func secondaryLimit(for rawName: String) -> Int {
        let name = normalized(rawName)
        if name.contains("lat prayer") || name.contains("straight arm pulldown") {
            return 0
        }
        let isolationPhrases = [
            "abduction", "adduction", "curl", "extension", "fly", "flye",
            "kickback", "prayer", "pullover", "pushdown", "raise", "shrug",
        ]
        let tokens = Set(name.split(separator: " ").map { token in
            let value = String(token)
            guard value.count > 4, value.hasSuffix("s"), !value.hasSuffix("ss") else { return value }
            return String(value.dropLast())
        })
        return isolationPhrases.contains { phrase in
            phrase.contains(" ") ? name.contains(phrase) : tokens.contains(phrase)
        } ? 1 : 2
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let compatibleSecondary: [String: Set<String>] = [
        "back": ["biceps", "forearms", "rear delts", "shoulders", "lats", "upper back", "middle back", "lower back", "traps"],
        "chest": ["triceps", "front delts", "shoulders"],
        "shoulders": ["triceps", "traps", "upper back", "middle back", "chest"],
        "biceps": ["forearms"],
        "triceps": ["chest", "front delts", "shoulders"],
        "forearms": ["biceps", "traps"],
        "quadriceps": ["glutes", "hamstrings", "calves", "adductors"],
        "hamstrings": ["glutes", "lower back", "calves"],
        "glutes": ["hamstrings", "quadriceps", "abductors", "adductors", "lower back"],
        "calves": ["hamstrings"],
        "abductors": ["glutes"],
        "adductors": ["glutes", "hamstrings", "quadriceps"],
        "abdominals": ["obliques", "lower back"],
        "obliques": ["abdominals", "lower back"],
        "lower back": ["glutes", "hamstrings", "abdominals", "obliques"],
        "cardiovascular": ["quadriceps", "glutes", "hamstrings", "calves", "lats", "upper back", "biceps", "shoulders", "triceps"],
    ]

    /// Kept beside the sanitizer instead of reaching into the main-actor UI
    /// catalog so background model output can be validated safely.
    private static let allowedMuscles = Set([
        "cardiovascular", "abdominals", "biceps", "triceps", "chest", "shoulders", "back", "lats",
        "middle back", "upper back", "lower back", "traps", "quadriceps", "hamstrings", "glutes",
        "calves", "forearms", "abductors", "adductors", "obliques", "neck", "hip flexors",
    ] + MuscleTaxonomy.children.values.flatMap { $0 })
}
