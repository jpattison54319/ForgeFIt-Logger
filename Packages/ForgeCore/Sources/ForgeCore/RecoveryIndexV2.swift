import Foundation

public enum RecoveryDomain: String, Codable, CaseIterable, Sendable {
    case hrv
    case heartRate
    case sleep
}

public struct RecoveryComponentInput: Equatable, Sendable {
    public let domain: RecoveryDomain
    public let adverseUnits: Double
    public let quality: Double

    public init(domain: RecoveryDomain, adverseUnits: Double, quality: Double) {
        self.domain = domain
        self.adverseUnits = adverseUnits
        self.quality = quality
    }

    public var score: Double {
        RecoveryIndexV2.componentScore(adverseUnits: adverseUnits)
    }
}

public struct RecoveryIndexResult: Equatable, Sendable {
    public let score: Double
    public let rawScore: Double
    public let coverage: Double
}

/// Pure arithmetic for the R2 personal recovery-signal index. The constants
/// are versioned product defaults pending prospective ForgeFit calibration.
public enum RecoveryIndexV2 {
    public static let analyticsVersion = "R2.0"
    public static let formulaHash = "r2-adverse30-equal-coverage1.5"

    public static func componentScore(adverseUnits: Double) -> Double {
        guard adverseUnits.isFinite else { return 0 }
        return min(100, max(0, 100 - 30 * max(0, adverseUnits)))
    }

    /// Returns nil rather than allowing one signal or thin history to create
    /// a headline score. At least one autonomic channel must be represented.
    public static func combine(
        _ inputs: [RecoveryComponentInput],
        minimumCoverage: Double = 0.50
    ) -> RecoveryIndexResult? {
        let usable = Dictionary(
            inputs.filter { $0.adverseUnits.isFinite && $0.quality.isFinite && $0.quality > 0 }
                .map { ($0.domain, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard usable.count >= 2,
              usable[.hrv] != nil || usable[.heartRate] != nil else { return nil }

        let prior = 1.0 / Double(RecoveryDomain.allCases.count)
        let weightedQuality = usable.values.reduce(0.0) {
            $0 + prior * min(1, max(0, $1.quality))
        }
        guard weightedQuality >= minimumCoverage else { return nil }

        let raw = usable.values.reduce(0.0) {
            $0 + prior * min(1, max(0, $1.quality)) * $1.score
        } / weightedQuality
        let score = 50 + pow(weightedQuality, 1.5) * (raw - 50)
        return RecoveryIndexResult(
            score: min(100, max(0, score)),
            rawScore: min(100, max(0, raw)),
            coverage: min(1, weightedQuality)
        )
    }

    public static func historyQuality(count: Int, spanDays: Int) -> Double {
        min(1, max(0, Double(count) / 28))
            * min(1, max(0, Double(spanDays) / 42))
    }
}
