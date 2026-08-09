import ForgeCore
import ForgeData
import Foundation
import SwiftData

struct PendingPlanImport: Identifiable {
    let id = UUID()
    let document: ForgeFitPlanDocument
    let isDuplicate: Bool

    var routineCount: Int { document.routines.count }
    var microcycleCount: Int {
        switch document.kind {
        case .routine: 0
        case .microcycle: 1
        case .mesocycle: document.folders.count { $0.parentID != nil }
        }
    }
    var exerciseCount: Int { document.exercises.count }
    var customExerciseCount: Int { document.exercises.count(where: \.isCustom) }
    var alternationCount: Int { document.alternations.count }
}

@MainActor
enum PlanImportService {
    static let importedPackagesDefaultsKey = "planImportPackages.v1"
    static let maximumFileSize = 5 * 1_024 * 1_024

    struct ImportResult {
        let rootFolderID: UUID?
        let routineIDs: [UUID]
    }

    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case tooLarge
        case unsupportedVersion(Int)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                "This ForgeFit plan couldn't be read."
            case .tooLarge:
                "This ForgeFit plan is larger than 5 MB and can't be imported."
            case .unsupportedVersion(let version):
                "This plan uses format v\(version). Update ForgeFit, then open it again."
            case .invalid(let reason):
                "This ForgeFit plan is incomplete or damaged. \(reason)"
            }
        }
    }

    static func load(from url: URL) throws -> PendingPlanImport {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maximumFileSize { throw ImportError.tooLarge }
        guard let data = try? Data(contentsOf: url), data.count <= maximumFileSize else {
            throw dataTooLarge(at: url) ? ImportError.tooLarge : ImportError.unreadable
        }

        let document: ForgeFitPlanDocument
        do {
            document = try ForgeFitPlanCodec.decode(data)
        } catch {
            throw ImportError.unreadable
        }
        guard document.formatVersion <= ForgeFitPlanDocument.currentVersion else {
            throw ImportError.unsupportedVersion(document.formatVersion)
        }
        try validate(document)
        return PendingPlanImport(
            document: document,
            isDuplicate: importedPackageIDs().contains(document.packageID)
        )
    }

    static func commit(
        _ document: ForgeFitPlanDocument,
        in sourceContext: ModelContext
    ) throws -> ImportResult {
        try validate(document)

        // A dedicated context makes failure rollback import-only; unrelated UI
        // edits already pending in the main context are never discarded.
        let context = ModelContext(sourceContext.container)
        context.autosaveEnabled = false
        let userID = ForgeFitDemo.userID
        let existingExercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let exerciseMap = try resolveExercises(
            document.exercises,
            existing: existingExercises,
            userID: userID,
            in: context
        )

        let existingFolders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
        let rootPosition = (existingFolders.filter { $0.parentID == nil }.map(\.position).max() ?? -1) + 1
        let sourceFolderIDs = Set(document.folders.map(\.id))
        let rootSourceID = document.folders.first { folder in
            folder.parentID.map { !sourceFolderIDs.contains($0) } ?? true
        }?.id
        var folderMap: [UUID: UUID] = [:]
        for folder in document.folders { folderMap[folder.id] = UUID() }

        for folder in document.folders.sorted(by: folderOrder) {
            let imported = RoutineFolderModel(
                id: folderMap[folder.id] ?? UUID(),
                userID: userID,
                name: folder.name,
                position: folder.id == rootSourceID ? rootPosition : folder.position,
                parentID: folder.parentID.flatMap { folderMap[$0] },
                defaultMicrocycleLengthDays: folder.defaultMicrocycleLengthDays,
                createdAt: .now,
                updatedAt: .now
            )
            context.insert(imported)
        }

        let existingRoutines = try context.fetch(FetchDescriptor<RoutineModel>())
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
        let standalonePosition = (existingRoutines.filter { $0.folderID == nil }.map(\.position).max() ?? -1) + 1
        var routineIDs: [UUID] = []
        var routineMap: [UUID: UUID] = [:]
        for source in document.routines { routineMap[source.id] = UUID() }

        for (offset, source) in document.routines.sorted(by: { $0.position < $1.position }).enumerated() {
            let routineID = routineMap[source.id] ?? UUID()
            routineIDs.append(routineID)
            let importedFolderID = source.folderID.flatMap { folderMap[$0] }
            let routine = RoutineModel(
                id: routineID,
                userID: userID,
                name: source.name,
                notes: source.notes,
                folderID: importedFolderID,
                position: document.kind == .routine || importedFolderID == nil
                    ? standalonePosition + offset
                    : source.position,
                createdAt: .now,
                updatedAt: .now,
                conditioningPlanJSON: try remapConditioning(source.conditioningPlanJSON, exerciseMap: exerciseMap),
                exercises: try source.exercises.sorted { $0.position < $1.position }.map { row in
                    RoutineExerciseModel(
                        id: UUID(),
                        userID: userID,
                        exerciseID: exerciseMap[row.exerciseID] ?? row.exerciseID,
                        position: row.position,
                        supersetGroup: row.supersetGroup,
                        progressionRuleID: row.progressionRuleID,
                        notes: row.notes,
                        intervalPlanJSON: row.intervalPlanJSON,
                        yogaFlowJSON: try remapYoga(row.yogaFlowJSON, exerciseMap: exerciseMap),
                        createdAt: .now,
                        updatedAt: .now,
                        sets: row.sets.sorted { $0.position < $1.position }.map { set in
                            RoutineSetModel(
                                id: UUID(),
                                userID: userID,
                                position: set.position,
                                setType: SetType(rawValue: set.setTypeRaw) ?? .working,
                                targetRepsLow: set.targetRepsLow,
                                targetRepsHigh: set.targetRepsHigh,
                                targetWeight: set.targetWeight,
                                targetRPE: set.targetRPE,
                                targetRIR: set.targetRIR,
                                targetDurationSeconds: set.targetDurationSeconds,
                                targetDistanceMeters: set.targetDistanceMeters,
                                plannedMiniSetCount: set.plannedMiniSetCount,
                                plannedMiniRepsJSON: set.plannedMiniRepsJSON,
                                createdAt: .now
                            )
                        }
                    )
                },
                blocks: try source.blocks.sorted { $0.position < $1.position }.map { block in
                    RoutineBlockModel(
                        id: UUID(),
                        userID: userID,
                        kind: WorkoutBlockKind(rawValue: block.kindRaw) ?? .conditioning,
                        position: block.position,
                        planJSON: try remapBlockPlan(block, exerciseMap: exerciseMap),
                        createdAt: .now,
                        updatedAt: .now
                    )
                }
            )
            for (row, sharedRow) in zip(routine.exercises.sorted(by: { $0.position < $1.position }), source.exercises.sorted(by: { $0.position < $1.position })) {
                row.progressionRuleJSON = sharedRow.progressionRuleJSON
            }
            context.insert(routine)
        }

        for source in document.alternations {
            guard let ownerID = routineMap[source.ownerRoutineID],
                  let partnerID = routineMap[source.partnerRoutineID] else {
                throw ImportError.invalid("An alternating routine is unavailable.")
            }
            context.insert(RoutineAlternationModel(
                id: UUID(),
                userID: userID,
                ownerRoutineID: ownerID,
                partnerRoutineID: partnerID,
                createdAt: .now,
                updatedAt: .now
            ))
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        recordImported(document.packageID)
        return ImportResult(rootFolderID: rootSourceID.flatMap { folderMap[$0] }, routineIDs: routineIDs)
    }

    static func validate(_ document: ForgeFitPlanDocument) throws {
        guard document.formatVersion > 0 else { throw ImportError.invalid("The format version is missing.") }
        guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.invalid("The plan name is missing.")
        }
        guard document.folders.count <= 26,
              document.routines.count <= 250,
              document.alternations.count <= 125,
              document.exercises.count <= 1_000,
              document.routines.flatMap(\.exercises).flatMap(\.sets).count <= 10_000 else {
            throw ImportError.invalid("The plan contains too many items.")
        }

        let folderIDs = document.folders.map(\.id)
        let routineIDs = document.routines.map(\.id)
        let alternationIDs = document.alternations.map(\.id)
        let exerciseIDs = document.exercises.map(\.id)
        guard Set(folderIDs).count == folderIDs.count,
              Set(routineIDs).count == routineIDs.count,
              Set(alternationIDs).count == alternationIDs.count,
              Set(exerciseIDs).count == exerciseIDs.count else {
            throw ImportError.invalid("It contains duplicate identifiers.")
        }
        let folderIDSet = Set(folderIDs)
        let routineIDSet = Set(routineIDs)
        let exerciseIDSet = Set(exerciseIDs)

        if document.formatVersion < 2, !document.alternations.isEmpty {
            throw ImportError.invalid("Its alternating routines require a newer format version.")
        }
        var claimedRoutineIDs: Set<UUID> = []
        for alternation in document.alternations {
            guard alternation.ownerRoutineID != alternation.partnerRoutineID,
                  routineIDSet.contains(alternation.ownerRoutineID),
                  routineIDSet.contains(alternation.partnerRoutineID),
                  claimedRoutineIDs.insert(alternation.ownerRoutineID).inserted,
                  claimedRoutineIDs.insert(alternation.partnerRoutineID).inserted else {
                throw ImportError.invalid("An alternating routine pair is invalid.")
            }
        }

        switch document.kind {
        case .routine:
            guard document.folders.isEmpty,
                  (1...2).contains(document.routines.count),
                  document.routines.allSatisfy({ $0.folderID == nil }),
                  (document.routines.count == 1
                    ? document.alternations.isEmpty
                    : document.alternations.count == 1) else {
                throw ImportError.invalid("The routine structure is invalid.")
            }
        case .microcycle:
            guard document.folders.count == 1,
                  document.folders.first?.parentID == nil,
                  let folderID = document.folders.first?.id,
                  document.routines.contains(where: { $0.folderID == folderID }),
                  document.routines.allSatisfy({ $0.folderID == folderID || $0.folderID == nil }),
                  companionsArePairedWithScope(
                    document.routines,
                    alternations: document.alternations,
                    scopedFolderIDs: Set([folderID])
                  ) else {
                throw ImportError.invalid("The microcycle structure is invalid.")
            }
        case .mesocycle:
            let roots = document.folders.filter { $0.parentID == nil }
            guard roots.count == 1,
                  let rootID = roots.first?.id,
                  document.folders.count >= 2,
                  document.folders.filter({ $0.id != rootID }).allSatisfy({ $0.parentID == rootID }),
                  document.routines.allSatisfy({ $0.folderID == nil || $0.folderID != rootID }),
                  companionsArePairedWithScope(
                    document.routines,
                    alternations: document.alternations,
                    scopedFolderIDs: Set(document.folders.filter { $0.id != rootID }.map(\.id))
                  ) else {
                throw ImportError.invalid("The mesocycle hierarchy is invalid.")
            }
        }

        for folder in document.folders {
            if let parentID = folder.parentID, !folderIDSet.contains(parentID) {
                throw ImportError.invalid("A cycle folder has no parent.")
            }
            if let days = folder.defaultMicrocycleLengthDays, !(1...31).contains(days) {
                throw ImportError.invalid("A microcycle day target is invalid.")
            }
        }
        for routine in document.routines {
            if let folderID = routine.folderID, !folderIDSet.contains(folderID) {
                throw ImportError.invalid("A routine has no cycle folder.")
            }
            guard !routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.invalid("A routine name is missing.")
            }
            try validateConditioning(routine.conditioningPlanJSON, exerciseIDs: exerciseIDSet)
            for block in routine.blocks {
                guard WorkoutBlockKind(rawValue: block.kindRaw) != nil else {
                    throw ImportError.invalid("A routine block type isn't supported.")
                }
                if block.kindRaw == WorkoutBlockKind.conditioning.rawValue {
                    try validateConditioning(block.planJSON, exerciseIDs: exerciseIDSet)
                } else if let yogaJSON = block.planJSON {
                    guard let flow = YogaFlowPlan.decode(from: yogaJSON),
                          flow.steps.allSatisfy({ exerciseIDSet.contains($0.poseID) }) else {
                        throw ImportError.invalid("A Yoga block isn't supported.")
                    }
                }
            }
            for row in routine.exercises {
                guard exerciseIDSet.contains(row.exerciseID) else {
                    throw ImportError.invalid("A routine references an unavailable exercise.")
                }
                if let intervalJSON = row.intervalPlanJSON, IntervalPlan.decode(from: intervalJSON) == nil {
                    throw ImportError.invalid("A cardio interval plan isn't supported.")
                }
                if let progressionJSON = row.progressionRuleJSON,
                   ProgressionRule.decode(from: progressionJSON) == nil {
                    throw ImportError.invalid("A progression rule isn't supported.")
                }
                if let yogaJSON = row.yogaFlowJSON {
                    guard let yoga = YogaFlowPlan.decode(from: yogaJSON),
                          yoga.steps.allSatisfy({ exerciseIDSet.contains($0.poseID) }) else {
                        throw ImportError.invalid("A Yoga flow isn't supported.")
                    }
                }
                for set in row.sets {
                    guard SetType(rawValue: set.setTypeRaw) != nil,
                          nonnegative(set.targetRepsLow), nonnegative(set.targetRepsHigh),
                          nonnegative(set.targetWeight), nonnegative(set.targetDurationSeconds),
                          nonnegative(set.targetDistanceMeters), nonnegative(set.plannedMiniSetCount),
                          set.targetRPE.map({ (0...10).contains($0) }) ?? true,
                          nonnegative(set.targetRIR),
                          validRepRange(low: set.targetRepsLow, high: set.targetRepsHigh),
                          validMiniReps(set.plannedMiniRepsJSON) else {
                        throw ImportError.invalid("A planned set target is invalid.")
                    }
                }
            }
        }
        for exercise in document.exercises {
            guard !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  WeightMode(rawValue: exercise.defaultWeightModeRaw) != nil,
                  exercise.modalityRaw.flatMap({ Modality(rawValue: $0) }) != nil || exercise.modalityRaw == nil else {
                throw ImportError.invalid("An exercise definition isn't supported.")
            }
        }
    }

    private static func validateConditioning(_ json: String?, exerciseIDs: Set<UUID>) throws {
        guard let json else { return }
        guard let plan = ConditioningPlan.decode(from: json),
              plan.sections.flatMap(\.movements).allSatisfy({ exerciseIDs.contains($0.exerciseID) }) else {
            throw ImportError.invalid("A conditioning plan isn't supported.")
        }
    }

    private static func companionsArePairedWithScope(
        _ routines: [SharedPlanRoutine],
        alternations: [SharedPlanAlternation],
        scopedFolderIDs: Set<UUID>
    ) -> Bool {
        let scopedIDs = Set(routines.filter {
            $0.folderID.map(scopedFolderIDs.contains) == true
        }.map(\.id))
        let companionIDs = Set(routines.filter { $0.folderID == nil }.map(\.id))
        guard !scopedIDs.isEmpty else { return false }
        let linkedCompanions = Set(alternations.flatMap { alternation -> [UUID] in
            if scopedIDs.contains(alternation.ownerRoutineID), companionIDs.contains(alternation.partnerRoutineID) {
                return [alternation.partnerRoutineID]
            }
            if scopedIDs.contains(alternation.partnerRoutineID), companionIDs.contains(alternation.ownerRoutineID) {
                return [alternation.ownerRoutineID]
            }
            return []
        })
        return linkedCompanions == companionIDs
    }

    private static func resolveExercises(
        _ definitions: [SharedPlanExercise],
        existing: [ExerciseLibraryModel],
        userID: UUID,
        in context: ModelContext
    ) throws -> [UUID: UUID] {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: UUID] = [:]
        for definition in definitions {
            if let present = existingByID[definition.id], !definition.isCustom || matches(definition, present) {
                result[definition.id] = present.id
                continue
            }
            let resolvedID = existingByID[definition.id] == nil ? definition.id : UUID()
            let exercise = ExerciseLibraryModel(
                id: resolvedID,
                ownerID: definition.isCustom ? userID : nil,
                name: definition.name,
                movementPattern: definition.movementPattern,
                primaryMuscles: definition.primaryMuscles,
                secondaryMuscles: definition.secondaryMuscles,
                equipment: definition.equipment,
                isUnilateral: definition.isUnilateral,
                defaultWeightMode: WeightMode(rawValue: definition.defaultWeightModeRaw) ?? .external,
                preferredWeightUnitRaw: definition.preferredWeightUnitRaw,
                difficulty: definition.difficulty,
                isCardio: definition.isCardio,
                cardioKindRaw: definition.cardioKindRaw,
                modalityRaw: definition.modalityRaw,
                defaultHoldSeconds: definition.defaultHoldSeconds,
                mappedGlobalID: definition.mappedGlobalID,
                instructions: definition.instructions,
                mechanic: definition.mechanic,
                mediaSlug: definition.mediaSlug,
                category: definition.category,
                force: definition.force,
                createdAt: .now,
                updatedAt: .now
            )
            context.insert(exercise)
            result[definition.id] = resolvedID
        }
        return result
    }

    private static func matches(_ definition: SharedPlanExercise, _ exercise: ExerciseLibraryModel) -> Bool {
        definition.name == exercise.name
            && definition.movementPattern == exercise.movementPattern
            && definition.primaryMuscles == exercise.primaryMuscles
            && definition.secondaryMuscles == exercise.secondaryMuscles
            && definition.modalityRaw == exercise.modalityRaw
            && definition.equipment == exercise.equipment
            && definition.isUnilateral == exercise.isUnilateral
            && definition.defaultWeightModeRaw == exercise.defaultWeightModeRaw
            && definition.preferredWeightUnitRaw == exercise.preferredWeightUnitRaw
            && definition.difficulty == exercise.difficulty
            && definition.isCardio == exercise.isCardio
            && definition.cardioKindRaw == exercise.cardioKindRaw
            && definition.defaultHoldSeconds == exercise.defaultHoldSeconds
            && definition.mappedGlobalID == exercise.mappedGlobalID
            && definition.instructions == exercise.instructions
            && definition.mechanic == exercise.mechanic
            && definition.mediaSlug == exercise.mediaSlug
            && definition.category == exercise.category
            && definition.force == exercise.force
    }

    private static func remapConditioning(_ json: String?, exerciseMap: [UUID: UUID]) throws -> String? {
        guard let json else { return nil }
        guard var plan = ConditioningPlan.decode(from: json) else {
            throw ImportError.invalid("A conditioning plan isn't supported.")
        }
        for sectionIndex in plan.sections.indices {
            for movementIndex in plan.sections[sectionIndex].movements.indices {
                let oldID = plan.sections[sectionIndex].movements[movementIndex].exerciseID
                guard let newID = exerciseMap[oldID] else {
                    throw ImportError.invalid("A conditioning exercise is unavailable.")
                }
                plan.sections[sectionIndex].movements[movementIndex].exerciseID = newID
            }
        }
        return plan.encodedJSON()
    }

    private static func remapYoga(_ json: String?, exerciseMap: [UUID: UUID]) throws -> String? {
        guard let json else { return nil }
        guard var flow = YogaFlowPlan.decode(from: json) else {
            throw ImportError.invalid("A Yoga flow isn't supported.")
        }
        for index in flow.steps.indices {
            let oldID = flow.steps[index].poseID
            guard let newID = exerciseMap[oldID] else {
                throw ImportError.invalid("A Yoga pose is unavailable.")
            }
            flow.steps[index].poseID = newID
        }
        return flow.encodedJSON()
    }

    private static func remapBlockPlan(
        _ block: SharedPlanRoutineBlock,
        exerciseMap: [UUID: UUID]
    ) throws -> String? {
        switch WorkoutBlockKind(rawValue: block.kindRaw) {
        case .conditioning: try remapConditioning(block.planJSON, exerciseMap: exerciseMap)
        case .yoga: try remapYoga(block.planJSON, exerciseMap: exerciseMap)
        case nil: throw ImportError.invalid("A routine block type isn't supported.")
        }
    }

    private static func importedPackageIDs() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: importedPackagesDefaultsKey),
              let records = try? JSONDecoder().decode([ImportedPackage].self, from: data) else { return [] }
        return Set(records.map(\.id))
    }

    private static func recordImported(_ id: UUID) {
        let defaults = UserDefaults.standard
        let existing = defaults.data(forKey: importedPackagesDefaultsKey)
            .flatMap { try? JSONDecoder().decode([ImportedPackage].self, from: $0) } ?? []
        var records = existing.filter { $0.id != id }
        records.append(ImportedPackage(id: id, importedAt: .now))
        records = Array(records.sorted { $0.importedAt > $1.importedAt }.prefix(100))
        defaults.set(try? JSONEncoder().encode(records), forKey: importedPackagesDefaultsKey)
    }

    private static func dataTooLarge(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > maximumFileSize } ?? false
    }

    private static func folderOrder(_ lhs: SharedPlanFolder, _ rhs: SharedPlanFolder) -> Bool {
        if (lhs.parentID == nil) != (rhs.parentID == nil) { return lhs.parentID == nil }
        return lhs.position < rhs.position
    }

    private static func nonnegative<T: BinaryInteger>(_ value: T?) -> Bool { value.map { $0 >= 0 } ?? true }
    private static func nonnegative<T: BinaryFloatingPoint>(_ value: T?) -> Bool { value.map { $0 >= 0 } ?? true }

    private static func validRepRange(low: Int?, high: Int?) -> Bool {
        guard let low, let high else { return true }
        return low <= high
    }

    private static func validMiniReps(_ json: String?) -> Bool {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([Int].self, from: data) else { return json == nil }
        return !values.isEmpty && values.allSatisfy { $0 >= 0 }
    }

    private struct ImportedPackage: Codable {
        let id: UUID
        let importedAt: Date
    }
}
