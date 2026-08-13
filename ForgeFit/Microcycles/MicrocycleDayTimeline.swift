import ForgeData
import Foundation

struct MicrocycleDayPresentation: Identifiable, Equatable {
    let date: Date
    let index: Int
    let status: MicrocycleDayStatus
    let routineMarkers: [String]
    let isToday: Bool

    var id: Date { date }
}

/// Builds each calendar day's logged state while keeping today's identity
/// independent from completion. Skipped days stay visibly unlogged as the
/// current-day marker advances with the window's calendar.
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
        return dates.map { day -> MicrocycleDayPresentation in
            let dayWorkouts = MicrocycleDayAssignmentService.dayWorkouts(
                on: day.date,
                in: window,
                workouts: workouts
            )
            let routineMarkers = MicrocycleRoutineMarker.markers(
                for: dayWorkouts.compactMap(\.workout.routineID),
                in: window.routines
            )
            let status: MicrocycleDayStatus
            if !dayWorkouts.isEmpty {
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
                routineMarkers: routineMarkers,
                isToday: calendar.isDate(day.date, inSameDayAs: now)
            )
        }
    }

    private static func calendar(for window: MicrocycleWindowModel) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: window.timeZoneIdentifier) ?? .current
        return calendar
    }
}
