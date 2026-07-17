import Foundation

/// ForgeFit's user-facing "export my data" file, v1 — produced on demand from
/// Settings and handed straight to the user via the share sheet.
///
/// The training log reuses the backup schema (`ForgeFitBackupFile`) so the two
/// serializations can't drift, then adds what the backup must never carry:
///
/// - `healthMetrics`: Apple-Health-derived values ForgeFit has stored, in a
///   separate appendix keyed by id. The backup's type-system privacy boundary
///   stays intact — App Store Guideline 5.1.3(ii) constrains what we put in
///   iCloud, not what the user exports into their own hands.
/// - `routines`: the plan layer (folders as macro/meso cycles, routines,
///   per-set targets), which the backup omits because CloudKit syncs it.
public struct ForgeFitExportFile: Codable, Sendable {
    /// Version policy matches the backup's: additive optional fields do NOT
    /// bump this — older files decode them as nil, and older apps ignore
    /// unknown keys. Bump only for breaking changes.
    public static let currentExportVersion = 1

    public var exportVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var trainingLog: ForgeFitBackupFile
    public var healthMetrics: ExportHealthMetrics
    public var routines: ExportRoutineLibrary

    public init(
        exportVersion: Int = ForgeFitExportFile.currentExportVersion,
        exportedAt: Date,
        appVersion: String? = nil,
        trainingLog: ForgeFitBackupFile,
        healthMetrics: ExportHealthMetrics = ExportHealthMetrics(),
        routines: ExportRoutineLibrary = ExportRoutineLibrary()
    ) {
        self.exportVersion = exportVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.trainingLog = trainingLog
        self.healthMetrics = healthMetrics
        self.routines = routines
    }
}

/// Health appendix, keyed by the same ids the training log uses. Keys are
/// UUID *strings* — `[UUID: V]` would encode as a flat array, not an object.
public struct ExportHealthMetrics: Codable, Sendable {
    public var workouts: [String: ExportWorkoutHealth]
    public var cardioSessions: [String: ExportCardioSessionHealth]

    public init(
        workouts: [String: ExportWorkoutHealth] = [:],
        cardioSessions: [String: ExportCardioSessionHealth] = [:]
    ) {
        self.workouts = workouts
        self.cardioSessions = cardioSessions
    }
}

public struct ExportWorkoutHealth: Codable, Sendable {
    public var avgHR: Int?
    public var maxHR: Int?
    public var activeEnergyKcal: Double?
    public var hrZoneSeconds: [Int]?
    public var readinessAtStart: Int?

    public init(
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        hrZoneSeconds: [Int]? = nil,
        readinessAtStart: Int? = nil
    ) {
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.hrZoneSeconds = hrZoneSeconds
        self.readinessAtStart = readinessAtStart
    }

    public var isEmpty: Bool {
        avgHR == nil && maxHR == nil && activeEnergyKcal == nil
            && (hrZoneSeconds?.allSatisfy { $0 == 0 } ?? true) && readinessAtStart == nil
    }
}

/// HR-derived and Apple-Health-sourced values only. Machine readouts and
/// pool metadata (pace/split, power, cadence, stroke rate/counts, resistance,
/// incline, elevation, pool length/lengths, stroke style) are training data:
/// they live on `BackupCardioSession` inside `trainingLog`, never here.
public struct ExportCardioSessionHealth: Codable, Sendable {
    public var avgHR: Int?
    public var maxHR: Int?
    public var activeEnergyKcal: Double?
    public var hrZoneSeconds: [Int]?
    public var tss: Double?
    public var totalSteps: Int?
    public var floorsClimbed: Int?

    public init(
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        hrZoneSeconds: [Int]? = nil,
        tss: Double? = nil,
        totalSteps: Int? = nil,
        floorsClimbed: Int? = nil
    ) {
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.hrZoneSeconds = hrZoneSeconds
        self.tss = tss
        self.totalSteps = totalSteps
        self.floorsClimbed = floorsClimbed
    }

    public var isEmpty: Bool {
        avgHR == nil && maxHR == nil && activeEnergyKcal == nil
            && (hrZoneSeconds?.allSatisfy { $0 == 0 } ?? true)
            && tss == nil && totalSteps == nil && floorsClimbed == nil
    }
}

// MARK: - Routines

public struct ExportRoutineLibrary: Codable, Sendable {
    public var folders: [ExportRoutineFolder]
    public var routines: [ExportRoutine]

    public init(folders: [ExportRoutineFolder] = [], routines: [ExportRoutine] = []) {
        self.folders = folders
        self.routines = routines
    }
}

public struct ExportRoutineFolder: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var position: Int
    /// Folders nest one level: a top-level folder with children is a
    /// macrocycle, its children are mesocycles.
    public var parentID: UUID?
    /// Present when the folder is archived (hidden but kept). Additive.
    public var archivedAt: Date?

    public init(id: UUID, name: String, position: Int, parentID: UUID? = nil, archivedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.position = position
        self.parentID = parentID
        self.archivedAt = archivedAt
    }
}

public struct ExportRoutine: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var notes: String?
    public var folderID: UUID?
    public var position: Int
    /// Present when the routine is archived (hidden but kept). Additive.
    public var archivedAt: Date?
    public var exercises: [ExportRoutineExercise]

    public init(
        id: UUID,
        name: String,
        notes: String? = nil,
        folderID: UUID? = nil,
        position: Int,
        archivedAt: Date? = nil,
        exercises: [ExportRoutineExercise] = []
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.folderID = folderID
        self.position = position
        self.archivedAt = archivedAt
        self.exercises = exercises
    }
}

public struct ExportRoutineExercise: Codable, Sendable {
    public var id: UUID
    public var exerciseID: UUID
    /// Denormalized so the file is self-contained without the library.
    public var name: String
    public var position: Int
    public var supersetGroup: Int?
    public var progressionRuleJSON: String?
    public var intervalPlanJSON: String?
    public var yogaFlowJSON: String?
    public var notes: String?
    public var sets: [ExportRoutineSet]

    public init(
        id: UUID,
        exerciseID: UUID,
        name: String,
        position: Int,
        supersetGroup: Int? = nil,
        progressionRuleJSON: String? = nil,
        intervalPlanJSON: String? = nil,
        yogaFlowJSON: String? = nil,
        notes: String? = nil,
        sets: [ExportRoutineSet] = []
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.name = name
        self.position = position
        self.supersetGroup = supersetGroup
        self.progressionRuleJSON = progressionRuleJSON
        self.intervalPlanJSON = intervalPlanJSON
        self.yogaFlowJSON = yogaFlowJSON
        self.notes = notes
        self.sets = sets
    }
}

public struct ExportRoutineSet: Codable, Sendable {
    public var position: Int
    public var setType: String
    public var targetRepsLow: Int?
    public var targetRepsHigh: Int?
    /// Kilograms — the canonical storage unit.
    public var targetWeightKg: Double?
    public var targetRPE: Double?
    public var targetRIR: Int?
    public var targetDurationSeconds: Int?
    public var plannedMiniSetCount: Int?
    public var plannedMiniReps: [Int]?

    public init(
        position: Int,
        setType: String,
        targetRepsLow: Int? = nil,
        targetRepsHigh: Int? = nil,
        targetWeightKg: Double? = nil,
        targetRPE: Double? = nil,
        targetRIR: Int? = nil,
        targetDurationSeconds: Int? = nil,
        plannedMiniSetCount: Int? = nil,
        plannedMiniReps: [Int]? = nil
    ) {
        self.position = position
        self.setType = setType
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.targetWeightKg = targetWeightKg
        self.targetRPE = targetRPE
        self.targetRIR = targetRIR
        self.targetDurationSeconds = targetDurationSeconds
        self.plannedMiniSetCount = plannedMiniSetCount
        self.plannedMiniReps = plannedMiniReps
    }
}
