import Foundation

/// Display unit for cardio distance/pace/speed. ForgeFit stores distance in
/// meters internally (see the cardio model comments); this controls how it is
/// shown. Lives in ForgeCore so the phone, watch, and widgets format the same
/// way. Defaults to kilometers.
public enum DistanceUnit: String, Codable, Sendable, CaseIterable {
    case km, mi

    public var title: String { self == .km ? "Kilometers" : "Miles" }
    public var abbreviation: String { self == .km ? "km" : "mi" }

    /// Meters in one of this unit.
    public var metersPerUnit: Double { self == .km ? 1000 : 1609.344 }

    public func distance(fromMeters meters: Double) -> Double { meters / metersPerUnit }
    public func meters(fromDistance value: Double) -> Double { value * metersPerUnit }

    /// Pace / speed suffixes ("/km" vs "/mi", "km/h" vs "mph").
    public var paceSuffix: String { self == .km ? "/km" : "/mi" }
    public var speedSuffix: String { self == .km ? "km/h" : "mph" }

    public var toggled: DistanceUnit { self == .km ? .mi : .km }
}
