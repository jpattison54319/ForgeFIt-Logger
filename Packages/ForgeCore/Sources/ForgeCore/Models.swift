import Foundation

// MARK: - Set taxonomy

/// The kind of set, mirroring the `set_type` enum in the Postgres schema.
public enum SetType: String, Codable, CaseIterable, Sendable {
    case warmup, working, drop, restPause, backoff, amrap, myoRep, cluster

    /// The types offered in set-type pickers. `restPause` is retired — it is
    /// indistinguishable from myo-reps in practice, so new sets can't choose
    /// it. The case stays in the enum so legacy synced data still decodes;
    /// a launch backfill converts stored rest-pause sets to myo-reps.
    public static var selectable: [SetType] {
        allCases.filter { $0 != .restPause }
    }

    /// Whether a set of this type contributes to *working* volume (set-count
    /// volume per muscle and tonnage). Warm-up sets do not count toward volume.
    public var countsAsWorkingVolume: Bool {
        self != .warmup
    }

    /// Rest after completing a whole set. Drop sets deliberately flow into
    /// the next drop without a timer; every other performed set gets a
    /// contextual default unless the exercise overrides it.
    public var defaultRestSeconds: Int? {
        switch self {
        case .warmup: 60
        case .working, .backoff: 120
        case .amrap: 180
        case .drop: nil
        case .myoRep, .restPause, .cluster: 120
        }
    }

    /// Rest between the activation/segments inside one structured set.
    public var defaultMicroRestSeconds: Int? {
        switch self {
        case .myoRep: 15
        case .restPause, .cluster: 20
        default: nil
        }
    }

    /// Structured sets are performed as activation/segment progress rather
    /// than a single flat row completion.
    public var isBlockType: Bool {
        self == .myoRep || self == .restPause || self == .cluster
    }
}

/// Minimal value used by both the phone and Watch command paths to reason
/// about superset rounds without depending on SwiftData models.
public struct SupersetSetProgress: Equatable, Sendable {
    public let id: UUID
    public let setType: SetType
    public let isComplete: Bool

    public init(id: UUID, setType: SetType, isComplete: Bool) {
        self.id = id
        self.setType = setType
        self.isComplete = isComplete
    }
}

/// Maps raw set arrays onto logical superset rounds. A base set and all drop
/// sets immediately following it belong to one round, so unequal drop chains
/// never shift the round compared with another superset member.
public enum SupersetRoundPolicy {
    public static func logicalRoundIndex(
        for setID: UUID,
        in sets: [SupersetSetProgress]
    ) -> Int? {
        var logicalRound = -1
        for set in sets {
            if set.setType != .drop {
                logicalRound += 1
            }
            if set.id == setID {
                return logicalRound >= 0 ? logicalRound : nil
            }
        }
        return nil
    }

    /// Missing rounds are satisfied, matching a shorter superset member: only
    /// a round that actually exists on that member can block group rest.
    public static func isRoundSatisfied(
        _ requestedRound: Int,
        in sets: [SupersetSetProgress]
    ) -> Bool {
        guard requestedRound >= 0 else { return false }
        var logicalRound = -1

        for set in sets {
            if set.setType != .drop {
                logicalRound += 1
                if logicalRound > requestedRound { break }
            }
            guard logicalRound == requestedRound else { continue }
            if !set.isComplete { return false }
        }

        return true
    }

    public static func hasPendingDrop(
        after setID: UUID,
        in sets: [SupersetSetProgress]
    ) -> Bool {
        guard let index = sets.firstIndex(where: { $0.id == setID }) else { return false }
        let nextIndex = index + 1
        guard sets.indices.contains(nextIndex), sets[nextIndex].setType == .drop else { return false }
        return !sets[nextIndex].isComplete
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

    // Structured-set shape (myo-reps / rest-pause / cluster), for effective
    // set counting: how many mini-sets followed the activation, and whether a
    // second side was logged explicitly (unilateral per-side flow).
    public var miniSetCount: Int
    public var side2Logged: Bool
    public var side2MiniSetCount: Int

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
        isPaused: Bool = false,
        miniSetCount: Int = 0,
        side2Logged: Bool = false,
        side2MiniSetCount: Int = 0
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
        self.miniSetCount = miniSetCount
        self.side2Logged = side2Logged
        self.side2MiniSetCount = side2MiniSetCount
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
