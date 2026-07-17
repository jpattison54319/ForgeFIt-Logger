import Foundation
import Testing
@testable import ForgeCore

struct RollingPaceWindowTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func steadyFeedReportsItsPace() {
        var window = RollingPaceWindow()
        // 5:00 /km = 300 s/km ≈ 3.333 m/s, sampled each second for 30 s.
        for second in 0...30 {
            window.add(meters: Double(second) * (1000.0 / 300.0), at: start.addingTimeInterval(Double(second)))
        }
        let pace = window.paceSecondsPerKm()
        #expect(pace != nil && abs(pace! - 300) < 1)
    }

    @Test func refusesToReportOnScraps() {
        var window = RollingPaceWindow()
        window.add(meters: 0, at: start)
        window.add(meters: 5, at: start.addingTimeInterval(5))
        // 5 m over 5 s: under both honesty floors.
        #expect(window.paceSecondsPerKm() == nil)
    }

    @Test func windowTracksSurgesNotHistory() {
        var window = RollingPaceWindow(window: 30)
        // 60 s of slow jog (6:00 /km ≈ 2.78 m/s)…
        var meters = 0.0
        for second in 0...60 {
            meters = Double(second) * (1000.0 / 360.0)
            window.add(meters: meters, at: start.addingTimeInterval(Double(second)))
        }
        // …then 30 s of hard surge (4:00 /km ≈ 4.17 m/s).
        for second in 61...90 {
            meters += 1000.0 / 240.0
            window.add(meters: meters, at: start.addingTimeInterval(Double(second)))
        }
        let pace = window.paceSecondsPerKm()
        // Only the surge remains in the 30 s window.
        #expect(pace != nil && abs(pace! - 240) < 5)
    }

    @Test func stoppingGoesQuietInsteadOfDivergingToInfinity() {
        var window = RollingPaceWindow(window: 30)
        for second in 0...30 {
            window.add(meters: Double(second) * 3, at: start.addingTimeInterval(Double(second)))
        }
        #expect(window.paceSecondsPerKm() != nil)
        // No samples for over a window → stopped, not "slow".
        #expect(window.paceSecondsPerKm(asOf: start.addingTimeInterval(120)) == nil)
    }

    @Test func nonMonotonicFeedResetsInsteadOfEmittingNegativeSplits() {
        var window = RollingPaceWindow()
        for second in 0...20 {
            window.add(meters: Double(second) * 3, at: start.addingTimeInterval(Double(second)))
        }
        // Source switch: cumulative distance drops (GPS → watch handoff).
        window.add(meters: 10, at: start.addingTimeInterval(21))
        #expect(window.paceSecondsPerKm() == nil)
    }
}
