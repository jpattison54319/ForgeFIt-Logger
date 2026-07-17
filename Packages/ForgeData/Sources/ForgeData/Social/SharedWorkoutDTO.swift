import Foundation

/// A training-only projection of a logged workout, safe to publish to OTHER
/// users via the CloudKit public database.
///
/// THE SANITIZATION BOUNDARY IS THE TYPE SYSTEM — exactly the discipline
/// `BackupWorkout` uses, but stricter because this leaves the user's own
/// devices. The type has no properties for:
///   • health data — heart rate, energy, HR zones, readiness, HealthKit
///     linkage, per-set `bodyweightKg`, or (on cardio) TSS / step / floor /
///     HR-sample-stream / flexibility-exposure fields;
///   • location — cardio `routePoints` (GPS) are dropped entirely;
///   • provenance/internal — import source/fingerprint, XP, soft-delete,
///     routine linkage, device, timestamps;
///   • free text — workout/exercise `notes` (UGC deferred to moderation).
/// Cardio and yoga sessions ARE shared, but only their training fields
/// (modality, duration, distance, pace, power, cadence, effort, yoga style,
/// poses, and non-GPS splits). A code path cannot leak into a friend's device
/// what the type cannot express.
///
/// Derived per-set aggregates (`effectiveLoad`, `totalVolume`, `estimated1RM`)
/// ARE carried: they are computed numbers that let a viewer show volume and
/// e1RM WITHOUT ever receiving the sharer's body weight (the input they were
/// derived from). `weightKg` is training load, not a scale reading.
public struct SharedWorkoutDTO: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var id: UUID
    public var title: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var exercises: [SharedExerciseDTO]
    public var cardioSessions: [SharedCardioSessionDTO]

    public init(
        schemaVersion: Int = SharedWorkoutDTO.currentSchemaVersion,
        id: UUID,
        title: String?,
        startedAt: Date,
        endedAt: Date?,
        exercises: [SharedExerciseDTO],
        cardioSessions: [SharedCardioSessionDTO] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exercises = exercises
        self.cardioSessions = cardioSessions
    }
}

/// A cardio or yoga session, health- and location-stripped. Mirrors the
/// training fields of `BackupCardioSession` MINUS `routePoints` (GPS) and the
/// device/internal fields — and, like the backup, has no property at all for
/// heart rate, energy, HR zones, TSS, steps, floors, or HR sample streams.
public struct SharedCardioSessionDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var modality: String
    public var startedAt: Date
    public var endedAt: Date?
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
    public var yogaStyleRaw: String?
    public var posesCompleted: Int?
    public var splits: [SharedCardioSplitDTO]

    public init(
        id: UUID, modality: String, startedAt: Date, endedAt: Date?, durationSeconds: Int?,
        distanceMeters: Double?, effort: Int?, avgPaceSecondsPerKm: Double?, split500mSeconds: Double?,
        strokeRate: Int?, avgPowerWatts: Double?, avgCadence: Int?, resistanceLevel: Int?,
        inclinePercent: Double?, elevationGainMeters: Double?, yogaStyleRaw: String?,
        posesCompleted: Int?, splits: [SharedCardioSplitDTO]
    ) {
        self.id = id
        self.modality = modality
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.effort = effort
        self.avgPaceSecondsPerKm = avgPaceSecondsPerKm
        self.split500mSeconds = split500mSeconds
        self.strokeRate = strokeRate
        self.avgPowerWatts = avgPowerWatts
        self.avgCadence = avgCadence
        self.resistanceLevel = resistanceLevel
        self.inclinePercent = inclinePercent
        self.elevationGainMeters = elevationGainMeters
        self.yogaStyleRaw = yogaStyleRaw
        self.posesCompleted = posesCompleted
        self.splits = splits
    }

    public var isYoga: Bool { modality == "yoga" }
}

/// A per-segment split — distance/pace/duration/elevation only. No coordinates.
public struct SharedCardioSplitDTO: Codable, Sendable, Equatable {
    public var index: Int
    public var distanceMeters: Double
    public var durationSeconds: Int
    public var paceSecondsPerKm: Double
    public var elevationGainMeters: Double?
    public var label: String?
    public var autoDetected: Bool

    public init(index: Int, distanceMeters: Double, durationSeconds: Int, paceSecondsPerKm: Double, elevationGainMeters: Double?, label: String?, autoDetected: Bool) {
        self.index = index
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.paceSecondsPerKm = paceSecondsPerKm
        self.elevationGainMeters = elevationGainMeters
        self.label = label
        self.autoDetected = autoDetected
    }
}

public struct SharedExerciseDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var exerciseID: UUID
    /// Denormalized so a viewer whose library lacks this row still sees a name.
    public var name: String
    public var position: Int
    public var supersetGroup: Int?
    public var sets: [SharedSetDTO]

    public init(
        id: UUID,
        exerciseID: UUID,
        name: String,
        position: Int,
        supersetGroup: Int?,
        sets: [SharedSetDTO]
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.name = name
        self.position = position
        self.supersetGroup = supersetGroup
        self.sets = sets
    }
}

public struct SharedSetDTO: Codable, Sendable, Equatable {
    public var id: UUID
    public var position: Int
    public var setType: String
    public var weightMode: String
    public var reps: Int?
    /// Kilograms — training load, not body weight.
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
    public var miniRepsJSON: String?
    public var side2Reps: Int?
    public var side2MiniRepsJSON: String?
    public var plannedMiniSetCount: Int?
    public var plannedMiniRepsJSON: String?
    /// Precomputed so a viewer sees load/e1RM without the sharer's body weight.
    public var effectiveLoad: Double?
    public var totalVolume: Double?
    public var estimated1RM: Double?
    public var completedAt: Date?

    public init(
        id: UUID,
        position: Int,
        setType: String,
        weightMode: String,
        reps: Int?,
        weightKg: Double?,
        rpe: Double?,
        rir: Int?,
        durationSeconds: Int?,
        holdSeconds: Int?,
        partialReps: Int?,
        addedWeight: Double?,
        assistanceWeight: Double?,
        isUnilateral: Bool,
        implementWeight: Double?,
        limbCount: Int,
        isEccentric: Bool,
        isPaused: Bool,
        machineSettingsJSON: String?,
        miniRepsJSON: String?,
        side2Reps: Int?,
        side2MiniRepsJSON: String?,
        plannedMiniSetCount: Int?,
        plannedMiniRepsJSON: String?,
        effectiveLoad: Double?,
        totalVolume: Double?,
        estimated1RM: Double?,
        completedAt: Date?
    ) {
        self.id = id
        self.position = position
        self.setType = setType
        self.weightMode = weightMode
        self.reps = reps
        self.weightKg = weightKg
        self.rpe = rpe
        self.rir = rir
        self.durationSeconds = durationSeconds
        self.holdSeconds = holdSeconds
        self.partialReps = partialReps
        self.addedWeight = addedWeight
        self.assistanceWeight = assistanceWeight
        self.isUnilateral = isUnilateral
        self.implementWeight = implementWeight
        self.limbCount = limbCount
        self.isEccentric = isEccentric
        self.isPaused = isPaused
        self.machineSettingsJSON = machineSettingsJSON
        self.miniRepsJSON = miniRepsJSON
        self.side2Reps = side2Reps
        self.side2MiniRepsJSON = side2MiniRepsJSON
        self.plannedMiniSetCount = plannedMiniSetCount
        self.plannedMiniRepsJSON = plannedMiniRepsJSON
        self.effectiveLoad = effectiveLoad
        self.totalVolume = totalVolume
        self.estimated1RM = estimated1RM
        self.completedAt = completedAt
    }
}

/// Compact, health-free rollup for a recent-workouts list and the queryable
/// CloudKit record fields (so a profile list renders without decoding the full
/// payload). Deliberately has no `avgHR` — unlike `TrainingAnalytics.Summary`,
/// which is health-derived.
public struct SharedWorkoutSummary: Codable, Sendable, Equatable {
    public var volumeKg: Double
    public var workingSets: Int
    public var reps: Int
    public var durationSeconds: Int
    public var exerciseCount: Int
    public var distanceMeters: Double
    /// "strength" | "cardio" | "yoga" — drives the row icon and which stats show.
    public var kind: String

    public init(volumeKg: Double, workingSets: Int, reps: Int, durationSeconds: Int, exerciseCount: Int, distanceMeters: Double = 0, kind: String = "strength") {
        self.volumeKg = volumeKg
        self.workingSets = workingSets
        self.reps = reps
        self.durationSeconds = durationSeconds
        self.exerciseCount = exerciseCount
        self.distanceMeters = distanceMeters
        self.kind = kind
    }
}
