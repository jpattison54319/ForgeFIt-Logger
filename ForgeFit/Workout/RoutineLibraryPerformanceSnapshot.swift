import ForgeCore
import ForgeData
import Foundation

struct RoutineLibraryCardPresentation {
    let orderedItems: [OrderedRoutineItem]
    let conditioningSummary: String?

    static func make(for routine: RoutineModel) -> Self {
        let orderedItems = OrderedRoutineItem.ordered(in: routine)
        // Preserve the existing legacy-card behavior: structured blocks render
        // in the ordered disclosure, while only a legacy routine-level plan
        // receives the compact conditioning label.
        let conditioningJSON = routine.blocks.isEmpty ? routine.conditioningPlanJSON : nil
        return Self(
            orderedItems: orderedItems,
            conditioningSummary: conditioningJSON.flatMap { summary(for: $0) }
        )
    }

    private static func summary(for json: String) -> String? {
        guard let plan = ConditioningPlan.decode(from: json),
              let first = plan.sections.first else { return nil }
        switch first.format {
        case .amrap:
            return "\(max(1, (first.durationSeconds ?? 1_200) / 60)) min AMRAP"
        case .emom:
            return "EMOM \(first.rounds ?? 20)"
        case .forTime:
            return "For Time"
        default:
            return first.format.title
        }
    }
}

/// Catalog names are a separate revision from the routine graph: changing one
/// exercise should rebuild the O(1) lookup, not repeat folder/alternation work.
@MainActor
enum RoutineLibraryExerciseLookup {
    static func namesByID(_ exercises: [ExerciseLibraryModel]) -> [UUID: String] {
        Dictionary(
            exercises.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

struct RoutineLibraryPerformanceKey: Equatable {
    let persistenceRevision: Int
    let routineCount: Int
    let folderCount: Int
    let alternationCount: Int
    let workoutCount: Int

    var generation: String {
        "\(persistenceRevision)|\(routineCount)|\(folderCount)|\(alternationCount)|\(workoutCount)"
    }
}

/// One body-pass snapshot for the Workout library. The screen previously
/// canonicalized, filtered, sorted, grouped, and resolved alternations again
/// for every folder and routine card. This keeps that work O(library + history)
/// per semantic change and makes each row lookup O(1).
@MainActor
struct RoutineLibraryPerformanceSnapshot {
    let generation: String
    let activeRoutines: [RoutineModel]
    let folders: [RoutineFolderModel]
    let topLevelFolders: [RoutineFolderModel]
    let ungroupedRoutines: [RoutineModel]
    let routinesByFolderID: [UUID: [RoutineModel]]
    let childFoldersByParentID: [UUID: [RoutineFolderModel]]
    let alternationStates: [RoutineAlternationService.State]
    let alternationStateByRoutineID: [UUID: RoutineAlternationService.State]
    let configuredAlternationRoutineIDs: Set<UUID>
    let canOrganize: Bool

    func routines(in folder: RoutineFolderModel) -> [RoutineModel] {
        routinesByFolderID[folder.id, default: []]
    }

    func childFolders(of folder: RoutineFolderModel) -> [RoutineFolderModel] {
        childFoldersByParentID[folder.id, default: []]
    }

    static func make(
        routines: [RoutineModel],
        folders allFolders: [RoutineFolderModel],
        alternations: [RoutineAlternationModel],
        workouts: [WorkoutModel],
        generation: String
    ) -> Self {
        let activeRoutines = RoutineDeduplicator.canonicalRoutines(routines)
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
            .sorted(by: routineSort)

        // Canonicalize before filtering. A soft-deleted CloudKit duplicate is
        // the production reconciliation winner and must not briefly resurrect
        // an older live folder while maintenance catches up.
        let folders = RoutineDeduplicator.canonicalFolders(allFolders)
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
            .sorted(by: folderSort)

        var routinesByFolderID: [UUID: [RoutineModel]] = [:]
        var ungroupedRoutines: [RoutineModel] = []
        for routine in activeRoutines {
            if let folderID = routine.folderID {
                routinesByFolderID[folderID, default: []].append(routine)
            } else {
                ungroupedRoutines.append(routine)
            }
        }

        var childFoldersByParentID: [UUID: [RoutineFolderModel]] = [:]
        var topLevelFolders: [RoutineFolderModel] = []
        for folder in folders {
            if let parentID = folder.parentID {
                childFoldersByParentID[parentID, default: []].append(folder)
            } else {
                topLevelFolders.append(folder)
            }
        }

        let states = RoutineAlternationService.states(
            alternations: alternations,
            routines: activeRoutines,
            workouts: workouts
        )
        var stateByRoutineID: [UUID: RoutineAlternationService.State] = [:]
        for state in states {
            stateByRoutineID[state.owner.id] = state
            stateByRoutineID[state.partner.id] = state
        }
        let configuredIDs = Set(
            RoutineAlternationService.live(alternations).flatMap {
                [$0.ownerRoutineID, $0.partnerRoutineID]
            }
        )
        let canOrganize = RoutineOrganizerDraft(
            folders: folders,
            routines: activeRoutines,
            alternationStates: states
        ).canOrganize

        return Self(
            generation: generation,
            activeRoutines: activeRoutines,
            folders: folders,
            topLevelFolders: topLevelFolders,
            ungroupedRoutines: ungroupedRoutines,
            routinesByFolderID: routinesByFolderID,
            childFoldersByParentID: childFoldersByParentID,
            alternationStates: states,
            alternationStateByRoutineID: stateByRoutineID,
            configuredAlternationRoutineIDs: configuredIDs,
            canOrganize: canOrganize
        )
    }

    private static func routineSort(_ lhs: RoutineModel, _ rhs: RoutineModel) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func folderSort(_ lhs: RoutineFolderModel, _ rhs: RoutineFolderModel) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
