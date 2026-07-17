import Foundation
@testable import ForgeCore
import Testing

struct InsightStatisticsTests {

    // MARK: - Ranks & Spearman

    @Test func fractionalRanksAverageTies() {
        let ranks = InsightStatistics.fractionalRanks([10, 20, 20, 30])
        #expect(ranks == [1, 2.5, 2.5, 4])
    }

    @Test func spearmanPerfectMonotonicIsOne() {
        let x: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        let y = x.map { $0 * $0 }   // nonlinear but perfectly monotonic
        #expect(abs((InsightStatistics.spearman(x, y) ?? 0) - 1) < 1e-9)
    }

    @Test func spearmanPerfectInverseIsMinusOne() {
        let x: [Double] = [1, 2, 3, 4, 5, 6]
        let y: [Double] = [12, 9, 7, 5, 2, 1]
        #expect(abs((InsightStatistics.spearman(x, y) ?? 0) + 1) < 1e-9)
    }

    @Test func spearmanIsUndefinedForConstantOrTiny() {
        #expect(InsightStatistics.spearman([1, 1, 1, 1], [1, 2, 3, 4]) == nil)
        #expect(InsightStatistics.spearman([1, 2], [1, 2]) == nil)
    }

    // MARK: - Theil–Sen

    @Test func theilSenRecoversCleanSlope() throws {
        let x: [Double] = (0..<20).map(Double.init)
        let y = x.map { 2 * $0 + 5 }
        let line = try #require(InsightStatistics.theilSen(x: x, y: y))
        #expect(abs(line.slope - 2) < 1e-9)
        #expect(abs(line.intercept - 5) < 1e-9)
    }

    /// One wild point must not drag the slope — the reason this is the
    /// default over ordinary least squares.
    @Test func theilSenShrugsOffAnOutlier() throws {
        var x: [Double] = (0..<20).map(Double.init)
        var y = x.map { 2 * $0 + 5 }
        x.append(20)
        y.append(500)
        let line = try #require(InsightStatistics.theilSen(x: x, y: y))
        #expect(abs(line.slope - 2) < 0.2)
    }

    @Test func theilSenNeedsVariedX() {
        #expect(InsightStatistics.theilSen(x: [3, 3, 3], y: [1, 2, 3]) == nil)
    }

    // MARK: - Block bootstrap

    private func noisyLinked(count: Int, seed: UInt64) -> (x: [Double], y: [Double]) {
        var rng = SplitMix64(seed: seed)
        let x = (0..<count).map { Double($0) + Double.random(in: -0.2...0.2, using: &rng) }
        let y = x.map { $0 * 1.5 + Double.random(in: -3...3, using: &rng) }
        return (x, y)
    }

    @Test func bootstrapIntervalIsDeterministicPerSeed() throws {
        let data = noisyLinked(count: 60, seed: 7)
        let a = try #require(InsightStatistics.blockBootstrapSpearmanInterval(x: data.x, y: data.y, seed: 42))
        let b = try #require(InsightStatistics.blockBootstrapSpearmanInterval(x: data.x, y: data.y, seed: 42))
        #expect(a == b)
    }

    @Test func bootstrapIntervalBracketsAStrongSignal() throws {
        let data = noisyLinked(count: 80, seed: 3)
        let interval = try #require(InsightStatistics.blockBootstrapSpearmanInterval(x: data.x, y: data.y, seed: 9))
        let point = try #require(InsightStatistics.spearman(data.x, data.y))
        // Percentile intervals aren't guaranteed to contain the point
        // estimate (resample ties bias near-perfect correlations slightly
        // down) — the product claims are "near the interval" and "clears
        // neutral", so that's what gets pinned.
        #expect(point >= interval.lowerBound - 0.03 && point <= interval.upperBound + 0.03)
        #expect(interval.lowerBound > 0, "A strong positive signal's interval should clear neutral.")
    }

    @Test func bootstrapRefusesSparsePairs() {
        let x: [Double] = [1, 2, 3, 4, 5]
        let y: [Double] = [2, 4, 6, 8, 10]
        #expect(InsightStatistics.blockBootstrapSpearmanInterval(x: x, y: y, seed: 1) == nil)
    }

    @Test func bootstrapHonorsCancellation() {
        let data = noisyLinked(count: 40, seed: 11)
        let result = InsightStatistics.blockBootstrapSpearmanInterval(
            x: data.x, y: data.y, seed: 5, shouldCancel: { true }
        )
        #expect(result == nil)
    }

    // MARK: - Outliers

    @Test func madFlagsTheWildPointOnly() {
        let values: [Double] = [10, 11, 9, 10, 12, 10, 11, 60]
        let flags = InsightStatistics.madOutlierFlags(values)
        #expect(flags == [false, false, false, false, false, false, false, true])
    }

    @Test func madWithZeroSpreadFlagsNothing() {
        let flags = InsightStatistics.madOutlierFlags([5, 5, 5, 5, 5, 9])
        // Median 5, MAD 0 — refuse to flag rather than flag everything.
        #expect(flags.allSatisfy { !$0 })
    }

    // MARK: - Helpers

    @Test func medianHandlesEvenAndOdd() {
        #expect(InsightStatistics.median([3, 1, 2]) == 2)
        #expect(InsightStatistics.median([4, 1, 2, 3]) == 2.5)
        #expect(InsightStatistics.median([]) == nil)
    }

    @Test func seedIsStableAndDistinct() {
        let a = InsightStatistics.seed(fromSignature: "trend;volume;12w")
        let b = InsightStatistics.seed(fromSignature: "trend;volume;12w")
        let c = InsightStatistics.seed(fromSignature: "trend;volume;4w")
        #expect(a == b)
        #expect(a != c)
    }
}
