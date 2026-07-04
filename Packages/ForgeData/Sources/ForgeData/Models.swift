import Foundation
import ForgeCore
import SwiftData

public enum ForgeDataSchema {
    public static var models: [any PersistentModel.Type] {
        [
            ExerciseLibraryModel.self,
            ExerciseAliasModel.self,
            UserExerciseNoteModel.self,
            RoutineFolderModel.self,
            RoutineModel.self,
            RoutineExerciseModel.self,
            RoutineSetModel.self,
            WorkoutModel.self,
            WorkoutExerciseModel.self,
            SetModel.self,
            WorkoutImportBatchModel.self,
            UserProgressModel.self,
            WorkoutXPEventModel.self,
            CardioSessionModel.self,
            CardioRoutePointModel.self,
            CardioSplitModel.self
        ]
    }
}

/// A named container for organizing routines (Workout tab folders). Empty
/// folders persist so users can create a folder before filling it.
@Model
public final class RoutineFolderModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    public var position: Int = 0
    /// Folders nest one level to model training cycles: a top-level folder
    /// with children is a macrocycle, its children are mesocycles, and the
    /// routines inside are the microcycles.
    public var parentID: UUID?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        position: Int = 0,
        parentID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.position = position
        self.parentID = parentID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

@Model
public final class ExerciseLibraryModel {
    public var id: UUID = UUID()
    public var ownerID: UUID?
    public var name: String = ""
    public var movementPattern: String?
    public var primaryMuscles: [String] = []
    public var secondaryMuscles: [String] = []
    public var equipment: String?
    public var isUnilateral: Bool = false
    public var defaultWeightModeRaw: String = WeightMode.external.rawValue
    public var preferredWeightUnitRaw: String?
    public var difficulty: String?
    public var isCardio: Bool = false
    public var mappedGlobalID: UUID?
    public var instructions: [String] = []
    public var mechanic: String?
    /// Image slug from the bundled exercise database (`{slug}/0.jpg`), used to
    /// resolve a remote illustration. Nil for user-created exercises.
    public var mediaSlug: String?
    public var category: String?
    public var force: String?
    /// Set when the user edits a built-in (seeded) exercise's attributes, so the
    /// launch re-seed (`ExerciseSeedRepository.seedGlobalLibrary`) stops
    /// overwriting their changes. Custom exercises don't need it but carry it
    /// harmlessly.
    public var userModified: Bool = false
    /// Import/classification metadata. When an exercise is auto-created (or
    /// auto-classified) from an imported history like Hevy, these record how
    /// confident the guess was and where it came from. `needsReview == true`
    /// flags a low-confidence guess for the user to confirm/fix in the review
    /// screen; `importedRawName` preserves the original imported name.
    public var needsReview: Bool = false
    public var classificationConfidence: Double = 1.0
    public var classificationSourceRaw: String?
    public var importBatchID: UUID?
    public var importedRawName: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        ownerID: UUID? = nil,
        name: String,
        movementPattern: String? = nil,
        primaryMuscles: [String] = [],
        secondaryMuscles: [String] = [],
        equipment: String? = nil,
        isUnilateral: Bool = false,
        defaultWeightMode: WeightMode = .external,
        preferredWeightUnitRaw: String? = nil,
        difficulty: String? = nil,
        isCardio: Bool = false,
        mappedGlobalID: UUID? = nil,
        instructions: [String] = [],
        mechanic: String? = nil,
        mediaSlug: String? = nil,
        category: String? = nil,
        force: String? = nil,
        userModified: Bool = false,
        needsReview: Bool = false,
        classificationConfidence: Double = 1.0,
        classificationSourceRaw: String? = nil,
        importBatchID: UUID? = nil,
        importedRawName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.name = name
        self.movementPattern = movementPattern
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.isUnilateral = isUnilateral
        self.defaultWeightModeRaw = defaultWeightMode.rawValue
        self.preferredWeightUnitRaw = preferredWeightUnitRaw
        self.difficulty = difficulty
        self.isCardio = isCardio
        self.mappedGlobalID = mappedGlobalID
        self.instructions = instructions
        self.mechanic = mechanic
        self.mediaSlug = mediaSlug
        self.category = category
        self.force = force
        self.userModified = userModified
        self.needsReview = needsReview
        self.classificationConfidence = classificationConfidence
        self.classificationSourceRaw = classificationSourceRaw
        self.importBatchID = importBatchID
        self.importedRawName = importedRawName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var defaultWeightMode: WeightMode {
        get { WeightMode(rawValue: defaultWeightModeRaw) ?? .external }
        set { defaultWeightModeRaw = newValue.rawValue }
    }

    public var classificationSource: ClassificationSource? {
        get { classificationSourceRaw.flatMap(ClassificationSource.init(rawValue:)) }
        set { classificationSourceRaw = newValue?.rawValue }
    }

    public var domainInfo: ExerciseInfo {
        ExerciseInfo(
            id: id,
            name: name,
            movementPattern: movementPattern,
            primaryMuscles: primaryMuscles,
            secondaryMuscles: secondaryMuscles,
            equipment: equipment,
            isUnilateral: isUnilateral,
            mappedGlobalID: mappedGlobalID
        )
    }
}

@Model
public final class ExerciseAliasModel {
    public var id: UUID = UUID()
    public var exerciseID: UUID = UUID()
    public var ownerID: UUID?
    public var alias: String = ""
    public var createdAt: Date = Date()

    public init(
        id: UUID = UUID(),
        exerciseID: UUID,
        ownerID: UUID? = nil,
        alias: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.ownerID = ownerID
        self.alias = alias
        self.createdAt = createdAt
    }

    public var domainAlias: ExerciseAlias {
        ExerciseAlias(id: id, exerciseID: exerciseID, ownerID: ownerID, alias: alias)
    }
}

@Model
public final class UserExerciseNoteModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var exerciseID: UUID = UUID()
    public var note: String = ""
    public var seatHeight: String?
    public var grip: String?
    public var stance: String?
    public var machineSettingsJSON: String?
    public var painFlag: Bool = false
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(
        id: UUID = UUID(),
        userID: UUID,
        exerciseID: UUID,
        note: String,
        seatHeight: String? = nil,
        grip: String? = nil,
        stance: String? = nil,
        machineSettingsJSON: String? = nil,
        painFlag: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.exerciseID = exerciseID
        self.note = note
        self.seatHeight = seatHeight
        self.grip = grip
        self.stance = stance
        self.machineSettingsJSON = machineSettingsJSON
        self.painFlag = painFlag
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
public final class RoutineModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    public var notes: String?
    public var folder: String?
    /// Owning folder (nil = ungrouped, shown at the top level).
    public var folderID: UUID?
    public var position: Int = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    // CloudKit requires relationships to be optional; the optional storage is
    // private and the public face stays non-optional. `originalName` keeps
    // existing local stores migrating in place.
    @Relationship(deleteRule: .cascade, originalName: "exercises", inverse: \RoutineExerciseModel.routine)
    private var storedExercises: [RoutineExerciseModel]?
    public var exercises: [RoutineExerciseModel] {
        get { storedExercises ?? [] }
        set { storedExercises = newValue }
    }

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        notes: String? = nil,
        folder: String? = nil,
        folderID: UUID? = nil,
        position: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        exercises: [RoutineExerciseModel] = []
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.notes = notes
        self.folder = folder
        self.folderID = folderID
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.exercises = exercises
    }
}

@Model
public final class RoutineExerciseModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var exerciseID: UUID = UUID()
    public var position: Int = 0
    public var supersetGroup: Int?
    public var progressionRuleID: UUID?
    public var notes: String?
    /// Structured cardio interval template (JSON-encoded `IntervalPlan`),
    /// nil for strength or steady-state cardio. Additive-optional.
    public var intervalPlanJSON: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var routine: RoutineModel?
    @Relationship(deleteRule: .cascade, originalName: "sets", inverse: \RoutineSetModel.routineExercise)
    private var storedSets: [RoutineSetModel]?
    public var sets: [RoutineSetModel] {
        get { storedSets ?? [] }
        set { storedSets = newValue }
    }

    public init(
        id: UUID = UUID(),
        userID: UUID,
        exerciseID: UUID,
        position: Int = 0,
        supersetGroup: Int? = nil,
        progressionRuleID: UUID? = nil,
        notes: String? = nil,
        intervalPlanJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sets: [RoutineSetModel] = []
    ) {
        self.id = id
        self.userID = userID
        self.exerciseID = exerciseID
        self.position = position
        self.supersetGroup = supersetGroup
        self.progressionRuleID = progressionRuleID
        self.notes = notes
        self.intervalPlanJSON = intervalPlanJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sets = sets
    }
}

@Model
public final class RoutineSetModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var position: Int = 0
    public var setTypeRaw: String = SetType.working.rawValue
    public var targetRepsLow: Int?
    public var targetRepsHigh: Int?
    public var targetWeight: Double?
    public var targetRPE: Double?
    public var targetRIR: Int?
    public var targetDurationSeconds: Int?
    public var createdAt: Date = Date()
    public var routineExercise: RoutineExerciseModel?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        position: Int = 0,
        setType: SetType = .working,
        targetRepsLow: Int? = nil,
        targetRepsHigh: Int? = nil,
        targetWeight: Double? = nil,
        targetRPE: Double? = nil,
        targetRIR: Int? = nil,
        targetDurationSeconds: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.position = position
        self.setTypeRaw = setType.rawValue
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetWeight = targetWeight
        self.targetRPE = targetRPE
        self.targetRIR = targetRIR
        self.targetDurationSeconds = targetDurationSeconds
        self.createdAt = createdAt
    }

    public var setType: SetType {
        get { SetType(rawValue: setTypeRaw) ?? .working }
        set { setTypeRaw = newValue.rawValue }
    }
}

@Model
public final class WorkoutModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var routineID: UUID?
    public var title: String?
    public var startedAt: Date = Date()
    public var endedAt: Date?
    public var hkWorkoutUUID: UUID?
    public var sourceDevice: String?
    public var totalVolume: Double?
    public var notes: String?
    // Session health metrics captured live from the Apple Watch (or filled
    // from HealthKit at finish) — stored with the workout so the user can
    // reflect on prior sessions.
    public var avgHR: Int?
    public var maxHR: Int?
    public var activeEnergyKcal: Double?
    /// Seconds spent in each of the 5 HR zones during the session.
    public var hrZoneSeconds: [Int] = []
    /// Readiness score (0–100) when the session started — "trained at 45%
    /// ready" is context worth keeping.
    public var readinessAtStart: Int?
    /// Provenance for non-HealthKit historical imports (Hevy, Strong, generic CSV,
    /// ForgeFit JSON). These fields make repeated imports idempotent and let the
    /// app explain where old history came from.
    public var externalSource: String?
    public var externalWorkoutID: String?
    public var importFingerprint: String?
    public var importBatchID: UUID?
    /// XP is awarded only through ForgeFit's finish pipeline. These fields make
    /// the award idempotent when a finish action is retried.
    public var xpAwardedAmount: Int?
    public var xpAwardedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    @Relationship(deleteRule: .cascade, originalName: "exercises", inverse: \WorkoutExerciseModel.workout)
    private var storedExercises: [WorkoutExerciseModel]?
    public var exercises: [WorkoutExerciseModel] {
        get { storedExercises ?? [] }
        set { storedExercises = newValue }
    }
    @Relationship(deleteRule: .cascade, originalName: "cardioSessions", inverse: \CardioSessionModel.workout)
    private var storedCardioSessions: [CardioSessionModel]?
    public var cardioSessions: [CardioSessionModel] {
        get { storedCardioSessions ?? [] }
        set { storedCardioSessions = newValue }
    }

    public init(
        id: UUID = UUID(),
        userID: UUID,
        routineID: UUID? = nil,
        title: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        hkWorkoutUUID: UUID? = nil,
        sourceDevice: String? = nil,
        totalVolume: Double? = nil,
        notes: String? = nil,
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        hrZoneSeconds: [Int] = [],
        readinessAtStart: Int? = nil,
        externalSource: String? = nil,
        externalWorkoutID: String? = nil,
        importFingerprint: String? = nil,
        importBatchID: UUID? = nil,
        xpAwardedAmount: Int? = nil,
        xpAwardedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        exercises: [WorkoutExerciseModel] = [],
        cardioSessions: [CardioSessionModel] = []
    ) {
        self.id = id
        self.userID = userID
        self.routineID = routineID
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.hkWorkoutUUID = hkWorkoutUUID
        self.sourceDevice = sourceDevice
        self.totalVolume = totalVolume
        self.notes = notes
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.hrZoneSeconds = hrZoneSeconds
        self.readinessAtStart = readinessAtStart
        self.externalSource = externalSource
        self.externalWorkoutID = externalWorkoutID
        self.importFingerprint = importFingerprint
        self.importBatchID = importBatchID
        self.xpAwardedAmount = xpAwardedAmount
        self.xpAwardedAt = xpAwardedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.exercises = exercises
        self.cardioSessions = cardioSessions
    }

    public func recomputeTotalVolume() {
        totalVolume = exercises.flatMap(\.sets)
            .filter { $0.completedAt != nil }
            .reduce(0) { $0 + ($1.totalVolume ?? 0) }
        updatedAt = Date()
    }
}

@Model
public final class WorkoutImportBatchModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var source: String = ""
    public var fileName: String = ""
    public var importedCount: Int = 0
    public var skippedDuplicateCount: Int = 0
    public var warningCount: Int = 0
    public var startedAt: Date?
    public var endedAt: Date?
    public var createdAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        source: String,
        fileName: String,
        importedCount: Int = 0,
        skippedDuplicateCount: Int = 0,
        warningCount: Int = 0,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        createdAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.source = source
        self.fileName = fileName
        self.importedCount = importedCount
        self.skippedDuplicateCount = skippedDuplicateCount
        self.warningCount = warningCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

@Model
public final class UserProgressModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var totalXP: Int = 0
    public var level: Int = 1
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        totalXP: Int = 0,
        level: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.totalXP = totalXP
        self.level = level
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

@Model
public final class WorkoutXPEventModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var workoutID: UUID = UUID()
    public var amount: Int = 0
    public var source: String = ""
    public var componentsJSON: String = "{}"
    public var createdAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        workoutID: UUID,
        amount: Int,
        source: String = "forgefit-workout",
        componentsJSON: String = "{}",
        createdAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.workoutID = workoutID
        self.amount = amount
        self.source = source
        self.componentsJSON = componentsJSON
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }
}

@Model
public final class WorkoutExerciseModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var exerciseID: UUID = UUID()
    public var position: Int = 0
    public var supersetGroup: Int?
    public var notes: String?
    /// Whether the sticky note is pinned to persist to this exercise in future
    /// workouts (mirrored into `UserExerciseNoteModel`).
    public var notePinned: Bool = false
    /// User-adjustable rest between straight sets for this exercise (seconds).
    /// nil = the contextual default for the set type.
    public var restSeconds: Int?
    /// User-adjustable micro-rest inside myo-rep / rest-pause / cluster blocks
    /// (seconds). nil = the contextual default for the set type.
    public var microRestSeconds: Int?
    /// Structured cardio interval template (JSON-encoded `IntervalPlan`),
    /// copied from the routine at start. Additive-optional.
    public var intervalPlanJSON: String?
    /// The `RoutineExerciseModel.id` this exercise was seeded from when the
    /// workout was started from a routine. Nil for ad-hoc exercises added
    /// mid-session or workouts not started from a routine. Used by
    /// `RoutineChangeSync` to detect structural drift at finish.
    public var sourceRoutineExerciseID: UUID?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var workout: WorkoutModel?
    @Relationship(deleteRule: .cascade, originalName: "sets", inverse: \SetModel.workoutExercise)
    private var storedSets: [SetModel]?
    public var sets: [SetModel] {
        get { storedSets ?? [] }
        set { storedSets = newValue }
    }

    public init(
        id: UUID = UUID(),
        userID: UUID,
        exerciseID: UUID,
        position: Int = 0,
        supersetGroup: Int? = nil,
        notes: String? = nil,
        notePinned: Bool = false,
        restSeconds: Int? = nil,
        microRestSeconds: Int? = nil,
        intervalPlanJSON: String? = nil,
        sourceRoutineExerciseID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sets: [SetModel] = []
    ) {
        self.id = id
        self.userID = userID
        self.exerciseID = exerciseID
        self.position = position
        self.supersetGroup = supersetGroup
        self.notes = notes
        self.notePinned = notePinned
        self.restSeconds = restSeconds
        self.microRestSeconds = microRestSeconds
        self.intervalPlanJSON = intervalPlanJSON
        self.sourceRoutineExerciseID = sourceRoutineExerciseID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sets = sets
    }
}

@Model
public final class SetModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var position: Int = 0
    public var setTypeRaw: String = SetType.working.rawValue
    public var weightModeRaw: String = WeightMode.external.rawValue
    public var reps: Int?
    public var weight: Double?
    public var rpe: Double?
    public var rir: Int?
    public var durationSeconds: Int?
    public var holdSeconds: Int?
    public var partialReps: Int?
    public var addedWeight: Double?
    public var assistanceWeight: Double?
    public var bodyweightKg: Double?
    public var isUnilateral: Bool = false
    public var implementWeight: Double?
    public var limbCount: Int = 2
    public var isEccentric: Bool = false
    public var isPaused: Bool = false
    public var machineSettingsJSON: String?
    /// The `RoutineSetModel.id` this set was seeded from when the workout was
    /// started from a routine. Nil for sets added mid-session or workouts not
    /// started from a routine. Used by `RoutineChangeSync` to preserve target
    /// values on unchanged sets while applying structural drift at finish.
    public var sourceRoutineSetID: UUID?
    /// Sub-segment rep tallies inside one logical set, JSON-encoded `[Int]`.
    /// Myo-reps / rest-pause: the mini-sets after the activation set (`reps` =
    /// activation reps). Cluster: every segment (`reps` mirrors the sum).
    public var miniRepsJSON: String?
    public var effectiveLoad: Double?
    public var totalVolume: Double?
    public var estimated1RM: Double?
    public var completedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var workoutExercise: WorkoutExerciseModel?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        position: Int = 0,
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
        machineSettingsJSON: String? = nil,
        sourceRoutineSetID: UUID? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.position = position
        self.setTypeRaw = setType.rawValue
        self.weightModeRaw = weightMode.rawValue
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
        self.machineSettingsJSON = machineSettingsJSON
        self.sourceRoutineSetID = sourceRoutineSetID
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        recomputeDerivedMetrics()
    }

    public convenience init(
        userID: UUID,
        position: Int = 0,
        entry: SetEntry,
        completedAt: Date? = Date()
    ) {
        self.init(
            id: entry.id,
            userID: userID,
            position: position,
            setType: entry.setType,
            weightMode: entry.weightMode,
            reps: entry.reps,
            weight: entry.weight,
            rpe: entry.rpe,
            rir: entry.rir,
            durationSeconds: entry.durationSeconds,
            holdSeconds: entry.holdSeconds,
            partialReps: entry.partialReps,
            addedWeight: entry.addedWeight,
            assistanceWeight: entry.assistanceWeight,
            bodyweightKg: entry.bodyweightKg,
            isUnilateral: entry.isUnilateral,
            implementWeight: entry.implementWeight,
            limbCount: entry.limbCount,
            isEccentric: entry.isEccentric,
            isPaused: entry.isPaused,
            completedAt: completedAt
        )
    }

    public var setType: SetType {
        get { SetType(rawValue: setTypeRaw) ?? .working }
        set {
            setTypeRaw = newValue.rawValue
            recomputeDerivedMetrics()
        }
    }

    public var weightMode: WeightMode {
        get { WeightMode(rawValue: weightModeRaw) ?? .external }
        set {
            weightModeRaw = newValue.rawValue
            recomputeDerivedMetrics()
        }
    }

    public var domainEntry: SetEntry {
        SetEntry(
            id: id,
            setType: setType,
            weightMode: weightMode,
            reps: reps,
            weight: weight,
            rpe: rpe,
            rir: rir,
            durationSeconds: durationSeconds,
            holdSeconds: holdSeconds,
            partialReps: partialReps,
            addedWeight: addedWeight,
            assistanceWeight: assistanceWeight,
            bodyweightKg: bodyweightKg,
            isUnilateral: isUnilateral,
            implementWeight: implementWeight,
            limbCount: limbCount,
            isEccentric: isEccentric,
            isPaused: isPaused
        )
    }

    /// Decoded view of `miniRepsJSON`. Setting recomputes derived metrics.
    public var miniReps: [Int] {
        get {
            guard let miniRepsJSON, let data = miniRepsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                miniRepsJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                miniRepsJSON = String(data: data, encoding: .utf8)
            }
            recomputeDerivedMetrics()
        }
    }

    public func recomputeDerivedMetrics() {
        let entry = domainEntry
        effectiveLoad = VolumeMath.effectiveLoad(entry)
        totalVolume = VolumeMath.tonnage(entry)
        estimated1RM = VolumeMath.estimated1RM(entry)
        // Myo-rep / rest-pause mini-sets are extra reps at the same load on top
        // of the activation set. (Cluster segments already sum into `reps`.)
        if setType == .myoRep || setType == .restPause {
            let miniTotal = miniReps.reduce(0, +)
            if miniTotal > 0, let load = effectiveLoad {
                totalVolume = (totalVolume ?? 0) + load * Double(miniTotal)
            }
        }
        updatedAt = Date()
    }
}

@Model
public final class CardioSessionModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// The workout exercise this cardio effort belongs to (nil for legacy
    /// whole-workout cardio sessions).
    public var workoutExerciseID: UUID?
    public var modality: String = ""
    public var startedAt: Date = Date()
    /// When the user tapped "Start" on this segment (nil = not started yet). The
    /// [liveStartedAt, endedAt] window is what HealthKit is queried against to
    /// auto-fill metrics from Apple Watch.
    public var liveStartedAt: Date?
    public var endedAt: Date?
    public var hkWorkoutUUID: UUID?
    public var sourceDevice: String?
    public var durationSeconds: Int?
    public var distanceMeters: Double?
    public var activeEnergyKcal: Double?
    public var avgHR: Int?
    public var maxHR: Int?
    public var hrZoneSeconds: [Int] = []
    public var effort: Int?
    public var floorsClimbed: Int?
    public var totalSteps: Int?
    public var avgPaceSecondsPerKm: Double?
    public var split500mSeconds: Double?
    public var strokeRate: Int?
    public var avgPowerWatts: Double?
    public var avgCadence: Int?
    public var resistanceLevel: Int?
    public var inclinePercent: Double?
    public var elevationGainMeters: Double?
    public var tss: Double?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    public var workout: WorkoutModel?
    @Relationship(deleteRule: .cascade, originalName: "routePoints", inverse: \CardioRoutePointModel.cardioSession)
    private var storedRoutePoints: [CardioRoutePointModel]?
    public var routePoints: [CardioRoutePointModel] {
        get { storedRoutePoints ?? [] }
        set { storedRoutePoints = newValue }
    }
    @Relationship(deleteRule: .cascade, originalName: "splits", inverse: \CardioSplitModel.cardioSession)
    private var storedSplits: [CardioSplitModel]?
    public var splits: [CardioSplitModel] {
        get { storedSplits ?? [] }
        set { storedSplits = newValue }
    }

    public init(
        id: UUID = UUID(),
        userID: UUID,
        workoutExerciseID: UUID? = nil,
        modality: String,
        startedAt: Date = Date(),
        liveStartedAt: Date? = nil,
        endedAt: Date? = nil,
        hkWorkoutUUID: UUID? = nil,
        sourceDevice: String? = nil,
        durationSeconds: Int? = nil,
        distanceMeters: Double? = nil,
        activeEnergyKcal: Double? = nil,
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        hrZoneSeconds: [Int] = [],
        effort: Int? = nil,
        floorsClimbed: Int? = nil,
        totalSteps: Int? = nil,
        avgPaceSecondsPerKm: Double? = nil,
        split500mSeconds: Double? = nil,
        strokeRate: Int? = nil,
        avgPowerWatts: Double? = nil,
        avgCadence: Int? = nil,
        resistanceLevel: Int? = nil,
        inclinePercent: Double? = nil,
        elevationGainMeters: Double? = nil,
        tss: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        routePoints: [CardioRoutePointModel] = [],
        splits: [CardioSplitModel] = []
    ) {
        self.id = id
        self.userID = userID
        self.workoutExerciseID = workoutExerciseID
        self.modality = modality
        self.startedAt = startedAt
        self.liveStartedAt = liveStartedAt
        self.endedAt = endedAt
        self.hkWorkoutUUID = hkWorkoutUUID
        self.sourceDevice = sourceDevice
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.activeEnergyKcal = activeEnergyKcal
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.hrZoneSeconds = hrZoneSeconds
        self.effort = effort
        self.floorsClimbed = floorsClimbed
        self.totalSteps = totalSteps
        self.avgPaceSecondsPerKm = avgPaceSecondsPerKm
        self.split500mSeconds = split500mSeconds
        self.strokeRate = strokeRate
        self.avgPowerWatts = avgPowerWatts
        self.avgCadence = avgCadence
        self.resistanceLevel = resistanceLevel
        self.inclinePercent = inclinePercent
        self.elevationGainMeters = elevationGainMeters
        self.tss = tss
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.routePoints = routePoints
        self.splits = splits
    }
}

@Model
public final class CardioRoutePointModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var cardioSessionID: UUID = UUID()
    public var timestamp: Date = Date()
    public var latitude: Double = 0
    public var longitude: Double = 0
    public var altitudeMeters: Double?
    public var horizontalAccuracyMeters: Double?
    public var speedMetersPerSecond: Double?
    public var createdAt: Date = Date()
    public var cardioSession: CardioSessionModel?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        cardioSessionID: UUID,
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double? = nil,
        horizontalAccuracyMeters: Double? = nil,
        speedMetersPerSecond: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.cardioSessionID = cardioSessionID
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.speedMetersPerSecond = speedMetersPerSecond
        self.createdAt = createdAt
    }
}

@Model
public final class CardioSplitModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var cardioSessionID: UUID = UUID()
    public var index: Int = 0
    public var distanceMeters: Double = 0
    public var durationSeconds: Int = 0
    public var paceSecondsPerKm: Double = 0
    public var elevationGainMeters: Double?
    /// Interval-step label (e.g. "Work 3/6") for structured sessions.
    /// Additive-optional; nil for plain distance/lap splits.
    public var label: String?
    public var startedAt: Date = Date()
    public var endedAt: Date = Date()
    public var createdAt: Date = Date()
    public var cardioSession: CardioSessionModel?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        cardioSessionID: UUID,
        index: Int,
        distanceMeters: Double,
        durationSeconds: Int,
        paceSecondsPerKm: Double,
        elevationGainMeters: Double? = nil,
        label: String? = nil,
        startedAt: Date,
        endedAt: Date,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.cardioSessionID = cardioSessionID
        self.index = index
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.paceSecondsPerKm = paceSecondsPerKm
        self.elevationGainMeters = elevationGainMeters
        self.label = label
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
    }
}
