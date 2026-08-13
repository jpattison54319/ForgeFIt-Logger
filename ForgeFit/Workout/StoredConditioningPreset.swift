import ForgeCore
import ForgeData
import Foundation

/// Tagged payloads stored beside legacy interval-preset rows. Keeping the
/// discriminator inside the JSON lets conditioning presets sync through the
/// existing plan store without changing the production CloudKit schema.
enum StoredConditioningPreset: Codable, Equatable, Sendable {
    case section(ConditioningSection)
    case deletedBuiltIn(String)

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(from json: String) -> Self? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

extension IntervalPresetModel {
    var storedConditioningPreset: StoredConditioningPreset? {
        StoredConditioningPreset.decode(from: planJSON)
    }

    var storedIntervalPlan: IntervalPlan? {
        IntervalPlan.decode(from: planJSON)
    }
}
