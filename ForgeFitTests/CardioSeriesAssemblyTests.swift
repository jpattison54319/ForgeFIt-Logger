import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

/// The single-pass series assembly must be output-identical to the old
/// per-bucket brute force it replaced (which was O(buckets × samples) —
/// ~2.3 M comparisons at the end of a 3 h run).
struct CardioSeriesAssemblyTests {

    /// The pre-optimization implementation, kept verbatim as the oracle.
    private func bruteForce(
        hr: [(t: Int, bpm: Int)],
        cumulative: [(t: Int, m: Double)],
        duration: Int,
        step: Int = 10
    ) -> [CardioSampleSeries.Sample] {
        func interpolate(_ points: [(t: Int, m: Double)], at t: Int) -> Double? {
            guard let first = points.first, let last = points.last else { return nil }
            if t <= first.t { return first.m }
            if t >= last.t { return last.m }
            for (a, b) in zip(points, points.dropFirst()) where t >= a.t && t <= b.t {
                guard b.t > a.t else { return a.m }
                return a.m + (b.m - a.m) * (Double(t - a.t) / Double(b.t - a.t))
            }
            return last.m
        }
        var samples: [CardioSampleSeries.Sample] = []
        for t in stride(from: 0, through: duration, by: step) {
            let bucket = hr.filter { $0.t >= t - step / 2 && $0.t < t + step / 2 }
            let bpm = bucket.isEmpty ? nil : Int((bucket.map { Double($0.bpm) }.reduce(0, +) / Double(bucket.count)).rounded())
            let meters = interpolate(cumulative, at: t)
            if bpm != nil || meters != nil {
                samples.append(.init(t: t, hr: bpm, meters: meters))
            }
        }
        return samples
    }

    private func expectEqualSeries(_ a: [CardioSampleSeries.Sample], _ b: [CardioSampleSeries.Sample]) {
        #expect(a.count == b.count)
        for (lhs, rhs) in zip(a, b) {
            #expect(lhs.t == rhs.t)
            #expect(lhs.hr == rhs.hr)
            if let lm = lhs.meters, let rm = rhs.meters {
                #expect(abs(lm - rm) < 0.0001)
            } else {
                #expect(lhs.meters == nil && rhs.meters == nil)
            }
        }
    }

    @Test func matchesBruteForceOnSeededRandomRun() {
        // Deterministic LCG — seeded randomness without Date()/random() so
        // the case reproduces exactly.
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }

        let duration = 3 * 3600
        // ~1 HR sample / 5 s with jitter and occasional gaps, deliberately unsorted.
        var hr: [(t: Int, bpm: Int)] = []
        var t = 0
        while t < duration {
            if next(10) != 0 {   // 10% dropout
                hr.append((t: t, bpm: 90 + next(80)))
            }
            t += 3 + next(5)
        }
        var generator = SeededGenerator(state: 42)
        hr.shuffle(using: &generator)
        // GPS route: cumulative distance every ~7 s.
        var cumulative: [(t: Int, m: Double)] = []
        var meters = 0.0
        var rt = next(20)
        while rt < duration {
            meters += Double(2 + next(4))
            cumulative.append((t: rt, m: meters))
            rt += 5 + next(5)
        }

        let fast = CardioSeriesService.assemble(hr: hr, cumulative: cumulative, duration: duration)
        let slow = bruteForce(hr: hr, cumulative: cumulative, duration: duration)
        expectEqualSeries(fast, slow)
        #expect(!fast.isEmpty)
    }

    @Test func edgeCases() {
        // Empty HR, route only.
        let route: [(t: Int, m: Double)] = [(t: 0, m: 0), (t: 30, m: 100), (t: 60, m: 180)]
        expectEqualSeries(
            CardioSeriesService.assemble(hr: [], cumulative: route, duration: 60),
            bruteForce(hr: [], cumulative: route, duration: 60)
        )
        // HR only, no route.
        let hr: [(t: Int, bpm: Int)] = [(t: 5, bpm: 120), (t: 15, bpm: 130), (t: 55, bpm: 150)]
        expectEqualSeries(
            CardioSeriesService.assemble(hr: hr, cumulative: [], duration: 60),
            bruteForce(hr: hr, cumulative: [], duration: 60)
        )
        // Single route point; duplicate route timestamps; samples outside range.
        let weird: [(t: Int, m: Double)] = [(t: 10, m: 5), (t: 10, m: 5), (t: 40, m: 50)]
        let strayHR: [(t: Int, bpm: Int)] = [(t: -5, bpm: 100), (t: 0, bpm: 110), (t: 61, bpm: 200)]
        expectEqualSeries(
            CardioSeriesService.assemble(hr: strayHR, cumulative: weird, duration: 60),
            bruteForce(hr: strayHR, cumulative: weird, duration: 60)
        )
        // Empty everything.
        #expect(CardioSeriesService.assemble(hr: [], cumulative: [], duration: 60).isEmpty)
    }
}

/// Minimal deterministic RandomNumberGenerator for the shuffle above.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
