import Foundation

/// ForgeFit's sanitized training-log backup, v1 — the file written to the
/// user's iCloud Drive (App Store Guideline 5.1.3(ii): no personal health
/// information in iCloud).
///
/// THE SANITIZATION BOUNDARY IS THE TYPE SYSTEM: these DTOs simply have no
/// properties for health data. There is no `avgHR`, no `activeEnergyKcal`,
/// no `hrZoneSeconds`, no `readinessAtStart`, no `hkWorkoutUUID`, no `tss`,
/// no `sampleSeriesJSON`, no `bodyweightKg`, no steps/floors, and no
/// check-in, wrapped-report, or HR-zone-config types at all — so no code
/// path can leak what the output type cannot express. Health metrics are
/// re-attached on restore from the user's own Apple Health store.
///
/// Field names deliberately mirror the "ForgeFit JSON" import shape where
/// they overlap, so `WorkoutHistoryImportParser.parseForgeFitJSON` can read
/// a backup file as a degraded fallback (JSONDecoder ignores unknown keys).
public struct ForgeFitBackupFile: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var userID: UUID
    public var appVersion: String?
    public var preferences: [String: BackupPreferenceValue]
    public var workouts: [BackupWorkout]
    public var importBatches: [BackupImportBatch]

    public init(
        schemaVersion: Int = ForgeFitBackupFile.currentSchemaVersion,
        exportedAt: Date,
        userID: UUID,
        appVersion: String? = nil,
        preferences: [String: BackupPreferenceValue] = [:],
        workouts: [BackupWorkout] = [],
        importBatches: [BackupImportBatch] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.userID = userID
        self.appVersion = appVersion
        self.preferences = preferences
        self.workouts = workouts
        self.importBatches = importBatches
    }
}

/// A UserDefaults preference value, restricted to the plist scalar types
/// the app actually stores.
public enum BackupPreferenceValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

public struct BackupWorkout: Codable, Sendable {
    public var id: UUID
    public var routineID: UUID?
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var sourceDevice: String?
    public var notes: String?
    public var externalSource: String?
    /// Named to match the import format's key.
    public var externalID: String?
    public var importFingerprint: String?
    public var importBatchID: UUID?
    public var xpAwardedAmount: Int?
    public var xpAwardedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Soft-deletes must survive restore, or the Health importer would
    /// resurrect deleted workouts on the new device.
    public var deletedAt: Date?
    public var exercises: [BackupWorkoutExercise]
    public var cardioSessions: [BackupCardioSession]
}

public struct BackupWorkoutExercise: Codable, Sendable {
    public var id: UUID
    public var exerciseID: UUID
    /// Denormalized so restore can re-match by name when the library row
    /// isn't in the destination CloudKit account.
    public var name: String
    public var position: Int
    public var supersetGroup: Int?
    public var notes: String?
    public var notePinned: Bool
    public var restSeconds: Int?
    public var microRestSeconds: Int?
    public var intervalPlanJSON: String?
    public var yogaFlowJSON: String?
    public var sourceRoutineExerciseID: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    public var sets: [BackupSet]
}

public struct BackupSet: Codable, Sendable {
    public var id: UUID
    public var position: Int
    public var setType: String
    public var weightMode: String
    public var reps: Int?
    /// Kilograms, matching the import format's `weightKg`.
    public var weightKg: Double?
    public var rpe: Double?
    public var rir: Int?
    public var durationSeconds: Int?
    public var holdSeconds: Int?
    public var partialReps: Int?
    public var addedWeight: Double?
    public var assistanceWeight: Double?
    public var isUnilateral: Bool
    public var implementWeight: Double?
    public var limbCount: Int
    public var isEccentric: Bool
    public var isPaused: Bool
    public var machineSettingsJSON: String?
    public var sourceRoutineSetID: UUID?
    public var miniRepsJSON: String?
    public var side2Reps: Int?
    public var side2MiniRepsJSON: String?
    public var plannedMiniSetCount: Int?
    public var plannedMiniRepsJSON: String?
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
}

public struct BackupCardioSession: Codable, Sendable {
    public var id: UUID
    public var workoutExerciseID: UUID?
    public var modality: String
    public var startedAt: Date
    public var liveStartedAt: Date?
    public var endedAt: Date?
    public var sourceDevice: String?
    public var durationSeconds: Int?
    public var distanceMeters: Double?
    /// Subjective 1–10 effort the user picked — a rating, not a biometric.
    public var effort: Int?
    public var avgPaceSecondsPerKm: Double?
    public var split500mSeconds: Double?
    public var strokeRate: Int?
    public var avgPowerWatts: Double?
    public var avgCadence: Int?
    public var resistanceLevel: Int?
    public var inclinePercent: Double?
    public var elevationGainMeters: Double?
    public var intervalsAutoApplied: Bool
    public var yogaStyleRaw: String?
    public var posesCompleted: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var splits: [BackupCardioSplit]
    public var routePoints: [BackupRoutePoint]
}

public struct BackupCardioSplit: Codable, Sendable {
    public var id: UUID
    public var index: Int
    public var distanceMeters: Double
    public var durationSeconds: Int
    public var paceSecondsPerKm: Double
    public var elevationGainMeters: Double?
    public var label: String?
    public var autoDetected: Bool
    public var startedAt: Date
    public var endedAt: Date
}

/// GPS route point — location data, not health data. Short keys because
/// this array dominates file size; coordinates are rounded to 6 decimals
/// (~11 cm) at mapping time.
public struct BackupRoutePoint: Codable, Sendable {
    public var t: Date
    public var lat: Double
    public var lon: Double
    public var alt: Double?
    public var acc: Double?
    public var spd: Double?
}

public struct BackupImportBatch: Codable, Sendable {
    public var id: UUID
    public var source: String
    public var fileName: String?
    public var importedCount: Int
    public var skippedDuplicateCount: Int
    public var warningCount: Int
    public var startedAt: Date?
    public var endedAt: Date?
    public var createdAt: Date
}
