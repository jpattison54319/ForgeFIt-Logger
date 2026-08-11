import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Restores a sanitized iCloud backup into the local training log. Unlike
/// the lossy CSV import pipeline, backups preserve model UUIDs — so dedup
/// is primarily by id, the full cardio graph (splits, routes) round-trips,
/// and cross-layer references (routineID, exerciseID) resolve against the
/// CloudKit-synced plan layer. Health metrics are re-attached afterwards by
/// HealthEnrichmentService.
@MainActor
enum BackupRestoreService {

    struct BackupInfo: Identifiable {
        let id = UUID()
        let url: URL
        let exportedAt: Date
        let workoutCount: Int
        let schemaVersion: Int
        let label: String
    }

    struct RestoreResult {
        var restoredWorkouts = 0
        var skippedDuplicates = 0
        var recreatedExercises = 0
        var restoredPreferences = 0
        var restoredMicrocycleTrackings = 0
        var restoredMicrocycleWindows = 0
        var restoredRestDays = 0
        var restoredWorkoutIDs: [UUID] = []
    }

    enum RestoreError: LocalizedError {
        case unreadable
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "This backup file couldn't be read."
            case .unsupportedVersion(let version):
                "This backup was made by a newer ForgeFit (format v\(version)). Update the app, then restore."
            }
        }
    }

    /// The rotation slots that exist in iCloud Drive right now, newest first.
    static func availableBackups() async -> [BackupInfo] {
        var infos: [BackupInfo] = []
        let candidates: [(URL?, String)] = [
            (await BackupExporter.shared.latestBackupURL(), "Latest"),
            (await BackupExporter.shared.previousBackupURL(), "Previous"),
        ]
        for (url, label) in candidates {
            guard let url else { continue }
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            guard let file = try? await loadFile(at: url) else { continue }
            infos.append(BackupInfo(
                url: url,
                exportedAt: file.exportedAt,
                workoutCount: file.workouts.count,
                schemaVersion: file.schemaVersion,
                label: label
            ))
        }
        return infos.sorted { $0.exportedAt > $1.exportedAt }
    }

    /// Coordinated read + decompress + decode + version gate.
    static func loadFile(at url: URL) async throws -> ForgeFitBackupFile {
        var coordinatorError: NSError?
        var raw: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { url in
            raw = try? Data(contentsOf: url)
        }
        guard coordinatorError == nil, let raw else { throw RestoreError.unreadable }
        let data = try BackupExporter.readBackupData(raw)
        let file: ForgeFitBackupFile
        do {
            file = try BackupMapper.decode(data)
        } catch {
            throw RestoreError.unreadable
        }
        guard file.schemaVersion <= ForgeFitBackupFile.currentSchemaVersion else {
            throw RestoreError.unsupportedVersion(file.schemaVersion)
        }
        return file
    }

    /// Restores a backup through one isolated save attempt: every fetch,
    /// insert, and save runs in a fresh context on the caller's container, so
    /// a pre-commit failure rolls back ONLY the restore's own pending changes.
    /// Unrelated unsaved edits already pending in the caller's context survive,
    /// and no later caller save can commit failed-restore residue (the
    /// PlanImportService pattern). Preferences are UserDefaults writes with no
    /// transaction scope of their own, so they land only after the isolated
    /// store save has succeeded.
    ///
    /// `performSave` is the failure-injection seam for tests, replacing the
    /// restore context's store save (default `save()`). An injected save must
    /// throw WITHOUT committing. Rollback only undoes an attempt that was never
    /// persisted. This seam does not claim distributed atomicity if a real
    /// save spanning multiple persistent stores fails after one store commits;
    /// that boundary requires split-store runtime validation.
    static func commit(
        _ file: ForgeFitBackupFile,
        restorePreferences: Bool,
        in context: ModelContext,
        performSave: ((ModelContext) throws -> Void)? = nil
    ) throws -> RestoreResult {
        // A dedicated context makes failure rollback restore-only; unrelated
        // UI edits already pending in the caller's context are never touched.
        let restoreContext = ModelContext(context.container)
        restoreContext.autosaveEnabled = false
        let save = performSave ?? { try $0.save() }

        var result: RestoreResult
        do {
            result = try performCommit(file, in: restoreContext, save: save)
        } catch {
            restoreContext.rollback()
            throw error
        }

        // UserDefaults writes are outside SwiftData's transaction scope, so
        // they land only after the isolated store save succeeded — a failed
        // restore must not leave preferences half-applied either.
        if restorePreferences {
            result.restoredPreferences = restore(preferences: file.preferences)
        }
        return result
    }

    /// The restore body, running entirely in `restoreContext` so `commit` can
    /// roll the whole attempt back with a single `rollback()`.
    private static func performCommit(
        _ file: ForgeFitBackupFile,
        in restoreContext: ModelContext,
        save: (ModelContext) throws -> Void
    ) throws -> RestoreResult {
        var result = RestoreResult()
        let userID = ForgeFitDemo.userID

        // Dedup keys, mirroring the import pipeline's two secondary sets
        // plus the primary id set only backups can offer.
        let existing = try restoreContext.fetch(FetchDescriptor<WorkoutModel>())
        var seenIDs = Set(existing.map(\.id))
        var seenFingerprints = Set(existing.compactMap(\.importFingerprint))
        var seenExternalKeys = Set(existing.compactMap { workout -> String? in
            guard let source = workout.externalSource, let external = workout.externalWorkoutID else { return nil }
            return "\(source)|\(external)"
        })

        // Exercise linkage: resolve against the plan layer; name-match as a
        // fallback; recreate (with the ORIGINAL id) as a last resort so the
        // restored history never points at a missing exercise.
        var library = try restoreContext.fetch(FetchDescriptor<ExerciseLibraryModel>())
        var libraryIDs = Set(library.map(\.id))

        for backupWorkout in file.workouts {
            let externalKey = zip(backupWorkout.externalSource, backupWorkout.externalID)
                .map { "\($0)|\($1)" }
            if seenIDs.contains(backupWorkout.id)
                || backupWorkout.importFingerprint.map(seenFingerprints.contains) == true
                || externalKey.map(seenExternalKeys.contains) == true {
                result.skippedDuplicates += 1
                continue
            }
            // Update the seen sets immediately, not only from pre-existing
            // rows. A hand-edited or merged backup can repeat an id,
            // fingerprint, or external key inside the same file; accepting
            // the first occurrence must make every later occurrence a skip.
            seenIDs.insert(backupWorkout.id)
            if let fingerprint = backupWorkout.importFingerprint {
                seenFingerprints.insert(fingerprint)
            }
            if let externalKey {
                seenExternalKeys.insert(externalKey)
            }

            var resolved = backupWorkout
            for index in resolved.exercises.indices {
                let exerciseID = resolved.exercises[index].exerciseID
                guard !libraryIDs.contains(exerciseID) else { continue }
                let name = resolved.exercises[index].name
                if let match = ImportExerciseMatcher.bestMatch(importedName: name, in: library.map(\.domainInfo)) {
                    resolved.exercises[index].exerciseID = match.exercise.id
                } else {
                    let recreated = ExerciseLibraryModel(name: name.isEmpty ? "Restored Exercise" : name)
                    recreated.id = exerciseID
                    recreated.ownerID = userID
                    recreated.needsReview = true
                    recreated.classificationConfidence = 0
                    restoreContext.insert(recreated)
                    library.append(recreated)
                    libraryIDs.insert(exerciseID)
                    result.recreatedExercises += 1
                }
            }

            let graph = BackupMapper.workoutModel(from: resolved, userID: userID)
            restoreContext.insert(graph.workout)
            for block in graph.blocks {
                restoreContext.insert(block)
                graph.workout.blocks.append(block)
            }
            for exercise in graph.exercises {
                restoreContext.insert(exercise)
                graph.workout.exercises.append(exercise)
            }
            for set in graph.sets {
                restoreContext.insert(set)
                // Sets carry no parent pointer in the DTO — attach by the
                // exercise their backup parent declared, preserved in order.
            }
            attach(sets: graph.sets, from: resolved, to: graph.exercises)
            for session in graph.sessions {
                restoreContext.insert(session)
                graph.workout.cardioSessions.append(session)
            }
            attachCardioChildren(graph: graph, in: restoreContext)
            graph.workout.recomputeTotalVolume()
            result.restoredWorkouts += 1
            result.restoredWorkoutIDs.append(graph.workout.id)
        }

        // Import-batch provenance rows (id-deduped), then a row recording
        // this restore itself.
        var seenBatchIDs = Set(try restoreContext.fetch(FetchDescriptor<WorkoutImportBatchModel>()).map(\.id))
        for batch in file.importBatches where seenBatchIDs.insert(batch.id).inserted {
            restoreContext.insert(BackupMapper.batchModel(from: batch, userID: userID))
        }

        var seenTrackingIDs = Set(
            try restoreContext.fetch(FetchDescriptor<MicrocycleTrackingModel>()).map(\.id)
        )
        for tracking in file.microcycleTrackings ?? [] where seenTrackingIDs.insert(tracking.id).inserted {
            restoreContext.insert(BackupMapper.trackingModel(from: tracking, userID: userID))
            result.restoredMicrocycleTrackings += 1
        }

        var seenWindowIDs = Set(
            try restoreContext.fetch(FetchDescriptor<MicrocycleWindowModel>()).map(\.id)
        )
        for window in file.microcycleWindows ?? [] where seenWindowIDs.insert(window.id).inserted {
            restoreContext.insert(BackupMapper.windowModel(from: window, userID: userID))
            result.restoredMicrocycleWindows += 1
        }

        var seenRestDayIDs = Set(
            try restoreContext.fetch(FetchDescriptor<RestDayModel>()).map(\.id)
        )
        for restDay in file.restDays ?? [] where seenRestDayIDs.insert(restDay.id).inserted {
            restoreContext.insert(BackupMapper.restDayModel(from: restDay, userID: userID))
            result.restoredRestDays += 1
        }

        if result.restoredWorkouts > 0 {
            restoreContext.insert(WorkoutImportBatchModel(
                userID: userID,
                source: "ForgeFit Backup",
                fileName: "iCloud restore",
                importedCount: result.restoredWorkouts,
                skippedDuplicateCount: result.skippedDuplicates,
                warningCount: 0,
                startedAt: file.exportedAt,
                endedAt: Date()
            ))
        }

        try save(restoreContext)
        return result
    }

    /// Wires each restored set to its exercise using the backup's own
    /// nesting (order-preserving, id-keyed).
    private static func attach(sets: [SetModel], from backup: BackupWorkout, to exercises: [WorkoutExerciseModel]) {
        let setsByID = Dictionary(sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let exercisesByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for backupExercise in backup.exercises {
            guard let exercise = exercisesByID[backupExercise.id] else { continue }
            for backupSet in backupExercise.sets {
                guard let set = setsByID[backupSet.id] else { continue }
                exercise.sets.append(set)
            }
        }
    }

    private static func attachCardioChildren(
        graph: (workout: WorkoutModel, blocks: [WorkoutBlockModel], exercises: [WorkoutExerciseModel], sets: [SetModel], sessions: [CardioSessionModel], splits: [CardioSplitModel], points: [CardioRoutePointModel]),
        in context: ModelContext
    ) {
        let sessionsByID = Dictionary(graph.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for split in graph.splits {
            context.insert(split)
            sessionsByID[split.cardioSessionID]?.splits.append(split)
        }
        for point in graph.points {
            context.insert(point)
            sessionsByID[point.cardioSessionID]?.routePoints.append(point)
        }
    }

    /// Writes only allow-listed keys — a hand-edited backup file can't
    /// smuggle arbitrary defaults into the app.
    private static func restore(preferences: [String: BackupPreferenceValue]) -> Int {
        let defaults = UserDefaults.standard
        let allowed = Set(AppPreferenceKeys.backedUp)
        var restored = 0
        for (key, value) in preferences where allowed.contains(key) {
            switch value {
            case .string(let string):
                // JSON-blob and CSV-encoded prefs round-trip through strings.
                if key == "homeQuickStartActions.v1" || key.hasPrefix("plateInventory") || key == WarmupRampConfigStore.key {
                    // A hand-edited backup must not change a Data-valued
                    // preference into a String. Invalid base64 is skipped and
                    // does not count as restored.
                    guard let data = Data(base64Encoded: string) else { continue }
                    defaults.set(data, forKey: key)
                } else if key == "reminderWeekdays" {
                    defaults.set(string.split(separator: ",").compactMap { Int($0) }, forKey: key)
                } else {
                    defaults.set(string, forKey: key)
                }
            case .int(let int): defaults.set(int, forKey: key)
            case .double(let double): defaults.set(double, forKey: key)
            case .bool(let bool): defaults.set(bool, forKey: key)
            }
            restored += 1
        }
        return restored
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}
