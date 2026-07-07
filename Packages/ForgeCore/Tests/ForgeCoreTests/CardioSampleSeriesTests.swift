import Foundation
import Testing
@testable import ForgeCore

struct CardioSampleSeriesTests {

    /// A steady run at a constant speed: best pace over any window equals the
    /// average pace, and windows longer than the session are unavailable.
    @Test func bestPaceIsConstantForSteadyRun() {
        // 1000 m over 300 s = 3.333 m/s => 300 s/km. Sample every 10 s.
        let speed = 1000.0 / 300.0
        let samples = stride(from: 0, through: 300, by: 10).map {
            CardioSampleSeries.Sample(t: $0, meters: Double($0) * speed)
        }
        let series = CardioSampleSeries(samples: samples)
        let pace60 = series.bestPaceSecPerKm(windowSeconds: 60)
        #expect(pace60 != nil)
        #expect(abs((pace60 ?? 0) - 300) < 15)
        // No window longer than the session.
        #expect(series.bestPaceSecPerKm(windowSeconds: 600) == nil)
    }

    @Test func bestPaceNilWithoutDistance() {
        let series = CardioSampleSeries(samples: (0...30).map { .init(t: $0 * 10, hr: 150) })
        #expect(series.bestPaceSecPerKm(windowSeconds: 60) == nil)
        #expect(series.hasDistance == false)
        #expect(series.hasHeartRate == true)
    }

    @Test func cumulativeMetersInterpolates() {
        let series = CardioSampleSeries(samples: [
            .init(t: 0, meters: 0),
            .init(t: 100, meters: 200),
        ])
        #expect(series.cumulativeMeters(at: 50) == 100)     // halfway
        #expect(series.cumulativeMeters(at: 0) == 0)
        #expect(series.cumulativeMeters(at: 200) == 200)    // clamps past end
    }

    /// Six clear 60 s surges over a low baseline should be detected as intervals.
    @Test func detectsClearIntervals() {
        var samples: [CardioSampleSeries.Sample] = []
        var t = 0
        for _ in 0..<6 { samples.append(.init(t: t, hr: 120)); t += 10 }   // warm-up
        for _ in 0..<6 {
            for _ in 0..<6 { samples.append(.init(t: t, hr: 175)); t += 10 }  // 60 s work
            for _ in 0..<6 { samples.append(.init(t: t, hr: 120)); t += 10 }  // 60 s recover
        }
        let segments = CardioSampleSeries.detectIntervals(in: CardioSampleSeries(samples: samples))
        #expect(segments != nil)
        #expect(segments?.filter { $0.kind == .work }.count == 6)
    }

    @Test func steadyRunIsNotChoppedIntoIntervals() {
        let samples = stride(from: 0, through: 900, by: 10).map { CardioSampleSeries.Sample(t: $0, hr: 145) }
        #expect(CardioSampleSeries.detectIntervals(in: CardioSampleSeries(samples: samples)) == nil)
    }

    @Test func tooShortSessionIsNotDetected() {
        let samples = (0...10).map { CardioSampleSeries.Sample(t: $0 * 10, hr: $0.isMultiple(of: 2) ? 120 : 175) }
        #expect(CardioSampleSeries.detectIntervals(in: CardioSampleSeries(samples: samples)) == nil)
    }

    @Test func jsonRoundTrips() {
        let series = CardioSampleSeries(samples: [
            .init(t: 0, hr: 120, meters: 0),
            .init(t: 10, hr: 130, meters: 33),
        ])
        let decoded = CardioSampleSeries.decode(from: series.encodedJSON())
        #expect(decoded == series)
        #expect(CardioSampleSeries.decode(from: nil) == nil)
        #expect(CardioSampleSeries().encodedJSON() == nil)   // empty => nothing to store
    }
}
