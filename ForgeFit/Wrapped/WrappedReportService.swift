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
nonisolated enum WrappedReportService {
    static let lastAutomaticAttemptKey = "wrapped.lastAutomaticAttempt"
    typealias SaveOperation = (ModelContext) throws -> Void

    private struct GenerationOutcome {
        var createdIDs: [UUID] = []
        var touchedIDs: [UUID] = []
    }

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
        in sourceContext: ModelContext,
        healthMetrics: [RecoveryEngine.DailyHealthMetric] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        weightUnit: WeightUnit = .lb,
        coalesceAutomaticAttempt: Bool = false,
        save: SaveOperation = { try $0.save() }
    ) -> [WrappedReportModel] {
        guard !Task.isCancelled else { return [] }
        var stampedAutomaticAttempt = false
        var completedAutomaticAttempt = false
        defer {
            if stampedAutomaticAttempt,
               (!completedAutomaticAttempt || Task.isCancelled) {
                // Cancellation and failed persistence both leave this daily
                // job due; the next foreground pass owns the exact retry.
                UserDefaults.standard.removeObject(forKey: lastAutomaticAttemptKey)
            }
        }
        if coalesceAutomaticAttempt,
           let lastAttempt = UserDefaults.standard.object(
               forKey: lastAutomaticAttemptKey
           ) as? Date,
           calendar.isDate(lastAttempt, inSameDayAs: now) {
            return []
        }
        if coalesceAutomaticAttempt {
            // Stamp before computation so repeated foreground notifications
            // cannot queue duplicate full-history passes on the same day.
            UserDefaults.standard.set(now, forKey: lastAutomaticAttemptKey)
            stampedAutomaticAttempt = true
        }

        let transaction = ModelContext(sourceContext.container)
        transaction.autosaveEnabled = false
        let outcome: GenerationOutcome
        do {
            outcome = try generateDueReports(
                in: transaction,
                healthMetrics: healthMetrics,
                now: now,
                calendar: calendar,
                weightUnit: weightUnit
            )
            guard !Task.isCancelled else { return [] }
            if transaction.hasChanges {
                try save(transaction)
            }
            completedAutomaticAttempt = true
        } catch {
            return []
        }

        // Fetching touched rows after the private commit refreshes any cached
        // report in the caller while never saving its unrelated pending edits.
        let touched = Set(outcome.touchedIDs)
        if !touched.isEmpty {
            _ = try? sourceContext.fetch(FetchDescriptor<WrappedReportModel>())
                .filter { touched.contains($0.id) }
        }
        guard !outcome.createdIDs.isEmpty else { return [] }
        let fetchedByID = Dictionary(
            ((try? sourceContext.fetch(FetchDescriptor<WrappedReportModel>())) ?? [])
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return outcome.createdIDs.compactMap { fetchedByID[$0] }
    }

    private static func generateDueReports(
        in context: ModelContext,
        healthMetrics: [RecoveryEngine.DailyHealthMetric],
        now: Date,
        calendar: Calendar,
        weightUnit: WeightUnit
    ) throws -> GenerationOutcome {

        // Checking whether a keyed report exists is a tiny indexed fetch. Load
        // the full workout/library graph only when a report is actually missing
        // or inside its short refresh window.
        var cachedBuilder: WrappedBuilder?
        func builder() throws -> WrappedBuilder {
            if let cachedBuilder { return cachedBuilder }
            let value = WrappedBuilder(
                workouts: try context.fetch(FetchDescriptor<WorkoutModel>()),
                exercises: try context.fetch(FetchDescriptor<ExerciseLibraryModel>()),
                healthMetrics: healthMetrics,
                calendar: calendar,
                weightUnit: weightUnit
            )
            cachedBuilder = value
            return value
        }
        var outcome = GenerationOutcome()

        guard !Task.isCancelled else { return outcome }
        if let monthStart = WrappedSchedule.dueMonthStart(now: now, calendar: calendar) {
            let year = calendar.component(.year, from: monthStart)
            let month = calendar.component(.month, from: monthStart)
            if let existing = try fetchReport(type: "monthly", year: year, month: month, in: context) {
                if WrappedSchedule.isInRefreshWindow(now: now, calendar: calendar),
                   let payload = try builder().buildMonth(starting: monthStart),
                   !Task.isCancelled,
                   payload.encodedJSON() != existing.payloadJSON {
                    existing.payloadJSON = payload.encodedJSON()
                    existing.updatedAt = now
                    outcome.touchedIDs.append(existing.id)
                }
            } else if let payload = try builder().buildMonth(starting: monthStart) {
                guard !Task.isCancelled else { return outcome }
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
                outcome.createdIDs.append(report.id)
                outcome.touchedIDs.append(report.id)
            }
        }

        guard !Task.isCancelled else { return outcome }
        if let dueYear = WrappedSchedule.dueYear(now: now, calendar: calendar),
           try fetchReport(type: "yearly", year: dueYear, month: 0, in: context) == nil,
           let payload = try builder().buildYear(dueYear) {
            guard !Task.isCancelled else { return outcome }
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
            outcome.createdIDs.append(report.id)
            outcome.touchedIDs.append(report.id)
        }

        return outcome
    }

    private static func fetchReport(type: String, year: Int, month: Int, in context: ModelContext) throws -> WrappedReportModel? {
        var descriptor = FetchDescriptor<WrappedReportModel>(
            predicate: #Predicate {
                $0.reportTypeRaw == type && $0.year == year && $0.month == month && $0.deletedAt == nil
            }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Opening the report (any page) counts as viewed — the Home card keys
    /// off this; the report stays permanently reachable from Profile.
    @MainActor
    static func markViewed(
        _ report: WrappedReportModel,
        in context: ModelContext,
        now: Date = Date(),
        save: SaveOperation = { try $0.save() }
    ) throws {
        let reportID = report.id
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        guard let persistedReport = try transaction.fetch(
            FetchDescriptor<WrappedReportModel>(predicate: #Predicate { $0.id == reportID })
        ).first,
        persistedReport.deletedAt == nil else { return }
        guard persistedReport.viewedAt == nil else { return }
        persistedReport.viewedAt = now
        persistedReport.updatedAt = now
        try save(transaction)
        _ = try context.fetch(
            FetchDescriptor<WrappedReportModel>(predicate: #Predicate { $0.id == reportID })
        ).first
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
