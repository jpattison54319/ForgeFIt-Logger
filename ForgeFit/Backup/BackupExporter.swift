import Compression
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Writes the sanitized training-log backup into the user's own iCloud
/// Drive (visible in Files → iCloud Drive → ForgeFit → Backups). The file
/// contains ONLY user-authored training data — the DTO types in
/// `BackupFormat.swift` cannot express health fields, and BackupFormatTests
/// asserts nothing health-derived ever appears in the bytes. This is the
/// 5.1.3(ii)-compliant replacement for syncing the log through CloudKit.
actor BackupExporter {
    static let shared = BackupExporter()

    enum Status: Equatable {
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

    /// Snapshot on the MainActor (SwiftData models are main-bound), map +
    /// compress + write here. Returns the resulting status.
    @discardableResult
    func exportNow(container: ModelContainer) async -> Status {
        guard let directory = backupDirectoryURL(),
              let latestURL = latestBackupURL(),
              let previousURL = previousBackupURL() else {
            status = .unavailable
            return status
        }
        status = .exporting
        do {
            let file = try await Self.snapshotFile(container: container)
            let data = try BackupMapper.encode(file)
            let compressed = try (data as NSData).compressed(using: .zlib) as Data

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ForgeFit-Backup-\(UUID().uuidString).\(Self.fileExtension)")
            try compressed.write(to: temp, options: .atomic)

            // Coordinated rotate: latest → previous, temp → latest.
            var coordinatorError: NSError?
            var moveError: Error?
            NSFileCoordinator().coordinate(writingItemAt: latestURL, options: .forReplacing, error: &coordinatorError) { url in
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try? FileManager.default.removeItem(at: previousURL)
                        try FileManager.default.moveItem(at: url, to: previousURL)
                    }
                    try FileManager.default.moveItem(at: temp, to: url)
                } catch {
                    moveError = error
                }
            }
            if let error = coordinatorError ?? (moveError.map { $0 as NSError }) { throw error }

            let stamp = Date()
            UserDefaults.standard.set(stamp, forKey: Self.lastSuccessKey)
            status = .done(stamp)
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
    func deleteAllBackups() {
        guard let latest = latestBackupURL(), let previous = previousBackupURL() else { return }
        for url in [latest, previous] {
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinatorError) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }
        UserDefaults.standard.removeObject(forKey: Self.lastSuccessKey)
        status = .idle
    }

    // MARK: - Snapshot (MainActor — models are main-bound)

    @MainActor
    private static func snapshotFile(container: ModelContainer) throws -> ForgeFitBackupFile {
        let context = container.mainContext
        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        let batches = try context.fetch(FetchDescriptor<WorkoutImportBatchModel>())
        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let names = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

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

        return BackupMapper.file(
            workouts: workouts,
            batches: batches,
            exerciseNames: names,
            preferences: preferences,
            userID: ForgeFitDemo.userID,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
    }
}
