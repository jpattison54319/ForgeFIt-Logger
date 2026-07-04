import Foundation

// MARK: - Set taxonomy

/// The kind of set, mirroring the `set_type` enum in the Postgres schema.
public enum SetType: String, Codable, CaseIterable, Sendable {
    case warmup, working, drop, restPause, backoff, amrap, myoRep, cluster

    /// Whether a set of this type contributes to *working* volume (set-count
    /// volume per muscle and tonnage). Warm-up sets do not count toward volume.
    public var countsAsWorkingVolume: Bool {
        self != .warmup
    }
}

/// How the load on a set is interpreted, mirroring `weight_mode` in the schema.
public enum WeightMode: String, Codable, Sendable {
    case external              // standard barbell/dumbbell/machine load
    case bodyweight            // pure bodyweight
    case bodyweightAssisted    // assistance subtracts from bodyweight
    case bodyweightAdded       // added weight adds to bodyweight
}

// MARK: - Domain values

/// A single logged set. Pure value type; the source of truth for all
/// load/volume math. Mirrors the `sets` table columns.
public struct SetEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var setType: SetType
    public var weightMode: WeightMode

    // Core metrics (nullable; presence depends on exercise/set type)
    public var reps: Int?
    public var weight: Double?          // the load the user entered (external mode)
    public var rpe: Double?
    public var rir: Int?
    public var durationSeconds: Int?
    public var holdSeconds: Int?
    public var partialReps: Int?

    // Bodyweight handling
    public var addedWeight: Double?
    public var assistanceWeight: Double?
    public var bodyweightKg: Double?

    // Unilateral handling
    public var isUnilateral: Bool
    public var implementWeight: Double? // weight of ONE dumbbell/implement
    public var limbCount: Int

    // Modifiers
    public var isEccentric: Bool
    public var isPaused: Bool

    public init(
        id: UUID = UUID(),
        setType: SetType = .working,
        weightMode: WeightMode = .external,
        reps: Int? = nil,
        weight: Double? = nil,
        rpe: Double? = nil,
        rir: Int? = nil,
        durationSeconds: Int? = nil,
        holdSeconds: Int? = nil,
        partialReps: Int? = nil,
        addedWeight: Double? = nil,
        assistanceWeight: Double? = nil,
        bodyweightKg: Double? = nil,
        isUnilateral: Bool = false,
        implementWeight: Double? = nil,
        limbCount: Int = 2,
        isEccentric: Bool = false,
        isPaused: Bool = false
    ) {
        self.id = id
        self.setType = setType
        self.weightMode = weightMode
        self.reps = reps
        self.weight = weight
        self.rpe = rpe
        self.rir = rir
        self.durationSeconds = durationSeconds
        self.holdSeconds = holdSeconds
        self.partialReps = partialReps
        self.addedWeight = addedWeight
        self.assistanceWeight = assistanceWeight
        self.bodyweightKg = bodyweightKg
        self.isUnilateral = isUnilateral
        self.implementWeight = implementWeight
        self.limbCount = limbCount
        self.isEccentric = isEccentric
        self.isPaused = isPaused
    }
}

/// The taxonomy facts about an exercise needed for muscle-volume accounting.
/// Mirrors the relevant `exercise_library` columns.
public struct ExerciseInfo: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var movementPattern: String?
    public var primaryMuscles: [String]
    public var secondaryMuscles: [String]
    public var equipment: String?
    public var isUnilateral: Bool
    public var mappedGlobalID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        movementPattern: String? = nil,
        primaryMuscles: [String] = [],
        secondaryMuscles: [String] = [],
        equipment: String? = nil,
        isUnilateral: Bool = false,
        mappedGlobalID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.movementPattern = movementPattern
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.isUnilateral = isUnilateral
        self.mappedGlobalID = mappedGlobalID
    }
}

public struct ExerciseAlias: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var exerciseID: UUID
    public var ownerID: UUID?
    public var alias: String

    public init(
        id: UUID = UUID(),
        exerciseID: UUID,
        ownerID: UUID? = nil,
        alias: String
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.ownerID = ownerID
        self.alias = alias
    }
}

public struct ExerciseSetupNote: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var userID: UUID
    public var exerciseID: UUID
    public var note: String
    public var seatHeight: String?
    public var grip: String?
    public var stance: String?
    public var painFlag: Bool

    public init(
        id: UUID = UUID(),
        userID: UUID,
        exerciseID: UUID,
        note: String,
        seatHeight: String? = nil,
        grip: String? = nil,
        stance: String? = nil,
        painFlag: Bool = false
    ) {
        self.id = id
        self.userID = userID
        self.exerciseID = exerciseID
        self.note = note
        self.seatHeight = seatHeight
        self.grip = grip
        self.stance = stance
        self.painFlag = painFlag
    }
}
