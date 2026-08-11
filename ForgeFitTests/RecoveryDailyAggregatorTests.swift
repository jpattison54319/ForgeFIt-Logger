import Foundation
import Testing
@testable import ForgeFit

struct RecoveryDailyAggregatorTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func queryBoundsChunkLongHistoriesWithoutOneGiantPredicate() {
        #expect(HealthQueryBounds.allDayChunkWidth == 30 * 24 * 60 * 60)
        #expect(HealthQueryBounds.hrvSamplesPerChunk < HealthQueryBounds.oxygenSamplesPerChunk)
        #expect(HealthQueryBounds.nocturnalHRSamplesPerQuery == 300_000)
        #expect(HealthQueryBounds.chunkRanges(totalCount: 0, maximumCount: HealthQueryBounds.sleepWindowsPerQuery).isEmpty)
        #expect(HealthQueryBounds.chunkRanges(totalCount: 8, maximumCount: HealthQueryBounds.sleepWindowsPerQuery) == [0..<3, 3..<6, 6..<8])
        #expect(HealthQueryBounds.isTruncated(90, limit: 90))
        #expect(!HealthQueryBounds.isTruncated(89, limit: 90))
    }

    @Test func sleepWindowIndexPreservesInclusiveBoundarySemantics() {
        let first = NocturnalAggregator.SleepWindow(
            start: date(2026, 8, 8, 22),
            end: date(2026, 8, 9, 6),
            day: date(2026, 8, 9)
        )
        let second = NocturnalAggregator.SleepWindow(
            start: date(2026, 8, 9, 23),
            end: date(2026, 8, 10, 7),
            day: date(2026, 8, 10)
        )
        let index = NocturnalAggregator.SleepWindowIndex([second, first])

        #expect(index.window(containing: first.start) == first)
        #expect(index.window(containing: first.end) == first)
        #expect(index.window(containing: date(2026, 8, 9, 12)) == nil)
        #expect(index.window(containing: second.end) == second)
    }

    @Test func fixedDatasetProducesExpectedDailyMetricAndSources() {
        let day = date(2026, 8, 10)
        let start = date(2026, 8, 10, 0)
        let end = date(2026, 8, 10, 8)
        let window = NocturnalAggregator.SleepWindow(start: start, end: end, day: day)
        let hrvValues = [40.0, 50.0, 60.0, 70.0]
        let hrValues = [58, 57, 56, 55, 54, 53, 52]
        let hrv = hrvValues.enumerated().map { offset, value in
            let sampleDate = start.addingTimeInterval(TimeInterval(offset * 60 * 60))
            return (start: sampleDate, end: sampleDate, value: value, sourceBundleID: "watch")
        }
        let hr = hrValues.enumerated().map { offset, value in
            (date: start.addingTimeInterval(TimeInterval(offset * 30 * 60)), bpm: value, sourceBundleID: "watch")
        }
        let inputs = RecoveryDailyAggregator.SampleInputs(
            calendar: calendar,
            hrv: hrv,
            restingHR: [(start: day, end: day, value: 61, sourceBundleID: "phone")],
            respiratory: [(start: start, end: end, value: 14.5, sourceBundleID: "watch")],
            oxygen: [(start: start, end: end, value: 97.5, sourceBundleID: "watch")],
            asleepSegments: [(start: start, end: end, sourceBundleID: "watch")],
            allSleepSegments: [
                (start: start, end: start.addingTimeInterval(90 * 60), rawValue: 4),
                (start: start.addingTimeInterval(90 * 60), end: start.addingTimeInterval(180 * 60), rawValue: 5),
                (start: start.addingTimeInterval(180 * 60), end: start.addingTimeInterval(195 * 60), rawValue: 2),
            ],
            windows: [window],
            nocturnalHR: hr
        )

        let result = RecoveryDailyAggregator.daily(inputs)
        #expect(result.count == 1)
        let metric = result[0]
        #expect(metric.date == day)
        #expect(metric.hrvSDNN == 55)
        #expect(metric.restingHR == 61)
        #expect(metric.respiratoryRate == 14.5)
        #expect(metric.oxygenSaturationPercent == 97.5)
        #expect(metric.sleepTotalMinutes == 480)
        #expect(metric.hrvSourceBundleID == "watch")
        #expect(metric.sleepingHRSourceBundleID == "watch")
        #expect(metric.sleepStart == start)
        #expect(metric.sleepEnd == end)
        #expect(metric.sleepDeepMinutes == 90)
        #expect(metric.sleepREMMinutes == 90)
        #expect(metric.sleepAwakeMinutes == 15)
        #expect(metric.nocturnalHRV != nil)
        #expect(metric.sleepingHR == 55)
    }

    @Test func sevenHundredThirtyNightAggregationStaysBounded() async {
        let baseDay = date(2024, 1, 1)
        var windows: [NocturnalAggregator.SleepWindow] = []
        var hrv: [(start: Date, end: Date, value: Double, sourceBundleID: String)] = []
        var heartRate: [(date: Date, bpm: Int, sourceBundleID: String)] = []
        var asleep: [(start: Date, end: Date, sourceBundleID: String)] = []
        for offset in 0..<730 {
            let day = calendar.date(byAdding: .day, value: offset, to: baseDay)!
            let start = day
            let end = day.addingTimeInterval(8 * 60 * 60)
            windows.append(.init(start: start, end: end, day: day))
            asleep.append((start, end, "watch"))
            for hour in 0..<4 {
                let sample = start.addingTimeInterval(TimeInterval(hour * 60 * 60))
                hrv.append((sample, sample, Double(45 + hour), "watch"))
            }
            for halfHour in 0..<7 {
                heartRate.append((start.addingTimeInterval(TimeInterval(halfHour * 30 * 60)), 55 + halfHour % 2, "watch"))
            }
        }
        let inputs = RecoveryDailyAggregator.SampleInputs(
            calendar: calendar,
            hrv: hrv,
            restingHR: [],
            respiratory: [],
            oxygen: [],
            asleepSegments: asleep,
            allSleepSegments: [],
            windows: windows,
            nocturnalHR: heartRate
        )

        let clock = ContinuousClock()
        let started = clock.now
        let result = await CancellableDetachedWork.run(priority: .utility) {
            RecoveryDailyAggregator.daily(inputs)
        }
        let elapsed = started.duration(to: clock.now)

        #expect(result.count == 730)
        #expect(elapsed < .seconds(5), "730-night pure aggregation took \(elapsed)")
    }

    @Test func detachedWorkRunsOffMainAndForwardsCancellation() async {
        let ranOnMain = await CancellableDetachedWork.run {
            Self.currentThreadIsMain()
        }
        #expect(!ranOnMain)

        let task = Task {
            await CancellableDetachedWork.run {
                while !Task.isCancelled { await Task.yield() }
                return Task.isCancelled
            }
        }
        task.cancel()
        #expect(await task.value)
    }

    @Test func inFlightGateDeliversAndStopsAtMostOnce() {
        let gate = InFlightHealthQuery<String>(cancelledValue: "cancelled")
        var values: [String] = []
        var stops = 0
        #expect(gate.register(resume: { values.append($0) }, stop: { stops += 1 }))
        #expect(gate.beginQueryStart())
        gate.markQueryStarted()
        gate.cancel()
        gate.cancel()
        gate.finish("late")

        #expect(values == ["cancelled"])
        #expect(stops == 1)
    }

    @Test func inFlightGateNeverExecutesAfterEarlyCancellation() {
        let gate = InFlightHealthQuery<String>(cancelledValue: "cancelled")
        var values: [String] = []
        var stops = 0
        gate.cancel()

        #expect(!gate.register(resume: { values.append($0) }, stop: { stops += 1 }))
        #expect(!gate.beginQueryStart())
        #expect(values == ["cancelled"])
        #expect(stops == 0)
    }

    @Test func cancellationDuringQueryStartStopsOnlyAfterExecutionBegins() {
        let gate = InFlightHealthQuery<String>(cancelledValue: "cancelled")
        var values: [String] = []
        var stops = 0
        #expect(gate.register(resume: { values.append($0) }, stop: { stops += 1 }))
        #expect(gate.beginQueryStart())

        // Models cancellation after the caller has committed to execute but
        // before HealthKit's execute call has returned.
        gate.cancel()
        #expect(stops == 0)
        gate.markQueryStarted()

        #expect(values == ["cancelled"])
        #expect(stops == 1)
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    nonisolated private static func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }
}
