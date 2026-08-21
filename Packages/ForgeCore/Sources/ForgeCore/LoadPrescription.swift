import Foundation

/// How a routine set determines its planned load. Fixed loads retain the
/// existing behavior; percentage prescriptions resolve from completed
/// performance history when a new workout is created.
public enum LoadPrescriptionMode: String, Codable, Sendable, CaseIterable {
    case fixed
    case percentEstimatedOneRepMax
}

/// A validated percentage-of-estimated-1RM prescription. `highPercent` is
/// nil for an exact target and non-nil for an athlete-adjustable range.
public struct EstimatedOneRepMaxPrescription: Codable, Sendable, Equatable {
    public static let validPercentRange = 1.0...100.0

    public let lowPercent: Double
    public let highPercent: Double?

    public init?(lowPercent: Double, highPercent: Double? = nil) {
        guard lowPercent.isFinite,
              Self.validPercentRange.contains(lowPercent),
              highPercent.map({ $0.isFinite && Self.validPercentRange.contains($0) && $0 >= lowPercent }) ?? true else {
            return nil
        }
        self.lowPercent = lowPercent
        self.highPercent = highPercent == lowPercent ? nil : highPercent
    }

    /// Accepts exact values ("82.5") and ranges ("67-72" / "67–72"). The
    /// percent symbol is optional because the field's visible suffix already
    /// communicates the unit.
    public static func parse(_ text: String) -> EstimatedOneRepMaxPrescription? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("%", with: "")
            .replacing("–", with: "-")
            .replacing("—", with: "-")
            .replacing(",", with: ".")
        guard !normalized.isEmpty else { return nil }
        let parts = normalized
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let low = parts.first.flatMap(Double.init) else { return nil }
        if parts.count == 1 {
            return .init(lowPercent: low)
        }
        guard let high = parts.last.flatMap(Double.init) else { return nil }
        return .init(lowPercent: low, highPercent: high)
    }

    public func resolving(estimatedOneRepMaxKg: Double) -> ResolvedLoadRange? {
        guard estimatedOneRepMaxKg.isFinite, estimatedOneRepMaxKg > 0 else { return nil }
        let low = estimatedOneRepMaxKg * lowPercent / 100
        let high = estimatedOneRepMaxKg * (highPercent ?? lowPercent) / 100
        return ResolvedLoadRange(lowKg: low, highKg: high)
    }
}

public struct ResolvedLoadRange: Codable, Sendable, Equatable {
    public let lowKg: Double
    public let highKg: Double

    public init(lowKg: Double, highKg: Double) {
        self.lowKg = lowKg
        self.highKg = max(lowKg, highKg)
    }
}
