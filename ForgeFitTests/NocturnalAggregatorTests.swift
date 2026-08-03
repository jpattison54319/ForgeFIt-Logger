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

    @Test func timeBalancedMediansIgnoreDaytimeSamples() throws {
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: [(start: d(1, 1, 23, 0), end: d(1, 2, 6, 30))], calendar: cal)
        let hrv: [(date: Date, value: Double)] = [
            (d(1, 2, 0, 0), 60), (d(1, 2, 1, 0), 70),
            (d(1, 2, 4, 0), 80), (d(1, 2, 6, 0), 90),
            (d(1, 2, 12, 0), 40),                        // daytime → ignored
        ]
        let hr: [(date: Date, bpm: Int)] = [
            (d(1, 2, 0, 0), 55), (d(1, 2, 0, 30), 56),
            (d(1, 2, 1, 0), 57), (d(1, 2, 2, 0), 59),
            (d(1, 2, 3, 0), 60), (d(1, 2, 4, 0), 61),
            (d(1, 2, 14, 0), 90),                        // daytime → ignored
        ]
        let nightly = NocturnalAggregator.nightly(windows: windows, hrv: hrv, hr: hr)
        let day = d(1, 2, 0, 0)
        let value = try #require(nightly[day]?.hrv)
        #expect(abs(value - sqrt(70 * 80)) < 0.001)
        #expect(nightly[day]?.sleepingHR == 58)
        #expect(nightly[day]?.hrvSampleCount == 4)
        #expect(nightly[day]?.hrvOccupiedBinCount == 4)
    }

    @Test func noSleepWindowsYieldsNothing() {
        #expect(NocturnalAggregator.windows(fromAsleepSegments: [], calendar: cal).isEmpty)
        #expect(NocturnalAggregator.nightly(windows: [], hrv: [(Date(), 50)], hr: [(Date(), 60)]).isEmpty)
    }

    @Test func sixDistributedHalfHourBinsYieldSleepingHR() {
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: [(start: d(1, 1, 23, 0), end: d(1, 2, 6, 30))], calendar: cal)
        let hr: [(date: Date, bpm: Int)] = [
            (d(1, 2, 0, 0), 54), (d(1, 2, 0, 30), 52), (d(1, 2, 1, 0), 50),
            (d(1, 2, 2, 0), 52), (d(1, 2, 3, 0), 57), (d(1, 2, 4, 0), 56),
        ]
        let nightly = NocturnalAggregator.nightly(windows: windows, hrv: [], hr: hr)
        let day = d(1, 2, 0, 0)
        #expect(nightly[day]?.sleepingHR == 53)
        #expect(nightly[day]?.sleepingHROccupiedBinCount == 6)
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
        #expect(nightly[day]?.hrv == nil)
    }

    @Test func denseClusterCannotMasqueradeAsWholeNightHRV() {
        let windows = NocturnalAggregator.windows(
            fromAsleepSegments: [(start: d(1, 1, 23, 0), end: d(1, 2, 6, 30))], calendar: cal)
        let hrv = stride(from: 0, through: 50, by: 5).map {
            (d(1, 2, 1, $0), 70.0)
        }

        let nightly = NocturnalAggregator.nightly(windows: windows, hrv: hrv, hr: [])

        #expect(nightly[d(1, 2, 0, 0)]?.hrv == nil)
    }
}
