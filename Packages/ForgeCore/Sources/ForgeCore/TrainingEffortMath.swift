import Foundation

/// Shared, bounded effort weighting for product training-dose estimates.
/// RPE 8 is the neutral anchor; the curve is intentionally modest because
/// perceived effort refines logged work rather than replacing the work itself.
public enum TrainingEffortMath {
    public static func clamped(_ effort: Double) -> Double {
        min(10, max(0, effort))
    }

    public static func resolved(rpe: Double?, rir: Int?, defaultEffort: Double) -> Double {
        if let rpe { return clamped(rpe) }
        if let rir { return clamped(10 - Double(rir)) }
        return clamped(defaultEffort)
    }

    public static func weight(for effort: Double) -> Double {
        let value = clamped(effort)
        return value <= 8
            ? max(0.55, 1 + (value - 8) * 0.15)
            : min(1.45, 1 + (value - 8) * 0.225)
    }
}
