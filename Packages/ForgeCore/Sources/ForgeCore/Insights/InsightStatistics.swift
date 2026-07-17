import Foundation

// Determinism note: every stochastic step below (bootstrap resampling,
// large-n pair sampling) uses ForgeCore's internal seeded `SplitMix64` (see
// YogaFlowGenerator.swift) so the same recipe over the same data always
// produces the same interval — a card must never flicker between conclusions.

/// Pure statistical primitives for the Insights Builder. Deliberately robust
/// and rank-based: personal training data is small, noisy, autocorrelated,
/// and outlier-prone, so classical OLS/Pearson defaults would overstate what
/// it can support.
///
/// House statistical contract (see the insights plan): Spearman is the
/// association measure, Theil–Sen the trend line, moving-block bootstrap the
/// interval (temporal structure preserved), MAD the outlier rule, and nothing
/// here produces p-values or causal claims — callers phrase results as
/// tendencies in the user's available history.
public enum InsightStatistics {

    // MARK: - Ranks & correlation

    /// Fractional ranks (1-based); ties receive the average of the positions
    /// they span — required for Spearman to behave with repeated values,
    /// which training data has constantly (identical rep counts, weights).
    public static func fractionalRanks(_ values: [Double]) -> [Double] {
        let indexed = values.enumerated().sorted { $0.element < $1.element }
        var ranks = [Double](repeating: 0, count: values.count)
        var position = 0
        while position < indexed.count {
            var end = position
            while end + 1 < indexed.count, indexed[end + 1].element == indexed[position].element {
                end += 1
            }
            // Average of 1-based positions position+1 ... end+1.
            let rank = Double(position + end + 2) / 2
            for i in position...end {
                ranks[indexed[i].offset] = rank
            }
            position = end + 1
        }
        return ranks
    }

    /// Spearman rank correlation: Pearson over fractional ranks. nil when
    /// fewer than 3 pairs or either variable is constant (correlation is
    /// undefined, not zero — a constant readiness score is "no information",
    /// not "no relationship").
    public static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        return pearson(fractionalRanks(x), fractionalRanks(y))
    }

    static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var covariance = 0.0
        var varianceX = 0.0
        var varianceY = 0.0
        for i in x.indices {
            let dx = x[i] - meanX
            let dy = y[i] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0, varianceY > 0 else { return nil }
        return covariance / (varianceX.squareRoot() * varianceY.squareRoot())
    }

    // MARK: - Robust trend

    public struct TrendLine: Equatable, Sendable {
        public let slope: Double
        public let intercept: Double

        public init(slope: Double, intercept: Double) {
            self.slope = slope
            self.intercept = intercept
        }
    }

    /// Theil–Sen estimator: median of pairwise slopes, intercept as the
    /// median residual anchor. Exact over all pairs up to `maxExactPairs`;
    /// beyond that a seeded random subset keeps it deterministic AND bounded
    /// (5 years of daily buckets is ~1.7M pairs — fine exactly, but the cap
    /// protects pathological all-history recipes).
    public static func theilSen(
        x: [Double],
        y: [Double],
        seed: UInt64 = 0,
        maxExactPairs: Int = 2_000_000
    ) -> TrendLine? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let n = x.count
        var slopes: [Double] = []
        let pairCount = n * (n - 1) / 2

        if pairCount <= maxExactPairs {
            slopes.reserveCapacity(pairCount)
            for i in 0..<(n - 1) {
                for j in (i + 1)..<n where x[j] != x[i] {
                    slopes.append((y[j] - y[i]) / (x[j] - x[i]))
                }
            }
        } else {
            var rng = SplitMix64(seed: seed ^ 0x7365_6E73)   // "sens"
            let samples = 500_000
            slopes.reserveCapacity(samples)
            for _ in 0..<samples {
                let i = Int.random(in: 0..<n, using: &rng)
                let j = Int.random(in: 0..<n, using: &rng)
                guard i != j, x[j] != x[i] else { continue }
                slopes.append((y[j] - y[i]) / (x[j] - x[i]))
            }
        }
        guard let slope = median(slopes) else { return nil }
        let residuals = zip(x, y).map { $1 - slope * $0 }
        guard let intercept = median(residuals) else { return nil }
        return TrendLine(slope: slope, intercept: intercept)
    }

    // MARK: - Block bootstrap interval

    /// Moving-block bootstrap percentile interval for Spearman correlation.
    /// Blocks of ⌈n^(1/3)⌉ consecutive pairs (circular) preserve the local
    /// temporal structure plain resampling would destroy — training and
    /// recovery data are autocorrelated, and pretending otherwise narrows
    /// intervals dishonestly. Deterministic for a given seed.
    ///
    /// `shouldCancel` is polled between resamples so a stale preview can
    /// abandon work; a cancelled run returns nil.
    public static func blockBootstrapSpearmanInterval(
        x: [Double],
        y: [Double],
        seed: UInt64,
        resamples: Int = 1_000,
        confidence: Double = 0.95,
        shouldCancel: () -> Bool = { false }
    ) -> ClosedRange<Double>? {
        guard x.count == y.count, x.count >= 10 else { return nil }
        let n = x.count
        let blockLength = max(1, Int(ceil(pow(Double(n), 1.0 / 3.0))))
        var rng = SplitMix64(seed: seed)
        var estimates: [Double] = []
        estimates.reserveCapacity(resamples)

        for _ in 0..<resamples {
            if shouldCancel() { return nil }
            var resampledX = [Double]()
            var resampledY = [Double]()
            resampledX.reserveCapacity(n)
            resampledY.reserveCapacity(n)
            while resampledX.count < n {
                let start = Int.random(in: 0..<n, using: &rng)
                for offset in 0..<blockLength where resampledX.count < n {
                    let index = (start + offset) % n   // circular blocks
                    resampledX.append(x[index])
                    resampledY.append(y[index])
                }
            }
            if let estimate = spearman(resampledX, resampledY) {
                estimates.append(estimate)
            }
        }
        // Constant resamples can make estimates sparse; demand enough for the
        // percentile tails to mean something.
        guard estimates.count >= max(30, resamples / 3) else { return nil }
        estimates.sort()
        let alpha = (1 - confidence) / 2
        let lower = percentile(sorted: estimates, alpha)
        let upper = percentile(sorted: estimates, 1 - alpha)
        return lower...upper
    }

    static func percentile(sorted values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let clamped = min(max(p, 0), 1)
        let position = clamped * Double(values.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return values[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return values[lowerIndex] * (1 - fraction) + values[upperIndex] * fraction
    }

    // MARK: - Outliers

    /// Modified z-score outlier flags via median/MAD (threshold 3.5, the
    /// Iglewicz–Hoaglin convention). MAD of zero (heavily tied data) flags
    /// nothing — better to under-flag than call every deviation an outlier.
    /// Flags are advisory: the engine shows a sensitivity comparison and
    /// never silently drops observations.
    public static func madOutlierFlags(_ values: [Double], threshold: Double = 3.5) -> [Bool] {
        guard let med = median(values) else { return [] }
        let deviations = values.map { abs($0 - med) }
        guard let mad = median(deviations), mad > 0 else {
            return [Bool](repeating: false, count: values.count)
        }
        return values.map { abs(0.6745 * ($0 - med) / mad) > threshold }
    }

    // MARK: - Shared helpers

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Stable 64-bit seed from a recipe signature string (FNV-1a). Lives here
    /// so the app and tests derive identical seeds.
    public static func seed(fromSignature signature: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in signature.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
