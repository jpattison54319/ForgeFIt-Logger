import Foundation

public enum ExerciseLoadMode {
    public static func isBodyweightEquipment(_ equipment: String?) -> Bool {
        switch equipment?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "body only", "bodyweight", "body weight", "bodyweight only", "no equipment": true
        default: false
        }
    }

    public static func inferred(equipment: String?, name: String) -> WeightMode {
        let words = name.lowercased().split { !$0.isLetter }
        if words.contains("assisted") { return .bodyweightAssisted }
        guard isBodyweightEquipment(equipment) else { return .external }
        return words.contains("weighted") ? .bodyweightAdded : .bodyweight
    }
}
