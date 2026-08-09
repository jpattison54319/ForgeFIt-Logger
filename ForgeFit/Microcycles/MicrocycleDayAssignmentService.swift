import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Links real completed workouts to microcycle days without altering workout
/// history. The window JSON is the source of truth so the link remains local,
/// reversible, backup-safe, and independent from HealthKit timestamps.
@MainActor
enum MicrocycleDayAssignmentService {
    enum ServiceError: LocalizedError, Equatable {
        case invalidDay
        case futureDay
        case dayAlreadyTrained
        case workoutUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidDay:
                "Choose a day inside this microcycle."
            case .futureDay:
                "A workout can only be added to today or a past day."
            case .dayAlreadyTrained:
                "This day already has a completed workout."
            case .workoutUnavailable:
                "That workout is no longer eligible for this microcycle."
            }
        }
    }

    struct DayWorkout: Identifiable {
        let workout: WorkoutModel
        let assignment: MicrocycleDayAssignment?

        var id: UUID { workout.id }
        var isBackfilled: Bool { assignment != nil }
    }

    static func dayWorkouts(
        on date: Date,
        in window: MicrocycleWindowModel,
        workouts: [WorkoutModel]
    ) -> [DayWorkout] {
        guard let calendar = try? calendar(for: window) else { return [] }
        let day = calendar.startOfDay(for: date)
        let liveWorkouts = workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
        var records: [UUID: DayWorkout] = [:]

        for workout in liveWorkouts where calendar.isDate(workout.startedAt, inSameDayAs: day) {
            records[workout.id] = DayWorkout(workout: workout, assignment: nil)
        }

        let workoutByID = Dictionary(
            liveWorkouts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for assignment in window.dayAssignments
            where calendar.isDate(assignment.day, inSameDayAs: day) {
            guard let workout = workoutByID[assignment.workoutID] else { continue }
            records[workout.id] = DayWorkout(workout: workout, assignment: assignment)
        }

        return records.values.sorted {
            if $0.workout.startedAt != $1.workout.startedAt {
                return $0.workout.startedAt < $1.workout.startedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Only completed workouts for routines still due in this window appear.
    /// Workouts already credited in any window of this tracking run are hidden,
    /// which keeps one real session from satisfying two microcycles.
    static func eligibleWorkouts(
        for date: Date,
        in window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        now: Date = .now
    ) -> [WorkoutModel] {
        guard let calendar = try? calendar(for: window) else { return [] }
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard day >= window.startsAt, day < window.endsAt, day <= today else { return [] }
        guard dayWorkouts(on: day, in: window, workouts: workouts).isEmpty else { return [] }

        let relevantWindows = windows.filter {
            $0.trackingID == window.trackingID && $0.deletedAt == nil
        }
        let currentProgress = MicrocycleTrackingService.progress(
            for: window,
            windows: relevantWindows,
            workouts: workouts
        )
        let remainingRoutineIDs = Set(
            currentProgress.routines.lazy.filter { !$0.isCompleted }.map(\.routine.id)
        )
        guard !remainingRoutineIDs.isEmpty else { return [] }

        let alreadyAssignedIDs = Set(relevantWindows.flatMap(\.dayAssignments).map(\.workoutID))
        let alreadyCreditedIDs = Set(relevantWindows.flatMap { candidateWindow in
            MicrocycleTrackingService.progress(
                for: candidateWindow,
                windows: relevantWindows,
                workouts: workouts
            ).routines.compactMap(\.workoutID)
        })

        return workouts
            .filter { workout in
                guard workout.endedAt != nil,
                      workout.deletedAt == nil,
                      workout.startedAt <= now,
                      let routineID = workout.routineID else { return false }
                return remainingRoutineIDs.contains(routineID)
                    && !alreadyAssignedIDs.contains(workout.id)
                    && !alreadyCreditedIDs.contains(workout.id)
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func assign(
        _ workout: WorkoutModel,
        to date: Date,
        in window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel],
        restDays: [RestDayModel],
        context: ModelContext,
        now: Date = .now
    ) throws {
        let calendar = try calendar(for: window)
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard day >= window.startsAt, day < window.endsAt else {
            throw ServiceError.invalidDay
        }
        guard day <= today else { throw ServiceError.futureDay }
        guard dayWorkouts(on: day, in: window, workouts: workouts).isEmpty else {
            throw ServiceError.dayAlreadyTrained
        }
        guard eligibleWorkouts(
            for: day,
            in: window,
            windows: windows,
            workouts: workouts,
            now: now
        ).contains(where: { $0.id == workout.id }) else {
            throw ServiceError.workoutUnavailable
        }

        // A day cannot truthfully be both an explicit rest day and a credited
        // training day. Replacing it is safe because the rest entry is a soft
        // deletion and the workout itself remains untouched.
        for restDay in restDays where restDay.deletedAt == nil
            && calendar.isDate(restDay.date, inSameDayAs: day) {
            restDay.deletedAt = now
            restDay.updatedAt = now
        }

        var assignments = window.dayAssignments.filter { assignment in
            !calendar.isDate(assignment.day, inSameDayAs: day)
        }
        assignments.append(MicrocycleDayAssignment(
            day: day,
            workoutID: workout.id,
            assignedAt: now
        ))
        assignments.sort {
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.id.uuidString < $1.id.uuidString
        }
        window.dayAssignments = assignments
        window.updatedAt = now
        try context.save()
    }

    static func remove(
        _ assignment: MicrocycleDayAssignment,
        from window: MicrocycleWindowModel,
        context: ModelContext,
        now: Date = .now
    ) throws {
        window.dayAssignments.removeAll { $0.id == assignment.id }
        window.updatedAt = now
        try context.save()
    }

    private static func calendar(for window: MicrocycleWindowModel) throws -> Calendar {
        try MicrocycleEngine.calendar(timeZoneIdentifier: window.timeZoneIdentifier)
    }
}
