import ForgeCore
import ForgeData
import Foundation

/// Read-only reconstruction of what belonged to a tracking run before it
/// ended. Live tracking keeps using `MicrocycleTrackingService`; this layer
/// adds an as-of boundary so later workouts cannot rewrite a stopped run.
@MainActor
enum MicrocycleHistoryPresentation {
    static func hasStoppedRun(_ trackings: [MicrocycleTrackingModel]) -> Bool {
        trackings.contains {
            $0.deletedAt == nil && ($0.endedAt != nil || $0.stateRaw == "ended")
        }
    }

    static func runs(
        trackings: [MicrocycleTrackingModel],
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        now: Date = .now
    ) -> [MicrocycleHistoryRunPresentation] {
        let windowsByTrackingID = Dictionary(grouping: windows.filter {
            $0.deletedAt == nil
        }, by: \.trackingID)

        return trackings
            .filter { $0.deletedAt == nil }
            .map { tracking in
                let endedAt = effectiveEndedAt(for: tracking)
                let trackingWindows = windowsByTrackingID[tracking.id] ?? []
                let presentedWindows = trackingWindows.compactMap { window in
                    windowPresentation(
                        tracking: tracking,
                        window: window,
                        windows: trackingWindows,
                        workouts: workouts,
                        now: now
                    )
                }
                .sorted { $0.cycleNumber > $1.cycleNumber }
                return MicrocycleHistoryRunPresentation(
                    trackingID: tracking.id,
                    folderName: tracking.folderName,
                    startsAt: trackingWindows.map(\.startsAt).min() ?? tracking.anchorDate,
                    endedAt: endedAt,
                    durationDays: tracking.durationDays,
                    isActive: tracking.isActive || tracking.needsAttention,
                    windows: presentedWindows
                )
            }
            .sorted { lhs, rhs in
                let lhsActivity = lhs.endedAt ?? now
                let rhsActivity = rhs.endedAt ?? now
                if lhsActivity != rhsActivity { return lhsActivity > rhsActivity }
                return lhs.trackingID.uuidString > rhs.trackingID.uuidString
            }
    }

    static func windowPresentation(
        tracking: MicrocycleTrackingModel,
        window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        now: Date = .now
    ) -> MicrocycleHistoryWindowPresentation? {
        guard tracking.deletedAt == nil,
              window.deletedAt == nil,
              window.trackingID == tracking.id else { return nil }

        let stoppedAt = effectiveEndedAt(for: tracking)
        let asOf = stoppedAt ?? now
        let startedBeforeCutoff = stoppedAt == nil
            ? window.startsAt <= asOf
            : window.startsAt < asOf
        guard startedBeforeCutoff else { return nil }
        let totalDays = MicrocycleTrackingService.windowDurationDays(for: window)
        let state: MicrocycleHistoryWindowState
        let visibleEndsAt: Date
        if let stoppedAt, stoppedAt < window.endsAt {
            let stoppedDay = stoppedDayNumber(
                endedAt: stoppedAt,
                window: window,
                totalDays: totalDays
            )
            state = .stopped(day: stoppedDay, total: totalDays)
            visibleEndsAt = max(
                window.startsAt,
                min(stoppedAt.addingTimeInterval(-1), window.endsAt.addingTimeInterval(-1))
            )
        } else if (tracking.isActive || tracking.needsAttention),
                  window.startsAt <= now,
                  now < window.endsAt {
            state = .inProgress(
                day: MicrocycleTrackingService.dayNumber(for: window, now: now),
                total: totalDays
            )
            visibleEndsAt = window.endsAt
        } else {
            state = .finished
            visibleEndsAt = window.endsAt
        }

        return MicrocycleHistoryWindowPresentation(
            trackingID: tracking.id,
            windowID: window.id,
            cycleNumber: window.index + 1,
            startsAt: window.startsAt,
            visibleEndsAt: visibleEndsAt,
            scheduledEndsAt: window.endsAt,
            state: state,
            progress: progress(
                tracking: tracking,
                window: window,
                windows: windows,
                workouts: workouts,
                now: now
            )
        )
    }

    static func days(
        tracking: MicrocycleTrackingModel,
        window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        restDays: [RestDayModel],
        now: Date = .now
    ) -> [MicrocycleDayPresentation] {
        guard let calendar = try? MicrocycleEngine.calendar(
            timeZoneIdentifier: window.timeZoneIdentifier
        ) else { return [] }

        let totalDays = MicrocycleTrackingService.windowDurationDays(for: window)
        let visibleDayCount = effectiveEndedAt(for: tracking).flatMap { endedAt in
            endedAt < window.endsAt
                ? stoppedDayNumber(endedAt: endedAt, window: window, totalDays: totalDays)
                : nil
        } ?? totalDays
        let asOf = cutoff(for: tracking, now: now)
        let eligibleRestDays = restDays.filter {
            $0.deletedAt == nil && $0.createdAt <= asOf
        }
        let workoutsByDay = Dictionary(grouping: datedDayWorkouts(
            tracking: tracking,
            windows: windows,
            workouts: workouts,
            now: now
        )) { record in
            calendar.startOfDay(for: record.effectiveDate)
        }

        return (0..<visibleDayCount).compactMap { index in
            guard let date = calendar.date(
                byAdding: .day,
                value: index,
                to: window.startsAt
            ) else { return nil }
            let dayWorkouts = workoutsByDay[calendar.startOfDay(for: date)] ?? []
            let markers = MicrocycleRoutineMarker.markers(
                for: dayWorkouts.compactMap(\.record.workout.routineID),
                in: window.routines
            )
            let status: MicrocycleDayStatus
            if !dayWorkouts.isEmpty {
                status = .trained
            } else if eligibleRestDays.contains(where: {
                calendar.isDate($0.date, inSameDayAs: date)
            }) {
                status = .rest
            } else {
                status = .empty
            }
            return MicrocycleDayPresentation(
                date: date,
                index: index,
                status: status,
                routineMarkers: markers,
                isToday: (tracking.isActive || tracking.needsAttention)
                    && calendar.isDate(date, inSameDayAs: now)
            )
        }
    }

    static func dayWorkouts(
        on date: Date,
        tracking: MicrocycleTrackingModel,
        window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        now: Date = .now
    ) -> [MicrocycleHistoryDayWorkout] {
        guard let calendar = try? MicrocycleEngine.calendar(
            timeZoneIdentifier: window.timeZoneIdentifier
        ) else { return [] }
        let selectedDay = calendar.startOfDay(for: date)
        return datedDayWorkouts(
            tracking: tracking,
            windows: windows,
            workouts: workouts,
            now: now
        )
        .filter {
            calendar.isDate($0.effectiveDate, inSameDayAs: selectedDay)
        }
        .map(\.record)
        .sorted {
            if $0.workout.startedAt != $1.workout.startedAt {
                return $0.workout.startedAt < $1.workout.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private struct DatedDayWorkout {
        let record: MicrocycleHistoryDayWorkout
        let effectiveDate: Date
    }

    private static func datedDayWorkouts(
        tracking: MicrocycleTrackingModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        now: Date
    ) -> [DatedDayWorkout] {
        let asOf = cutoff(for: tracking, now: now)
        let assignments = effectiveAssignments(
            trackingID: tracking.id,
            windows: windows,
            asOf: asOf
        )
        return workouts.compactMap { workout in
            guard isEligible(workout, asOf: asOf) else { return nil }
            let assignment = assignments[workout.id]?.assignment
            return DatedDayWorkout(
                record: MicrocycleHistoryDayWorkout(
                    workout: workout,
                    assignment: assignment
                ),
                effectiveDate: assignment?.day ?? workout.startedAt
            )
        }
    }

    private static func progress(
        tracking: MicrocycleTrackingModel,
        window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        now: Date
    ) -> MicrocycleProgress {
        let asOf = cutoff(for: tracking, now: now)
        let evidenceEndsAt = min(window.endsAt, asOf)
        let domainWindow = MicrocycleWindow(
            index: window.index,
            startsAt: window.startsAt,
            endsAt: max(window.startsAt, evidenceEndsAt)
        )
        let assignments = effectiveAssignments(
            trackingID: tracking.id,
            windows: windows,
            asOf: asOf
        )
        let evidence = workouts.map { workout in
            MicrocycleWorkoutEvidence(
                id: workout.id,
                routineID: workout.routineID,
                startedAt: assignments[workout.id]?.assignment.day ?? workout.startedAt,
                isCompleted: isEligible(workout, asOf: asOf),
                isDeleted: workout.deletedAt != nil
            )
        }
        return MicrocycleEngine.progress(
            window: domainWindow,
            routines: window.routines,
            workouts: evidence
        )
    }

    private static func stoppedDayNumber(
        endedAt: Date,
        window: MicrocycleWindowModel,
        totalDays: Int
    ) -> Int {
        guard let calendar = try? MicrocycleEngine.calendar(
            timeZoneIdentifier: window.timeZoneIdentifier
        ) else { return 1 }
        let inclusiveStop = max(
            window.startsAt,
            min(endedAt.addingTimeInterval(-1), window.endsAt.addingTimeInterval(-1))
        )
        let stopDay = calendar.startOfDay(for: inclusiveStop)
        let elapsed = calendar.dateComponents(
            [.day],
            from: window.startsAt,
            to: stopDay
        ).day ?? 0
        return min(max(elapsed + 1, 1), totalDays)
    }

    private static func isEligible(_ workout: WorkoutModel, asOf: Date) -> Bool {
        guard workout.deletedAt == nil,
              workout.createdAt <= asOf,
              let endedAt = workout.endedAt else { return false }
        return endedAt <= asOf
    }

    static func cutoff(
        for tracking: MicrocycleTrackingModel,
        now: Date = .now
    ) -> Date {
        effectiveEndedAt(for: tracking) ?? now
    }

    private static func effectiveEndedAt(
        for tracking: MicrocycleTrackingModel
    ) -> Date? {
        if let endedAt = tracking.endedAt { return endedAt }
        return tracking.stateRaw == "ended" ? tracking.updatedAt : nil
    }

    private struct EffectiveAssignment {
        let assignment: MicrocycleDayAssignment
        let windowID: UUID
    }

    private static func effectiveAssignments(
        trackingID: UUID,
        windows: [MicrocycleWindowModel],
        asOf: Date
    ) -> [UUID: EffectiveAssignment] {
        var result: [UUID: EffectiveAssignment] = [:]
        for window in windows where window.trackingID == trackingID && window.deletedAt == nil {
            for assignment in window.dayAssignments where assignment.assignedAt <= asOf {
                let existing = result[assignment.workoutID]
                let shouldReplace = existing == nil
                    || assignment.assignedAt > (existing?.assignment.assignedAt ?? .distantPast)
                    || (assignment.assignedAt == existing?.assignment.assignedAt
                        && assignment.id.uuidString > (existing?.assignment.id.uuidString ?? ""))
                if shouldReplace {
                    result[assignment.workoutID] = EffectiveAssignment(
                        assignment: assignment,
                        windowID: window.id
                    )
                }
            }
        }
        return result
    }
}
