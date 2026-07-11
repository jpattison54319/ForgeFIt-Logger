import Foundation
import Testing
@testable import ForgeCore

struct DistanceBestEffortsTests {

    // MARK: - Helpers

    /// Deterministic PRNG (SplitMix64) so the random-walk fixture is identical
    /// on every runner — no seed drift, no flaky comparisons.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        mutating func nextDouble() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }

    /// O(n²) reference: same candidate definition as the production sweep
    /// (window with one edge on a sample, other edge linearly interpolated),
    /// but with independent nested-loop scans instead of shared pointers.
    private static func bruteForceSeconds(samples: [(t: Int, meters: Double)], target: Double) -> Double? {
        let sorted = samples.sorted { $0.t < $1.t }
        var pts: [(t: Double, m: Double)] = []
        var runningMax = -Double.infinity
        for s in sorted {
            runningMax = max(runningMax, s.meters)
            pts.append((Double(s.t), runningMax))
        }
        guard pts.count >= 2 else { return nil }
        var best: Double?

        // Start anchored on sample i, end interpolated at the first crossing.
        for i in 0..<pts.count {
            let needed = pts[i].m + target
            for j in (i + 1)..<pts.count where pts[j].m >= needed {
                let a = pts[j - 1], b = pts[j]
                let endT = b.m > a.m ? a.t + (b.t - a.t) * (needed - a.m) / (b.m - a.m) : b.t
                let duration = endT - pts[i].t
                if best == nil || duration < best! { best = duration }
                break
            }
        }
        // End anchored on sample j, start interpolated at the latest crossing.
        for j in 0..<pts.count {
            let needed = pts[j].m - target
            for i in stride(from: j - 1, through: 0, by: -1) where pts[i].m <= needed {
                let a = pts[i], b = pts[i + 1]
                let startT = b.m > a.m ? a.t + (b.t - a.t) * (needed - a.m) / (b.m - a.m) : b.t
                let duration = pts[j].t - startT
                if best == nil || duration < best! { best = duration }
                break
            }
        }
        return best
    }

    private func effort(_ efforts: [DistanceBestEfforts.Effort], _ meters: Double) -> DistanceBestEfforts.Effort? {
        efforts.first { $0.targetMeters == meters }
    }

    // MARK: - Interpolation exactness

    /// Constant 5:00/km pace: interpolation must land the 1 km effort at
    /// exactly 300 s, not 300 s ± one sampling interval.
    @Test func constantPaceYieldsExact1kTime() {
        // 100 m every 30 s (exactly representable), 1800 s / 6000 m total.
        let samples = (0...60).map { (t: $0 * 30, meters: Double($0) * 100) }
        let efforts = DistanceBestEfforts.bestEfforts(samples: samples)
        let oneK = effort(efforts, 1000)
        #expect(oneK != nil)
        #expect(abs((oneK?.seconds ?? 0) - 300) < 1e-9)
        #expect(oneK?.label == "1 km")
        // Constant pace scales linearly to every available target.
        #expect(abs((effort(efforts, 5000)?.seconds ?? 0) - 1500) < 1e-9)
    }

    /// Negative split (2 m/s then 4 m/s): the best 1 km must come from the
    /// fast second half, so it beats the best 1 km of the first half alone.
    @Test func negativeSplitBest1kIsInSecondHalf() {
        var samples: [(t: Int, meters: Double)] = []
        for t in stride(from: 0, through: 1200, by: 10) {
            let m = t <= 600 ? Double(t) * 2 : 1200 + Double(t - 600) * 4
            samples.append((t: t, meters: m))
        }
        let full = DistanceBestEfforts.bestEfforts(samples: samples)
        let firstHalf = DistanceBestEfforts.bestEfforts(samples: samples.filter { $0.t <= 600 })

        let full1k = effort(full, 1000)
        let firstHalf1k = effort(firstHalf, 1000)
        #expect(abs((full1k?.seconds ?? 0) - 250) < 1e-9)   // 1000 m at 4 m/s
        #expect(abs((firstHalf1k?.seconds ?? 0) - 500) < 1e-9)
        #expect((full1k?.seconds ?? .infinity) < (firstHalf1k?.seconds ?? 0))
    }

    /// Sparse samples 100 m apart: 1 mi (1609.344 m) crosses mid-segment, so
    /// snapping to samples would err by ~36 s; interpolation must stay <0.5 s.
    @Test func interpolationAccurateAcrossSparseSamples() {
        // 2.5 m/s, one sample per 100 m (every 40 s), 2000 m total.
        let samples = (0...20).map { (t: $0 * 40, meters: Double($0) * 100) }
        let mile = effort(DistanceBestEfforts.bestEfforts(samples: samples), 1609.344)
        #expect(mile != nil)
        #expect(abs((mile?.seconds ?? 0) - 1609.344 / 2.5) < 0.5)
    }

    /// A case only the end-anchored sweep can win: accelerating session where
    /// the optimal window ends exactly on a sample but starts mid-segment.
    @Test func endAnchoredWindowBeatsStartAnchored() {
        let samples: [(t: Int, meters: Double)] = [(0, 0), (10, 100), (20, 300)]
        let efforts = DistanceBestEfforts.bestEfforts(
            samples: samples,
            targets: [(meters: 250, label: "250 m")]
        )
        // Start-anchored best is 17.5 s (t=0 to t=17.5); the true optimum is
        // 15 s, starting at t=5 (m=50) and ending at t=20 (m=300).
        #expect(efforts.count == 1)
        #expect(abs((efforts.first?.seconds ?? 0) - 15) < 1e-9)
    }

    // MARK: - Target availability

    @Test func skipsTargetsLongerThanTotalDistance() {
        // 4.9 km total: 5 km, 10 km, and half must not appear.
        let samples = (0...49).map { (t: $0 * 30, meters: Double($0) * 100) }
        let efforts = DistanceBestEfforts.bestEfforts(samples: samples)
        #expect(effort(efforts, 400) != nil)
        #expect(effort(efforts, 1000) != nil)
        #expect(effort(efforts, 1609.344) != nil)
        #expect(effort(efforts, 5000) == nil)
        #expect(effort(efforts, 10000) == nil)
        #expect(effort(efforts, 21097.5) == nil)
    }

    /// A session covering exactly the target distance still counts — runners
    /// who run a dead-on 1 km expect to see their 1 km time.
    @Test func exactTargetDistanceIsIncluded() {
        let samples = (0...10).map { (t: $0 * 30, meters: Double($0) * 100) }   // exactly 1000 m
        let efforts = DistanceBestEfforts.bestEfforts(samples: samples)
        let oneK = effort(efforts, 1000)
        #expect(oneK != nil)
        #expect(abs((oneK?.seconds ?? 0) - 300) < 1e-9)
    }

    @Test func resultsFollowTargetOrder() {
        let samples = (0...20).map { (t: $0 * 30, meters: Double($0) * 100) }   // 2000 m
        let efforts = DistanceBestEfforts.bestEfforts(samples: samples)
        #expect(efforts.map(\.label) == ["400 m", "1 km", "1 mi"])
        #expect(efforts.map(\.targetMeters) == [400, 1000, 1609.344])
    }

    @Test func customTargetsAreRespected() {
        let samples = (0...10).map { (t: $0 * 10, meters: Double($0) * 50) }    // 500 m
        let efforts = DistanceBestEfforts.bestEfforts(
            samples: samples,
            targets: [(meters: 200, label: "200 m"), (meters: 800, label: "800 m")]
        )
        #expect(efforts.count == 1)
        #expect(efforts.first?.label == "200 m")
        #expect(abs((efforts.first?.seconds ?? 0) - 40) < 1e-9)                 // 5 m/s
    }

    // MARK: - Guards

    @Test func emptyInputYieldsNoEfforts() {
        #expect(DistanceBestEfforts.bestEfforts(samples: []) == [])
    }

    @Test func singleSampleYieldsNoEfforts() {
        #expect(DistanceBestEfforts.bestEfforts(samples: [(t: 0, meters: 5000)]) == [])
    }

    @Test func flatDistanceYieldsNoEfforts() {
        let samples = (0...10).map { (t: $0 * 10, meters: 250.0) }
        #expect(DistanceBestEfforts.bestEfforts(samples: samples) == [])
    }

    /// GPS jitter that reports the runner moving backwards must not crash,
    /// must never produce a negative or zero time, and must behave exactly as
    /// if the dips were flattened.
    @Test func nonMonotonicGlitchIsClampedFlat() {
        let raw: [(t: Int, meters: Double)] = [
            (0, 0), (10, 100), (20, 250), (30, 240),    // dip backwards
            (40, 300), (50, 290), (60, 420), (70, 500), // and again
        ]
        let clamped: [(t: Int, meters: Double)] = [
            (0, 0), (10, 100), (20, 250), (30, 250),
            (40, 300), (50, 300), (60, 420), (70, 500),
        ]
        let rawEfforts = DistanceBestEfforts.bestEfforts(samples: raw)
        #expect(rawEfforts == DistanceBestEfforts.bestEfforts(samples: clamped))
        #expect(!rawEfforts.isEmpty)                                            // 400 m fits in 500 m
        #expect(rawEfforts.allSatisfy { $0.seconds > 0 && $0.seconds.isFinite })
    }

    // MARK: - Two-pointer vs brute force

    /// 500-sample seeded random walk (with deliberate backwards glitches):
    /// the O(n) two-pointer sweep must agree with the O(n²) reference on
    /// every standard target.
    @Test func twoPointerMatchesBruteForceOnRandomWalk() {
        var rng = SplitMix64(state: 0xF0F0_1234_5678_9ABC)
        var samples: [(t: Int, meters: Double)] = []
        var cumulative = 0.0
        for i in 0..<500 {
            cumulative += rng.nextDouble() * 12                                 // 0..12 m per 5 s tick
            // Every 17th sample, report a backwards GPS glitch in the raw data.
            let jitter = i % 17 == 0 ? -rng.nextDouble() * 8 : 0
            samples.append((t: i * 5, meters: max(0, cumulative + jitter)))
        }

        let efforts = DistanceBestEfforts.bestEfforts(samples: samples)
        #expect(!efforts.isEmpty)                                               // ~3 km walk covers 400 m+
        for target in DistanceBestEfforts.standardTargets {
            let reference = Self.bruteForceSeconds(samples: samples, target: target.meters)
            let fast = effort(efforts, target.meters)?.seconds
            let covered = samples.map(\.meters).max()! - samples.first!.meters
            if target.meters <= covered {
                #expect(fast != nil, "missing \(target.label)")
                #expect(reference != nil, "brute force missing \(target.label)")
                #expect(abs((fast ?? 0) - (reference ?? -1)) < 1e-6, "\(target.label) mismatch")
                #expect((fast ?? -1) > 0)
            } else {
                #expect(fast == nil, "unexpected \(target.label)")
            }
        }
    }

    // MARK: - Series convenience

    /// `fromSeries` must drop HR-only samples (meters == nil) rather than
    /// treating them as zero-distance points that would poison the walk.
    @Test func fromSeriesFiltersNilMeters() {
        let series = CardioSampleSeries(samples: [
            .init(t: 0, hr: 140, meters: 0),
            .init(t: 10, hr: 152),                       // HR-only bucket
            .init(t: 20, meters: 150),
            .init(t: 30, hr: 158),                       // HR-only bucket
            .init(t: 40, meters: 400),
            .init(t: 60, meters: 800),
        ])
        let viaSeries = DistanceBestEfforts.fromSeries(series)
        let direct = DistanceBestEfforts.bestEfforts(
            samples: [(t: 0, meters: 0), (t: 20, meters: 150), (t: 40, meters: 400), (t: 60, meters: 800)]
        )
        #expect(viaSeries == direct)
        #expect(effort(viaSeries, 400) != nil)
    }

    @Test func fromSeriesWithoutDistanceYieldsNoEfforts() {
        let hrOnly = CardioSampleSeries(samples: (0...30).map { .init(t: $0 * 10, hr: 150) })
        #expect(DistanceBestEfforts.fromSeries(hrOnly) == [])
        #expect(DistanceBestEfforts.fromSeries(CardioSampleSeries()) == [])
    }
}
