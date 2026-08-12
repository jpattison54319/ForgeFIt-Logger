import ForgeCore
import ForgeData
import Foundation
import SwiftData

nonisolated struct WrappedReportNotice: Sendable, Equatable {
    let title: String
}

/// Builds due reports on a private context. Wrapped can traverse a full year of
/// nested workout/set history; automatic launch maintenance must never do that
/// on MainActor merely because today is early in a month.
nonisolated struct WrappedReportWorker: Sendable {
    let modelContainer: ModelContainer

    func generateIfDue(
        healthMetrics: [RecoveryEngine.DailyHealthMetric],
        now: Date = .now,
        calendar: Calendar = .current,
        weightUnit: WeightUnit = .lb
    ) async -> [WrappedReportNotice] {
        let container = modelContainer
        let task = Task.detached(priority: .utility) { () -> [WrappedReportNotice] in
            guard !Task.isCancelled else { return [] }
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let reports = WrappedReportService.generateIfDue(
                in: context,
                healthMetrics: healthMetrics,
                now: now,
                calendar: calendar,
                weightUnit: weightUnit,
                coalesceAutomaticAttempt: true
            )
            guard !Task.isCancelled else {
                context.rollback()
                return []
            }
            return reports.map {
                WrappedReportNotice(
                    title: WrappedReportService.title(for: $0, calendar: calendar)
                )
            }
        }
        return await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
    }
}
