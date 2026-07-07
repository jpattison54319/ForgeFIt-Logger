import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Generates, refreshes, and marks-viewed Wrapped reports.
///
/// Generation is launch/foreground-driven (no reliance on iOS background
/// execution): every call to `generateIfDue` is a cheap idempotent check —
/// reports are keyed by (type, year, month) and queried before insert, so
/// repeated calls, delayed launches days after the 1st, and timezone changes
/// can't create duplicates.
@MainActor
enum WrappedReportService {

    /// Pure calendar logic, separated so date/idempotency tests never touch
    /// SwiftData.
    enum WrappedSchedule {
        /// The month whose report should exist right now: always the previous
        /// calendar month (on July 1 — or any later July day — June is due).
        static func dueMonthStart(now: Date, calendar: Calendar) -> Date? {
            guard let thisMonthStart = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
            return calendar.date(byAdding: .month, value: -1, to: thisMonthStart)
        }

        /// The year whose report should exist right now — only non-nil in
        /// January (on Jan 1, 2027 the 2026 yearly is due).
        static func dueYear(now: Date, calendar: Calendar) -> Int? {
            guard calendar.component(.month, from: now) == 1 else { return nil }
            return calendar.component(.year, from: now) - 1
        }

        /// Reports generated early in a month can be missing late-syncing
        /// data (Health imports, watch workouts) — allow in-place payload
        /// refresh while `now` is within the first `refreshWindowDays` of
        /// the month after the reported period.
        static let refreshWindowDays = 4

        static func isInRefreshWindow(now: Date, calendar: Calendar) -> Bool {
            calendar.component(.day, from: now) <= refreshWindowDays
        }
    }

    /// Idempotent: generates the previous month's report (and previous year's
    /// in January) when missing; refreshes a just-generated report while in
    /// the early-month window. Returns newly created reports (for
    /// notification scheduling by the caller's UI layer).
    @discardableResult
    static func generateIfDue(
        in context: ModelContext,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WrappedReportModel] {
        let workouts = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let builder = WrappedBuilder(
            workouts: workouts,
            exercises: exercises,
            healthMetrics: HealthMetricsStore.shared.metrics,
            calendar: calendar
        )
        var created: [WrappedReportModel] = []

        if let monthStart = WrappedSchedule.dueMonthStart(now: now, calendar: calendar) {
            let year = calendar.component(.year, from: monthStart)
            let month = calendar.component(.month, from: monthStart)
            if let existing = fetchReport(type: "monthly", year: year, month: month, in: context) {
                if WrappedSchedule.isInRefreshWindow(now: now, calendar: calendar),
                   let payload = builder.buildMonth(starting: monthStart),
                   payload.encodedJSON() != existing.payloadJSON {
                    existing.payloadJSON = payload.encodedJSON()
                    existing.updatedAt = now
                    try? context.save()
                }
            } else if let payload = builder.buildMonth(starting: monthStart) {
                let interval = calendar.dateInterval(of: .month, for: monthStart)
                let report = WrappedReportModel(
                    userID: ForgeFitDemo.userID,
                    reportTypeRaw: "monthly",
                    year: year,
                    month: month,
                    generatedAt: now,
                    updatedAt: now,
                    payloadJSON: payload.encodedJSON(),
                    sourceRangeStart: interval?.start ?? monthStart,
                    sourceRangeEnd: interval?.end ?? monthStart
                )
                context.insert(report)
                try? context.save()
                created.append(report)
            }
        }

        if let dueYear = WrappedSchedule.dueYear(now: now, calendar: calendar),
           fetchReport(type: "yearly", year: dueYear, month: 0, in: context) == nil,
           let payload = builder.buildYear(dueYear) {
            var components = DateComponents()
            components.year = dueYear
            components.month = 1
            components.day = 1
            let yearStart = calendar.date(from: components) ?? now
            let interval = calendar.dateInterval(of: .year, for: yearStart)
            let report = WrappedReportModel(
                userID: ForgeFitDemo.userID,
                reportTypeRaw: "yearly",
                year: dueYear,
                month: 0,
                generatedAt: now,
                updatedAt: now,
                payloadJSON: payload.encodedJSON(),
                sourceRangeStart: interval?.start ?? yearStart,
                sourceRangeEnd: interval?.end ?? yearStart
            )
            context.insert(report)
            try? context.save()
            created.append(report)
        }

        return created
    }

    static func fetchReport(type: String, year: Int, month: Int, in context: ModelContext) -> WrappedReportModel? {
        var descriptor = FetchDescriptor<WrappedReportModel>(
            predicate: #Predicate {
                $0.reportTypeRaw == type && $0.year == year && $0.month == month && $0.deletedAt == nil
            }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Opening the report (any page) counts as viewed — the Home card keys
    /// off this; the report stays permanently reachable from Profile.
    static func markViewed(_ report: WrappedReportModel, in context: ModelContext, now: Date = Date()) {
        guard report.viewedAt == nil else { return }
        report.viewedAt = now
        report.updatedAt = now
        try? context.save()
    }

    /// Human title like "June Wrapped" / "2026 Wrapped".
    static func title(for report: WrappedReportModel, calendar: Calendar = .current) -> String {
        guard report.isMonthly else { return "\(report.year) Wrapped" }
        var components = DateComponents()
        components.year = report.year
        components.month = report.month
        components.day = 1
        let date = calendar.date(from: components) ?? Date()
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        return "\(date.formatted(style.month(.wide))) Wrapped"
    }
}
