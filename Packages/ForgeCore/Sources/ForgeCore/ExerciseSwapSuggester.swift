import Foundation

/// Ranks replacement candidates for the "gym swap" flow: the machine you
/// wanted is taken (or gone), so lead with a handful of close substitutes
/// instead of a full library search. Pure scoring over lightweight snapshots —
/// the app maps its exercise models in and copy for the match facets out.
public enum ExerciseSwapSuggester {

    /// An explicit equipment direction selected by the lifter. This is a
    /// ranking preference rather than a filter: movement quality still wins,
    /// and the full set of useful substitutes remains available.
    public enum SwapPreference: CaseIterable, Equatable, Sendable {
        case freeWeights
        case machineOrCable
        case bodyweight
    }

    /// A snapshot of the fields that matter for similarity.
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let movementPattern: String?
        public let primaryMuscles: [String]
        public let secondaryMuscles: [String]
        public let equipment: String?
        public let mechanic: String?
        public let force: String?

        public init(
            id: UUID,
            name: String,
            movementPattern: String? = nil,
            primaryMuscles: [String] = [],
            secondaryMuscles: [String] = [],
            equipment: String? = nil,
            mechanic: String? = nil,
            force: String? = nil
        ) {
            self.id = id
            self.name = name
            self.movementPattern = movementPattern
            self.primaryMuscles = primaryMuscles
            self.secondaryMuscles = secondaryMuscles
            self.equipment = equipment
            self.mechanic = mechanic
            self.force = force
        }
    }

    /// Why a candidate matched — the UI turns these into row captions.
    public enum MatchFacet: Equatable, Sendable {
        /// Primary muscles shared with the exercise being replaced.
        case sharedMuscles([String])
        case samePattern
        case sameEquipment(String)
        /// The target is machine/cable-based and this candidate needs no
        /// machine — the "station is taken" escape route.
        case freeWeightAlternative(String)
        /// The candidate matches the equipment direction the lifter selected.
        case preferredEquipment(String)
        /// The lifter has completed sets of this exercise before, so ghosts
        /// and records light up immediately after the swap.
        case trainedBefore
    }

    public struct Suggestion: Equatable, Sendable {
        public let candidate: Candidate
        public let score: Double
        public let facets: [MatchFacet]
    }

    /// Top substitutes for `target`, best first. Candidates with no
    /// primary-muscle overlap are dropped — a swap that trains something else
    /// isn't a substitute. `trainedIDs` are exercises the user has completed
    /// sets for; `excluding` removes exercises already in the workout/routine.
    public static func suggest(
        replacing target: Candidate,
        from pool: [Candidate],
        trainedIDs: Set<UUID> = [],
        excluding: Set<UUID> = [],
        preference: SwapPreference? = nil,
        limit: Int = 6
    ) -> [Suggestion] {
        let targetPrimary = Set(target.primaryMuscles.map(normalize))
        guard !targetPrimary.isEmpty else { return [] }
        let targetMachineBased = isMachineBased(target.equipment)

        var ranked: [(suggestion: Suggestion, trained: Bool)] = []
        for candidate in pool {
            guard candidate.id != target.id, !excluding.contains(candidate.id) else { continue }

            let candidatePrimary = Set(candidate.primaryMuscles.map(normalize))
            let sharedPrimary = targetPrimary.intersection(candidatePrimary)
            guard !sharedPrimary.isEmpty else { continue }

            var score = 3.0 * Double(sharedPrimary.count) / Double(targetPrimary.count)
            var facets: [MatchFacet] = [.sharedMuscles(sharedPrimary.sorted())]

            let candidateSecondary = Set(candidate.secondaryMuscles.map(normalize))
            score += 0.75 * Double(targetPrimary.intersection(candidateSecondary).count)
                / Double(targetPrimary.count)

            let samePattern = target.movementPattern.map(normalize) == candidate.movementPattern.map(normalize)
                && target.movementPattern?.isEmpty == false
            if samePattern {
                score += 2.0
                facets.append(.samePattern)
            }

            // A complete muscle match in the same movement family is much
            // more likely to preserve the purpose of the programmed exercise.
            if sharedPrimary.count == targetPrimary.count, samePattern {
                score += 1.0
            }
            if let force = target.force, !force.isEmpty,
               normalize(force) == normalize(candidate.force ?? "") {
                score += 0.4
            }
            if let mechanic = target.mechanic, !mechanic.isEmpty,
               normalize(mechanic) == normalize(candidate.mechanic ?? "") {
                score += 0.4
            }

            if let targetEquipment = target.equipment, let candidateEquipment = candidate.equipment,
               normalize(targetEquipment) == normalize(candidateEquipment) {
                score += 0.8
                facets.append(.sameEquipment(candidateEquipment))
            } else if targetMachineBased, isFreeWeight(candidate.equipment), let equipment = candidate.equipment {
                score += 1.0
                facets.append(.freeWeightAlternative(equipment))
            }

            if let preference, matches(preference, equipment: candidate.equipment),
               let equipment = candidate.equipment {
                // Strong enough to reorder close substitutes, but smaller than
                // the same-pattern signal so equipment never defines quality.
                score += 0.9
                facets.append(.preferredEquipment(equipment))
            }

            let trained = trainedIDs.contains(candidate.id)
            if trained {
                facets.append(.trainedBefore)
            }

            ranked.append((Suggestion(candidate: candidate, score: score, facets: facets), trained))
        }

        // History is deliberately only a near-equal tiebreaker. Grouping from
        // the best score in each band keeps the comparison deterministic.
        let byQuality = ranked.sorted { lhs, rhs in
            if lhs.suggestion.score != rhs.suggestion.score {
                return lhs.suggestion.score > rhs.suggestion.score
            }
            return lhs.suggestion.candidate.name < rhs.suggestion.candidate.name
        }
        var suggestions: [Suggestion] = []
        var index = 0
        while index < byQuality.count {
            let bestScore = byQuality[index].suggestion.score
            var end = index + 1
            while end < byQuality.count, bestScore - byQuality[end].suggestion.score <= 0.35 {
                end += 1
            }
            suggestions.append(contentsOf: byQuality[index..<end].sorted { lhs, rhs in
                if lhs.trained != rhs.trained { return lhs.trained }
                if lhs.suggestion.score != rhs.suggestion.score {
                    return lhs.suggestion.score > rhs.suggestion.score
                }
                return lhs.suggestion.candidate.name < rhs.suggestion.candidate.name
            }.map(\.suggestion))
            index = end
        }

        return suggestions
            .prefix(limit)
            .map { $0 }
    }

    /// Equipment shortcuts worth showing for this target and pool. Directions
    /// with no same-primary-muscle candidate are omitted, avoiding dead chips.
    public static func availablePreferences(
        replacing target: Candidate,
        from pool: [Candidate],
        excluding: Set<UUID> = []
    ) -> [SwapPreference] {
        let targetPrimary = Set(target.primaryMuscles.map(normalize))
        guard !targetPrimary.isEmpty else { return [] }

        let viable = pool.filter { candidate in
            guard candidate.id != target.id, !excluding.contains(candidate.id) else { return false }
            return !targetPrimary.intersection(candidate.primaryMuscles.map(normalize)).isEmpty
        }
        let currentPreference = preference(for: target.equipment)
        return SwapPreference.allCases.filter { preference in
            preference != currentPreference && viable.contains { matches(preference, equipment: $0.equipment) }
        }
    }

    // MARK: - Equipment classes

    static func isMachineBased(_ equipment: String?) -> Bool {
        guard let e = equipment?.lowercased() else { return false }
        return e.contains("machine") || e.contains("smith") || e.contains("cable") || e.contains("leverage")
    }

    static func isFreeWeight(_ equipment: String?) -> Bool {
        guard let e = equipment?.lowercased() else { return false }
        return e.contains("barbell") || e.contains("dumbbell") || e.contains("kettlebell")
            || e.contains("e-z") || e.contains("ez ")
            || e.contains("medicine") || e.contains("weighted")
    }

    static func isBodyweight(_ equipment: String?) -> Bool {
        guard let e = equipment?.lowercased() else { return false }
        return e.contains("body") || e.contains("calisthenic") || e == "none"
    }

    private static func matches(_ preference: SwapPreference, equipment: String?) -> Bool {
        switch preference {
        case .freeWeights: isFreeWeight(equipment)
        case .machineOrCable: isMachineBased(equipment)
        case .bodyweight: isBodyweight(equipment)
        }
    }

    private static func preference(for equipment: String?) -> SwapPreference? {
        if isFreeWeight(equipment) { return .freeWeights }
        if isMachineBased(equipment) { return .machineOrCable }
        if isBodyweight(equipment) { return .bodyweight }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
