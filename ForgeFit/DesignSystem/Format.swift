import Foundation

/// Display unit for loads. ForgeFit stores load in kilograms internally (see the
/// data-layer model comments); this controls how it is shown. Defaults to lbs to
/// match the way the reference screens are configured.
enum WeightUnit: String, Codable {
    case lb, kg

    var suffix: String { self == .lb ? "lbs" : "kg" }
    var shortSuffix: String { self == .lb ? "lb" : "kg" }

    func displayValue(fromKilograms value: Double) -> Double {
        switch self {
        case .kg: value
        case .lb: value * 2.2046226218
        }
    }

    func kilograms(fromDisplayValue value: Double) -> Double {
        switch self {
        case .kg: value
        case .lb: value / 2.2046226218
        }
    }

    var toggled: WeightUnit {
        self == .lb ? .kg : .lb
    }
}

/// Lightweight display formatters tuned to the Hevy visual language
/// ("15k lbs", "43min", "2min 0s"). Kept separate from the data layer's
/// `DisplayFormatters` so UI can evolve without touching persistence.
///
enum Fmt {
    static var unit: WeightUnit = .lb

    /// A compact volume like "15k lbs" / "14,533 lbs".
    static func volume(_ value: Double?, unit: WeightUnit = Fmt.unit) -> String {
        guard let value, value > 0 else { return "0 \(unit.suffix)" }
        let display = unit.displayValue(fromKilograms: value)
        if display >= 10_000 {
            let k = display / 1_000
            return "\(k.formatted(.number.precision(.fractionLength(0...1))))k \(unit.suffix)"
        }
        return "\(display.formatted(.number.precision(.fractionLength(0)))) \(unit.suffix)"
    }

    /// Full precision volume like "14,533.8 lbs".
    static func volumeFull(_ value: Double?, unit: WeightUnit = Fmt.unit) -> String {
        guard let value else { return "0 \(unit.suffix)" }
        return "\(unit.displayValue(fromKilograms: value).formatted(.number.precision(.fractionLength(0...1)))) \(unit.suffix)"
    }

    /// A single load value without a unit suffix (for set tables).
    static func load(_ value: Double?, unit: WeightUnit = Fmt.unit) -> String {
        guard let value else { return "—" }
        return unit.displayValue(fromKilograms: value).formatted(.number.precision(.fractionLength(0...1)))
    }

    static func loadUnit(_ value: Double?, unit: WeightUnit = Fmt.unit) -> String {
        guard value != nil else { return "— \(unit.suffix)" }
        return "\(load(value, unit: unit)) \(unit.suffix)"
    }

    static func loadKilograms(from text: String, unit: WeightUnit = Fmt.unit) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let displayValue = Double(normalized) else { return nil }
        return unit.kilograms(fromDisplayValue: displayValue)
    }

    /// "43min" / "1h 12min" / "45s".
    static func durationShort(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "0s" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return m > 0 ? "\(h)h \(m)min" : "\(h)h" }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }

    /// Compact clock for rest timers and countdowns: "2:00", "0:15".
    static func restTimer(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Elapsed clock for the active-workout header: "1s" / "12:04".
    static func elapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    static func distanceKm(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return "\((meters / 1000).formatted(.number.precision(.fractionLength(0...2)))) km"
    }

    static func bpm(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)"
    }
}
