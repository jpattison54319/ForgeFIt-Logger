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

    static func commit(_ file: ForgeFitBackupFile, restorePreferences: Bool, in context: ModelContext) throws -> RestoreResult {
        var result = RestoreResult()
        let userID = ForgeFitDemo.userID

        // Dedup keys, mirroring the import pipeline's two secondary sets
        // plus the primary id set only backups can offer.
        let existing = try context.fetch(FetchDescriptor<WorkoutModel>())
        let existingIDs = Set(existing.map(\.id))
        let existingFingerprints = Set(existing.compactMap(\.importFingerprint))
        let existingExternalKeys = Set(existing.compactMap { workout -> String? in
            guard let source = workout.externalSource, let external = workout.externalWorkoutID else { return nil }
            return "\(source)|\(external)"
        })

        // Exercise linkage: resolve against the plan layer; name-match as a
        // fallback; recreate (with the ORIGINAL id) as a last resort so the
        // restored history never points at a missing exercise.
        var library = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        var libraryIDs = Set(library.map(\.id))

        for backupWorkout in file.workouts {
            if existingIDs.contains(backupWorkout.id)
                || backupWorkout.importFingerprint.map(existingFingerprints.contains) == true
                || zip(backupWorkout.externalSource, backupWorkout.externalID)
                    .map({ existingExternalKeys.contains("\($0)|\($1)") }) == true {
                result.skippedDuplicates += 1
                continue
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
                    context.insert(recreated)
                    library.append(recreated)
                    libraryIDs.insert(exerciseID)
                    result.recreatedExercises += 1
                }
            }

            let graph = BackupMapper.workoutModel(from: resolved, userID: userID)
            context.insert(graph.workout)
            for exercise in graph.exercises {
                context.insert(exercise)
                graph.workout.exercises.append(exercise)
            }
            for set in graph.sets {
                context.insert(set)
                // Sets carry no parent pointer in the DTO — attach by the
                // exercise their backup parent declared, preserved in order.
            }
            attach(sets: graph.sets, from: resolved, to: graph.exercises)
            for session in graph.sessions {
                context.insert(session)
                graph.workout.cardioSessions.append(session)
            }
            attachCardioChildren(graph: graph, in: context)
            graph.workout.recomputeTotalVolume()
            result.restoredWorkouts += 1
            result.restoredWorkoutIDs.append(graph.workout.id)
        }

        // Import-batch provenance rows (id-deduped), then a row recording
        // this restore itself.
        let existingBatchIDs = Set(try context.fetch(FetchDescriptor<WorkoutImportBatchModel>()).map(\.id))
        for batch in file.importBatches where !existingBatchIDs.contains(batch.id) {
            context.insert(BackupMapper.batchModel(from: batch, userID: userID))
        }
        if result.restoredWorkouts > 0 {
            context.insert(WorkoutImportBatchModel(
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

        if restorePreferences {
            result.restoredPreferences = restore(preferences: file.preferences)
        }

        try context.save()
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
        graph: (workout: WorkoutModel, exercises: [WorkoutExerciseModel], sets: [SetModel], sessions: [CardioSessionModel], splits: [CardioSplitModel], points: [CardioRoutePointModel]),
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
                if key == "homeQuickStartActions.v1" || key.hasPrefix("plateInventory") || key == WarmupRampConfigStore.key,
                   let data = Data(base64Encoded: string) {
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
