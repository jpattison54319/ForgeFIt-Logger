import Foundation

nonisolated extension PersonalRangeReading {
    var interpretation: VitalInterpretation {
        switch status {
        case .typical:
            return .typical
        case .building:
            return .building
        case .belowRange:
            return kind.favorsHigherValue ? .adverse : .favorable
        case .aboveRange:
            return kind.favorsHigherValue ? .favorable : .adverse
        }
    }

    /// Bottom is 0 and top is 1. The usual zone owns the central 60% of the
    /// axis, while adverse and favorable values occupy the outer 20% each.
    /// Values more than one band width outside the observed range clamp at the
    /// visual edge.
    var normalizedVitalPosition: Double {
        guard status != .building, let lowerBound, let upperBound else { return 0.5 }
        let width = upperBound - lowerBound
        guard width > 0 else {
            if status == .typical { return 0.5 }
            return interpretation == .favorable ? 1 : 0
        }

        let outer = VitalBandScale.outerFraction
        switch status {
        case .typical:
            let fraction = min(1, max(0, (value - lowerBound) / width))
            let directed = kind.favorsHigherValue ? fraction : 1 - fraction
            return VitalBandScale.usualLowerBound + VitalBandScale.usualFraction * directed
        case .belowRange:
            let distance = min(1, max(0, (lowerBound - value) / width))
            return kind.favorsHigherValue
                ? outer * (1 - distance)
                : VitalBandScale.usualUpperBound + outer * distance
        case .aboveRange:
            let distance = min(1, max(0, (value - upperBound) / width))
            return kind.favorsHigherValue
                ? VitalBandScale.usualUpperBound + outer * distance
                : outer * (1 - distance)
        case .building:
            return 0.5
        }
    }

    var formattedVitalValue: String {
        switch kind {
        case .respiratoryRate:
            return "\(value.formatted(.number.precision(.fractionLength(1)))) \(unit)"
        case .bloodOxygen:
            return "\(Int(value.rounded()))\(unit)"
        case .heartRate, .hrv:
            return "\(Int(value.rounded())) \(unit)"
        }
    }

    var vitalRelationText: String {
        switch status {
        case .typical:
            return "within usual band"
        case .building:
            return "usual band building"
        case .belowRange:
            return interpretation == .favorable
                ? "below usual, favorable"
                : "below usual, needs attention"
        case .aboveRange:
            return interpretation == .favorable
                ? "above usual, favorable"
                : "above usual, needs attention"
        }
    }
}
