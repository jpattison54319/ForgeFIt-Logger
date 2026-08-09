import Foundation

nonisolated enum CalendarDayHealthSupport {
    static func metric(
        for day: Date,
        in metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> RecoveryEngine.DailyHealthMetric? {
        metrics.last { calendar.isDate($0.date, inSameDayAs: day) }
    }

    static func assessment(
        for day: Date,
        in metrics: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> HealthRangeAssessment {
        guard metric(for: day, in: metrics, calendar: calendar) != nil else {
            return HealthRangeAssessment(readings: [])
        }
        let key = calendar.startOfDay(for: day)
        return HealthRangeAssessment.make(metrics: metrics.filter {
            calendar.startOfDay(for: $0.date) <= key
        }, calendar: calendar)
    }
}
