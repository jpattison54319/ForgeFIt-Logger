import ForgeCore
import Foundation

enum ExerciseSwapPresentation {
    static func caption(
        for facets: [ExerciseSwapSuggester.MatchFacet],
        referenceDate: Date
    ) -> String {
        var parts: [String] = []
        let hasExactPattern = facets.contains(.samePattern)

        // Personal history is the reason this ranking is meaningfully theirs,
        // so keep it ahead of generic similarity/equipment details where the
        // row's two-line caption cannot show everything.
        let orderedFacets = facets.enumerated().sorted { lhs, rhs in
            let lhsPriority = priority(of: lhs.element)
            let rhsPriority = priority(of: rhs.element)
            return lhsPriority == rhsPriority ? lhs.offset < rhs.offset : lhsPriority < rhsPriority
        }.map(\.element)

        for facet in orderedFacets {
            switch facet {
            case .sharedMuscles(let muscles):
                parts.append(muscles.prefix(2).map(\.capitalized).joined(separator: " · "))
            case .samePattern:
                parts.append("Same movement pattern")
            case .sameEquipment:
                parts.append("Same equipment")
            case .freeWeightAlternative:
                parts.append("No machine needed")
            case .preferredEquipment:
                parts.append("Matches your equipment choice")
            case .trainedBefore:
                parts.append("In your history")
            case .sameMovementFamily(let family):
                if !hasExactPattern {
                    parts.append("Same \(family.rawValue) movement")
                }
            case .usage(let recentSessionCount, let lastUsedAt):
                if recentSessionCount > 0 {
                    let sessionWord = recentSessionCount == 1 ? "session" : "sessions"
                    parts.append("\(recentSessionCount) \(sessionWord) in 90d")
                }
                parts.append(lastUsedText(lastUsedAt, referenceDate: referenceDate))
            }
        }

        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func priority(of facet: ExerciseSwapSuggester.MatchFacet) -> Int {
        switch facet {
        case .sharedMuscles: 0
        case .usage: 1
        case .samePattern: 2
        case .sameMovementFamily: 3
        case .preferredEquipment, .freeWeightAlternative: 4
        case .sameEquipment: 5
        case .trainedBefore: 6
        }
    }

    private static func lastUsedText(_ lastUsedAt: Date, referenceDate: Date) -> String {
        let days = max(0, Int(referenceDate.timeIntervalSince(lastUsedAt) / 86_400))
        return days == 0 ? "Last used today" : "Last used \(days)d ago"
    }
}
