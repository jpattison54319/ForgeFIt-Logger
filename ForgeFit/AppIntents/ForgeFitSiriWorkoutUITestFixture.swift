#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// A deterministic workout catalog and tracked microcycle for exercising the
/// production App Intent entity and navigation routes from XCUITest without
/// automating the system-owned Siri UI.
@MainActor
enum ForgeFitAppIntentWorkoutUITestFixture {
    static let launchArgument = "--app-intent-workout-fixture"
    static let tokenArgumentKey = "appIntentWorkoutFixtureToken"
    static let tokenEnvironmentKey = "FORGEFIT_APP_INTENT_WORKOUT_FIXTURE_TOKEN"
    private static let cindyRoutineID = UUID(
        uuidString: "00000000-0000-7000-8000-000000000924"
    )!
    private static let cindyRoutineExerciseID = UUID(
        uuidString: "00000000-0000-7000-8000-000000000925"
    )!
    private static let cindyRoutineSetID = UUID(
        uuidString: "00000000-0000-7000-8000-000000000926"
    )!
    private static let ax400RoutineID = UUID(
        uuidString: "00000000-0000-7000-8000-000000000921"
    )!
    private static let ax400RoutineExerciseID = UUID(
        uuidString: "00000000-0000-7000-8000-000000000922"
    )!
    private static let ax400RoutineSetID = UUID(
        uuidString: "00000000-0000-7000-8000-000000000923"
    )!

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
            || ProcessInfo.processInfo.environment[tokenEnvironmentKey] != nil
    }

    static var token: String? {
        ProcessInfo.processInfo.environment[tokenEnvironmentKey]
            ?? ForgeFitLaunchArguments.value(for: tokenArgumentKey)
    }

    static func seed(in context: ModelContext, now: Date = .now) throws {
        // The simulator's App Group outlives app reinstalls. Establish this
        // fixture's entire workout-history boundary in an isolated context so
        // a row registered by the keep-resident SwiftUI context cannot survive
        // or be re-saved when the first process terminates. Deleting completed
        // rows as well also prevents a same-day prior run from making the one
        // routine in this fixture look complete to the next-workout resolver.
        WorkoutFinisher.cancelLiveRuntime()
        let logResetContext = ModelContext(context.container)
        logResetContext.autosaveEnabled = false
        for workout in try logResetContext.fetch(FetchDescriptor<WorkoutModel>()) {
            logResetContext.delete(workout)
        }
        for window in try logResetContext.fetch(FetchDescriptor<MicrocycleWindowModel>()) {
            logResetContext.delete(window)
        }
        for tracking in try logResetContext.fetch(FetchDescriptor<MicrocycleTrackingModel>()) {
            logResetContext.delete(tracking)
        }
        try logResetContext.save()
        context.rollback()

        // Plan edits also use a private context. Repeated UI-test launches
        // reuse fixed fixture IDs; updating them in the same context that once
        // registered deleted instances can otherwise preserve the prior run's
        // setup-note value even though save() succeeds.
        let fixtureContext = ModelContext(context.container)
        fixtureContext.autosaveEnabled = false

        // Give this run a unique marker that follows the real setup-note →
        // workout-exercise copy path. After a process relaunch, XCUITest can
        // therefore prove it opened the workout created by this exact App Intent
        // request rather than any active row retained by an earlier run.
        if let token {
            let noteID = ForgeFitDemo.machinePressNoteID
            var noteDescriptor = FetchDescriptor<UserExerciseNoteModel>(
                predicate: #Predicate { $0.id == noteID }
            )
            noteDescriptor.fetchLimit = 1
            if let note = try fixtureContext.fetch(noteDescriptor).first {
                note.note = token
                note.updatedAt = now
            } else {
                fixtureContext.insert(UserExerciseNoteModel(
                    id: noteID,
                    userID: ForgeFitDemo.userID,
                    exerciseID: GlobalExerciseLibrary.machineChestPressID,
                    note: token,
                    createdAt: now,
                    updatedAt: now
                ))
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startsAt = calendar.startOfDay(for: now)
        guard let endsAt = calendar.date(byAdding: .day, value: 7, to: startsAt) else {
            throw FixtureError.windowUnavailable
        }
        let folderID = UUID(uuidString: "00000000-0000-7000-8000-000000000920")!
        var folderDescriptor = FetchDescriptor<RoutineFolderModel>(
            predicate: #Predicate { $0.id == folderID }
        )
        folderDescriptor.fetchLimit = 1
        let folder: RoutineFolderModel
        if let existingFolder = try fixtureContext.fetch(folderDescriptor).first {
            folder = existingFolder
            folder.name = "App Intent Cycle"
            folder.position = 0
            folder.defaultMicrocycleLengthDays = 7
            folder.updatedAt = now
        } else {
            folder = RoutineFolderModel(
                id: folderID,
                userID: ForgeFitDemo.userID,
                name: "App Intent Cycle",
                position: 0,
                defaultMicrocycleLengthDays: 7,
                createdAt: startsAt,
                updatedAt: now
            )
            fixtureContext.insert(folder)
        }
        // Cindy is deliberately the next tracked workout, while AX400 is a
        // second saved routine with a visibly different exercise. Both use
        // dedicated IDs: the production onboarding cleanup is intentionally
        // allowed to delete the seeded starter routine and must never classify
        // either fixture routine (or its active workout) as starter content.
        var cindyDescriptor = FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == cindyRoutineID }
        )
        cindyDescriptor.fetchLimit = 1
        let cindy: RoutineModel
        if let existingCindy = try fixtureContext.fetch(cindyDescriptor).first {
            cindy = existingCindy
            cindy.name = "Cindy"
            cindy.folderID = folderID
            cindy.position = 0
            cindy.deletedAt = nil
            cindy.archivedAt = nil
            cindy.updatedAt = now
            if let firstExercise = cindy.exercises.first {
                firstExercise.exerciseID = GlobalExerciseLibrary.machineChestPressID
                firstExercise.position = 0
                firstExercise.updatedAt = now
                if firstExercise.sets.isEmpty {
                    firstExercise.sets = [makeCindySet(now: now)]
                }
            } else {
                cindy.exercises = [makeCindyExercise(now: now)]
            }
        } else {
            cindy = RoutineModel(
                id: cindyRoutineID,
                userID: ForgeFitDemo.userID,
                name: "Cindy",
                folderID: folderID,
                position: 0,
                createdAt: startsAt,
                updatedAt: now,
                exercises: [makeCindyExercise(now: now)]
            )
            fixtureContext.insert(cindy)
        }

        var ax400Descriptor = FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == ax400RoutineID }
        )
        ax400Descriptor.fetchLimit = 1
        let ax400: RoutineModel
        if let existingAX400 = try fixtureContext.fetch(ax400Descriptor).first {
            ax400 = existingAX400
            ax400.name = "AX400"
            ax400.folderID = folderID
            ax400.position = 1
            ax400.deletedAt = nil
            ax400.archivedAt = nil
            ax400.updatedAt = now
            if let firstExercise = ax400.exercises.first {
                firstExercise.exerciseID = GlobalExerciseLibrary.smithMachineSquatID
                firstExercise.position = 0
                firstExercise.updatedAt = now
            } else {
                ax400.exercises = [makeAX400Exercise(now: now)]
            }
        } else {
            ax400 = RoutineModel(
                id: ax400RoutineID,
                userID: ForgeFitDemo.userID,
                name: "AX400",
                folderID: folderID,
                position: 1,
                createdAt: startsAt,
                updatedAt: now,
                exercises: [makeAX400Exercise(now: now)]
            )
            fixtureContext.insert(ax400)
        }
        // Plan rows live in the CloudKit-configured store; commit them before
        // inserting the current microcycle's log-store rows so the fixture
        // remains deterministic even when the simulator has no iCloud account.
        try fixtureContext.save()

        let tracking = MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: folderID,
            folderName: "App Intent Cycle",
            anchorDate: startsAt,
            durationDays: 7,
            timeZoneIdentifier: calendar.timeZone.identifier,
            createdAt: startsAt,
            updatedAt: now
        )
        let window = MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: tracking.id,
            folderID: folderID,
            folderName: tracking.folderName,
            index: 0,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZoneIdentifier: calendar.timeZone.identifier,
            routines: [MicrocycleRoutineSnapshot(
                id: cindy.id,
                name: cindy.name,
                position: cindy.position
            )],
            createdAt: startsAt,
            updatedAt: now
        )
        fixtureContext.insert(tracking)
        fixtureContext.insert(window)
        try fixtureContext.save()
        context.rollback()
    }

    private static func makeCindyExercise(now: Date) -> RoutineExerciseModel {
        RoutineExerciseModel(
            id: cindyRoutineExerciseID,
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            createdAt: now,
            updatedAt: now,
            sets: [makeCindySet(now: now)]
        )
    }

    private static func makeCindySet(now: Date) -> RoutineSetModel {
        RoutineSetModel(
            id: cindyRoutineSetID,
            userID: ForgeFitDemo.userID,
            position: 0,
            targetRepsLow: 8,
            targetRepsHigh: 12,
            targetWeight: 80,
            targetRPE: 8,
            createdAt: now
        )
    }

    private static func makeAX400Exercise(now: Date) -> RoutineExerciseModel {
        RoutineExerciseModel(
            id: ax400RoutineExerciseID,
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.smithMachineSquatID,
            position: 0,
            createdAt: now,
            updatedAt: now,
            sets: [RoutineSetModel(
                id: ax400RoutineSetID,
                userID: ForgeFitDemo.userID,
                position: 0,
                targetRepsLow: 8,
                targetRepsHigh: 12,
                targetWeight: 80,
                targetRPE: 8,
                createdAt: now
            )]
        )
    }

    private enum FixtureError: Error {
        case windowUnavailable
    }
}
#endif
