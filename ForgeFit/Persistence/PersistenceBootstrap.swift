import ForgeData
import Foundation
import SwiftData

/// Builds the app's split persistence stack (App Store Guideline 5.1.3(ii)):
///
/// - `default.store` — the training LOG (workouts, sets, cardio, health-
///   derived metrics, check-ins). LOCAL ONLY, never CloudKit: these models
///   carry personal health information, which must not be stored in iCloud.
///   Cross-device continuity comes from the sanitized iCloud Drive backup
///   plus re-enrichment from Apple Health.
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
    static var defaultStoreURL: URL {
        ModelConfiguration(
            schema: Schema(ForgeDataSchema.models),
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        ).url
    }

    static var planStoreURL: URL {
        defaultStoreURL.deletingLastPathComponent().appendingPathComponent("plan.store")
    }

    @MainActor
    static func makeContainer() -> ModelContainer {
        migratePlanRowsIfNeeded()
        restoreQuarantinedWorkoutLogIfNeeded()

        do {
            return try makeSplitContainer()
        } catch {
            // The plan store is CloudKit-recoverable; the local workout log is
            // not. The old fallback quarantined BOTH stores when either one
            // failed, which could replace a healthy workout history with an
            // empty database after an unrelated plan-store schema error.
            guard canOpenWorkoutLog() else {
                fatalError("Local workout store could not open; it was preserved for recovery: \(error)")
            }
            quarantine(storeURL: planStoreURL)
            do {
                return try makeSplitContainer()
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
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

    private static func replaceStore(at destination: URL, withStoreAt source: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let destinationFile = URL(fileURLWithPath: destination.path + suffix)
            let sourceFile = URL(fileURLWithPath: source.path + suffix)
            if fileManager.fileExists(atPath: destinationFile.path) {
                try fileManager.removeItem(at: destinationFile)
            }
            if fileManager.fileExists(atPath: sourceFile.path) {
                try fileManager.copyItem(at: sourceFile, to: destinationFile)
            }
        }
    }

    /// One-time copy of plan rows out of the legacy combined store. MUST run
    /// before the split container's first open of `default.store` — that
    /// open drops the plan tables from the legacy file (by design, after
    /// the copy). Fresh installs just stamp the flag.
    @MainActor
    private static func migratePlanRowsIfNeeded() {
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
            // Legacy store unreadable with the current schema — the split
            // container will hit the same wall and quarantine it; migration
            // then has nothing left to do.
            print("PlanStoreSplitMigration failed (continuing to quarantine path): \(error)")
            defaults.set(true, forKey: splitMigrationDoneKey)
        }
    }

    private static func quarantine(storeURL: URL) {
        let dir = storeURL.deletingLastPathComponent()
        let base = storeURL.lastPathComponent
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupDir = dir.appendingPathComponent("StoreBackup-\(stamp)-\(base)", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for name in [base, base + "-shm", base + "-wal"] {
            let source = dir.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: source, to: backupDir.appendingPathComponent(name))
            try? FileManager.default.removeItem(at: source)
        }
    }
}
