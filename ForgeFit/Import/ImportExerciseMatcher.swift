import Foundation
import ForgeCore

/// Conservative identity matcher for the workout-history importer.
///
/// The interactive exercise picker uses `ExerciseLibrarySnapshot.search`, whose
/// substring/prefix heuristics are exactly right for "type a few letters and see
/// candidates" — but wrong for import, where a loose hit silently links a logged
/// set to the wrong exercise (e.g. an imported `Squat` matching the catalog's
/// `Squat Jerk`, or `Leg Press` matching `Calf Press On The Leg Press Machine`).
/// Corrupting history that way is far worse than under-matching: an unmatched
/// name simply becomes a correctly-named custom exercise that lands in the
/// review queue, where the user can confirm or merge it.
///
/// So this matcher only auto-links on a *confident identity match*: the two names
/// share the same core (non-equipment) tokens, order-independent, with compatible
/// equipment. That reunites Hevy's `Name (Equipment)` format with the catalog's
/// `Equipment Name` ordering (`Squat (Barbell)` ↔ `Barbell Squat`) without ever
/// collapsing distinct movements onto one another.
nonisolated enum ImportExerciseMatcher {
    /// Score reported for an exact normalized-name match.
    static let exactScore = 100
    /// Score reported for a confident token-identity match.
    static let identityScore = 95

    struct Match: Equatable {
        var exercise: ExerciseInfo
        var score: Int
    }

    /// The best confident match for `importedName`, or `nil` when nothing is a
    /// confident identity match (caller should then create a custom exercise).
    static func bestMatch(importedName: String, in candidates: [ExerciseInfo]) -> Match? {
        let query = Parsed(name: importedName, equipmentHint: nil)
        guard !query.core.isEmpty else { return nil }

        var exact: [(ExerciseInfo, Parsed)] = []
        var identity: [(ExerciseInfo, Parsed)] = []
        for candidate in candidates {
            let parsed = Parsed(name: candidate.name, equipmentHint: candidate.equipment)
            if query.normalized == parsed.normalized {
                exact.append((candidate, parsed))
            } else if query.core == parsed.core, equipmentCompatible(query.equipment, parsed.equipment) {
                identity.append((candidate, parsed))
            }
        }

        if let best = pickBest(from: exact) {
            return Match(exercise: best, score: exactScore)
        }
        guard !identity.isEmpty else { return nil }

        // When the import names no equipment, don't guess between candidates that
        // disagree on it (an equipment-less "Squat" must not silently become a
        // "Barbell Squat" when a "Dumbbell Squat" is equally plausible).
        if query.equipment.isEmpty {
            let distinctEquipment = Set(identity.flatMap { $0.1.equipment })
            if distinctEquipment.count > 1 { return nil }
        }

        guard let best = pickBest(from: identity) else { return nil }
        return Match(exercise: best, score: identityScore)
    }

    /// Deterministic winner among equally-confident candidates: fewer tokens
    /// (the least-embellished name), then alphabetical.
    private static func pickBest(from candidates: [(ExerciseInfo, Parsed)]) -> ExerciseInfo? {
        candidates.min { lhs, rhs in
            if lhs.1.tokenCount != rhs.1.tokenCount { return lhs.1.tokenCount < rhs.1.tokenCount }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }?.0
    }

    /// Equipment matches when at least one side is unspecified, or the two sides
    /// name overlapping equipment. Two *different* specified pieces of equipment
    /// (barbell vs dumbbell) keep the exercises distinct.
    private static func equipmentCompatible(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        if lhs.isEmpty || rhs.isEmpty { return true }
        return !lhs.isDisjoint(with: rhs)
    }

    // MARK: - Parsing

    private struct Parsed {
        let normalized: String
        /// Movement-defining tokens (everything that isn't equipment or filler).
        let core: Set<String>
        /// Canonicalized equipment tokens found in the name or the equipment hint.
        let equipment: Set<String>
        let tokenCount: Int

        init(name: String, equipmentHint: String?) {
            let normalized = ImportExerciseMatcher.normalized(name)
            self.normalized = normalized
            let tokens = normalized.split(separator: " ").map(String.init)
            self.tokenCount = tokens.count

            var core = Set<String>()
            var equipment = Set<String>()
            for token in tokens {
                let stem = ImportExerciseMatcher.singularized(token)
                if let canonical = ImportExerciseMatcher.equipmentSynonyms[stem] {
                    equipment.insert(canonical)
                } else if !ImportExerciseMatcher.fillerTokens.contains(stem) {
                    core.insert(stem)
                }
            }
            if let hint = equipmentHint {
                for token in ImportExerciseMatcher.normalized(hint).split(separator: " ") {
                    let stem = ImportExerciseMatcher.singularized(String(token))
                    if let canonical = ImportExerciseMatcher.equipmentSynonyms[stem] {
                        equipment.insert(canonical)
                    }
                }
            }
            self.core = core
            self.equipment = equipment
        }
    }

    static func normalized(_ value: String) -> String {
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

    /// Light singularization so `squats`/`squat` and `curls`/`curl` unify without
    /// mangling words like `press` (guarded by the `ss` and length checks).
    private static func singularized(_ token: String) -> String {
        guard token.count > 4, token.hasSuffix("s"), !token.hasSuffix("ss") else { return token }
        return String(token.dropLast())
    }

    /// Tokens that name equipment, mapped to a canonical form. Kept deliberately
    /// tight — ambiguous exercise words (e.g. "hammer", as in hammer curl) are
    /// intentionally absent so they stay part of the movement identity.
    private static let equipmentSynonyms: [String: String] = [
        "barbell": "barbell",
        "dumbbell": "dumbbell", "dumbell": "dumbbell",
        "cable": "cable",
        "machine": "machine",
        "smith": "smith",
        "kettlebell": "kettlebell",
        "band": "band", "resistance": "band",
        "bodyweight": "bodyweight",
        "sled": "sled",
        "lever": "lever",
        "plate": "plate",
        "ezbar": "ezbar",
    ]

    /// Connective filler that carries no movement meaning.
    private static let fillerTokens: Set<String> = [
        "the", "a", "with", "and", "to", "of", "on", "in", "for", "using",
    ]
}
