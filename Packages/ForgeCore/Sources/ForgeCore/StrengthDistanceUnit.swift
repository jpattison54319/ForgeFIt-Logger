import Foundation

public enum StrengthDistanceUnit: String, CaseIterable, Sendable {
    case meters = "m"
    case feet = "ft"

    public static let preferenceKey = "strengthDistanceUnit"

    public var title: String { self == .meters ? "Meters" : "Feet" }

    public func meters(from value: Double) -> Double {
        self == .meters ? value : value * 0.3048
    }

    public func displayValue(meters: Double) -> Double {
        self == .meters ? meters : meters / 0.3048
    }

    public func number(meters: Double) -> String {
        displayValue(meters: meters).formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    public func label(meters: Double) -> String { "\(number(meters: meters)) \(rawValue)" }

    public static func validMeters(_ meters: Double?) -> Double? {
        guard let meters, meters.isFinite, meters > 0, meters <= 100_000 else { return nil }
        return meters
    }
}
