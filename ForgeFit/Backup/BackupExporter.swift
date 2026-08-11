import Compression
import ForgeCore
import ForgeData
import Foundation
import SwiftData

nonisolated struct BackupSnapshotMetadata: Sendable {
    let preferences: [String: BackupPreferenceValue]
    let userID: UUID
    let appVersion: String?
}

/// Structured outcome of a reset-time backup deletion. The reset flow maps
/// this directly onto user-facing consequences, so every failure mode must be
/// named explicitly — a swallowed delete must never read as "backup removed".
nonisolated enum BackupDeletionResult: Sendable, Equatable {
    /// Both backup files were removed (or none existed). The success stamp was
    /// cleared and the exporter returned to idle.
    case deleted
    /// The ubiquity container could not be resolved (signed out, offline, or
    /// inaccessible). The backup's fate is UNKNOWN — it may still exist — so
    /// status becomes `.unavailable` while the success stamp is preserved.
    case unavailable
    /// The deletion was interrupted (task cancelled) before completing.
    case cancelled
    /// The deletion failed; the backup may still exist. Carries the reason.
    case failed(String)
}

/// Injection seam for reset-time backup deletion. `BackupExporter` is the
/// production implementation; tests inject stubs so offline, failure, and
/// interruption paths run deterministically without touching iCloud.
nonisolated protocol BackupDeleting: Sendable {
    func deleteAllBackups() async -> BackupDeletionResult
}

/// Two-slot rotation that never moves `latest` out of the way. The prior
/// latest is copied atomically to `previous` first; only then is `latest`
/// atomically replaced with the new bytes. A failure or process interruption
/// before promotion therefore leaves the old latest in place.
nonisolated enum BackupFileRotation {
    enum Step: CaseIterable, Equatable, Sendable {
        case beforePreviousWrite
        case afterPreviousWrite
        case beforeLatestWrite
        case afterLatestWrite
    }

    static func rotate(
        newData: Data,
        latestURL: URL,
        previousURL: URL,
        atStep: ((Step) throws -> Void)? = nil
    ) throws {
        let priorLatest = FileManager.default.fileExists(atPath: latestURL.path)
            ? try Data(contentsOf: latestURL)
            : nil

        try atStep?(.beforePreviousWrite)
        if let priorLatest {
            try priorLatest.write(to: previousURL, options: .atomic)
        }
        try atStep?(.afterPreviousWrite)

        try atStep?(.beforeLatestWrite)
        try newData.write(to: latestURL, options: .atomic)
        try atStep?(.afterLatestWrite)
    }
}

/// Reads and maps the full log graph on a private context. Automatic backups
/// are intentionally delayed until the app is idle, but that delay is not a
/// performance boundary by itself: doing the eventual relationship faulting
/// on MainActor would still freeze scrolling when a daily backup is due.
nonisolated struct BackupSnapshotWorker: Sendable {
    let modelContainer: ModelContainer

    func snapshot(metadata: BackupSnapshotMetadata) async throws -> ForgeFitBackupFile {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let context = ModelContext(container)
            let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
            let batches = try context.fetch(FetchDescriptor<WorkoutImportBatchModel>())
            let microcycleTrackings = try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
            let microcycleWindows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            let restDays = try context.fetch(FetchDescriptor<RestDayModel>())
            let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
            let names = Dictionary(
                exercises.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            let file = BackupMapper.file(
                workouts: workouts,
                batches: batches,
                exerciseNames: names,
                preferences: metadata.preferences,
                userID: metadata.userID,
                appVersion: metadata.appVersion,
                microcycleTrackings: microcycleTrackings,
                microcycleWindows: microcycleWindows,
                restDays: restDays
            )
            try Task.checkCancellation()
            return file
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    #if DEBUG
    func isExecutingOnMainThreadForTesting() async -> Bool {
        let container = modelContainer
        return await Task.detached(priority: .utility) {
            _ = ModelContext(container)
            return Self.currentThreadIsMain()
        }.value
    }

    private static func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }
    #endif
}

/// Writes the sanitized training-log backup into the user's own iCloud
/// Drive (visible in Files → iCloud Drive → ForgeFit → Backups). The file
/// contains user-recorded training data. Direct Health fields are absent from
/// the DTOs, while `BackupMapper` filters HealthKit-imported workouts and
/// Health-provenance values. BackupFormatTests guard both layers.
actor BackupExporter {
    static let shared = BackupExporter()

    nonisolated enum Status: Equatable, Sendable {
        case idle
        case exporting
        /// Signed out of iCloud (ubiquity container unavailable).
        case unavailable
        case done(Date)
        case failed(String)
    }

    static let containerID = "iCloud.org.xpetsllc.ForgeFit"
    static let fileExtension = "forgefitbackup"
    static let lastSuccessKey = "backupLastSuccessAt"

    private(set) var status: Status = .idle

    /// Injectable for tests; nil = real ubiquity container.
    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    /// `Documents/Backups` inside the ubiquity container — Documents scope
    /// is what Files.app shows. Nil when signed out of iCloud.
    func backupDirectoryURL() -> URL? {
        if let directoryOverride { return directoryOverride }
        // Deliberately off-main: the first call can block while iCloud
        // provisions the container.
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID) else {
            return nil
        }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    func latestBackupURL() -> URL? {
        backupDirectoryURL()?.appendingPathComponent("ForgeFit-Backup-latest.\(Self.fileExtension)")
    }

    func previousBackupURL() -> URL? {
        backupDirectoryURL()?.appendingPathComponent("ForgeFit-Backup-previous.\(Self.fileExtension)")
    }

    /// Snapshot on a private SwiftData context, then map + compress + write on
    /// this actor. Returns the resulting status.
    @discardableResult
    func exportNow(container: ModelContainer) async -> Status {
        guard !Task.isCancelled else { return .idle }
        guard let directory = backupDirectoryURL(),
              let latestURL = latestBackupURL(),
              let previousURL = previousBackupURL() else {
            status = .unavailable
            return status
        }
        status = .exporting
        do {
            let file = try await Self.snapshotFile(container: container)
            guard !Task.isCancelled else {
                status = .idle
                return status
            }
            let data = try BackupMapper.encode(file)
            let compressed = try (data as NSData).compressed(using: .zlib) as Data

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Coordinate both slots. Rotation copies the prior latest to the
            // previous slot before atomically replacing latest, so there is no
            // move boundary at which the current backup disappears (FF-018).
            var coordinatorError: NSError?
            var rotationError: Error?
            NSFileCoordinator().coordinate(
                writingItemAt: latestURL,
                options: .forReplacing,
                writingItemAt: previousURL,
                options: .forReplacing,
                error: &coordinatorError
            ) { coordinatedLatest, coordinatedPrevious in
                do {
                    try BackupFileRotation.rotate(
                        newData: compressed,
                        latestURL: coordinatedLatest,
                        previousURL: coordinatedPrevious
                    )
                } catch {
                    rotationError = error
                }
            }
            if let error = coordinatorError ?? (rotationError.map { $0 as NSError }) { throw error }

            let stamp = Date()
            UserDefaults.standard.set(stamp, forKey: Self.lastSuccessKey)
            status = .done(stamp)
        } catch is CancellationError {
            // Lifecycle cancellation (a workout opened or the app moved to
            // background) is expected. Keep the prior backup and let the
            // scheduler retry later; never surface it as a user-facing error.
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
        return status
    }

    /// Reads either a zlib-compressed or plain-JSON backup file.
    static func readBackupData(_ raw: Data) throws -> Data {
        if let first = raw.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return raw
        }
        return try (raw as NSData).decompressed(using: .zlib) as Data
    }

    /// The privacy policy promises "Erase All Data also removes the backup".
    /// Unlike the old fire-and-forget task, this awaits the coordinated
    /// removal and reports a structured result. The success stamp is cleared
    /// and status returns to idle ONLY when deletion actually completed; a
    /// failure, interruption, or unavailable container preserves the success
    /// stamp and leaves a non-idle status so no caller can mistake an
    /// incomplete delete for a done one.
    /// Coordinator and removal errors are surfaced, never swallowed.
    @discardableResult
    func deleteAllBackups() async -> BackupDeletionResult {
        guard !Task.isCancelled else {
            status = .failed("Backup deletion was interrupted.")
            return .cancelled
        }
        guard let latest = latestBackupURL(), let previous = previousBackupURL() else {
            // The ubiquity container could not be resolved (signed out,
            // offline, or inaccessible). That proves nothing about the backup
            // files themselves — it only proves we could not look for them —
            // so the outcome is unresolved, not success: no stamp clear, no
            // idle transition.
            status = .unavailable
            return .unavailable
        }
        do {
            try Self.removeBackupFileIfPresent(at: latest)
            try Task.checkCancellation()
            try Self.removeBackupFileIfPresent(at: previous)
        } catch is CancellationError {
            status = .failed("Backup deletion was interrupted.")
            return .cancelled
        } catch {
            status = .failed(error.localizedDescription)
            return .failed(error.localizedDescription)
        }
        UserDefaults.standard.removeObject(forKey: Self.lastSuccessKey)
        status = .idle
        return .deleted
    }

    /// Coordinated removal of one backup file. A missing file is success
    /// (nothing to delete); any coordinator or removal error is thrown so the
    /// caller can report the failure instead of assuming the backup is gone.
    private static func removeBackupFileIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinatorError: NSError?
        var removeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { deletionURL in
            do {
                try FileManager.default.removeItem(at: deletionURL)
            } catch {
                removeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let removeError { throw removeError }
    }

    // MARK: - Snapshot

    // Internal (not private): the user-facing data export reuses this same
    // snapshot so backup and export can never disagree about the training log.
    nonisolated static func snapshotFile(container: ModelContainer) async throws -> ForgeFitBackupFile {
        let metadata = await MainActor.run { snapshotMetadata() }
        return try await BackupSnapshotWorker(modelContainer: container)
            .snapshot(metadata: metadata)
    }

    @MainActor
    private static func snapshotMetadata() -> BackupSnapshotMetadata {
        var preferences: [String: BackupPreferenceValue] = [:]
        let defaults = UserDefaults.standard
        for key in AppPreferenceKeys.backedUp {
            guard let value = defaults.object(forKey: key) else { continue }
            switch value {
            case let bool as Bool where CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID():
                preferences[key] = .bool(bool)
            case let int as Int:
                preferences[key] = .int(int)
            case let double as Double:
                preferences[key] = .double(double)
            case let string as String:
                preferences[key] = .string(string)
            case let data as Data:
                // JSON-blob prefs (quick starts, plate inventory) travel as
                // base64 strings.
                preferences[key] = .string(data.base64EncodedString())
            case let array as [Int]:
                // reminderWeekdays — encode as CSV string.
                preferences[key] = .string(array.map(String.init).joined(separator: ","))
            default:
                continue
            }
        }

        return BackupSnapshotMetadata(
            preferences: preferences,
            userID: ForgeFitDemo.userID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }
}

extension BackupExporter: BackupDeleting {}
extension BackupExporter: BackupManaging {}
