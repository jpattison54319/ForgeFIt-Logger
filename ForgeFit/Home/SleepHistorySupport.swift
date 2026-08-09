import Foundation

nonisolated enum SleepHistorySupport {
    struct MonthSection: Identifiable, Sendable {
        let id: Date
        let title: String
        let nights: [RecoveryEngine.DailyHealthMetric]
    }

    static func filtered(
        _ metrics: [RecoveryEngine.DailyHealthMetric],
        searchText: String,
        selectedDate: Date?,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [RecoveryEngine.DailyHealthMetric] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return metrics.filter { metric in
            if let selectedDate,
               !calendar.isDate(metric.date, inSameDayAs: selectedDate) {
                return false
            }
            guard !trimmed.isEmpty else { return true }
            return searchTokens(for: metric.date, calendar: calendar, locale: locale)
                .contains { $0.localizedStandardContains(trimmed) }
        }
    }

    static func sections(
        for metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [MonthSection] {
        let grouped = Dictionary(grouping: metrics) { metric in
            calendar.dateInterval(of: .month, for: metric.date)?.start
                ?? calendar.startOfDay(for: metric.date)
        }
        return grouped.keys.sorted(by: >).map { month in
            MonthSection(
                id: month,
                title: formatted(
                    month,
                    style: .dateTime.month(.wide).year(),
                    calendar: calendar,
                    locale: locale
                ),
                nights: (grouped[month] ?? []).sorted { $0.date > $1.date }
            )
        }
    }

    private static func searchTokens(
        for date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> [String] {
        let components = calendar.dateComponents([.day, .month, .year], from: date)
        return [
            formatted(date, style: .dateTime.weekday(.wide).month(.wide).day().year(), calendar: calendar, locale: locale),
            formatted(date, style: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year(), calendar: calendar, locale: locale),
            formatted(date, style: .dateTime.month(.twoDigits).day(.twoDigits).year(), calendar: calendar, locale: locale),
            components.day.map(String.init) ?? "",
            components.year.map(String.init) ?? "",
        ]
    }

    private static func formatted(
        _ date: Date,
        style: Date.FormatStyle,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var resolved = style.locale(locale)
        resolved.timeZone = calendar.timeZone
        return date.formatted(resolved)
    }
}
