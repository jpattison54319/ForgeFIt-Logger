import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// Transactional guarantees of `BackupRestoreService.commit`: the restore
/// runs in an isolated context, so an injected save failure leaves zero rows,
/// a later caller save commits no residue, unrelated unsaved caller edits
/// survive, a retry applies exactly once, preferences follow the save result,
/// and the success path persists the full graph.
@MainActor
@Suite(.serialized)
struct BackupRestoreRollbackTests {
    private enum SimulatedSaveFailure: Error, Equatable {
        case saveFailed
    }

    private let userID = ForgeFitDemo.userID

    // MARK: - Fixture

    private func backupFile() -> ForgeFitBackupFile {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let strengthExerciseID = UUID()
        let strengthExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: strengthExerciseID,
            position: 0,
            sets: [
                SetModel(
                    userID: userID,
                    position: 0,
                    setType: .working,
                    weightMode: .external,
                    reps: 8,
                    weight: 100,
                    completedAt: now.addingTimeInterval(300)
                ),
                SetModel(
                    userID: userID,
                    position: 1,
                    setType: .working,
                    weightMode: .external,
                    reps: 6,
                    weight: 105,
                    completedAt: now.addingTimeInterval(600)
                ),
            ]
        )
        let sessionID = UUID()
        let strength = WorkoutModel(
            id: UUID(),
            userID: userID,
            title: "Strength Day",
            startedAt: now,
            endedAt: now.addingTimeInterval(1800),
            externalSource: "fixture",
            externalWorkoutID: "strength-1",
            importFingerprint: "fixture-strength-1",
            createdAt: now,
            updatedAt: now,
            exercises: [strengthExercise]
        )

        let cardioExerciseID = UUID()
        let cardioExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: cardioExerciseID,
            position: 0,
            sets: [SetModel(
                userID: userID,
                position: 0,
                setType: .working,
                weightMode: .bodyweight,
                reps: 1,
                completedAt: now.addingTimeInterval(5_400)
            )]
        )
        let split = CardioSplitModel(
            userID: userID,
            cardioSessionID: sessionID,
            index: 0,
            distanceMeters: 1_000,
            durationSeconds: 300,
            paceSecondsPerKm: 300,
            startedAt: now.addingTimeInterval(3_600),
            endedAt: now.addingTimeInterval(3_900)
        )
        let point = CardioRoutePointModel(
            userID: userID,
            cardioSessionID: sessionID,
            timestamp: now.addingTimeInterval(3_600),
            latitude: 51.5,
            longitude: -0.12
        )
        let cardioSession = CardioSessionModel(
            id: sessionID,
            userID: userID,
            workoutExerciseID: cardioExercise.id,
            modality: "run",
            startedAt: now.addingTimeInterval(3_600),
            endedAt: now.addingTimeInterval(5_400),
            durationSeconds: 1_800,
            distanceMeters: 5_000,
            intervalsAutoApplied: false,
            createdAt: now,
            updatedAt: now,
            routePoints: [point],
            splits: [split]
        )
        let cardio = WorkoutModel(
            id: UUID(),
            userID: userID,
            title: "Run",
            startedAt: now.addingTimeInterval(3600),
            endedAt: now.addingTimeInterval(5400),
            externalSource: "fixture",
            externalWorkoutID: "cardio-1",
            importFingerprint: "fixture-cardio-1",
            createdAt: now,
            updatedAt: now,
            exercises: [cardioExercise],
            cardioSessions: [cardioSession]
        )

        let trackingID = UUID()
        let folderID = UUID()
        return BackupMapper.file(
            workouts: [strength, cardio],
            batches: [WorkoutImportBatchModel(
                userID: userID,
                source: "ForgeFit Backup",
                fileName: "fixture.forgefitbackup",
                importedCount: 2,
                startedAt: now,
                endedAt: now.addingTimeInterval(1),
                createdAt: now
            )],
            exerciseNames: [
                strengthExerciseID: "Bench Press",
                cardioExerciseID: "Incline Treadmill",
            ],
            preferences: [:],
            userID: userID,
            appVersion: nil,
            microcycleTrackings: [MicrocycleTrackingModel(
                id: trackingID,
                userID: userID,
                folderID: folderID,
                folderName: "Block",
                anchorDate: now,
                durationDays: 21,
                timeZoneIdentifier: "UTC",
                createdAt: now,
                updatedAt: now
            )],
            microcycleWindows: [MicrocycleWindowModel(
                userID: userID,
                trackingID: trackingID,
                folderID: folderID,
                folderName: "Block",
                index: 0,
                startsAt: now,
                endsAt: now.addingTimeInterval(86_400),
                timeZoneIdentifier: "UTC",
                routines: [],
                createdAt: now,
                updatedAt: now
            )],
            restDays: [RestDayModel(
                userID: userID,
                date: now,
                timeZoneIdentifier: "UTC",
                createdAt: now,
                updatedAt: now
            )],
            now: now
        )
    }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<T>()).count
    }

    // MARK: - Failure isolation

    @Test func injectedSaveFailureYieldsZeroRestoredRows() throws {
        let (container, context) = try TestStore.make()

        #expect(throws: SimulatedSaveFailure.saveFailed) {
            try BackupRestoreService.commit(
                backupFile(), restorePreferences: false, in: context,
                performSave: { _ in throw SimulatedSaveFailure.saveFailed }
            )
        }

        let persisted = ModelContext(container)
        #expect(try count(WorkoutModel.self, in: persisted) == 0)
        #expect(try count(WorkoutExerciseModel.self, in: persisted) == 0)
        #expect(try count(SetModel.self, in: persisted) == 0)
        #expect(try count(ExerciseLibraryModel.self, in: persisted) == 0)
        #expect(try count(CardioSessionModel.self, in: persisted) == 0)
        #expect(try count(CardioSplitModel.self, in: persisted) == 0)
        #expect(try count(CardioRoutePointModel.self, in: persisted) == 0)
        #expect(try count(WorkoutImportBatchModel.self, in: persisted) == 0)
        #expect(try count(MicrocycleTrackingModel.self, in: persisted) == 0)
        #expect(try count(MicrocycleWindowModel.self, in: persisted) == 0)
        #expect(try count(RestDayModel.self, in: persisted) == 0)
    }

    @Test func laterCallerSaveCommitsNoFailedRestoreResidue() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        #expect(throws: SimulatedSaveFailure.saveFailed) {
            try BackupRestoreService.commit(
                backupFile(), restorePreferences: false, in: context,
                performSave: { _ in throw SimulatedSaveFailure.saveFailed }
            )
        }

        // A later, unrelated save in the caller context persists nothing from
        // the failed restore.
        context.insert(WorkoutModel(userID: userID, title: "Unrelated", startedAt: Date()))
        try context.save()

        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        #expect(workouts.count == 1)
        #expect(workouts.first?.title == "Unrelated")
        #expect(try count(ExerciseLibraryModel.self, in: context) == 0)
        #expect(try count(WorkoutImportBatchModel.self, in: context) == 0)
        #expect(try count(CardioSessionModel.self, in: context) == 0)
    }

    @Test func unrelatedUnsavedCallerModelSurvivesFailedRestoreAndSaves() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        // Pending in the CALLER context, never saved.
        let unrelated = ExerciseLibraryModel(name: "Squat")
        context.insert(unrelated)

        #expect(throws: SimulatedSaveFailure.saveFailed) {
            try BackupRestoreService.commit(
                backupFile(), restorePreferences: false, in: context,
                performSave: { _ in throw SimulatedSaveFailure.saveFailed }
            )
        }

        // Rollback was isolated to the restore context: the caller's pending
        // edit survives and can be saved.
        try context.save()
        let libraries = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        #expect(libraries.count == 1)
        #expect(libraries.first?.name == "Squat")
        #expect(try count(WorkoutModel.self, in: context) == 0)
        #expect(try count(WorkoutImportBatchModel.self, in: context) == 0)
    }

    @Test func retryAfterFailedRestoreCommitsExactlyOnce() throws {
        let (container, context) = try TestStore.make()
        let file = backupFile()

        #expect(throws: SimulatedSaveFailure.saveFailed) {
            try BackupRestoreService.commit(
                file, restorePreferences: false, in: context,
                performSave: { _ in throw SimulatedSaveFailure.saveFailed }
            )
        }

        let retry = try BackupRestoreService.commit(file, restorePreferences: false, in: context)
        #expect(retry.restoredWorkouts == 2)
        #expect(retry.skippedDuplicates == 0)
        let persisted = ModelContext(container)
        #expect(try count(WorkoutModel.self, in: persisted) == 2)
        #expect(try count(WorkoutImportBatchModel.self, in: persisted) == 2)
    }

    @Test func restoringTheSameFileTwiceSkipsEveryWorkoutAndAddsNoRows() throws {
        let (container, context) = try TestStore.make()
        let file = backupFile()

        let first = try BackupRestoreService.commit(file, restorePreferences: false, in: context)
        let second = try BackupRestoreService.commit(file, restorePreferences: false, in: context)

        #expect(first.restoredWorkouts == 2)
        #expect(second.restoredWorkouts == 0)
        #expect(second.skippedDuplicates == 2)
        let persisted = ModelContext(container)
        #expect(try count(WorkoutModel.self, in: persisted) == 2)
        #expect(try count(WorkoutImportBatchModel.self, in: persisted) == 2)
    }

    @Test func duplicateKeysInsideOneBackupAreSkippedBeforeInsertion() throws {
        let (container, context) = try TestStore.make()
        var file = backupFile()

        var sameFingerprint = file.workouts[0]
        sameFingerprint.id = UUID()
        sameFingerprint.externalSource = nil
        sameFingerprint.externalID = nil

        var sameExternalKey = file.workouts[1]
        sameExternalKey.id = UUID()
        sameExternalKey.importFingerprint = nil

        file.workouts.append(file.workouts[0])
        file.workouts.append(sameFingerprint)
        file.workouts.append(sameExternalKey)
        file.importBatches.append(file.importBatches[0])
        if let duplicate = file.microcycleTrackings?.first {
            file.microcycleTrackings?.append(duplicate)
        }
        if let duplicate = file.microcycleWindows?.first {
            file.microcycleWindows?.append(duplicate)
        }
        if let duplicate = file.restDays?.first {
            file.restDays?.append(duplicate)
        }

        let result = try BackupRestoreService.commit(file, restorePreferences: false, in: context)

        #expect(result.restoredWorkouts == 2)
        #expect(result.skippedDuplicates == 3)
        let persisted = ModelContext(container)
        #expect(try count(WorkoutModel.self, in: persisted) == 2)
        #expect(try count(WorkoutImportBatchModel.self, in: persisted) == 2)
        #expect(try count(MicrocycleTrackingModel.self, in: persisted) == 1)
        #expect(try count(MicrocycleWindowModel.self, in: persisted) == 1)
        #expect(try count(RestDayModel.self, in: persisted) == 1)
    }

    // MARK: - Success path

    @Test func successfulRestorePersistsFullGraph() throws {
        let (container, context) = try TestStore.make()

        let result = try BackupRestoreService.commit(backupFile(), restorePreferences: false, in: context)

        #expect(result.restoredWorkouts == 2)
        #expect(result.skippedDuplicates == 0)
        #expect(result.recreatedExercises == 2)
        #expect(result.restoredMicrocycleTrackings == 1)
        #expect(result.restoredMicrocycleWindows == 1)
        #expect(result.restoredRestDays == 1)

        let persisted = ModelContext(container)
        #expect(try count(WorkoutModel.self, in: persisted) == 2)
        #expect(try count(WorkoutExerciseModel.self, in: persisted) == 2)
        #expect(try count(SetModel.self, in: persisted) == 3)
        #expect(try count(ExerciseLibraryModel.self, in: persisted) == 2)
        #expect(try count(CardioSessionModel.self, in: persisted) == 1)
        #expect(try count(CardioSplitModel.self, in: persisted) == 1)
        #expect(try count(CardioRoutePointModel.self, in: persisted) == 1)
        #expect(try count(WorkoutImportBatchModel.self, in: persisted) == 2)
        #expect(try count(MicrocycleTrackingModel.self, in: persisted) == 1)
        #expect(try count(MicrocycleWindowModel.self, in: persisted) == 1)
        #expect(try count(RestDayModel.self, in: persisted) == 1)

        let workouts = try persisted.fetch(FetchDescriptor<WorkoutModel>())
        let strength = try #require(workouts.first { $0.title == "Strength Day" })
        let run = try #require(workouts.first { $0.title == "Run" })
        #expect(strength.exercises.count == 1)
        #expect(strength.exercises[0].sets.count == 2)
        #expect(run.exercises.count == 1)
        #expect(run.exercises[0].sets.count == 1)
        let session = try #require(run.cardioSessions.first)
        #expect(session.splits.count == 1)
        #expect(session.routePoints.count == 1)
        #expect(session.splits[0].cardioSessionID == session.id)
        #expect(session.routePoints[0].cardioSessionID == session.id)
    }

    // MARK: - Preferences

    @Test func preferencesUnchangedOnFailureAndAppliedOnSuccess() throws {
        let defaults = UserDefaults.standard
        let nameKey = "profileDisplayName"
        let dataKey = "homeQuickStartActions.v1"
        let weekdaysKey = "reminderWeekdays"
        let rejectedKey = "health-derived-key-must-not-restore"
        let keys = [nameKey, dataKey, weekdaysKey, rejectedKey]
        let snapshot = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in snapshot {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }

        let originalData = Data([9, 9, 9])
        let restoredData = Data([1, 2, 3, 4])
        defaults.set("sentinel", forKey: nameKey)
        defaults.set(originalData, forKey: dataKey)
        defaults.set([2], forKey: weekdaysKey)

        do {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            var failing = backupFile()
            failing.preferences = [
                nameKey: .string("James"),
                dataKey: .string(restoredData.base64EncodedString()),
                weekdaysKey: .string("1,3,5"),
            ]
            #expect(throws: SimulatedSaveFailure.saveFailed) {
                try BackupRestoreService.commit(
                    failing, restorePreferences: true, in: context,
                    performSave: { _ in throw SimulatedSaveFailure.saveFailed }
                )
            }
            #expect(defaults.string(forKey: nameKey) == "sentinel")
            #expect(defaults.data(forKey: dataKey) == originalData)
            #expect(defaults.array(forKey: weekdaysKey) as? [Int] == [2])
        }

        do {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            var succeeding = backupFile()
            succeeding.preferences = [
                nameKey: .string("James"),
                dataKey: .string(restoredData.base64EncodedString()),
                weekdaysKey: .string("1,3,5"),
                rejectedKey: .string("must not land"),
            ]
            let result = try BackupRestoreService.commit(
                succeeding,
                restorePreferences: true,
                in: context
            )
            #expect(result.restoredPreferences == 3)
            #expect(defaults.string(forKey: nameKey) == "James")
            #expect(defaults.data(forKey: dataKey) == restoredData)
            #expect(defaults.array(forKey: weekdaysKey) as? [Int] == [1, 3, 5])
            #expect(defaults.object(forKey: rejectedKey) == nil)
        }

        do {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            defaults.set(originalData, forKey: dataKey)
            var malformed = backupFile()
            malformed.preferences = [dataKey: .string("not valid base64 %%%")]

            let result = try BackupRestoreService.commit(
                malformed,
                restorePreferences: true,
                in: context
            )

            #expect(result.restoredPreferences == 0)
            #expect(defaults.data(forKey: dataKey) == originalData)
            #expect(defaults.string(forKey: dataKey) == nil)
        }
    }
}
