import Foundation

/// Calendar-safe fixed-window math and deterministic routine completion.
public enum MicrocycleEngine {
    public enum Error: Swift.Error, Equatable {
        case invalidDuration
        case invalidTimeZone
        case dateBeforeAnchor
        case dateOverflow
    }

    public static func calendar(timeZoneIdentifier: String) throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw Error.invalidTimeZone
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func normalizedAnchor(
        _ date: Date,
        timeZoneIdentifier: String
    ) throws -> Date {
        try calendar(timeZoneIdentifier: timeZoneIdentifier).startOfDay(for: date)
    }

    public static func window(
        anchor: Date,
        durationDays: Int,
        containing date: Date,
        timeZoneIdentifier: String
    ) throws -> MicrocycleWindow {
        guard durationDays > 0 else { throw Error.invalidDuration }
        let calendar = try calendar(timeZoneIdentifier: timeZoneIdentifier)
        let normalizedAnchor = calendar.startOfDay(for: anchor)
        let normalizedDate = calendar.startOfDay(for: date)
        guard normalizedDate >= normalizedAnchor else { throw Error.dateBeforeAnchor }
        guard let elapsedDays = calendar.dateComponents(
            [.day],
            from: normalizedAnchor,
            to: normalizedDate
        ).day else {
            throw Error.dateOverflow
        }
        let index = elapsedDays / durationDays
        return try window(
            anchor: normalizedAnchor,
            durationDays: durationDays,
            index: index,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    public static func window(
        anchor: Date,
        durationDays: Int,
        index: Int,
        timeZoneIdentifier: String
    ) throws -> MicrocycleWindow {
        guard durationDays > 0 else { throw Error.invalidDuration }
        guard index >= 0 else { throw Error.dateBeforeAnchor }
        let calendar = try calendar(timeZoneIdentifier: timeZoneIdentifier)
        let normalizedAnchor = calendar.startOfDay(for: anchor)
        guard let startsAt = calendar.date(
            byAdding: .day,
            value: index * durationDays,
            to: normalizedAnchor
        ), let endsAt = calendar.date(
            byAdding: .day,
            value: durationDays,
            to: startsAt
        ) else {
            throw Error.dateOverflow
        }
        return MicrocycleWindow(index: index, startsAt: startsAt, endsAt: endsAt)
    }

    public static func progress(
        window: MicrocycleWindow,
        routines: [MicrocycleRoutineSnapshot],
        workouts: [MicrocycleWorkoutEvidence]
    ) -> MicrocycleProgress {
        let eligible = workouts
            .filter {
                $0.isCompleted
                    && !$0.isDeleted
                    && window.contains($0.startedAt)
                    && $0.routineID != nil
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        let progress = routines
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { routine in
                let match = eligible.first { $0.routineID == routine.id }
                return MicrocycleRoutineProgress(
                    routine: routine,
                    workoutID: match?.id,
                    completedAt: match?.startedAt
                )
            }
        return MicrocycleProgress(window: window, routines: progress)
    }
}
