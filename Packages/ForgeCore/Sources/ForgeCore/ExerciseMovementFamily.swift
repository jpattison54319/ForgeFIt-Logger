import Foundation

/// Broad movement compatibility for exercise replacement. This is deliberately
/// coarser than an exact movement pattern: it prevents history from promoting
/// a familiar exercise from the wrong family while legacy/custom metadata is
/// still allowed to fall back to shared primary muscles when no family is known.
public enum ExerciseMovementFamily: String, Sendable, Equatable {
    case push
    case pull
    case legs
    case core
    case cardio

    public static func infer(
        movementPattern: String?,
        primaryMuscles: [String]
    ) -> ExerciseMovementFamily? {
        let pattern = normalizePattern(movementPattern)
        if pattern == "cardio" { return .cardio }

        let muscles = Set(primaryMuscles.map(MuscleTaxonomy.canonical))
        if !muscles.isDisjoint(with: legMuscles) { return .legs }

        if pushPatterns.contains(pattern) { return .push }
        if pullPatterns.contains(pattern) { return .pull }
        if legPatterns.contains(pattern) { return .legs }
        if corePatterns.contains(pattern) { return .core }

        var inferred = Set<ExerciseMovementFamily>()
        if !muscles.isDisjoint(with: pushMuscles) { inferred.insert(.push) }
        if !muscles.isDisjoint(with: pullMuscles) { inferred.insert(.pull) }
        if !muscles.isDisjoint(with: coreMuscles) { inferred.insert(.core) }
        return inferred.count == 1 ? inferred.first : nil
    }

    private static let pushPatterns: Set<String> = [
        "horizontal push", "vertical push", "push", "press", "elbow extension"
    ]

    private static let pullPatterns: Set<String> = [
        "horizontal pull", "vertical pull", "pull", "row", "elbow flexion"
    ]

    private static let legPatterns: Set<String> = [
        "squat", "hinge", "lunge", "knee extension", "knee flexion",
        "hip extension", "hip flexion", "calf raise"
    ]

    private static let corePatterns: Set<String> = [
        "anti extension", "anti rotation", "rotation", "trunk flexion",
        "trunk extension", "carry"
    ]

    private static let legMuscles: Set<String> = [
        "quadriceps", "hamstrings", "glutes", "calves", "adductors", "abductors"
    ]

    private static let pushMuscles: Set<String> = [
        "chest", "upper chest", "mid chest", "lower chest", "triceps",
        "front delts", "side delts"
    ]

    private static let pullMuscles: Set<String> = [
        "back", "lats", "upper back", "middle back", "traps", "rear delts",
        "biceps", "forearms"
    ]

    private static let coreMuscles: Set<String> = [
        "abdominals", "obliques", "transverse abdominis", "lower back"
    ]

    private static func normalizePattern(_ raw: String?) -> String {
        guard let raw else { return "" }
        return raw
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}
