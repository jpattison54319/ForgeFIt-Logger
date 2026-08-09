import ForgeData
import Foundation

struct MicrocycleDayPresentation: Identifiable, Equatable {
    let date: Date
    let index: Int
    let status: MicrocycleDayStatus
    let isToday: Bool

    var id: Date { date }
}

/// Builds the calendar-day strip and advances its single ready marker as soon
/// as a workout or rest day completes. The marker is intentionally independent
/// of the wall-clock date: solid days are done; the outlined green day is next.
@MainActor
enum MicrocycleDayTimeline {
    static func days(
        in window: MicrocycleWindowModel,
        workouts: [WorkoutModel],
        restDays: [RestDayModel],
        now: Date = .now
    ) -> [MicrocycleDayPresentation] {
        let calendar = calendar(for: window)
        let total = max(1, calendar.dateComponents(
            [.day],
            from: window.startsAt,
            to: window.endsAt
        ).day ?? 1)
        let dates = (0..<total).compactMap { index -> (date: Date, index: Int)? in
            guard let date = calendar.date(
                byAdding: .day,
                value: index,
                to: window.startsAt
            ) else { return nil }
            return (date, index)
        }
        let base = dates.map { day -> MicrocycleDayPresentation in
            let status: MicrocycleDayStatus
            if !MicrocycleDayAssignmentService.dayWorkouts(
                on: day.date,
                in: window,
                workouts: workouts
            ).isEmpty {
                status = .trained
            } else if restDays.contains(where: {
                $0.deletedAt == nil && calendar.isDate($0.date, inSameDayAs: day.date)
            }) {
                status = .rest
            } else {
                status = .empty
            }
            return MicrocycleDayPresentation(
                date: day.date,
                index: day.index,
                status: status,
                isToday: calendar.isDate(day.date, inSameDayAs: now)
            )
        }

        let latestCompletedIndex = base.last {
            $0.status == .trained || $0.status == .rest
        }?.index
        let readyIndex = latestCompletedIndex.map { $0 + 1 } ?? 0

        return base.map { day in
            guard day.index == readyIndex, day.status == .empty else { return day }
            return MicrocycleDayPresentation(
                date: day.date,
                index: day.index,
                status: .ready,
                isToday: day.isToday
            )
        }
    }

    private static func calendar(for window: MicrocycleWindowModel) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: window.timeZoneIdentifier) ?? .current
        return calendar
    }
}
