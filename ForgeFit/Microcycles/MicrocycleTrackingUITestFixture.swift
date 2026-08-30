#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Deterministic tracking data for the end-to-end microcycle history flows.
/// It creates two parent runs of the same folder plus a second selectable
/// microcycle, without introducing Health data.
@MainActor
enum MicrocycleTrackingUITestFixture {
    static func seed(
        in context: ModelContext,
        now: Date = .now,
        includesAlternation: Bool = false
    ) throws {
        for window in try context.fetch(FetchDescriptor<MicrocycleWindowModel>()) {
            context.delete(window)
        }
        for tracking in try context.fetch(FetchDescriptor<MicrocycleTrackingModel>()) {
            context.delete(tracking)
        }
        for workout in try context.fetch(FetchDescriptor<WorkoutModel>()) {
            context.delete(workout)
        }
        for alternation in try context.fetch(FetchDescriptor<RoutineAlternationModel>()) {
            context.delete(alternation)
        }
        for routine in try context.fetch(FetchDescriptor<RoutineModel>()) {
            context.delete(routine)
        }
        for folder in try context.fetch(FetchDescriptor<RoutineFolderModel>()) {
            context.delete(folder)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let strengthFolder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Strength Cycle",
            position: 0,
            defaultMicrocycleLengthDays: 7
        )
        let conditioningFolder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Conditioning Cycle",
            position: 1,
            defaultMicrocycleLengthDays: 5
        )
        let upper = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: strengthFolder.id,
            position: 0
        )
        let lower = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Lower",
            folderID: strengthFolder.id,
            position: 1
        )
        let intervals = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Intervals",
            folderID: conditioningFolder.id,
            position: 0
        )
        [strengthFolder, conditioningFolder].forEach(context.insert)
        [upper, lower, intervals].forEach(context.insert)
        let strengthRoutines: [MicrocycleRoutineSnapshot]
        if includesAlternation {
            let createdAt = today.addingTimeInterval(-7_200)
            context.insert(RoutineAlternationModel(
                userID: ForgeFitDemo.userID,
                ownerRoutineID: upper.id,
                partnerRoutineID: lower.id,
                memberRoutineIDs: [upper.id, lower.id],
                createdAt: createdAt,
                updatedAt: createdAt
            ))
            strengthRoutines = [
                MicrocycleRoutineSnapshot(
                    id: upper.id,
                    name: upper.name,
                    position: 0,
                    alternateRoutineID: lower.id,
                    alternateRoutineName: lower.name,
                    memberRoutineIDs: [upper.id, lower.id],
                    memberRoutineNames: [upper.name, lower.name]
                ),
            ]
        } else {
            strengthRoutines = [
                MicrocycleRoutineSnapshot(id: upper.id, name: upper.name, position: 0),
                MicrocycleRoutineSnapshot(id: lower.id, name: lower.name, position: 1),
            ]
        }

        let stoppedStart = calendar.date(byAdding: .day, value: -14, to: today)!
        let stoppedAt = calendar.date(byAdding: .hour, value: 12, to:
            calendar.date(byAdding: .day, value: -10, to: today)!
        )!
        let stoppedTracking = MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: strengthFolder.id,
            folderName: strengthFolder.name,
            anchorDate: stoppedStart,
            durationDays: 7,
            timeZoneIdentifier: calendar.timeZone.identifier,
            stateRaw: "ended",
            showsOnHome: false,
            showsFolderHeader: false,
            endedAt: stoppedAt,
            createdAt: stoppedStart,
            updatedAt: stoppedAt
        )
        let stoppedWindow = MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: stoppedTracking.id,
            folderID: strengthFolder.id,
            folderName: strengthFolder.name,
            index: 0,
            startsAt: stoppedStart,
            endsAt: calendar.date(byAdding: .day, value: 7, to: stoppedStart)!,
            timeZoneIdentifier: calendar.timeZone.identifier,
            routines: strengthRoutines,
            createdAt: stoppedStart,
            updatedAt: stoppedAt
        )

        let activeStart = calendar.date(byAdding: .day, value: -9, to: today)!
        let currentStart = calendar.date(byAdding: .day, value: 7, to: activeStart)!
        let activeTracking = MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: strengthFolder.id,
            folderName: strengthFolder.name,
            anchorDate: activeStart,
            durationDays: 7,
            timeZoneIdentifier: calendar.timeZone.identifier,
            createdAt: activeStart,
            updatedAt: now
        )
        let activePreviousWindow = MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: activeTracking.id,
            folderID: strengthFolder.id,
            folderName: strengthFolder.name,
            index: 0,
            startsAt: activeStart,
            endsAt: calendar.date(byAdding: .day, value: 7, to: activeStart)!,
            timeZoneIdentifier: calendar.timeZone.identifier,
            routines: strengthRoutines,
            createdAt: activeStart,
            updatedAt: now
        )
        let activeCurrentWindow = MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: activeTracking.id,
            folderID: strengthFolder.id,
            folderName: strengthFolder.name,
            index: 1,
            startsAt: currentStart,
            endsAt: calendar.date(byAdding: .day, value: 7, to: currentStart)!,
            timeZoneIdentifier: calendar.timeZone.identifier,
            routines: strengthRoutines,
            createdAt: currentStart,
            updatedAt: now
        )

        [stoppedTracking, activeTracking].forEach(context.insert)
        [stoppedWindow, activePreviousWindow, activeCurrentWindow].forEach(context.insert)
        UserDefaults.standard.set(
            strengthFolder.id.uuidString,
            forKey: CyclePreferenceMigration.activeMicrocycleKey
        )
        try context.save()
    }
}
#endif
