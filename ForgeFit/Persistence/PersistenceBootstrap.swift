import ForgeData
import Foundation
import SQLite3
import SwiftData

enum PersistenceLaunchFailure: Equatable {
    /// The one-time legacy plan migration could not complete. Opening the
    /// split stack anyway could drop the only local copy of those plan rows,
    /// so launch stops before either store is changed.
    case planMigrationUnavailable

    /// The irreplaceable local workout log could not be opened. It is never
    /// quarantined or replaced automatically.
    case workoutLogUnavailable

    /// The workout log opened independently, but the complete split stack
    /// still could not be created. Both active stores remain in place.
    case storeStackUnavailable

    /// The store directory could not be excluded from device backup. Running
    /// anyway could place workout and Health-derived data in iCloud backup,
    /// violating ForgeFit's release privacy boundary.
    case backupProtectionUnavailable

    var recoveryMessage: String {
        switch self {
        case .planMigrationUnavailable:
            "Your workout history and training plan were left untouched because ForgeFit could not finish updating its data. Check that your iPhone has free storage, then try again."
        case .workoutLogUnavailable:
            "Your workout history was left untouched. Check that your iPhone has free storage, then try again."
        case .storeStackUnavailable:
            "Your workout history and training plan were left untouched. Check that your iPhone has free storage, then try again."
        case .backupProtectionUnavailable:
            "ForgeFit could not apply required privacy protection to your local workout data. Your data was left untouched. Check that your iPhone has free storage, then try again."
        }
    }

    var supportCode: String {
        switch self {
        case .planMigrationUnavailable: "DATA-MIGRATE-1"
        case .workoutLogUnavailable: "DATA-OPEN-1"
        case .storeStackUnavailable: "DATA-OPEN-2"
        case .backupProtectionUnavailable: "DATA-PRIVACY-1"
        }
    }
}

enum PersistenceLaunchState {
    case ready(ModelContainer)
    case blocked(PersistenceLaunchFailure)

    var container: ModelContainer? {
        guard case let .ready(container) = self else { return nil }
        return container
    }

    var failure: PersistenceLaunchFailure? {
        guard case let .blocked(failure) = self else { return nil }
        return failure
    }
}

/// Builds the app's split persistence stack (App Store Guideline 5.1.3(ii)):
///
/// - `default.store` — the training LOG (workouts, sets, cardio, health-
///   derived metrics, check-ins). LOCAL ONLY, never CloudKit: these models
///   carry personal health information, which must not be stored in iCloud.
///   Users can make an explicit export for continuity; legacy sanitized
///   iCloud Drive backups can still be restored, with Health values
///   re-enriched from Apple Health.
/// - `plan.store` — the training PLAN (routines, exercise library, notes,
///   presets, flows, XP). Syncs via CloudKit; contains no health data by
///   construction (see `ForgeDataSchema.planModels`).
///
/// The two layers share no SwiftData relationships — only UUID references —
/// so they partition cleanly into separate stores (SchemaSplitTests pins
/// this). Existing installs migrate their plan rows out of the legacy
/// combined store exactly once before the split container first opens it.
enum PersistenceBootstrap {
    static let splitMigrationDoneKey = "storeSplitMigration.v1.done"

    /// The legacy combined store's location — SwiftData's default URL,
    /// discovered the same way the pre-split code did (via a URL-less
    /// configuration) so it can never drift from where data actually lives.
    // Resolving SwiftData's default URL constructs a schema-backed
    // ModelConfiguration. Cache it once: recovery, migration, container
    // creation, and backup exclusion all need the same immutable location,
    // and recomputing it repeatedly adds avoidable cold-launch work.
    static let defaultStoreURL: URL = {
        ModelConfiguration(
            schema: Schema(ForgeDataSchema.models),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        ).url
    }()

    static let planStoreURL: URL = {
        defaultStoreURL.deletingLastPathComponent().appendingPathComponent("plan.store")
    }()

    @MainActor
    static func makeContainer(
        prepare: @MainActor () throws -> Void = {
            try PersistenceBootstrap.migratePlanRowsIfNeeded()
            PersistenceBootstrap.restoreQuarantinedWorkoutLogIfNeeded()
        },
        openSplit: @MainActor () throws -> ModelContainer = {
            try PersistenceBootstrap.makeSplitContainer()
        },
        workoutLogCanOpen: @MainActor () -> Bool = {
            PersistenceBootstrap.canOpenWorkoutLog()
        },
        protectStoresFromBackup: @MainActor () throws -> Void = {
            try PersistenceBootstrap.excludeStoreDirectoryFromSystemBackup()
        }
    ) -> PersistenceLaunchState {
        do {
            try prepare()
        } catch {
            // A failed migration is not permission to continue into the split
            // stack: doing so can make legacy plan rows unreachable. Leave
            // both stores exactly where they are and let the user retry.
            print("Plan-store migration could not complete; preserving both stores: \(error)")
            return .blocked(.planMigrationUnavailable)
        }

        do {
            let container = try openSplit()
            do {
                try protectStoresFromBackup()
            } catch {
                print("Required local-store backup exclusion failed: \(error)")
                return .blocked(.backupProtectionUnavailable)
            }
            return .ready(container)
        } catch {
            // Never move an active user-authored store automatically. The old
            // fallback quarantined stores and retried with empty databases;
            // that could make intact history or an unsynced plan look erased.
            guard workoutLogCanOpen() else {
                print("Local workout store could not open; preserving it for recovery: \(error)")
                return .blocked(.workoutLogUnavailable)
            }
            print("Split store stack could not open; preserving both active stores: \(error)")
            return .blocked(.storeStackUnavailable)
        }
    }

    /// The LOG store contains Health-derived values and experiments. Neither
    /// belongs in Apple's opaque device backup. Workout continuity comes from
    /// ForgeFit's sanitized iCloud Drive backup, while plan rows sync through
    /// their private CloudKit store. Excluding the containing directory also
    /// covers SQLite's transient WAL/SHM files and prevents the unsanitized
    /// local database from entering iCloud through the system backup path.
    private static func excludeStoreDirectoryFromSystemBackup() throws {
        let directory = defaultStoreURL.deletingLastPathComponent()
        try excludeDirectoryFromSystemBackup(directory)
    }

    static func excludeDirectoryFromSystemBackup(_ url: URL) throws {
        var directory = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private static func makeSplitContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(ForgeDataSchema.models),
            configurations: [
                ModelConfiguration(
                    "log",
                    schema: Schema(ForgeDataSchema.logModels),
                    url: defaultStoreURL,
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "plan",
                    schema: Schema(ForgeDataSchema.planModels),
                    url: planStoreURL,
                    cloudKitDatabase: .automatic
                ),
            ]
        )
    }

    /// Verifies the irreplaceable local log independently from CloudKit. The
    /// container is scoped so all SQLite handles close before recovery moves
    /// any files.
    @MainActor
    private static func canOpenWorkoutLog() -> Bool {
        do {
            try autoreleasepool {
                _ = try ModelContainer(
                    for: Schema(ForgeDataSchema.logModels),
                    configurations: [ModelConfiguration(
                        "log-check",
                        schema: Schema(ForgeDataSchema.logModels),
                        url: defaultStoreURL,
                        cloudKitDatabase: .none
                    )]
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// Repairs devices affected by the old all-store quarantine fallback.
    /// It restores only when a preserved quarantine contains more workouts
    /// than the active log. The active store may no longer be empty because
    /// HealthKit can re-import a subset immediately after the loss; comparing
    /// counts still gives us concrete evidence that the quarantine is the more
    /// complete history.
    @MainActor
    private static func restoreQuarantinedWorkoutLogIfNeeded() {
        guard let currentCount = workoutCount(at: defaultStoreURL) else { return }

        let parent = defaultStoreURL.deletingLastPathComponent()
        let suffix = "-\(defaultStoreURL.lastPathComponent)"
        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter {
                let isDirectory = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return isDirectory && $0.lastPathComponent.hasPrefix("StoreBackup-")
                    && $0.lastPathComponent.hasSuffix(suffix)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        for directory in candidates {
            let preservedURL = directory.appendingPathComponent(defaultStoreURL.lastPathComponent)
            guard let count = workoutCount(at: preservedURL), count > currentCount else { continue }
            do {
                try replaceStore(at: defaultStoreURL, withStoreAt: preservedURL)
                print("Recovered \(count) workouts over incomplete \(currentCount)-workout log from preserved local store \(directory.lastPathComponent)")
                return
            } catch {
                print("Workout log recovery failed for \(directory.lastPathComponent): \(error)")
            }
        }
    }

    @MainActor
    private static func workoutCount(at storeURL: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return 0 }
        if let count = sqliteWorkoutCount(at: storeURL) {
            return count
        }

        // Compatibility fallback if a future SwiftData schema renames its
        // backing table. Normal launches use the read-only SQLite COUNT above;
        // constructing another full ModelContainer cost ~650 ms on a
        // phone-sized store before the first frame.
        do {
            return try autoreleasepool {
                let container = try ModelContainer(
                    for: Schema(ForgeDataSchema.logModels),
                    configurations: [ModelConfiguration(
                        "log-recovery-check",
                        schema: Schema(ForgeDataSchema.logModels),
                        url: storeURL,
                        cloudKitDatabase: .none
                    )]
                )
                return try container.mainContext.fetchCount(FetchDescriptor<WorkoutModel>())
            }
        } catch {
            return nil
        }
    }

    /// Core Data's table name is stable for the current `WorkoutModel` schema.
    /// SQLite opens the WAL read-only as part of the same store, so this sees
    /// committed rows without migrating, mutating, or faulting model objects.
    private static func sqliteWorkoutCount(at storeURL: URL) -> Int? {
        var database: OpaquePointer?
        let openResult = storeURL.path.withCString { path in
            sqlite3_open_v2(
                path,
                &database,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard openResult == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM ZWORKOUTMODEL",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(exactly: sqlite3_column_int64(statement, 0))
    }

    /// Replaces a three-file SQLite store without deleting the active copy
    /// until every source component has first been staged successfully. A
    /// failed staging copy leaves the destination byte-for-byte untouched; a
    /// failed promotion rolls moved destination files back from a same-volume
    /// directory. The preserved source is never moved, so a process death in
    /// the narrow promotion window can retry recovery on the next launch.
    static func replaceStore(at destination: URL, withStoreAt source: URL) throws {
        let fileManager = FileManager.default
        let suffixes = ["", "-shm", "-wal"]
        guard fileManager.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".StoreRestore-\(UUID().uuidString)", isDirectory: true)
        let rollback = parent.appendingPathComponent(".StoreRollback-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let sourceSuffixes = suffixes.filter {
            fileManager.fileExists(atPath: URL(fileURLWithPath: source.path + $0).path)
        }
        for suffix in sourceSuffixes {
            let sourceFile = URL(fileURLWithPath: source.path + suffix)
            let stagedFile = staging.appendingPathComponent(destination.lastPathComponent + suffix)
            try fileManager.copyItem(at: sourceFile, to: stagedFile)
        }

        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: false)
        var movedDestinationSuffixes: [String] = []
        var installedSourceSuffixes: [String] = []
        do {
            for suffix in suffixes {
                let destinationFile = URL(fileURLWithPath: destination.path + suffix)
                guard fileManager.fileExists(atPath: destinationFile.path) else { continue }
                try fileManager.moveItem(
                    at: destinationFile,
                    to: rollback.appendingPathComponent(destination.lastPathComponent + suffix)
                )
                movedDestinationSuffixes.append(suffix)
            }

            for suffix in sourceSuffixes {
                let stagedFile = staging.appendingPathComponent(destination.lastPathComponent + suffix)
                let destinationFile = URL(fileURLWithPath: destination.path + suffix)
                try fileManager.moveItem(at: stagedFile, to: destinationFile)
                installedSourceSuffixes.append(suffix)
            }
        } catch {
            for suffix in installedSourceSuffixes {
                try? fileManager.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
            }
            var rollbackCompleted = true
            for suffix in movedDestinationSuffixes.reversed() {
                let preserved = rollback.appendingPathComponent(destination.lastPathComponent + suffix)
                let destinationFile = URL(fileURLWithPath: destination.path + suffix)
                do {
                    try fileManager.moveItem(at: preserved, to: destinationFile)
                } catch {
                    rollbackCompleted = false
                }
            }
            if rollbackCompleted { try? fileManager.removeItem(at: rollback) }
            throw error
        }
        try fileManager.removeItem(at: rollback)
    }

    /// One-time copy of plan rows out of the legacy combined store. MUST run
    /// before the split container's first open of `default.store` — that
    /// open drops the plan tables from the legacy file (by design, after
    /// the copy). Fresh installs just stamp the flag.
    @MainActor
    private static func migratePlanRowsIfNeeded() throws {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: splitMigrationDoneKey) else { return }
        guard FileManager.default.fileExists(atPath: defaultStoreURL.path) else {
            defaults.set(true, forKey: splitMigrationDoneKey)
            return
        }
        do {
            let summary = try PlanStoreSplitMigration.migrate(
                legacyStoreURL: defaultStoreURL,
                planStoreURL: planStoreURL
            )
            defaults.set(true, forKey: splitMigrationDoneKey)
            print("PlanStoreSplitMigration copied \(summary.totalCopied) rows: \(summary.copiedByType)")
        } catch {
            // Never stamp a failed migration complete. Opening the split
            // stack after this point can make legacy plan rows unreachable;
            // the launch recovery surface leaves the store intact for retry.
            print("PlanStoreSplitMigration failed: \(error)")
            throw error
        }
    }
}
