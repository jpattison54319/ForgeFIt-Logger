import ForgeCore
import Foundation

public enum StrengthSetDistance {
    public static func meters(in metadata: String?) -> Double? {
        StrengthDistanceUnit.validMeters(settings(in: metadata)["strengthDistanceMeters"] as? Double)
    }

    static func settings(in json: String?) -> [String: Any] {
        guard let json,
              let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let settings = decoded as? [String: Any] else { return [:] }
        return settings
    }
}

extension SetModel {
    /// Measured strength-set metadata travels with the local workout and its
    /// training backup through the existing extensible set settings field.
    public var strengthDistanceMeters: Double? {
        get { StrengthSetDistance.meters(in: machineSettingsJSON) }
        set {
            var settings = StrengthSetDistance.settings(in: machineSettingsJSON)
            settings["strengthDistanceMeters"] = StrengthDistanceUnit.validMeters(newValue)
            guard !settings.isEmpty else {
                machineSettingsJSON = nil
                return
            }
            if let encoded = try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]) {
                machineSettingsJSON = String(decoding: encoded, as: UTF8.self)
            }
        }
    }

}
