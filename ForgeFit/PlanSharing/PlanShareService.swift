import ForgeCore
import ForgeData
import Foundation

@MainActor
enum PlanShareService {
    enum ShareError: LocalizedError {
        case missingExercise(String)
        case invalidStructuredPlan(String)

        var errorDescription: String? {
            switch self {
            case .missingExercise(let name):
                "The plan references \(name), but that exercise is no longer available."
            case .invalidStructuredPlan(let name):
                "\(name) contains plan details this version of ForgeFit can't share."
            }
        }
    }

    static func routineDocument(
        _ routine: RoutineModel,
        allRoutines: [RoutineModel] = [],
        alternations: [RoutineAlternationModel] = [],
        exercises: [ExerciseLibraryModel]
    ) throws -> ForgeFitPlanDocument {
        try document(
            kind: .routine,
            name: routine.name,
            folders: [],
            routines: [routine],
            allRoutines: allRoutines,
            alternations: alternations,
            exerciseLibrary: exercises
        )
    }

    static func microcycleDocument(
        _ folder: RoutineFolderModel,
        routines: [RoutineModel],
        allRoutines: [RoutineModel] = [],
        alternations: [RoutineAlternationModel] = [],
        exercises: [ExerciseLibraryModel]
    ) throws -> ForgeFitPlanDocument {
        try document(
            kind: .microcycle,
            name: folder.name,
            folders: [folder],
            routines: routines,
            allRoutines: allRoutines,
            alternations: alternations,
            exerciseLibrary: exercises
        )
    }

    static func mesocycleDocument(
        _ folder: RoutineFolderModel,
        microcycles: [RoutineFolderModel],
        routines: [RoutineModel],
        allRoutines: [RoutineModel] = [],
        alternations: [RoutineAlternationModel] = [],
        exercises: [ExerciseLibraryModel]
    ) throws -> ForgeFitPlanDocument {
        try document(
            kind: .mesocycle,
            name: folder.name,
            folders: [folder] + microcycles,
            routines: routines,
            allRoutines: allRoutines,
            alternations: alternations,
            exerciseLibrary: exercises
        )
    }

    static func write(_ document: ForgeFitPlanDocument) throws -> URL {
        let directory = URL.temporaryDirectory.appending(path: "ForgeFit Shares", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(safeFilename(document.name)).forgefitplan")
        try ForgeFitPlanCodec.encode(document).write(to: url, options: .atomic)
        return url
    }

    private static func document(
        kind: ForgeFitPlanKind,
        name: String,
        folders: [RoutineFolderModel],
        routines: [RoutineModel],
        allRoutines: [RoutineModel],
        alternations: [RoutineAlternationModel],
        exerciseLibrary: [ExerciseLibraryModel]
    ) throws -> ForgeFitPlanDocument {
        let availableRoutines = (allRoutines.isEmpty ? routines : allRoutines)
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
        let availableByID = Dictionary(
            availableRoutines.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var includedRoutineIDs = Set(routines.filter {
            $0.deletedAt == nil && $0.archivedAt == nil
        }.map(\.id))
        var includedAlternations: [RoutineAlternationModel] = []
        let validAlternations = RoutineAlternationService.states(
            alternations: alternations,
            routines: availableRoutines,
            workouts: []
        ).map(\.alternation)
        for alternation in validAlternations {
            guard includedRoutineIDs.contains(alternation.ownerRoutineID)
                    || includedRoutineIDs.contains(alternation.partnerRoutineID),
                  availableByID[alternation.ownerRoutineID] != nil,
                  availableByID[alternation.partnerRoutineID] != nil else { continue }
            includedRoutineIDs.insert(alternation.ownerRoutineID)
            includedRoutineIDs.insert(alternation.partnerRoutineID)
            includedAlternations.append(alternation)
        }
        let liveRoutines = availableRoutines
            .filter { includedRoutineIDs.contains($0.id) }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
        let referencedIDs = try referencedExerciseIDs(in: liveRoutines)
        let libraryByID = Dictionary(
            exerciseLibrary.filter { $0.deletedAt == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let definitions = try referencedIDs.map { id in
            guard let exercise = libraryByID[id] else {
                throw ShareError.missingExercise("an unavailable exercise")
            }
            return sharedExercise(exercise)
        }
        .sorted { (lhs: SharedPlanExercise, rhs: SharedPlanExercise) in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let includedFolderIDs = Set(folders.map(\.id))
        return ForgeFitPlanDocument(
            createdAt: .now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            kind: kind,
            name: name,
            folders: folders
                .filter { $0.deletedAt == nil && $0.archivedAt == nil }
                .sorted { $0.position < $1.position }
                .map {
                    SharedPlanFolder(
                        id: $0.id,
                        name: $0.name,
                        position: $0.position,
                        parentID: $0.parentID.flatMap { includedFolderIDs.contains($0) ? $0 : nil },
                        defaultMicrocycleLengthDays: $0.defaultMicrocycleLengthDays
                    )
                },
            routines: liveRoutines.map { routine in
                sharedRoutine(
                    routine,
                    folderID: routine.folderID.flatMap { includedFolderIDs.contains($0) ? $0 : nil }
                )
            },
            alternations: includedAlternations.map {
                SharedPlanAlternation(
                    id: $0.id,
                    ownerRoutineID: $0.ownerRoutineID,
                    partnerRoutineID: $0.partnerRoutineID
                )
            },
            exercises: definitions
        )
    }

    private static func referencedExerciseIDs(in routines: [RoutineModel]) throws -> Set<UUID> {
        var ids = Set(routines.flatMap { $0.exercises.map(\.exerciseID) })
        for routine in routines {
            for row in routine.exercises {
                if let yogaJSON = row.yogaFlowJSON {
                    guard let flow = YogaFlowPlan.decode(from: yogaJSON) else {
                        throw ShareError.invalidStructuredPlan(routine.name)
                    }
                    ids.formUnion(flow.steps.map(\.poseID))
                }
            }
            let conditioningJSON = [routine.conditioningPlanJSON]
                + routine.blocks.filter { $0.kind == .conditioning }.map(\.planJSON)
            for json in conditioningJSON.compactMap({ $0 }) {
                guard let plan = ConditioningPlan.decode(from: json) else {
                    throw ShareError.invalidStructuredPlan(routine.name)
                }
                ids.formUnion(plan.sections.flatMap(\.movements).map(\.exerciseID))
            }
            for json in routine.blocks.filter({ $0.kind == .yoga }).compactMap(\.planJSON) {
                guard let flow = YogaFlowPlan.decode(from: json) else {
                    throw ShareError.invalidStructuredPlan(routine.name)
                }
                ids.formUnion(flow.steps.map(\.poseID))
            }
        }
        return ids
    }

    private static func sharedRoutine(_ routine: RoutineModel, folderID: UUID?) -> SharedPlanRoutine {
        SharedPlanRoutine(
            id: routine.id,
            name: routine.name,
            notes: routine.notes,
            folderID: folderID,
            position: routine.position,
            conditioningPlanJSON: routine.conditioningPlanJSON,
            exercises: routine.exercises.sorted { $0.position < $1.position }.map { row in
                SharedPlanRoutineExercise(
                    id: row.id,
                    exerciseID: row.exerciseID,
                    position: row.position,
                    supersetGroup: row.supersetGroup,
                    progressionRuleID: row.progressionRuleID,
                    progressionRuleJSON: row.progressionRuleJSON,
                    notes: row.notes,
                    intervalPlanJSON: row.intervalPlanJSON,
                    yogaFlowJSON: row.yogaFlowJSON,
                    sets: row.sets.sorted { $0.position < $1.position }.map { set in
                        SharedPlanRoutineSet(
                            id: set.id,
                            position: set.position,
                            setTypeRaw: set.setTypeRaw,
                            targetRepsLow: set.targetRepsLow,
                            targetRepsHigh: set.targetRepsHigh,
                            targetWeight: set.targetWeight,
                            targetRPE: set.targetRPE,
                            targetRIR: set.targetRIR,
                            targetDurationSeconds: set.targetDurationSeconds,
                            targetDistanceMeters: set.targetDistanceMeters,
                            plannedMiniSetCount: set.plannedMiniSetCount,
                            plannedMiniRepsJSON: set.plannedMiniRepsJSON
                        )
                    }
                )
            },
            blocks: routine.blocks.sorted { $0.position < $1.position }.map {
                SharedPlanRoutineBlock(
                    id: $0.id,
                    kindRaw: $0.kindRaw,
                    position: $0.position,
                    planJSON: $0.planJSON
                )
            }
        )
    }

    private static func sharedExercise(_ exercise: ExerciseLibraryModel) -> SharedPlanExercise {
        SharedPlanExercise(
            id: exercise.id,
            isCustom: exercise.ownerID != nil,
            name: exercise.name,
            movementPattern: exercise.movementPattern,
            primaryMuscles: exercise.primaryMuscles,
            secondaryMuscles: exercise.secondaryMuscles,
            equipment: exercise.equipment,
            isUnilateral: exercise.isUnilateral,
            defaultWeightModeRaw: exercise.defaultWeightModeRaw,
            preferredWeightUnitRaw: exercise.preferredWeightUnitRaw,
            difficulty: exercise.difficulty,
            isCardio: exercise.isCardio,
            cardioKindRaw: exercise.cardioKindRaw,
            modalityRaw: exercise.modalityRaw,
            defaultHoldSeconds: exercise.defaultHoldSeconds,
            mappedGlobalID: exercise.mappedGlobalID,
            instructions: exercise.instructions,
            mechanic: exercise.mechanic,
            mediaSlug: exercise.mediaSlug,
            category: exercise.category,
            force: exercise.force
        )
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet.alphanumerics.union(.whitespaces).inverted
        let clean = name.components(separatedBy: invalid).joined(separator: "-")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        return clean.isEmpty ? "ForgeFit-Plan" : String(clean.prefix(80))
    }
}
