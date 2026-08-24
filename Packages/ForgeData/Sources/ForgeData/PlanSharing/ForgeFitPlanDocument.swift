import ForgeCore
import Foundation

/// The plan-file vocabulary for authored set types. This switch is
/// intentionally exhaustive: adding a `SetType` cannot compile until its
/// sharing compatibility is classified. Raising the returned version also
/// raises `ForgeFitPlanDocument.currentVersion` automatically.
public enum ForgeFitPlanSetTypeContract {
    public static func introducedVersion(for type: SetType) -> Int {
        switch type {
        case .warmup, .working, .drop, .restPause, .backoff, .amrap, .myoRep, .cluster:
            1
        case .lengthenedPartial, .lengthenedExtended:
            3
        }
    }

    public static var latestVersion: Int {
        SetType.allCases.map(introducedVersion(for:)).max() ?? 1
    }

    public static func supports(_ type: SetType, in documentVersion: Int) -> Bool {
        if documentVersion >= introducedVersion(for: type) { return true }

        // Builds between the set-type launch and the explicit v3 contract
        // emitted these two raw values in v2 files. Keep those files usable.
        return documentVersion == 2
            && (type == .lengthenedPartial || type == .lengthenedExtended)
    }
}

/// A user-created training plan that can leave ForgeFit without carrying any
/// workout history, Health data, account identity, or local progress state.
public struct ForgeFitPlanDocument: Codable, Equatable, Sendable {
    /// v3 adds the lengthened-partial and lengthened-extended set vocabulary.
    /// Keeping this distinct from v2 makes older recipients request an app
    /// update instead of misdiagnosing a valid set type as document damage.
    public static let currentVersion = max(2, ForgeFitPlanSetTypeContract.latestVersion)

    public var formatVersion: Int
    public var packageID: UUID
    public var createdAt: Date
    public var appVersion: String?
    public var kind: ForgeFitPlanKind
    public var name: String
    public var folders: [SharedPlanFolder]
    public var routines: [SharedPlanRoutine]
    public var alternations: [SharedPlanAlternation]
    public var exercises: [SharedPlanExercise]

    public init(
        formatVersion: Int = Self.currentVersion,
        packageID: UUID = UUID(),
        createdAt: Date,
        appVersion: String? = nil,
        kind: ForgeFitPlanKind,
        name: String,
        folders: [SharedPlanFolder] = [],
        routines: [SharedPlanRoutine],
        alternations: [SharedPlanAlternation] = [],
        exercises: [SharedPlanExercise]
    ) {
        self.formatVersion = formatVersion
        self.packageID = packageID
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.kind = kind
        self.name = name
        self.folders = folders
        self.routines = routines
        self.alternations = alternations
        self.exercises = exercises
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, packageID, createdAt, appVersion, kind, name
        case folders, routines, alternations, exercises
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        packageID = try container.decode(UUID.self, forKey: .packageID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        kind = try container.decode(ForgeFitPlanKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        folders = try container.decode([SharedPlanFolder].self, forKey: .folders)
        routines = try container.decode([SharedPlanRoutine].self, forKey: .routines)
        alternations = try container.decodeIfPresent([SharedPlanAlternation].self, forKey: .alternations) ?? []
        exercises = try container.decode([SharedPlanExercise].self, forKey: .exercises)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(packageID, forKey: .packageID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
        try container.encode(folders, forKey: .folders)
        try container.encode(routines, forKey: .routines)
        try container.encode(alternations, forKey: .alternations)
        try container.encode(exercises, forKey: .exercises)
    }
}

public enum ForgeFitPlanKind: String, Codable, CaseIterable, Sendable {
    case routine
    case microcycle
    case mesocycle

    public var title: String {
        switch self {
        case .routine: "Routine"
        case .microcycle: "Microcycle"
        case .mesocycle: "Mesocycle"
        }
    }
}

public struct SharedPlanFolder: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var position: Int
    public var parentID: UUID?
    public var defaultMicrocycleLengthDays: Int?

    public init(
        id: UUID,
        name: String,
        position: Int,
        parentID: UUID? = nil,
        defaultMicrocycleLengthDays: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.position = position
        self.parentID = parentID
        self.defaultMicrocycleLengthDays = defaultMicrocycleLengthDays
    }
}

public struct SharedPlanRoutine: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String?
    public var folderID: UUID?
    public var position: Int
    public var conditioningPlanJSON: String?
    public var exercises: [SharedPlanRoutineExercise]
    public var blocks: [SharedPlanRoutineBlock]

    public init(
        id: UUID,
        name: String,
        notes: String? = nil,
        folderID: UUID? = nil,
        position: Int,
        conditioningPlanJSON: String? = nil,
        exercises: [SharedPlanRoutineExercise] = [],
        blocks: [SharedPlanRoutineBlock] = []
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.folderID = folderID
        self.position = position
        self.conditioningPlanJSON = conditioningPlanJSON
        self.exercises = exercises
        self.blocks = blocks
    }
}

public struct SharedPlanAlternation: Codable, Equatable, Sendable {
    public var id: UUID
    public var ownerRoutineID: UUID
    public var partnerRoutineID: UUID

    public init(id: UUID, ownerRoutineID: UUID, partnerRoutineID: UUID) {
        self.id = id
        self.ownerRoutineID = ownerRoutineID
        self.partnerRoutineID = partnerRoutineID
    }
}

public struct SharedPlanRoutineBlock: Codable, Equatable, Sendable {
    public var id: UUID
    public var kindRaw: String
    public var position: Int
    public var planJSON: String?

    public init(id: UUID, kindRaw: String, position: Int, planJSON: String? = nil) {
        self.id = id
        self.kindRaw = kindRaw
        self.position = position
        self.planJSON = planJSON
    }
}

public struct SharedPlanRoutineExercise: Codable, Equatable, Sendable {
    public var id: UUID
    public var exerciseID: UUID
    public var position: Int
    public var supersetGroup: Int?
    public var progressionRuleID: UUID?
    public var progressionRuleJSON: String?
    public var notes: String?
    public var intervalPlanJSON: String?
    public var yogaFlowJSON: String?
    public var sets: [SharedPlanRoutineSet]

    public init(
        id: UUID,
        exerciseID: UUID,
        position: Int,
        supersetGroup: Int? = nil,
        progressionRuleID: UUID? = nil,
        progressionRuleJSON: String? = nil,
        notes: String? = nil,
        intervalPlanJSON: String? = nil,
        yogaFlowJSON: String? = nil,
        sets: [SharedPlanRoutineSet] = []
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.position = position
        self.supersetGroup = supersetGroup
        self.progressionRuleID = progressionRuleID
        self.progressionRuleJSON = progressionRuleJSON
        self.notes = notes
        self.intervalPlanJSON = intervalPlanJSON
        self.yogaFlowJSON = yogaFlowJSON
        self.sets = sets
    }
}

public struct SharedPlanRoutineSet: Codable, Equatable, Sendable {
    public var id: UUID
    public var position: Int
    public var setTypeRaw: String
    public var targetRepsLow: Int?
    public var targetRepsHigh: Int?
    public var targetWeight: Double?
    public var loadPrescriptionModeRaw: String?
    public var target1RMPercentLow: Double?
    public var target1RMPercentHigh: Double?
    public var targetRPE: Double?
    public var targetRIR: Int?
    public var targetDurationSeconds: Int?
    public var targetDistanceMeters: Double?
    public var plannedMiniSetCount: Int?
    public var plannedMiniRepsJSON: String?

    public init(
        id: UUID,
        position: Int,
        setTypeRaw: String,
        targetRepsLow: Int? = nil,
        targetRepsHigh: Int? = nil,
        targetWeight: Double? = nil,
        loadPrescriptionModeRaw: String? = nil,
        target1RMPercentLow: Double? = nil,
        target1RMPercentHigh: Double? = nil,
        targetRPE: Double? = nil,
        targetRIR: Int? = nil,
        targetDurationSeconds: Int? = nil,
        targetDistanceMeters: Double? = nil,
        plannedMiniSetCount: Int? = nil,
        plannedMiniRepsJSON: String? = nil
    ) {
        self.id = id
        self.position = position
        self.setTypeRaw = setTypeRaw
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetWeight = targetWeight
        self.loadPrescriptionModeRaw = loadPrescriptionModeRaw
        self.target1RMPercentLow = target1RMPercentLow
        self.target1RMPercentHigh = target1RMPercentHigh
        self.targetRPE = targetRPE
        self.targetRIR = targetRIR
        self.targetDurationSeconds = targetDurationSeconds
        self.targetDistanceMeters = targetDistanceMeters
        self.plannedMiniSetCount = plannedMiniSetCount
        self.plannedMiniRepsJSON = plannedMiniRepsJSON
    }
}

/// A self-contained exercise fallback. Account/import bookkeeping is omitted;
/// only fields needed to understand and execute a shared plan are present.
public struct SharedPlanExercise: Codable, Equatable, Sendable {
    public var id: UUID
    public var isCustom: Bool
    public var name: String
    public var movementPattern: String?
    public var primaryMuscles: [String]
    public var secondaryMuscles: [String]
    public var equipment: String?
    public var isUnilateral: Bool
    public var defaultWeightModeRaw: String
    public var preferredWeightUnitRaw: String?
    public var difficulty: String?
    public var isCardio: Bool
    public var cardioKindRaw: String?
    public var modalityRaw: String?
    public var defaultHoldSeconds: Int?
    public var mappedGlobalID: UUID?
    public var instructions: [String]
    public var mechanic: String?
    public var mediaSlug: String?
    public var category: String?
    public var force: String?

    public init(
        id: UUID,
        isCustom: Bool,
        name: String,
        movementPattern: String? = nil,
        primaryMuscles: [String] = [],
        secondaryMuscles: [String] = [],
        equipment: String? = nil,
        isUnilateral: Bool = false,
        defaultWeightModeRaw: String,
        preferredWeightUnitRaw: String? = nil,
        difficulty: String? = nil,
        isCardio: Bool = false,
        cardioKindRaw: String? = nil,
        modalityRaw: String? = nil,
        defaultHoldSeconds: Int? = nil,
        mappedGlobalID: UUID? = nil,
        instructions: [String] = [],
        mechanic: String? = nil,
        mediaSlug: String? = nil,
        category: String? = nil,
        force: String? = nil
    ) {
        self.id = id
        self.isCustom = isCustom
        self.name = name
        self.movementPattern = movementPattern
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.isUnilateral = isUnilateral
        self.defaultWeightModeRaw = defaultWeightModeRaw
        self.preferredWeightUnitRaw = preferredWeightUnitRaw
        self.difficulty = difficulty
        self.isCardio = isCardio
        self.cardioKindRaw = cardioKindRaw
        self.modalityRaw = modalityRaw
        self.defaultHoldSeconds = defaultHoldSeconds
        self.mappedGlobalID = mappedGlobalID
        self.instructions = instructions
        self.mechanic = mechanic
        self.mediaSlug = mediaSlug
        self.category = category
        self.force = force
    }
}

public enum ForgeFitPlanCodec {
    public static func encode(_ document: ForgeFitPlanDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> ForgeFitPlanDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ForgeFitPlanDocument.self, from: data)
    }
}
