import Foundation
import Testing
@testable import ForgeFit

struct NocturnalAggregatorTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func d(_ mo: Int, _ day: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: mo, day: day, hour: h, minute: mi))!
    }

    @Test func stitchesBriefAwakeningsIntoOneWindow() {
        let segments = [
            (start: d(1, 1, 23, 0), end: d(1, 2, 2, 0)),
            (start: d(1, 2, 2, 10), end: d(1, 2, 6, 30)),   // 10-min gap → same night
        ]
        let windows = NocturnalAggregator.windows(fromAsleepSegments: segments, calendar: cal)
        #expect(windows.count == 1)
        #expect(windows.first?.start == d(1, 1, 23, 0))
        #expect(windows.first?.end == d(1, 2, 6, 30))
        // Attributed to the morning it ended.
        #expect(windows.first?.day == d(1, 2, 0, 0))
    }

    @Test func keepsSeparateNightsApart() {
        let segments = [
            (start: d(1, 1, 23, 0), end: d(1, 2, 6, 30)),
            (start: d(1, 2, 22, 30), end: d(1, 3, 6, 0)),
        ]
        #expect(NocturnalAggregator.windows(fromAsleepSegments: segments, calendar: cal).count == 2)
    }

    @Test func averagesNocturnalSamplesAndIgnoresDaytime() {
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: [(start: d(1, 1, 23, 0), end: d(1, 2, 6, 30))], calendar: cal)
        let hrv: [(date: Date, value: Double)] = [
            (d(1, 2, 0, 0), 60), (d(1, 2, 4, 0), 80),   // in-window → mean 70
            (d(1, 2, 12, 0), 40),                        // daytime → ignored
        ]
        let hr: [(date: Date, bpm: Int)] = [
            (d(1, 2, 1, 0), 55), (d(1, 2, 3, 0), 58), (d(1, 2, 5, 0), 61), // in-window → mean 58
            (d(1, 2, 14, 0), 90),                        // daytime → ignored
        ]
        let nightly = NocturnalAggregator.nightly(windows: windows, hrv: hrv, hr: hr)
        let day = d(1, 2, 0, 0)
        #expect(nightly[day]?.hrv == 70)
        #expect(nightly[day]?.sleepingHR == 58)
        #expect(nightly[day]?.hrvSampleCount == 2)
    }

    @Test func noSleepWindowsYieldsNothing() {
        #expect(NocturnalAggregator.windows(fromAsleepSegments: [], calendar: cal).isEmpty)
        #expect(NocturnalAggregator.nightly(windows: [], hrv: [(Date(), 50)], hr: [(Date(), 60)]).isEmpty)
    }

    /// Garmin-through-Apple-Health density: smart recording can be a sample
    /// every ~10–15 minutes — sparse, but still a valid sleeping HR.
    @Test func sparseSmartRecordingSamplesStillYieldSleepingHR() {
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: [(start: d(1, 1, 23, 0), end: d(1, 2, 6, 30))], calendar: cal)
        // One reading every ~90 min across the night, no HRV (Garmin Connect
        // doesn't sync it).
        let hr: [(date: Date, bpm: Int)] = [
            (d(1, 2, 0, 0), 54), (d(1, 2, 1, 30), 52), (d(1, 2, 3, 0), 50),
            (d(1, 2, 4, 30), 52), (d(1, 2, 6, 0), 57),
        ]
        let nightly = NocturnalAggregator.nightly(windows: windows, hrv: [], hr: hr)
        let day = d(1, 2, 0, 0)
        #expect(nightly[day]?.sleepingHR == 53)
        #expect(nightly[day]?.hrv == nil)
    }

    /// A single overnight reading is a spot value, not a sleeping HR — one
    /// spurious sample (restless moment, bad contact) must not define the
    /// night.
    @Test func belowMinimumSamplesYieldsNoSleepingHR() {
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: [(start: d(1, 1, 23, 0), end: d(1, 2, 6, 30))], calendar: cal)
        let hr: [(date: Date, bpm: Int)] = [(d(1, 2, 2, 0), 95), (d(1, 2, 3, 0), 96)]
        let nightly = NocturnalAggregator.nightly(windows: windows, hrv: [(d(1, 2, 1, 0), 62)], hr: hr)
        let day = d(1, 2, 0, 0)
        #expect(nightly[day]?.sleepingHR == nil)
        // HRV is not gated by the HR floor.
        #expect(nightly[day]?.hrv == 62)
    }
}
