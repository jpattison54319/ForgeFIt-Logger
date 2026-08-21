import Foundation
import ForgeCore
import SwiftData

public enum ForgeDataSchema {
    /// The CloudKit-synced PLANNING layer. NOTHING in this list may ever
    /// carry Apple Health data — App Store Guideline 5.1.3(ii) forbids
    /// storing personal health information in iCloud. Models here hold only
    /// user-authored training plans, catalog content, and gamification
    /// state. Adding a model with health-derived fields to this list is a
    /// policy violation, not a style choice.
    public static var planModels: [any PersistentModel.Type] {
        [
            ExerciseLibraryModel.self,
            ExerciseAliasModel.self,
            UserExerciseNoteModel.self,
            RoutineFolderModel.self,
            RoutineModel.self,
            RoutineAlternationModel.self,
            RoutineBlockModel.self,
            RoutineExerciseModel.self,
            RoutineSetModel.self,
            UserProgressModel.self,
            WorkoutXPEventModel.self,
            IntervalPresetModel.self,
            YogaFlowModel.self,
            CoachingProfileModel.self,
            CoachedProgramModel.self,
            CoachingWeekOverrideModel.self,
            SavedInsightModel.self
        ]
    }

    /// The LOCAL-ONLY training log. These models may contain Health-derived
    /// fields (heart rate, energy, zones, readiness, body weight, check-ins),
    /// so they never sync to CloudKit. Cross-device continuity comes from
    /// the sanitized iCloud Drive backup (DTO allow-list plus provenance
    /// filtering) and re-enrichment from the user's own Apple Health store.
    public static var logModels: [any PersistentModel.Type] {
        [
            WorkoutModel.self,
            WorkoutBlockModel.self,
            WorkoutExerciseModel.self,
            SetModel.self,
            WorkoutImportBatchModel.self,
            CardioSessionModel.self,
            CardioRoutePointModel.self,
            CardioSplitModel.self,
            WrappedReportModel.self,
            ProgressionSuggestionModel.self,
            DailyCheckinModel.self,
            ExperimentModel.self,
            ExperimentTrackerModel.self,
            ExperimentEntryModel.self,
            MicrocycleTrackingModel.self,
            MicrocycleWindowModel.self,
            RestDayModel.self
        ]
    }

    public static var models: [any PersistentModel.Type] {
        planModels + logModels
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
    /// Folders nest one level to model training cycles: a parent folder is a
    /// mesocycle, its leaf children are microcycles, and routines are the
    /// workout sessions performed inside a microcycle.
    public var parentID: UUID?
    /// Preferred duration when this leaf folder is tracked as a microcycle.
    /// Nil means it has not been configured. Additive-optional for CloudKit.
    public var defaultMicrocycleLengthDays: Int?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?
    /// Hidden-but-kept, distinct from `deletedAt`: an archived folder vanishes
    /// from every active surface yet keeps its structure (children stay
    /// linked) so restoring it rebuilds the cycle intact. A whole archived
    /// subtree shares ONE timestamp — that identity is what "restore the
    /// folder" uses to bring back exactly what was archived with it.
    /// Additive-optional for CloudKit.
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        position: Int = 0,
        parentID: UUID? = nil,
        defaultMicrocycleLengthDays: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.position = position
        self.parentID = parentID
        self.defaultMicrocycleLengthDays = defaultMicrocycleLengthDays
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.archivedAt = archivedAt
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
    /// Explicit cardio modality (CardioKind raw value) chosen at creation.
    /// Nil = infer from name/equipment, which stays correct for the built-in
    /// library and legacy custom exercises. Additive-optional for CloudKit.
    public var cardioKindRaw: String?
    /// Explicit `Modality` raw value. Nil = legacy row: fall back to `isCardio`
    /// (see `modality`). New rows write both so old and new code agree.
    /// Additive-optional for CloudKit.
    public var modalityRaw: String?
    /// Default hold duration for yoga poses (seconds), used by the flow
    /// builder when a pose is added to a sequence. Nil for non-yoga rows.
    /// Additive-optional for CloudKit.
    public var defaultHoldSeconds: Int?
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
        cardioKindRaw: String? = nil,
        modalityRaw: String? = nil,
        defaultHoldSeconds: Int? = nil,
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
        self.cardioKindRaw = cardioKindRaw
        self.modalityRaw = modalityRaw
        self.defaultHoldSeconds = defaultHoldSeconds
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

    /// Resolved discipline. Legacy rows (nil `modalityRaw`) fall back to the
    /// `isCardio` flag, so the whole pre-yoga library resolves correctly
    /// without any migration. Setting keeps `isCardio` in sync so old code
    /// paths (and old app versions reading synced rows) stay honest.
    public var modality: Modality {
        get { modalityRaw.flatMap(Modality.init(rawValue:)) ?? (isCardio ? .cardio : .strength) }
        set {
            modalityRaw = newValue.rawValue
            isCardio = newValue == .cardio
        }
    }

    public var isYoga: Bool { modality == .yoga }

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
    /// Hidden-but-kept, distinct from `deletedAt`: hidden from every active
    /// surface (lists, Home, watch, quick actions) but restorable. Carries the
    /// owning folder's stamp when archived as part of a folder — see
    /// `RoutineFolderModel.archivedAt`. Additive-optional for CloudKit.
    public var archivedAt: Date?
    /// Optional structured conditioning plan. Nil keeps the routine on the
    /// existing set-based path. JSON mirrors interval/yoga plans and remains
    /// additive for CloudKit stores created by older app versions.
    public var conditioningPlanJSON: String?
    // CloudKit requires relationships to be optional; the optional storage is
    // private and the public face stays non-optional. `originalName` keeps
    // existing local stores migrating in place.
    @Relationship(deleteRule: .cascade, originalName: "exercises", inverse: \RoutineExerciseModel.routine)
    private var storedExercises: [RoutineExerciseModel]?
    public var exercises: [RoutineExerciseModel] {
        get { storedExercises ?? [] }
        set { storedExercises = newValue }
    }
    @Relationship(deleteRule: .cascade, inverse: \RoutineBlockModel.routine)
    private var storedBlocks: [RoutineBlockModel]?
    public var blocks: [RoutineBlockModel] {
        get { storedBlocks ?? [] }
        set { storedBlocks = newValue }
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
        archivedAt: Date? = nil,
        conditioningPlanJSON: String? = nil,
        exercises: [RoutineExerciseModel] = [],
        blocks: [RoutineBlockModel] = []
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
        self.archivedAt = archivedAt
        self.conditioningPlanJSON = conditioningPlanJSON
        self.exercises = exercises
        self.blocks = blocks
    }
}

/// A user-authored two-routine slot whose owner keeps its library and
/// microcycle position while either member can be performed. Scalar IDs keep
/// the CloudKit plan record independent from SwiftData relationship delivery
/// order; `RoutineAlternationService` validates both endpoints before use.
@Model
public final class RoutineAlternationModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var ownerRoutineID: UUID = UUID()
    public var partnerRoutineID: UUID = UUID()
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        ownerRoutineID: UUID,
        partnerRoutineID: UUID,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.ownerRoutineID = ownerRoutineID
        self.partnerRoutineID = partnerRoutineID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
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
    /// JSON-encoded `ProgressionRule` (ForgeCore); nil = the double-progression
    /// default. Additive-optional for CloudKit.
    public var progressionRuleJSON: String?
    public var notes: String?
    /// Structured cardio interval template (JSON-encoded `IntervalPlan`),
    /// nil for strength or steady-state cardio. Additive-optional.
    public var intervalPlanJSON: String?
    /// Guided yoga sequence (JSON-encoded `YogaFlowPlan`), nil for non-yoga
    /// exercises. Additive-optional.
    public var yogaFlowJSON: String?
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
        yogaFlowJSON: String? = nil,
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
        self.yogaFlowJSON = yogaFlowJSON
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
    /// Fixed-load routines keep their existing behavior. Percentage-based
    /// routines resolve from completed exercise history only when a workout
    /// starts, so the authored plan can adapt without mutating itself.
    public var loadPrescriptionModeRaw: String = LoadPrescriptionMode.fixed.rawValue
    public var target1RMPercentLow: Double?
    public var target1RMPercentHigh: Double?
    public var targetRPE: Double?
    public var targetRIR: Int?
    public var targetDurationSeconds: Int?
    /// Cardio distance target in meters — the peer of `targetDurationSeconds`
    /// for distance-planned efforts ("row 2000 m"). Plan-store synced; a
    /// planned distance is training intent, not health data.
    public var targetDistanceMeters: Double?
    /// Myo-reps plan: how many mini-sets to perform after the activation set.
    /// Reps are deliberately NOT planned — myo minis log whatever the lifter
    /// achieves live.
    public var plannedMiniSetCount: Int?
    /// Cluster plan: goal reps for each segment, JSON-encoded `[Int]` — a
    /// cluster is one set broken into mini-sets, so rep goals matter.
    public var plannedMiniRepsJSON: String?
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
        loadPrescriptionMode: LoadPrescriptionMode = .fixed,
        target1RMPercentLow: Double? = nil,
        target1RMPercentHigh: Double? = nil,
        targetRPE: Double? = nil,
        targetRIR: Int? = nil,
        targetDurationSeconds: Int? = nil,
        targetDistanceMeters: Double? = nil,
        plannedMiniSetCount: Int? = nil,
        plannedMiniRepsJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.position = position
        self.setTypeRaw = setType.rawValue
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetWeight = targetWeight
        self.loadPrescriptionModeRaw = loadPrescriptionMode.rawValue
        self.target1RMPercentLow = target1RMPercentLow
        self.target1RMPercentHigh = target1RMPercentHigh
        self.targetRPE = targetRPE
        self.targetRIR = targetRIR
        self.targetDurationSeconds = targetDurationSeconds
        self.targetDistanceMeters = targetDistanceMeters
        self.plannedMiniSetCount = plannedMiniSetCount
        self.plannedMiniRepsJSON = plannedMiniRepsJSON
        self.createdAt = createdAt
    }

    public var setType: SetType {
        get { SetType(rawValue: setTypeRaw) ?? .working }
        set { setTypeRaw = newValue.rawValue }
    }

    public var loadPrescriptionMode: LoadPrescriptionMode {
        get { LoadPrescriptionMode(rawValue: loadPrescriptionModeRaw) ?? .fixed }
        set { loadPrescriptionModeRaw = newValue.rawValue }
    }

    public var estimatedOneRepMaxPrescription: EstimatedOneRepMaxPrescription? {
        guard loadPrescriptionMode == .percentEstimatedOneRepMax,
              let target1RMPercentLow else { return nil }
        return EstimatedOneRepMaxPrescription(
            lowPercent: target1RMPercentLow,
            highPercent: target1RMPercentHigh
        )
    }

    /// Decoded view of `plannedMiniRepsJSON` (cluster segment rep goals).
    public var plannedMiniReps: [Int] {
        get {
            guard let plannedMiniRepsJSON, let data = plannedMiniRepsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                plannedMiniRepsJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                plannedMiniRepsJSON = String(data: data, encoding: .utf8)
            }
        }
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
    /// Frozen plan, live reducer state, and final score for conditioning or
    /// mixed workouts. Training data only; Health-derived values stay in the
    /// existing local health fields.
    public var conditioningPlanSnapshotJSON: String?
    public var conditioningProgressJSON: String?
    public var conditioningResultJSON: String?
    // Session health metrics captured live from the Apple Watch (or filled
    // from HealthKit at finish) — stored with the workout so the user can
    // reflect on prior sessions.
    public var avgHR: Int?
    public var maxHR: Int?
    public var activeEnergyKcal: Double?
    /// Seconds spent in each of the 5 HR zones during the session.
    public var hrZoneSeconds: [Int] = []
    /// Optional whole-session CR10 rating. Unlike per-set RPE, this describes
    /// the complete workout and is eligible for same-method session load.
    public var wholeSessionRPE: Double?
    public var wholeSessionRPERatedAt: Date?
    public var wholeSessionRPEProtocolVersion: String?
    /// Readiness score (0–100) when the session started — "trained at 45%
    /// ready" is context worth keeping.
    public var readinessAtStart: Int?
    /// Method and coverage make future workout-outcome calibration compare
    /// like with like. These stay local with the Health-derived score.
    public var readinessMethodID: String?
    public var readinessCoverageAtStart: Double?
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
    @Relationship(deleteRule: .cascade, inverse: \WorkoutBlockModel.workout)
    private var storedBlocks: [WorkoutBlockModel]?
    public var blocks: [WorkoutBlockModel] {
        get { storedBlocks ?? [] }
        set { storedBlocks = newValue }
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
        conditioningPlanSnapshotJSON: String? = nil,
        conditioningProgressJSON: String? = nil,
        conditioningResultJSON: String? = nil,
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        hrZoneSeconds: [Int] = [],
        wholeSessionRPE: Double? = nil,
        wholeSessionRPERatedAt: Date? = nil,
        wholeSessionRPEProtocolVersion: String? = nil,
        readinessAtStart: Int? = nil,
        readinessMethodID: String? = nil,
        readinessCoverageAtStart: Double? = nil,
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
        cardioSessions: [CardioSessionModel] = [],
        blocks: [WorkoutBlockModel] = []
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
        self.conditioningPlanSnapshotJSON = conditioningPlanSnapshotJSON
        self.conditioningProgressJSON = conditioningProgressJSON
        self.conditioningResultJSON = conditioningResultJSON
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.hrZoneSeconds = hrZoneSeconds
        self.wholeSessionRPE = wholeSessionRPE
        self.wholeSessionRPERatedAt = wholeSessionRPERatedAt
        self.wholeSessionRPEProtocolVersion = wholeSessionRPEProtocolVersion
        self.readinessAtStart = readinessAtStart
        self.readinessMethodID = readinessMethodID
        self.readinessCoverageAtStart = readinessCoverageAtStart
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
        self.blocks = blocks
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
    /// Guided yoga sequence (JSON-encoded `YogaFlowPlan`), copied from the
    /// routine at start. Additive-optional.
    public var yogaFlowJSON: String?
    /// Conditioning movement rows materialized by a workout block remain in
    /// exercise analytics but are not independent, reorderable logger rows.
    public var generatedByWorkoutBlockID: UUID?
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
        yogaFlowJSON: String? = nil,
        generatedByWorkoutBlockID: UUID? = nil,
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
        self.yogaFlowJSON = yogaFlowJSON
        self.generatedByWorkoutBlockID = generatedByWorkoutBlockID
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
    /// Second-side data for structured sets on unilateral exercises: the
    /// lifter runs the whole block (activation + minis) on one limb, then
    /// repeats it on the other. Side 1 lives in the existing `reps` /
    /// `miniRepsJSON`; these hold side 2. Both nil on bilateral work — and
    /// when they're nil, volume math is exactly the pre-existing single-entry
    /// behavior (nothing changes for old data).
    public var side2Reps: Int?
    public var side2MiniRepsJSON: String?
    /// Myo-reps plan carried from the routine: how many mini-sets were
    /// planned after the activation. Renders as ghost pill slots to fill
    /// live; never prefills reps.
    public var plannedMiniSetCount: Int?
    /// Cluster plan carried from the routine: goal reps per segment,
    /// JSON-encoded `[Int]`. Ghost pills show the goals; tapping one logs it.
    public var plannedMiniRepsJSON: String?
    /// Immutable prescription context captured when this workout started.
    /// These are local training-log fields; the routine remains the synced
    /// source of authored intent and later PRs never rewrite this snapshot.
    public var prescribedLoadModeRaw: String = LoadPrescriptionMode.fixed.rawValue
    public var prescribed1RMPercentLow: Double?
    public var prescribed1RMPercentHigh: Double?
    public var prescribed1RMBaselineKg: Double?
    public var prescribedLoadLowKg: Double?
    public var prescribedLoadHighKg: Double?
    /// Authored rep intent captured with an adaptive load. These bounds stay
    /// separate from `reps`, which is the athlete's concrete performed value.
    public var prescribedRepsLow: Int?
    public var prescribedRepsHigh: Int?
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
        plannedMiniSetCount: Int? = nil,
        plannedMiniRepsJSON: String? = nil,
        prescribedLoadMode: LoadPrescriptionMode = .fixed,
        prescribed1RMPercentLow: Double? = nil,
        prescribed1RMPercentHigh: Double? = nil,
        prescribed1RMBaselineKg: Double? = nil,
        prescribedLoadLowKg: Double? = nil,
        prescribedLoadHighKg: Double? = nil,
        prescribedRepsLow: Int? = nil,
        prescribedRepsHigh: Int? = nil,
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
        self.plannedMiniSetCount = plannedMiniSetCount
        self.plannedMiniRepsJSON = plannedMiniRepsJSON
        self.prescribedLoadModeRaw = prescribedLoadMode.rawValue
        self.prescribed1RMPercentLow = prescribed1RMPercentLow
        self.prescribed1RMPercentHigh = prescribed1RMPercentHigh
        self.prescribed1RMBaselineKg = prescribed1RMBaselineKg
        self.prescribedLoadLowKg = prescribedLoadLowKg
        self.prescribedLoadHighKg = prescribedLoadHighKg
        self.prescribedRepsLow = prescribedRepsLow
        self.prescribedRepsHigh = prescribedRepsHigh
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

    public var supersetProgress: SupersetSetProgress {
        SupersetSetProgress(id: id, setType: setType, isComplete: completedAt != nil)
    }

    public var weightMode: WeightMode {
        get { WeightMode(rawValue: weightModeRaw) ?? .external }
        set {
            weightModeRaw = newValue.rawValue
            recomputeDerivedMetrics()
        }
    }

    public var estimatedOneRepMaxPrescription: EstimatedOneRepMaxPrescription? {
        guard loadPrescriptionMode == .percentEstimatedOneRepMax,
              let prescribed1RMPercentLow else { return nil }
        return EstimatedOneRepMaxPrescription(
            lowPercent: prescribed1RMPercentLow,
            highPercent: prescribed1RMPercentHigh
        )
    }

    public var loadPrescriptionMode: LoadPrescriptionMode {
        get { LoadPrescriptionMode(rawValue: prescribedLoadModeRaw) ?? .fixed }
        set { prescribedLoadModeRaw = newValue.rawValue }
    }

    public var prescribedRepTarget: PlannedRepTarget? {
        PlannedRepTarget(low: prescribedRepsLow, high: prescribedRepsHigh)
    }

    /// Only ordinary percentage-based strength rows require one concrete rep
    /// result. Structured blocks and AMRAP own distinct execution semantics.
    public var requiresConcreteRepsBeforeCompletion: Bool {
        loadPrescriptionMode == .percentEstimatedOneRepMax
            && !setType.isBlockType
            && setType != .amrap
            && prescribedRepTarget?.exactValue == nil
            && reps == nil
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
            isPaused: isPaused,
            miniSetCount: miniReps.count,
            side2Logged: hasSide2Data,
            side2MiniSetCount: side2MiniReps.count
        )
    }

    /// Decoded view of `plannedMiniRepsJSON` (cluster segment rep goals from
    /// the routine plan). Read-only in the logger; goals aren't achievements.
    public var plannedMiniReps: [Int] {
        guard let plannedMiniRepsJSON, let data = plannedMiniRepsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
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

    /// Decoded view of `side2MiniRepsJSON`. Setting recomputes derived metrics.
    public var side2MiniReps: [Int] {
        get {
            guard let side2MiniRepsJSON, let data = side2MiniRepsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                side2MiniRepsJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                side2MiniRepsJSON = String(data: data, encoding: .utf8)
            }
            recomputeDerivedMetrics()
        }
    }

    /// True when this set carries explicit per-side data (unilateral block
    /// flow) — side 2's reps and minis are logged separately instead of being
    /// inferred by doubling side 1.
    public var hasSide2Data: Bool {
        side2Reps != nil || side2MiniRepsJSON != nil
    }

    /// The weight input means a different stored field per mode: external
    /// load, weight added to bodyweight, or assistance subtracted from
    /// bodyweight. Every read/write of "the set's weight number" must route
    /// through this accessor so inputs, "previous" ghosts, watch sync, and
    /// the volume math (`VolumeMath.effectiveLoad`) agree on the same field —
    /// writing a non-external set's value into `weight` silently computes
    /// tonnage as if the raw number were an external load.
    public var modeWeight: Double? {
        switch weightMode {
        case .external: weight
        case .bodyweightAdded: addedWeight
        case .bodyweightAssisted: assistanceWeight
        case .bodyweight: nil
        }
    }

    public func setModeWeight(_ value: Double?) {
        switch weightMode {
        case .external: weight = value
        case .bodyweightAdded: addedWeight = value
        case .bodyweightAssisted: assistanceWeight = value
        case .bodyweight: break
        }
        recomputeDerivedMetrics()
    }

    public func recomputeDerivedMetrics() {
        let entry = domainEntry
        effectiveLoad = VolumeMath.effectiveLoad(entry)
        totalVolume = VolumeMath.tonnage(entry)
        estimated1RM = VolumeMath.estimated1RM(entry)
        if hasSide2Data {
            // Per-side logging: each side's reps are real, counted once. The
            // single-entry unilateral convention (`tonnage` multiplying one
            // entered value by limbCount because the user only logs one limb)
            // would double-count side 1, so back that multiplier out and add
            // side 2 explicitly at the same load.
            if isUnilateral, limbCount > 1, let volume = totalVolume {
                totalVolume = volume / Double(limbCount)
            }
            if let load = effectiveLoad {
                let side2Total = (side2Reps ?? 0) + side2MiniReps.reduce(0, +)
                if side2Total > 0 {
                    totalVolume = (totalVolume ?? 0) + load * Double(side2Total)
                }
            }
        }
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

/// Provenance for the aggregate distance stored on a cardio session. The log
/// store is local-only, but the sanitized iCloud backup uses this marker to
/// omit values filled from HealthKit while preserving user/machine, route,
/// Watch-input, and user-directed-import distances.
public enum CardioDistanceSource: String, Codable, Sendable {
    case userEntered
    case route
    case watchInput
    case importedFile
    case healthKit
    case restoredBackup
}

@Model
public final class CardioSessionModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// The workout exercise this cardio effort belongs to (nil for legacy
    /// whole-workout cardio sessions).
    public var workoutExerciseID: UUID?
    /// Timed-session owner for first-class yoga/conditioning blocks. Nil for
    /// exercise-backed cardio and legacy yoga rows.
    public var workoutBlockID: UUID?
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
    public var distanceSourceRaw: String?
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
    /// Downsampled per-session HR + cumulative-distance time-series (JSON),
    /// captured at completion. Powers the critical-pace curve and after-the-fact
    /// interval detection. CloudKit-safe: optional attribute, nil default.
    public var sampleSeriesJSON: String?
    /// True once ForgeFit has auto-detected and applied interval segments to this
    /// session, so we can offer a revert and not re-detect on reopen.
    public var intervalsAutoApplied: Bool = false
    /// Yoga sessions ride this model (modality == "yoga") to reuse the live
    /// state machine, HealthKit auto-fill, and watch plumbing. These fields
    /// are nil on real cardio sessions. Additive-optional for CloudKit.
    public var yogaStyleRaw: String?
    /// Per-region seconds-under-stretch snapshot (JSON `[String: Int]`),
    /// computed once at finish so analytics never re-derive from splits.
    public var flexibilityExposureJSON: String?
    /// Number of logical poses completed in a guided class. Builds predating
    /// the logical-pose policy may contain an expanded Left/Right hold count;
    /// `logicalYogaPosesCompleted` derives the corrected value from splits.
    public var posesCompleted: Int?
    /// Swimming contract (nil on every other modality). Pool length ×
    /// lengths is the distance source of truth for pool swims; /100 m pace
    /// and SWOLF are derived from these, never stored. Additive-optional
    /// for CloudKit.
    public var poolLengthMeters: Double?
    public var lengthsCompleted: Int?
    public var totalStrokes: Int?
    /// `SwimStrokeStyle` raw value.
    public var strokeStyleRaw: String?
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
        workoutBlockID: UUID? = nil,
        modality: String,
        startedAt: Date = Date(),
        liveStartedAt: Date? = nil,
        endedAt: Date? = nil,
        hkWorkoutUUID: UUID? = nil,
        sourceDevice: String? = nil,
        durationSeconds: Int? = nil,
        distanceMeters: Double? = nil,
        distanceSource: CardioDistanceSource? = nil,
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
        sampleSeriesJSON: String? = nil,
        intervalsAutoApplied: Bool = false,
        yogaStyleRaw: String? = nil,
        flexibilityExposureJSON: String? = nil,
        posesCompleted: Int? = nil,
        poolLengthMeters: Double? = nil,
        lengthsCompleted: Int? = nil,
        totalStrokes: Int? = nil,
        strokeStyleRaw: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        routePoints: [CardioRoutePointModel] = [],
        splits: [CardioSplitModel] = []
    ) {
        self.id = id
        self.userID = userID
        self.workoutExerciseID = workoutExerciseID
        self.workoutBlockID = workoutBlockID
        self.modality = modality
        self.startedAt = startedAt
        self.liveStartedAt = liveStartedAt
        self.endedAt = endedAt
        self.hkWorkoutUUID = hkWorkoutUUID
        self.sourceDevice = sourceDevice
        self.durationSeconds = durationSeconds
        self.distanceMeters = distanceMeters
        self.distanceSourceRaw = distanceSource?.rawValue
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
        self.sampleSeriesJSON = sampleSeriesJSON
        self.intervalsAutoApplied = intervalsAutoApplied
        self.yogaStyleRaw = yogaStyleRaw
        self.flexibilityExposureJSON = flexibilityExposureJSON
        self.posesCompleted = posesCompleted
        self.poolLengthMeters = poolLengthMeters
        self.lengthsCompleted = lengthsCompleted
        self.totalStrokes = totalStrokes
        self.strokeStyleRaw = strokeStyleRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.routePoints = routePoints
        self.splits = splits
    }

    /// Yoga rides the cardio session model; every cardio-specific analytics
    /// or UI path must exclude sessions where this is true.
    public var isYogaSession: Bool { modality == Self.yogaModality }
    public var isConditioningSession: Bool { modality == Self.conditioningModality }
    public var isWorkoutBlockSession: Bool { workoutBlockID != nil }

    public var distanceSource: CardioDistanceSource? {
        get { distanceSourceRaw.flatMap(CardioDistanceSource.init(rawValue:)) }
        set { distanceSourceRaw = newValue?.rawValue }
    }

    public var yogaStyle: YogaStyle? {
        get { yogaStyleRaw.flatMap(YogaStyle.init(rawValue:)) }
        set { yogaStyleRaw = newValue?.rawValue }
    }

    /// Canonical user-facing pose count. Split labels are authoritative for
    /// legacy and partial sessions; duplicate split indexes are ignored so a
    /// replayed completion cannot inflate the result.
    public var logicalYogaPosesCompleted: Int? {
        var seenIndexes = Set<Int>()
        let labels = splits
            .sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .compactMap { split -> String? in
                guard seenIndexes.insert(split.index).inserted,
                      let label = split.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty else { return nil }
                return label
            }
        guard !labels.isEmpty else { return posesCompleted }
        return YogaPoseCounting.logicalCount(labels: labels)
    }

    /// The `modality` string marking a yoga session (vs a `CardioKind` raw).
    public static let yogaModality = "yoga"
    public static let conditioningModality = "conditioning"
    /// `sourceDevice` marker for a deliberate unguided (manual) yoga log —
    /// distinguishes it from an untouched planned session at finish time.
    public static let yogaManualSource = "iphone-yoga-manual"
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
    /// True when this lap was proposed by after-the-fact interval detection
    /// (vs a manual plan or a distance split), so it can be reverted as a group.
    public var autoDetected: Bool = false
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
        autoDetected: Bool = false,
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
        self.autoDetected = autoDetected
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
    }
}

/// A generated Wrapped report (monthly or yearly training story). The report
/// is a SNAPSHOT: every stat and page it shows is computed once at generation
/// time and frozen into `payloadJSON`, because the analytics inputs it's
/// derived from drift (daily health metrics only reach ~60 days back, and
/// workouts/exercises can be edited later). Old reports must render exactly
/// as generated, never recompute.
///
/// Uniqueness is (reportTypeRaw, year, month), enforced by the generation
/// service via query-before-insert — CloudKit-backed SwiftData can't express
/// unique constraints.
@Model
public final class WrappedReportModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// "monthly" or "yearly".
    public var reportTypeRaw: String = "monthly"
    public var year: Int = 0
    /// 1–12 for monthly reports; 0 for yearly.
    public var month: Int = 0
    public var generatedAt: Date = Date()
    public var updatedAt: Date = Date()
    /// When the user first OPENED the report (any page) — drives the Home
    /// card's disappearance. Nil = unviewed.
    public var viewedAt: Date?
    /// Payload schema version, so future decoders can migrate or hide pages
    /// they no longer understand.
    public var reportVersion: Int = 1
    /// JSON-encoded `WrappedPayload` — the frozen page/stat snapshot.
    public var payloadJSON: String = "{}"
    public var sourceRangeStart: Date = Date()
    public var sourceRangeEnd: Date = Date()
    public var createdAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        reportTypeRaw: String,
        year: Int,
        month: Int = 0,
        generatedAt: Date = Date(),
        updatedAt: Date = Date(),
        viewedAt: Date? = nil,
        reportVersion: Int = 1,
        payloadJSON: String = "{}",
        sourceRangeStart: Date = Date(),
        sourceRangeEnd: Date = Date(),
        createdAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.reportTypeRaw = reportTypeRaw
        self.year = year
        self.month = month
        self.generatedAt = generatedAt
        self.updatedAt = updatedAt
        self.viewedAt = viewedAt
        self.reportVersion = reportVersion
        self.payloadJSON = payloadJSON
        self.sourceRangeStart = sourceRangeStart
        self.sourceRangeEnd = sourceRangeEnd
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    public var isViewed: Bool { viewedAt != nil }
    public var isMonthly: Bool { reportTypeRaw == "monthly" }
}

/// A user-saved plan preset, named for one-tap reuse. The persisted type name
/// predates conditioning presets: legacy cardio rows store a raw `IntervalPlan`
/// in `planJSON`, while newer preset families use tagged JSON payloads. Keeping
/// the existing model preserves the production CloudKit schema. Soft-deleted
/// via `deletedAt` so a preset can be removed without a hard delete.
@Model
public final class IntervalPresetModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    /// JSON-encoded frozen preset structure; readers discriminate its payload.
    public var planJSON: String = "{}"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        planJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.planJSON = planJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// One offered next-session target ("Bench 110 → 115 lb — hit 12 ≥ target 10")
/// and what the lifter did with it. Mirrors the progression_recommendations
/// design in docs/02-schema.sql; status resolves at workout save (accepted /
/// edited / rejected) and powers the suggestion-interaction metric.
@Model
public final class ProgressionSuggestionModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var exerciseID: UUID = UUID()
    /// The workout this suggestion was offered in.
    public var workoutID: UUID = UUID()
    public var workoutExerciseID: UUID = UUID()
    /// ProgressionSuggestion.Kind raw value (increase/hold/addReps).
    public var kindRaw: String = ""
    public var suggestedWeightKg: Double?
    public var suggestedRepsLow: Int?
    public var suggestedRepsHigh: Int?
    public var rationale: String = ""
    /// pending → accepted / edited / rejected.
    public var statusRaw: String = "pending"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        exerciseID: UUID,
        workoutID: UUID,
        workoutExerciseID: UUID,
        kindRaw: String,
        suggestedWeightKg: Double? = nil,
        suggestedRepsLow: Int? = nil,
        suggestedRepsHigh: Int? = nil,
        rationale: String = "",
        statusRaw: String = "pending"
    ) {
        self.id = id
        self.userID = userID
        self.exerciseID = exerciseID
        self.workoutID = workoutID
        self.workoutExerciseID = workoutExerciseID
        self.kindRaw = kindRaw
        self.suggestedWeightKg = suggestedWeightKg
        self.suggestedRepsLow = suggestedRepsLow
        self.suggestedRepsHigh = suggestedRepsHigh
        self.rationale = rationale
        self.statusRaw = statusRaw
    }
}

/// A user-saved yoga flow (guided pose sequence), named for reuse from the
/// flow browser and the routine editor. The sequence is frozen into
/// `planJSON` (a JSON-encoded `YogaFlowPlan`, the same shape stored on
/// `RoutineExerciseModel.yogaFlowJSON`); attaching a flow value-copies the
/// JSON, so later edits to the saved flow don't rewrite old routines.
/// Built-in flows are catalog-only (bundled JSON) and never stored here.
/// Soft-deleted via `deletedAt`, matching `IntervalPresetModel`.
@Model
public final class YogaFlowModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    /// `YogaStyle` raw value; denormalized from the plan for cheap filtering.
    public var styleRaw: String = ""
    /// JSON-encoded `YogaFlowPlan` — the frozen sequence this flow restores.
    public var planJSON: String = "{}"
    public var position: Int = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        styleRaw: String = "",
        planJSON: String = "{}",
        position: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.styleRaw = styleRaw
        self.planJSON = planJSON
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var plan: YogaFlowPlan? { YogaFlowPlan.decode(from: planJSON) }
}

/// One-tap morning check-in: subjective context tags (slept badly, sore,
/// stressed, alcohol, sick) for a calendar day. Kept as context beside the
/// biometric readiness — shown as reason chips today, correlated in Insights
/// once enough history accumulates. One row per day (query-before-insert;
/// CloudKit forbids unique constraints).
@Model
public final class DailyCheckinModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// Start-of-day for the day being described.
    public var date: Date = Date()
    /// Comma-joined tag identifiers (e.g. "slept-badly,sore").
    public var tagsRaw: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public var tags: [String] {
        get { tagsRaw.isEmpty ? [] : tagsRaw.components(separatedBy: ",") }
        set { tagsRaw = newValue.joined(separator: ",") }
    }

    public init(id: UUID = UUID(), userID: UUID, date: Date, tags: [String] = []) {
        self.id = id
        self.userID = userID
        self.date = date
        self.tagsRaw = tags.joined(separator: ",")
    }
}

// MARK: - Coach's Corner (Phase 1)
//
// The models below hold ONLY user-authored coaching preferences and plan
// bookkeeping — training focus, goals, program cadence, and performance-
// derived weekly overrides. Nothing here may ever carry Apple Health data
// (readiness, HRV, sleep, heart rate, etc.); that's the same 5.1.3(ii) rule
// that governs the rest of `ForgeDataSchema.planModels`, which is where
// these three are registered.

/// Mirrors the app's `TrainingFocus` (ForgeFit/Shared/TrainingFocus.swift)
/// raw values exactly. ForgeData can't depend on the app target, so this is
/// a parallel enum kept in lockstep by convention rather than a shared
/// type — the raw string is what's actually persisted and synced, and both
/// sides agree on it.
public enum CoachingFocus: String, Codable, CaseIterable, Sendable {
    case strength, cardio, yoga, mixed
}

public enum CoachingExperience: String, Codable, CaseIterable, Sendable {
    case beginner, intermediate, advanced
}

/// The user's non-health coaching preferences, captured during the coaching
/// setup flow: training focus, goal, experience, weekly cadence, and
/// equipment access. Drives program selection and the AI coach's default
/// framing. One row per user (query-before-insert; CloudKit forbids unique
/// constraints).
@Model
public final class CoachingProfileModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// `CoachingFocus` raw value. Empty string is the CloudKit-required
    /// default only — the setup flow always writes a real value before the
    /// row is saved.
    public var focusRaw: String = ""
    /// App-defined goal identifier (e.g. "build-muscle", "lose-fat",
    /// "general-fitness"). Deliberately not enumerated here so the app's
    /// goal picker can evolve independently of the data layer.
    public var goalRaw: String = ""
    /// `CoachingExperience` raw value.
    public var experienceRaw: String = ""
    public var sessionsPerWeek: Int = 3
    public var sessionMinutes: Int = 60
    /// JSON-encoded `[String]` of equipment the user has access to (e.g.
    /// ["barbell", "dumbbell", "bands"]). Nil = not asked yet / no
    /// constraint recorded. Additive-optional for CloudKit.
    public var equipmentJSON: String?
    /// Raw value mirroring the app's `CardioKind` (ForgeFit/Cardio/CardioMetrics.swift)
    /// for the cardio modality the user prefers when a program needs to
    /// pick one on their behalf. Nil = no preference recorded.
    public var preferredCardioRaw: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(
        id: UUID = UUID(),
        userID: UUID,
        focusRaw: String,
        goalRaw: String,
        experienceRaw: String,
        sessionsPerWeek: Int = 3,
        sessionMinutes: Int = 60,
        equipmentJSON: String? = nil,
        preferredCardioRaw: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.focusRaw = focusRaw
        self.goalRaw = goalRaw
        self.experienceRaw = experienceRaw
        self.sessionsPerWeek = sessionsPerWeek
        self.sessionMinutes = sessionMinutes
        self.equipmentJSON = equipmentJSON
        self.preferredCardioRaw = preferredCardioRaw
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var focus: CoachingFocus? {
        get { CoachingFocus(rawValue: focusRaw) }
        set { focusRaw = newValue?.rawValue ?? "" }
    }

    public var experience: CoachingExperience? {
        get { CoachingExperience(rawValue: experienceRaw) }
        set { experienceRaw = newValue?.rawValue ?? "" }
    }

    /// Decoded view of `equipmentJSON`.
    public var equipment: [String] {
        get {
            guard let equipmentJSON, let data = equipmentJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            if newValue.isEmpty {
                equipmentJSON = nil
            } else if let data = try? JSONEncoder().encode(newValue) {
                equipmentJSON = String(data: data, encoding: .utf8)
            }
        }
    }
}

/// Links a coached plan to the routine folder it manages. Either wraps a
/// catalog program import (`catalogProgramID` set) or simply "owns" a
/// folder the user already built by hand (`catalogProgramID == ""`), so the
/// weekly-review pipeline knows which folders are coach-managed without
/// tagging `RoutineFolderModel` itself.
@Model
public final class CoachedProgramModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// The `RoutineFolderModel` this program owns. Nil = not yet attached
    /// (e.g. mid-setup, before the user picks or creates a folder).
    public var folderID: UUID?
    /// Catalog program identifier the folder was generated from. Empty
    /// string = the user attached their own existing folder rather than
    /// importing a catalog program.
    public var catalogProgramID: String = ""
    public var startDate: Date = Date()
    /// Total weeks in the program. 0 = open-ended (attached plans with no
    /// fixed length).
    public var weeks: Int = 0
    public var weeklySessionTarget: Int = 3
    public var isActive: Bool = false
    /// Monday anchor of the last weekly review the coach completed for this
    /// program. Nil = never reviewed.
    public var lastReviewedWeekAnchor: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        folderID: UUID? = nil,
        catalogProgramID: String = "",
        startDate: Date,
        weeks: Int = 0,
        weeklySessionTarget: Int = 3,
        isActive: Bool = false,
        lastReviewedWeekAnchor: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.folderID = folderID
        self.catalogProgramID = catalogProgramID
        self.startDate = startDate
        self.weeks = weeks
        self.weeklySessionTarget = weeklySessionTarget
        self.isActive = isActive
        self.lastReviewedWeekAnchor = lastReviewedWeekAnchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// True when this program owns a user-attached folder rather than an
    /// imported catalog program.
    public var isAttachedPlan: Bool { catalogProgramID.isEmpty }
}

public enum CoachingOverrideKind: String, Codable, CaseIterable, Sendable {
    case progressionHold, deloadWeek, carryForward
}

public enum CoachingOverrideStatus: String, Codable, CaseIterable, Sendable {
    case proposed, active, cancelled
}

/// A time-bounded weekly coaching override — e.g. holding progression on an
/// exercise, calling a deload week, or carrying forward last week's targets
/// — scoped to a single Monday-anchored week.
///
/// PRIVACY INVARIANT: `reason` may only ever contain performance/schedule-
/// derived text (e.g. "Bench press under target 2 sessions running").
/// It must NEVER contain readiness/HRV/sleep/health-derived reasoning —
/// this model syncs via CloudKit, and Guideline 5.1.3(ii) forbids storing
/// Apple Health data there.
///
/// Expiry is derived, not stored: an override is expired once "today" has
/// passed the week described by `weekStart` — there is no separate expired
/// status.
@Model
public final class CoachingWeekOverrideModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var programID: UUID?
    /// `CoachingOverrideKind` raw value. Empty string is the CloudKit-
    /// required default; a real row always has one of the enum's cases.
    public var kindRaw: String = ""
    /// For `.progressionHold`: the `ExerciseLibraryModel` the hold applies
    /// to. Nil for overrides that aren't exercise-scoped.
    public var exerciseID: UUID?
    public var routineID: UUID?
    /// Monday anchor of the week this override applies to.
    public var weekStart: Date = Date()
    /// `CoachingOverrideStatus` raw value. Empty string is the CloudKit-
    /// required default; a real row always has one of the enum's cases.
    public var statusRaw: String = ""
    /// Performance/schedule-derived explanation only — see the privacy
    /// invariant on the type doc comment above.
    public var reason: String = ""
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(
        id: UUID = UUID(),
        userID: UUID,
        programID: UUID? = nil,
        kindRaw: String = "",
        exerciseID: UUID? = nil,
        routineID: UUID? = nil,
        weekStart: Date,
        statusRaw: String = "",
        reason: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.programID = programID
        self.kindRaw = kindRaw
        self.exerciseID = exerciseID
        self.routineID = routineID
        self.weekStart = weekStart
        self.statusRaw = statusRaw
        self.reason = reason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kind: CoachingOverrideKind? {
        get { CoachingOverrideKind(rawValue: kindRaw) }
        set { kindRaw = newValue?.rawValue ?? "" }
    }

    public var status: CoachingOverrideStatus? {
        get { CoachingOverrideStatus(rawValue: statusRaw) }
        set { statusRaw = newValue?.rawValue ?? "" }
    }
}

/// A saved Insights Builder card: the user-authored SHAPE of a comparison —
/// which metric ids, alignment, lag, filters, and chart — serialized as
/// versioned `InsightRecipe` JSON. Founder-ruled CloudKit-eligible
/// (2026-07-15): recipes are configuration, like routine names and plans; the
/// observations behind them are fetched live on-device and are NEVER stored
/// here. Keeping the recipe as a JSON payload means recipe evolution never
/// needs a CloudKit schema migration (interval/yoga plan precedent).
@Model
public final class SavedInsightModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    /// Versioned `InsightRecipe` JSON. Optional for CloudKit; a nil or
    /// undecodable payload renders as an editable "needs attention" card,
    /// never a crash.
    public var recipeJSON: String?
    public var position: Int = 0
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String = "",
        recipeJSON: String? = nil,
        position: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.recipeJSON = recipeJSON
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

// MARK: - Experiments

/// Persisted lifecycle for a local personal experiment. Deletion/discard is
/// represented separately by `ExperimentModel.deletedAt`, so it cannot be
/// confused with a completed observation window.
public enum ExperimentState: String, Codable, CaseIterable, Sendable {
    case active
    case completed
}

/// The shape of values a custom experiment tracker accepts.
public enum ExperimentTrackerType: String, Codable, CaseIterable, Sendable {
    case number
    case boolean
    case rating
    case choice
    case note
}

/// When an experiment tracker is eligible to collect an observation.
public enum ExperimentTrackerCadence: String, Codable, CaseIterable, Sendable {
    case daily
    case selectedWeekdays
    case perWorkout
    case anytime
}

/// Typed view over the scalar value columns on `ExperimentEntryModel`.
public enum ExperimentEntryValue: Equatable, Sendable {
    case number(Double)
    case boolean(Bool)
    case rating(Int)
    case choice(String)
    case note(String)
}

/// A local-only, time-bounded personal experiment.
///
/// This model deliberately owns no SwiftData relationships. Workouts,
/// trackers, and comparison selections are connected by UUID/JSON scalars so
/// the experiment graph cannot cross the local LOG and CloudKit PLAN stores.
@Model
public final class ExperimentModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var name: String = ""
    public var protocolDescription: String?
    public var question: String?
    /// Start-inclusive observation boundary.
    public var startedAt: Date = Date()
    /// Scheduled end-exclusive observation boundary.
    public var plannedEndAt: Date = Date()
    /// Actual end-exclusive boundary after completion or an early stop.
    public var endedAt: Date?
    /// IANA identifier frozen at start for DST-safe daily aggregation.
    public var timeZoneIdentifier: String = "UTC"
    public var stateRaw: String = ExperimentState.active.rawValue
    /// Versioned JSON selections owned by the analytics/domain layer.
    public var headlineMetricSelectionsJSON: String = "[]"
    /// Versioned JSON comparison selection owned by the analytics/domain layer.
    public var savedComparisonJSON: String?
    public var reminderEnabled: Bool = false
    /// Local wall-clock minutes after midnight, 0...1439.
    public var reminderTimeMinutes: Int?
    public var resultsViewedAt: Date?
    public var schemaVersion: Int = 1
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        protocolDescription: String? = nil,
        question: String? = nil,
        startedAt: Date = Date(),
        plannedEndAt: Date,
        endedAt: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        state: ExperimentState = .active,
        headlineMetricSelectionsJSON: String = "[]",
        savedComparisonJSON: String? = nil,
        reminderEnabled: Bool = false,
        reminderTimeMinutes: Int? = nil,
        resultsViewedAt: Date? = nil,
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.protocolDescription = protocolDescription
        self.question = question
        self.startedAt = startedAt
        self.plannedEndAt = plannedEndAt
        self.endedAt = endedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.stateRaw = state.rawValue
        self.headlineMetricSelectionsJSON = headlineMetricSelectionsJSON
        self.savedComparisonJSON = savedComparisonJSON
        self.reminderEnabled = reminderEnabled
        self.reminderTimeMinutes = reminderTimeMinutes
        self.resultsViewedAt = resultsViewedAt
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Unknown future states fail closed as completed so an old app never
    /// resumes collecting into a lifecycle it does not understand.
    public var state: ExperimentState {
        get { ExperimentState(rawValue: stateRaw) ?? .completed }
        set { stateRaw = newValue.rawValue }
    }

    public var isActive: Bool {
        state == .active && endedAt == nil && deletedAt == nil
    }

    /// The end of data that can be observed as of `date`. This never extends
    /// beyond either an explicit completion or the scheduled boundary.
    public func observationEnd(asOf date: Date = Date()) -> Date {
        min(endedAt ?? plannedEndAt, date)
    }

    /// Start-inclusive/end-exclusive membership over data observable so far.
    public func contains(_ date: Date, asOf referenceDate: Date = Date()) -> Bool {
        date >= startedAt && date < observationEnd(asOf: referenceDate)
    }
}

/// A user-defined value collected during an experiment.
///
/// The tracker references its experiment by UUID instead of a relationship so
/// all experiment data remains independently routable to the local LOG store.
@Model
public final class ExperimentTrackerModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var experimentID: UUID = UUID()
    public var label: String = ""
    public var typeRaw: String = ExperimentTrackerType.note.rawValue
    public var unit: String?
    public var scaleMinimumLabel: String?
    public var scaleMaximumLabel: String?
    public var optionsJSON: String = "[]"
    public var cadenceRaw: String = ExperimentTrackerCadence.daily.rawValue
    /// JSON-encoded Calendar weekday numbers (Sunday = 1 ... Saturday = 7).
    public var selectedWeekdaysJSON: String = "[]"
    public var position: Int = 0
    /// Increment when the persisted tracker-definition shape changes.
    public var definitionVersion: Int = 1
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var archivedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        experimentID: UUID,
        label: String,
        type: ExperimentTrackerType,
        unit: String? = nil,
        scaleMinimumLabel: String? = nil,
        scaleMaximumLabel: String? = nil,
        options: [String] = [],
        cadence: ExperimentTrackerCadence = .daily,
        selectedWeekdays: [Int] = [],
        position: Int = 0,
        definitionVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archivedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.experimentID = experimentID
        self.label = label
        self.typeRaw = type.rawValue
        self.unit = unit
        self.scaleMinimumLabel = scaleMinimumLabel
        self.scaleMaximumLabel = scaleMaximumLabel
        self.cadenceRaw = cadence.rawValue
        self.position = position
        self.definitionVersion = definitionVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.options = options
        self.selectedWeekdays = selectedWeekdays
    }

    /// Unknown future tracker types render as notes instead of coercing a
    /// stored value into a numeric or boolean meaning.
    public var type: ExperimentTrackerType {
        get { ExperimentTrackerType(rawValue: typeRaw) ?? .note }
        set { typeRaw = newValue.rawValue }
    }

    /// Unknown future cadences do not auto-prompt in older apps.
    public var cadence: ExperimentTrackerCadence {
        get { ExperimentTrackerCadence(rawValue: cadenceRaw) ?? .anytime }
        set { cadenceRaw = newValue.rawValue }
    }

    public var options: [String] {
        get { Self.decodeStringArray(optionsJSON) }
        set { optionsJSON = Self.encodeArray(newValue) }
    }

    public var selectedWeekdays: [Int] {
        get { Self.decodeIntArray(selectedWeekdaysJSON) }
        set { selectedWeekdaysJSON = Self.encodeArray(newValue) }
    }

    public var isArchived: Bool { archivedAt != nil }

    private static func decodeStringArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func decodeIntArray(_ json: String) -> [Int] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Int].self, from: data)) ?? []
    }

    private static func encodeArray<T: Encodable>(_ values: T) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

/// One custom observation inside an experiment.
///
/// Values occupy scalar columns rather than an opaque payload so filtering
/// and aggregation remain deterministic. `definitionSnapshotJSON` freezes the
/// tracker label/unit/options needed to explain historical rows after edits.
@Model
public final class ExperimentEntryModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var experimentID: UUID = UUID()
    public var trackerID: UUID = UUID()
    public var workoutID: UUID?
    public var observedAt: Date = Date()
    public var valueTypeRaw: String = ""
    public var numericValue: Double?
    public var booleanValue: Bool?
    public var ratingValue: Int?
    public var choiceValue: String?
    public var textValue: String?
    public var definitionSnapshotJSON: String = "{}"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        experimentID: UUID,
        trackerID: UUID,
        workoutID: UUID? = nil,
        observedAt: Date = Date(),
        value: ExperimentEntryValue,
        definitionSnapshotJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.experimentID = experimentID
        self.trackerID = trackerID
        self.workoutID = workoutID
        self.observedAt = observedAt
        self.definitionSnapshotJSON = definitionSnapshotJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.value = value
    }

    /// Setting a typed value clears every sibling column, preserving the
    /// one-value-per-entry invariant without a SwiftData relationship.
    public var value: ExperimentEntryValue? {
        get {
            switch ExperimentTrackerType(rawValue: valueTypeRaw) {
            case .number:
                return numericValue.map(ExperimentEntryValue.number)
            case .boolean:
                return booleanValue.map(ExperimentEntryValue.boolean)
            case .rating:
                return ratingValue.map(ExperimentEntryValue.rating)
            case .choice:
                return choiceValue.map(ExperimentEntryValue.choice)
            case .note:
                return textValue.map(ExperimentEntryValue.note)
            case nil:
                return nil
            }
        }
        set {
            numericValue = nil
            booleanValue = nil
            ratingValue = nil
            choiceValue = nil
            textValue = nil

            switch newValue {
            case let .number(value):
                valueTypeRaw = ExperimentTrackerType.number.rawValue
                numericValue = value
            case let .boolean(value):
                valueTypeRaw = ExperimentTrackerType.boolean.rawValue
                booleanValue = value
            case let .rating(value):
                valueTypeRaw = ExperimentTrackerType.rating.rawValue
                ratingValue = value
            case let .choice(value):
                valueTypeRaw = ExperimentTrackerType.choice.rawValue
                choiceValue = value
            case let .note(value):
                valueTypeRaw = ExperimentTrackerType.note.rawValue
                textValue = value
            case nil:
                valueTypeRaw = ""
            }
        }
    }
}

// MARK: - Microcycle Tracking

/// One locally evaluated run of a leaf routine folder. Folder configuration
/// belongs to the synced plan store; this row stays with the local workout log
/// because its progress is derived from local workout history.
@Model
public final class MicrocycleTrackingModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var folderID: UUID = UUID()
    public var folderName: String = ""
    /// Start-of-day anchor for window zero in `timeZoneIdentifier`.
    public var anchorDate: Date = Date()
    public var durationDays: Int = 7
    public var timeZoneIdentifier: String = "UTC"
    /// Persisted values are `active`, `needsAttention`, and `ended`.
    public var stateRaw: String = "active"
    /// Presentation choices are independent from tracking itself.
    public var showsOnHome: Bool = true
    public var showsFolderHeader: Bool = true
    public var endedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        folderID: UUID,
        folderName: String,
        anchorDate: Date,
        durationDays: Int,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        stateRaw: String = "active",
        showsOnHome: Bool = true,
        showsFolderHeader: Bool = true,
        endedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.folderID = folderID
        self.folderName = folderName
        self.anchorDate = anchorDate
        self.durationDays = durationDays
        self.timeZoneIdentifier = timeZoneIdentifier
        self.stateRaw = stateRaw
        self.showsOnHome = showsOnHome
        self.showsFolderHeader = showsFolderHeader
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isActive: Bool {
        stateRaw == "active" && endedAt == nil && deletedAt == nil
    }

    public var needsAttention: Bool {
        stateRaw == "needsAttention" && endedAt == nil && deletedAt == nil
    }
}

/// Frozen expectation for one fixed microcycle window. Scalar identifiers
/// avoid relationships between the CloudKit plan and local log stores.
@Model
public final class MicrocycleWindowModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var trackingID: UUID = UUID()
    public var folderID: UUID = UUID()
    public var folderName: String = ""
    public var index: Int = 0
    public var startsAt: Date = Date()
    public var endsAt: Date = Date()
    public var timeZoneIdentifier: String = "UTC"
    public var routineSnapshotJSON: String = "[]"
    /// Reversible links that credit existing completed workouts to specific
    /// days without rewriting their real workout-history timestamps.
    public var dayAssignmentSnapshotJSON: String = "[]"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        trackingID: UUID,
        folderID: UUID,
        folderName: String,
        index: Int,
        startsAt: Date,
        endsAt: Date,
        timeZoneIdentifier: String,
        routines: [MicrocycleRoutineSnapshot],
        dayAssignments: [MicrocycleDayAssignment] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.trackingID = trackingID
        self.folderID = folderID
        self.folderName = folderName
        self.index = index
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.routines = routines
        self.dayAssignments = dayAssignments
    }

    public var routines: [MicrocycleRoutineSnapshot] {
        get {
            guard let data = routineSnapshotJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([MicrocycleRoutineSnapshot].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                routineSnapshotJSON = "[]"
                return
            }
            routineSnapshotJSON = json
        }
    }

    public var dayAssignments: [MicrocycleDayAssignment] {
        get {
            guard let data = dayAssignmentSnapshotJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([MicrocycleDayAssignment].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let json = String(data: data, encoding: .utf8) else {
                dayAssignmentSnapshotJSON = "[]"
                return
            }
            dayAssignmentSnapshotJSON = json
        }
    }
}

/// An explicit user statement that no training occurred on one calendar day.
/// It is optional context, never a completion requirement.
@Model
public final class RestDayModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    /// Start-of-day in `timeZoneIdentifier`.
    public var date: Date = Date()
    public var timeZoneIdentifier: String = "UTC"
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        date: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userID = userID
        self.date = date
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
