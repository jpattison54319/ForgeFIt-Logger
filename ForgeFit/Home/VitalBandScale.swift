import Foundation

/// Keeps the normalized vital positions aligned with the rendered plot bands.
nonisolated enum VitalBandScale {
    static let outerFraction = 0.20
    static let usualFraction = 0.60
    static let usualLowerBound = outerFraction
    static let usualUpperBound = usualLowerBound + usualFraction
}
