import Foundation
import Testing
@testable import ForgeFit

struct SleepHistorySupportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, minutes: Int = 480) -> RecoveryEngine.DailyHealthMetric {
        RecoveryEngine.DailyHealthMetric(
            date: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!,
            sleepTotalMinutes: minutes
        )
    }

    @Test func textSearchMatchesMonthDayYearAndWeekday() {
        let nights = [day(2026, 8, 9), day(2025, 12, 25)]
        let locale = Locale(identifier: "en_US")

        #expect(SleepHistorySupport.filtered(nights, searchText: "August", selectedDate: nil, calendar: calendar, locale: locale).count == 1)
        #expect(SleepHistorySupport.filtered(nights, searchText: "2025", selectedDate: nil, calendar: calendar, locale: locale).count == 1)
        #expect(SleepHistorySupport.filtered(nights, searchText: "Sunday", selectedDate: nil, calendar: calendar, locale: locale).count == 1)
    }

    @Test func exactDateFilterDoesNotReturnAnAdjacentNight() {
        let selected = day(2026, 8, 9).date
        let nights = [day(2026, 8, 9), day(2026, 8, 8)]
        let result = SleepHistorySupport.filtered(
            nights,
            searchText: "",
            selectedDate: selected,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )
        #expect(result.map(\.date) == [selected])
    }

    @Test func historyGroupsNewestMonthsAndNightsFirst() {
        let nights = [day(2025, 12, 25), day(2026, 8, 8), day(2026, 8, 9)]
        let sections = SleepHistorySupport.sections(
            for: nights,
            calendar: calendar,
            locale: Locale(identifier: "en_US")
        )
        #expect(sections.map(\.title) == ["August 2026", "December 2025"])
        #expect(sections.first?.nights.map(\.date) == [day(2026, 8, 9).date, day(2026, 8, 8).date])
    }
}

private struct SleepHistoryLoaderStub: SleepHistoryLoading {
    let metrics: [RecoveryEngine.DailyHealthMetric]
    func load() async -> [RecoveryEngine.DailyHealthMetric] { metrics }
}

private nonisolated struct ThreadReportingSleepHistoryLoader: SleepHistoryLoading {
    func load() async -> [RecoveryEngine.DailyHealthMetric] {
        [RecoveryEngine.DailyHealthMetric(
            date: Date(timeIntervalSince1970: 1_800_000_000),
            sleepTotalMinutes: 480,
            source: Thread.isMainThread ? "main" : "worker"
        )]
    }
}

@MainActor
struct SleepHistoryStoreTests {
    @Test func storeKeepsTheCompleteHistoryRatherThanSevenNights() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let metrics = (0..<20).map { offset in
            RecoveryEngine.DailyHealthMetric(
                date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                sleepTotalMinutes: 420 + offset
            )
        }
        let store = SleepHistoryStore(worker: SleepHistoryLoaderStub(metrics: metrics))
        await store.load(recentMetrics: [])
        #expect(store.nights.count == 20)
        #expect(store.nights.first?.date == today)
    }

    @Test func fullHistoryLoaderNeverRunsOnTheMainThread() async {
        let store = SleepHistoryStore(worker: ThreadReportingSleepHistoryLoader())

        await store.load(recentMetrics: [])

        #expect(store.nights.first?.source == "worker")
    }

    @Test func sleepOnlyHistoryAppliesCorrectionsWithoutInventingPartialWear() {
        let suiteName = "SleepHistoryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let store = SleepOverrideStore(defaults: defaults, calendar: calendar)
        let metrics = (0..<12).map { offset in
            RecoveryEngine.DailyHealthMetric(
                date: calendar.date(byAdding: .day, value: -offset, to: today)!,
                sleepTotalMinutes: offset == 0 ? 120 : 480
            )
        }
        store.set(.manual(minutes: 450), for: today)

        let processed = store.processHistory(metrics)
        let latest = processed.last { calendar.isDate($0.date, inSameDayAs: today) }
        #expect(latest?.sleepTotalMinutes == 450)
        #expect(latest?.sleepOverrideStatus == .edited)
        #expect(latest?.sleepLikelyPartial == false)
    }
}

private nonisolated struct ThreadReportingCalendarHealthLoader: CalendarHealthLoading {
    func load(endingAt end: Date) async -> [RecoveryEngine.DailyHealthMetric] {
        [RecoveryEngine.DailyHealthMetric(
            date: end,
            hrvSDNN: 60,
            source: Thread.isMainThread ? "main" : "worker"
        )]
    }
}

@MainActor
struct CalendarHealthStoreTests {
    @Test func selectedDayLoaderNeverRunsOnTheMainThread() async {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let store = CalendarHealthStore(
            worker: ThreadReportingCalendarHealthLoader(),
            calendar: calendar
        )

        await store.load(day: day, fallback: [])

        #expect(store.metrics(for: day, fallback: []).first?.source == "worker")
    }
}

struct CalendarDayHealthSupportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func missingSelectedDayDoesNotBorrowThePreviousReading() {
        let selected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 9))!
        let previous = calendar.date(byAdding: .day, value: -1, to: selected)!
        let metric = RecoveryEngine.DailyHealthMetric(date: previous, hrvSDNN: 60)

        #expect(CalendarDayHealthSupport.metric(for: selected, in: [metric], calendar: calendar) == nil)
        #expect(CalendarDayHealthSupport.assessment(for: selected, in: [metric], calendar: calendar).readings.isEmpty)
    }

    @Test func futureMetricsAreExcludedFromHistoricalAssessment() throws {
        let selected = calendar.date(from: DateComponents(year: 2026, month: 8, day: 9))!
        var metrics = (1...45).map { offset in
            RecoveryEngine.DailyHealthMetric(
                date: calendar.date(byAdding: .day, value: -offset, to: selected)!,
                hrvSDNN: 60,
                source: "test"
            )
        }
        metrics.append(RecoveryEngine.DailyHealthMetric(date: selected, hrvSDNN: 60, source: "test"))
        metrics.append(RecoveryEngine.DailyHealthMetric(
            date: calendar.date(byAdding: .day, value: 1, to: selected)!,
            hrvSDNN: 200,
            source: "test"
        ))

        let assessment = CalendarDayHealthSupport.assessment(for: selected, in: metrics, calendar: calendar)
        let hrv = try #require(assessment.readings.first { $0.id == "hrv" })
        #expect(hrv.value == 60)
        #expect(hrv.status == .typical)
    }
}
