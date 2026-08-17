import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum RestDayService {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

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
        timeZone: TimeZone = .current,
        save: SaveOperation = { try $0.save() }
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
            let previousDeletedAt = existing.deletedAt
            let previousUpdatedAt = existing.updatedAt
            existing.deletedAt = nil
            existing.updatedAt = now
            do {
                try save(context)
            } catch {
                existing.deletedAt = previousDeletedAt
                existing.updatedAt = previousUpdatedAt
                throw error
            }
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
        do {
            try save(context)
        } catch {
            context.delete(restDay)
            throw error
        }
        return restDay
    }

    static func remove(
        _ restDay: RestDayModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let previousDeletedAt = restDay.deletedAt
        let previousUpdatedAt = restDay.updatedAt
        restDay.deletedAt = now
        restDay.updatedAt = now
        do {
            try save(context)
        } catch {
            restDay.deletedAt = previousDeletedAt
            restDay.updatedAt = previousUpdatedAt
            throw error
        }
    }

    static func removeWorkoutConflicts(
        in context: ModelContext,
        now: Date = .now,
        shouldSave: Bool = true,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        let restDays = try context.fetch(FetchDescriptor<RestDayModel>())
            .filter { $0.deletedAt == nil }
        var snapshots: [(restDay: RestDayModel, deletedAt: Date?, updatedAt: Date)] = []
        for restDay in restDays {
            guard let calendar = try? MicrocycleEngine.calendar(
                timeZoneIdentifier: restDay.timeZoneIdentifier
            ) else { continue }
            if containsCompletedWorkout(on: restDay.date, workouts: workouts, calendar: calendar) {
                snapshots.append((restDay, restDay.deletedAt, restDay.updatedAt))
                restDay.deletedAt = now
                restDay.updatedAt = now
            }
        }
        guard !snapshots.isEmpty else { return }
        guard shouldSave else { return }
        do {
            try save(context)
        } catch {
            for snapshot in snapshots {
                snapshot.restDay.deletedAt = snapshot.deletedAt
                snapshot.restDay.updatedAt = snapshot.updatedAt
            }
            throw error
        }
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
