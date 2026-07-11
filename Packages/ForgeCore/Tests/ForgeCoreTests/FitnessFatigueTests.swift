import Foundation
import Testing
@testable import ForgeCore

struct FitnessFatigueTests {

    /// Fixed ISO8601 + UTC so results never drift with the runner's locale or DST.
    private static let utc: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var cal: Calendar { Self.utc }

    /// Day `offset` after 2026-01-01, at the given hour, in the fixed UTC calendar.
    private func day(_ offset: Int, hour: Int = 9) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 1
        comps.day = 1
        comps.hour = hour
        let base = Self.utc.date(from: comps)!
        return Self.utc.date(byAdding: .day, value: offset, to: base)!
    }

    // MARK: - Basics

    @Test func emptyInputProducesEmptySeries() {
        #expect(FitnessFatigue.series(dailyLoads: [], calendar: cal).isEmpty)
    }

    @Test func emptyInputProducesNilToday() {
        #expect(FitnessFatigue.today(dailyLoads: [], calendar: cal, now: day(0)) == nil)
    }

    @Test func singleLoadSplitsAcrossTimeConstants() {
        let points = FitnessFatigue.series(
            dailyLoads: [(date: day(0), load: 100)], calendar: cal
        )
        #expect(points.count == 1)
        let p = points[0]
        #expect(abs(p.ctl - 100.0 / 42.0) < 1e-9)
        #expect(abs(p.atl - 100.0 / 7.0) < 1e-9)
        // A fresh spike is all fatigue, no fitness yet: form must be negative.
        #expect(p.tsb < 0)
    }

    @Test func seriesDatesAreConsecutiveStartOfDays() {
        let loads = [(date: day(0, hour: 23), load: 10.0), (date: day(3, hour: 1), load: 10.0)]
        let points = FitnessFatigue.series(dailyLoads: loads, calendar: cal)
        #expect(points.count == 4)
        for (i, p) in points.enumerated() {
            #expect(p.date == cal.startOfDay(for: day(i)))
        }
    }

    // MARK: - Steady state and training phases

    @Test func constantLoadConvergesToLoad() {
        let loads = (0..<200).map { (date: day($0), load: 80.0) }
        let last = FitnessFatigue.series(dailyLoads: loads, calendar: cal).last!
        #expect(abs(last.ctl - 80) / 80 < 0.01)
        #expect(abs(last.atl - 80) / 80 < 0.01)
        #expect(abs(last.tsb) < 1.0)
    }

    @Test func taperTurnsFormPositive() {
        var loads = (0..<60).map { (date: day($0), load: 100.0) }
        loads += (60..<67).map { (date: day($0), load: 0.0) }
        let points = FitnessFatigue.series(dailyLoads: loads, calendar: cal)
        // Under constant loading fatigue leads fitness...
        #expect(points[59].tsb < 0)
        // ...and 7 zero days drain ATL much faster than CTL: form flips positive.
        #expect(points.last!.tsb > 0)
    }

    @Test func rampingLoadKeepsFormNegative() {
        var loads = (0..<30).map { (date: day($0), load: 50.0) }
        loads += (30..<44).map { (date: day($0), load: 100.0) }
        let last = FitnessFatigue.series(dailyLoads: loads, calendar: cal).last!
        #expect(last.tsb < 0)
    }

    @Test func fatigueRespondsFasterThanFitness() {
        // One spike, then a month of nothing: ATL must dominate immediately,
        // then decay away faster so TSB eventually crosses positive.
        let loads = [(date: day(0), load: 100.0), (date: day(30), load: 0.0)]
        let points = FitnessFatigue.series(dailyLoads: loads, calendar: cal)
        #expect(points.first!.atl > points.first!.ctl)
        #expect(points.first!.tsb < 0)
        #expect(points.last!.tsb > 0)
    }

    // MARK: - Bucketing and gaps

    @Test func gapDaysAreWalkedAsZeroLoad() {
        let loads = [(date: day(0), load: 100.0), (date: day(10), load: 100.0)]
        let points = FitnessFatigue.series(dailyLoads: loads, calendar: cal)
        #expect(points.count == 11)
        // Every silent day decays ATL by exactly (1 - 1/7).
        for i in 1..<10 {
            #expect(abs(points[i].atl - points[i - 1].atl * (6.0 / 7.0)) < 1e-9)
        }
        // The day-10 workout pushes fatigue back up.
        #expect(points[10].atl > points[9].atl)
    }

    @Test func sameDayLoadsSum() {
        let split = [(date: day(0, hour: 7), load: 60.0), (date: day(0, hour: 18), load: 40.0)]
        let single = [(date: day(0), load: 100.0)]
        let a = FitnessFatigue.series(dailyLoads: split, calendar: cal)
        let b = FitnessFatigue.series(dailyLoads: single, calendar: cal)
        #expect(a == b)
    }

    @Test func inputOrderDoesNotMatter() {
        let sorted = (0..<20).map { (date: day($0), load: Double($0 * 10)) }
        var shuffled = sorted
        shuffled.shuffle()
        let fromShuffled = FitnessFatigue.series(dailyLoads: shuffled, calendar: cal)
        let fromSorted = FitnessFatigue.series(dailyLoads: sorted, calendar: cal)
        #expect(fromShuffled == fromSorted)
    }

    // MARK: - today()

    @Test func todayDecaysThroughRestDaysToNow() {
        let loads = [(date: day(0), load: 100.0)]
        let now = day(7, hour: 15)
        let p = FitnessFatigue.today(dailyLoads: loads, calendar: cal, now: now)!
        #expect(p.date == cal.startOfDay(for: now))
        // Closed-form EWMA decay from the day-0 spike over 7 zero-load days.
        let expectedATL = (100.0 / 7.0) * pow(6.0 / 7.0, 7)
        let expectedCTL = (100.0 / 42.0) * pow(41.0 / 42.0, 7)
        #expect(abs(p.atl - expectedATL) < 1e-9)
        #expect(abs(p.ctl - expectedCTL) < 1e-9)
    }

    @Test func todayOnLastLoadDayMatchesSeriesTail() {
        let loads = (0..<5).map { (date: day($0), load: 50.0) }
        let tail = FitnessFatigue.series(dailyLoads: loads, calendar: cal).last!
        let p = FitnessFatigue.today(dailyLoads: loads, calendar: cal, now: day(4, hour: 23))!
        #expect(p == tail)
    }

    @Test func todayAfterAWeekOffShowsPositiveFormFromSteadyTraining() {
        // 100 days of steady training, then a full week off ending "now":
        // the honest readout is decayed numbers and a positive TSB (freshness).
        let loads = (0..<100).map { (date: day($0), load: 60.0) }
        let lastLogged = FitnessFatigue.series(dailyLoads: loads, calendar: cal).last!
        let p = FitnessFatigue.today(dailyLoads: loads, calendar: cal, now: day(106))!
        #expect(p.ctl < lastLogged.ctl)
        #expect(p.atl < lastLogged.atl)
        #expect(p.tsb > 0)
    }
}
