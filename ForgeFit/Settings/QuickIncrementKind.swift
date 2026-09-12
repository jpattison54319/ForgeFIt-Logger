import Foundation

enum QuickIncrementKind: String, CaseIterable, Identifiable {
    case reps, pounds, kilograms

    var id: Self { self }

    static func weight(_ unit: WeightUnit) -> Self {
        unit == .kg ? .kilograms : .pounds
    }

    var title: String {
        switch self {
        case .reps: "Reps"
        case .pounds: "Pounds (lb)"
        case .kilograms: "Kilograms (kg)"
        }
    }

    var defaults: [Double] {
        switch self {
        case .reps: [1, 2, 3]
        case .pounds: [2.5, 5, 7.5]
        case .kilograms: [1.25, 2.5, 3.75]
        }
    }

    func key(_ index: Int) -> String { "quickIncrement.\(rawValue).\(index)" }

    /// Three distinct positive amounts, ordered from the field outward.
    /// Two decimal places match the precision of the live weight editor.
    func isValid(_ values: [Double]) -> Bool {
        guard values.count == 3, values.allSatisfy({ value in
            value.isFinite && value >= (self == .reps ? 1 : 0.01) && value <= 1_000
                && (self == .reps
                    ? value == value.rounded()
                    : abs(value * 100 - (value * 100).rounded()) < 0.000_001)
        }) else { return false }
        return values[0] < values[1] && values[1] < values[2]
    }

    var validationMessage: String {
        self == .reps
            ? "Use three increasing whole numbers from 1 to 1,000."
            : "Use three increasing amounts from 0.01 to 1,000, with up to two decimal places."
    }
}
