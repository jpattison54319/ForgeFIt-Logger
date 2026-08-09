import Foundation

/// Ranks candidates for replacing an exercise. Muscle region and movement
/// family define what is a valid substitute; the lifter's completed-workout
/// count then puts familiar favorites first inside that honest candidate set.
public enum ExerciseSwapSuggester {

    /// A strict equipment filter for replacement results.
    public enum EquipmentFilter: CaseIterable, Equatable, Hashable, Sendable {
        case freeWeights
        case machineOrCable
        case bodyweight
    }

    /// Lifetime completed-workout count for one exercise. One workout counts
    /// once regardless of how many sets or duplicate rows it contains.
    public struct UsageProfile: Equatable, Sendable {
        public let completedWorkoutCount: Int

        public init(completedWorkoutCount: Int) {
            self.completedWorkoutCount = max(0, completedWorkoutCount)
        }

        /// Compatibility initializer for callers that already hold session
        /// dates. Replacement ranking intentionally uses only the total count.
        public init(sessionDates: [Date]) {
            completedWorkoutCount = sessionDates.count
        }
    }

    /// A lightweight snapshot of the fields that define replacement quality.
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let name: String
        public let movementPattern: String?
        public let primaryMuscles: [String]
        public let secondaryMuscles: [String]
        public let equipment: String?
        public let weightMode: WeightMode
        public let mechanic: String?
        public let force: String?

        public init(
            id: UUID,
            name: String,
            movementPattern: String? = nil,
            primaryMuscles: [String] = [],
            secondaryMuscles: [String] = [],
            equipment: String? = nil,
            weightMode: WeightMode = .external,
            mechanic: String? = nil,
            force: String? = nil
        ) {
            self.id = id
            self.name = name
            self.movementPattern = movementPattern
            self.primaryMuscles = primaryMuscles
            self.secondaryMuscles = secondaryMuscles
            self.equipment = equipment
            self.weightMode = weightMode
            self.mechanic = mechanic
            self.force = force
        }
    }

    /// Testable reasons a candidate matched. The concise replacement UI does
    /// not render these as explanatory copy.
    public enum MatchFacet: Equatable, Sendable {
        case sharedMuscles([String])
        case sameMuscleRegion([String])
        case samePattern
        case sameEquipment(String)
        case freeWeightAlternative(String)
        case trainedBefore
        case sameMovementFamily(ExerciseMovementFamily)
        case usage(completedWorkoutCount: Int)
    }

    public struct Suggestion: Equatable, Sendable {
        public let candidate: Candidate
        public let score: Double
        public let facets: [MatchFacet]
    }

    /// Returns valid substitutes with favorites first. A candidate must share
    /// a primary muscle region with the target, and known movement families
    /// must agree. Secondary-muscle overlap improves similarity but can never
    /// admit a candidate from another primary region.
    public static func suggest(
        replacing target: Candidate,
        from pool: [Candidate],
        trainedIDs: Set<UUID> = [],
        excluding: Set<UUID> = [],
        equipmentFilter: EquipmentFilter? = nil,
        usageByID: [UUID: UsageProfile] = [:],
        referenceDate: Date = .now,
        limit: Int = 6
    ) -> [Suggestion] {
        // Kept in the source-compatible API so existing call sites can supply
        // a deterministic clock; favorite-first ranking does not use recency.
        _ = referenceDate

        guard !canonicalMuscles(target.primaryMuscles).isEmpty else { return [] }

        var ranked: [(suggestion: Suggestion, completedWorkoutCount: Int)] = []
        for candidate in pool {
            guard candidate.id != target.id,
                  !excluding.contains(candidate.id),
                  isStructurallyCompatible(candidate, with: target),
                  equipmentFilter.map({ matches($0, candidate: candidate) }) ?? true else {
                continue
            }

            let similarity = similarityScore(candidate, target: target)
            var facets = similarity.facets
            let completedWorkoutCount = usageByID[candidate.id]?.completedWorkoutCount
                ?? (trainedIDs.contains(candidate.id) ? 1 : 0)
            if completedWorkoutCount > 0 {
                facets.append(.trainedBefore)
                facets.append(.usage(completedWorkoutCount: completedWorkoutCount))
            }

            ranked.append((
                Suggestion(candidate: candidate, score: similarity.score, facets: facets),
                completedWorkoutCount
            ))
        }

        return ranked.sorted { lhs, rhs in
            if lhs.completedWorkoutCount != rhs.completedWorkoutCount {
                return lhs.completedWorkoutCount > rhs.completedWorkoutCount
            }
            if lhs.suggestion.score != rhs.suggestion.score {
                return lhs.suggestion.score > rhs.suggestion.score
            }
            return lhs.suggestion.candidate.name.localizedStandardCompare(
                rhs.suggestion.candidate.name
            ) == .orderedAscending
        }
        .prefix(limit)
        .map(\.suggestion)
    }

    /// Strict equipment filters that have at least one structurally valid
    /// candidate after current/in-use exercises are excluded.
    public static func availableFilters(
        replacing target: Candidate,
        from pool: [Candidate],
        excluding: Set<UUID> = []
    ) -> [EquipmentFilter] {
        EquipmentFilter.allCases.filter { filter in
            pool.contains { candidate in
                candidate.id != target.id
                    && !excluding.contains(candidate.id)
                    && isStructurallyCompatible(candidate, with: target)
                    && matches(filter, candidate: candidate)
            }
        }
    }

    /// Shared classification used by the quick sheet and full replacement
    /// search so an active equipment filter cannot leak other categories.
    public static func matches(_ filter: EquipmentFilter, candidate: Candidate) -> Bool {
        switch filter {
        case .freeWeights:
            isFreeWeight(candidate.equipment)
        case .machineOrCable:
            isMachineBased(candidate.equipment)
        case .bodyweight:
            !isFreeWeight(candidate.equipment)
                && !isMachineBased(candidate.equipment)
                && (candidate.weightMode != .external || isBodyweight(candidate.equipment))
        }
    }

    // MARK: - Structural compatibility

    private static func isStructurallyCompatible(_ candidate: Candidate, with target: Candidate) -> Bool {
        let targetRegions = muscleRegions(target.primaryMuscles)
        let candidateRegions = muscleRegions(candidate.primaryMuscles)
        guard !targetRegions.isEmpty,
              !candidateRegions.isEmpty,
              !targetRegions.isDisjoint(with: candidateRegions) else {
            return false
        }

        let targetFamily = ExerciseMovementFamily.infer(
            movementPattern: target.movementPattern,
            primaryMuscles: target.primaryMuscles
        )
        let candidateFamily = ExerciseMovementFamily.infer(
            movementPattern: candidate.movementPattern,
            primaryMuscles: candidate.primaryMuscles
        )
        if let targetFamily, let candidateFamily, targetFamily != candidateFamily {
            return false
        }
        return true
    }

    private static func similarityScore(
        _ candidate: Candidate,
        target: Candidate
    ) -> (score: Double, facets: [MatchFacet]) {
        let targetPrimary = canonicalMuscles(target.primaryMuscles)
        let targetSecondary = canonicalMuscles(target.secondaryMuscles)
        let candidatePrimary = canonicalMuscles(candidate.primaryMuscles)
        let candidateSecondary = canonicalMuscles(candidate.secondaryMuscles)

        let exactPrimary = targetPrimary.intersection(candidatePrimary)
        let sharedRegions = muscleRegions(target.primaryMuscles)
            .intersection(muscleRegions(candidate.primaryMuscles))

        var score = 6 * overlapRatio(exactPrimary.count, denominator: targetPrimary.count)
        score += 3 * overlapRatio(sharedRegions.count, denominator: muscleRegions(target.primaryMuscles).count)
        score += 1.5 * overlapRatio(
            targetPrimary.intersection(candidateSecondary).count,
            denominator: targetPrimary.count
        )
        score += 1.25 * overlapRatio(
            targetSecondary.intersection(candidatePrimary).count,
            denominator: max(1, targetSecondary.count)
        )
        score += 0.5 * overlapRatio(
            targetSecondary.intersection(candidateSecondary).count,
            denominator: max(1, targetSecondary.count)
        )

        var facets: [MatchFacet] = []
        if !exactPrimary.isEmpty {
            facets.append(.sharedMuscles(exactPrimary.sorted()))
        }
        if !sharedRegions.isEmpty {
            facets.append(.sameMuscleRegion(sharedRegions.sorted()))
        }

        let targetPattern = normalizePattern(target.movementPattern)
        let candidatePattern = normalizePattern(candidate.movementPattern)
        let samePattern = !targetPattern.isEmpty && targetPattern == candidatePattern
        if samePattern {
            score += 3
            facets.append(.samePattern)
        }

        let targetFamily = ExerciseMovementFamily.infer(
            movementPattern: target.movementPattern,
            primaryMuscles: target.primaryMuscles
        )
        let candidateFamily = ExerciseMovementFamily.infer(
            movementPattern: candidate.movementPattern,
            primaryMuscles: candidate.primaryMuscles
        )
        if let targetFamily, targetFamily == candidateFamily {
            score += 1
            facets.append(.sameMovementFamily(targetFamily))
        }

        let targetForce = normalize(target.force ?? "")
        let candidateForce = normalize(candidate.force ?? "")
        let forceDuplicatesPattern = !targetForce.isEmpty
            && targetForce == targetPattern
            && candidateForce == candidatePattern
        if !targetForce.isEmpty, targetForce == candidateForce, !forceDuplicatesPattern {
            score += 0.4
        }
        if let mechanic = target.mechanic, !mechanic.isEmpty,
           normalize(mechanic) == normalize(candidate.mechanic ?? "") {
            score += 0.4
        }

        if let targetEquipment = target.equipment,
           let candidateEquipment = candidate.equipment,
           normalize(targetEquipment) == normalize(candidateEquipment) {
            score += 0.8
            facets.append(.sameEquipment(candidateEquipment))
        } else if isMachineBased(target.equipment),
                  isFreeWeight(candidate.equipment),
                  let equipment = candidate.equipment {
            score += 0.6
            facets.append(.freeWeightAlternative(equipment))
        }

        return (score, facets)
    }

    private static func canonicalMuscles(_ muscles: [String]) -> Set<String> {
        Set(muscles.map(MuscleTaxonomy.canonical))
    }

    private static func muscleRegions(_ muscles: [String]) -> Set<String> {
        Set(muscles.map { MuscleTaxonomy.parent(of: $0) })
    }

    private static func overlapRatio(_ count: Int, denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(count) / Double(denominator)
    }

    // MARK: - Equipment classes

    private static func isMachineBased(_ equipment: String?) -> Bool {
        guard let equipment else { return false }
        let value = normalize(equipment)
        return value.contains("machine") || value.contains("smith")
            || value.contains("cable") || value.contains("leverage")
    }

    private static func isFreeWeight(_ equipment: String?) -> Bool {
        guard let equipment else { return false }
        let value = normalize(equipment)
        return value.contains("barbell") || value.contains("dumbbell")
            || value.contains("kettlebell") || value.contains("e-z")
            || value.contains("ez ") || value.contains("medicine")
            || value.contains("weighted")
    }

    private static func isBodyweight(_ equipment: String?) -> Bool {
        guard let equipment else { return false }
        let value = normalize(equipment)
        return value.contains("body") || value.contains("calisthenic") || value == "none"
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePattern(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .lowercased()
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}
