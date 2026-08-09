import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum RestDayService {
    enum ServiceError: LocalizedError, Equatable {
        case futureDate
        case trainingExists

        var errorDescription: String? {
            switch self {
            case .futureDate: "Choose today or a past date."
            case .trainingExists: "A completed workout is already logged on this date."
            }
        }
    }

    @discardableResult
    static func log(
        date: Date,
        workouts: [WorkoutModel],
        in context: ModelContext,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) throws -> RestDayModel {
        let identifier = timeZone.identifier
        let calendar = try MicrocycleEngine.calendar(timeZoneIdentifier: identifier)
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        guard day <= today else { throw ServiceError.futureDate }
        guard !containsCompletedWorkout(on: day, workouts: workouts, calendar: calendar) else {
            throw ServiceError.trainingExists
        }

        let all = try context.fetch(FetchDescriptor<RestDayModel>())
        if let existing = all.first(where: {
            calendar.isDate($0.date, inSameDayAs: day) && $0.timeZoneIdentifier == identifier
        }) {
            existing.deletedAt = nil
            existing.updatedAt = now
            try context.save()
            return existing
        }

        let restDay = RestDayModel(
            userID: ForgeFitDemo.userID,
            date: day,
            timeZoneIdentifier: identifier,
            createdAt: now,
            updatedAt: now
        )
        context.insert(restDay)
        try context.save()
        return restDay
    }

    static func remove(
        _ restDay: RestDayModel,
        in context: ModelContext,
        now: Date = .now
    ) throws {
        restDay.deletedAt = now
        restDay.updatedAt = now
        try context.save()
    }

    static func removeWorkoutConflicts(
        in context: ModelContext,
        now: Date = .now
    ) throws {
        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        let restDays = try context.fetch(FetchDescriptor<RestDayModel>())
            .filter { $0.deletedAt == nil }
        var changed = false
        for restDay in restDays {
            guard let calendar = try? MicrocycleEngine.calendar(
                timeZoneIdentifier: restDay.timeZoneIdentifier
            ) else { continue }
            if containsCompletedWorkout(on: restDay.date, workouts: workouts, calendar: calendar) {
                restDay.deletedAt = now
                restDay.updatedAt = now
                changed = true
            }
        }
        if changed { try context.save() }
    }

    static func live(_ restDays: [RestDayModel]) -> [RestDayModel] {
        restDays.filter { $0.deletedAt == nil }
    }

    private static func containsCompletedWorkout(
        on date: Date,
        workouts: [WorkoutModel],
        calendar: Calendar
    ) -> Bool {
        workouts.contains {
            $0.endedAt != nil
                && $0.deletedAt == nil
                && calendar.isDate($0.startedAt, inSameDayAs: date)
        }
    }
}
