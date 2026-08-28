import Combine
import CoreData
import ForgeCore
import ForgeData
import Foundation
import SwiftData
import SwiftUI

/// Shallow, publisher-semantic identity for one catalog parent row. Revision
/// work happens in `WorkoutIntentCatalogWorker`'s private context after the
/// idle delay, never while SwiftUI is rendering the app shell.
nonisolated struct WorkoutIntentCatalogRevisionEntry: Hashable, Sendable {
    enum Kind: Int, Hashable, Sendable {
        case routine
        case exercise
        case yogaFlow
        case conditioningPreset
    }

    let kind: Kind
    let id: UUID
    let name: String
    let updatedAt: Date
    let deletedAt: Date?
    let archivedAt: Date?
    let detail: String
}

nonisolated enum WorkoutIntentCatalogRevision {
    static func fingerprint(_ entries: [WorkoutIntentCatalogRevisionEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        for entry in entries.sorted(by: stableOrder) {
            hasher.combine(entry)
        }
        return hasher.finalize()
    }

    private static func stableOrder(
        _ lhs: WorkoutIntentCatalogRevisionEntry,
        _ rhs: WorkoutIntentCatalogRevisionEntry
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Immutable catalog projection returned by the private SwiftData context.
/// No model object crosses the worker boundary.
nonisolated struct WorkoutIntentCatalogSnapshot: Sendable {
    struct Routine: Sendable {
        let id: UUID
        let name: String
        let deletedAt: Date?
        let archivedAt: Date?
        let isAvailableForWorkoutStart: Bool
    }

    struct Exercise: Sendable {
        let id: UUID
        let name: String
        let deletedAt: Date?
        let primaryMuscle: String?
        let equipment: String?
    }

    struct YogaFlow: Sendable {
        let id: UUID
        let name: String
        let deletedAt: Date?
        let hasSteps: Bool
    }

    struct ConditioningPresetRecord: Sendable {
        let id: UUID
        let name: String
        let planJSON: String
        let deletedAt: Date?
    }

    let revision: Int
    let routines: [Routine]
    let exercises: [Exercise]
    let yogaFlows: [YogaFlow]
    let conditioningPresetRecords: [ConditioningPresetRecord]
    let availableExerciseIDs: Set<UUID>
    let availableExerciseNames: Set<String>
}

/// Shared availability rules for the live-model and detached-snapshot intent
/// builders. Callers construct the exercise sets once per catalog, avoiding
/// the former O(presets * exercises) set allocation loop.
nonisolated enum WorkoutIntentAvailability {
    static func routine(
        _ routine: RoutineModel,
        availableExerciseIDs: Set<UUID>
    ) -> Bool {
        guard routine.deletedAt == nil, routine.archivedAt == nil else { return false }
        if routine.exercises.contains(where: { availableExerciseIDs.contains($0.exerciseID) }) {
            return true
        }
        if routine.blocks.contains(where: { block in
            switch block.kind {
            case .conditioning:
                guard let plan = ConditioningPlan.decode(from: block.planJSON),
                      !plan.isEmpty else { return false }
                return plan.sections
                    .flatMap(\.movements)
                    .allSatisfy { availableExerciseIDs.contains($0.exerciseID) }
            case .yoga:
                return YogaFlowPlan.decode(from: block.planJSON)?.hasSteps == true
            }
        }) {
            return true
        }
        guard let legacyPlan = ConditioningPlan.decode(from: routine.conditioningPlanJSON),
              !legacyPlan.isEmpty else { return false }
        return legacyPlan.sections
            .flatMap(\.movements)
            .allSatisfy { availableExerciseIDs.contains($0.exerciseID) }
    }

    static func savedPreset(
        _ section: ConditioningSection,
        availableExerciseIDs: Set<UUID>
    ) -> Bool {
        !section.movements.isEmpty
            && section.movements.allSatisfy { availableExerciseIDs.contains($0.exerciseID) }
    }
}

/// A save notification is only a cheap wake-up signal. Exact semantic
/// equality is decided later by the worker fingerprint, so unrelated workout
/// saves never fetch or traverse the intent catalogs.
nonisolated enum WorkoutIntentCatalogInvalidationPolicy {
    private static let entityNames: Set<String> = [
        "RoutineModel",
        "RoutineExerciseModel",
        "RoutineSetModel",
        "RoutineBlockModel",
        "ExerciseLibraryModel",
        "YogaFlowModel",
        "IntervalPresetModel",
    ]

    static func isCatalogEntity(named entityName: String) -> Bool {
        entityNames.contains(entityName)
    }

    static func containsCatalogChange(_ notification: Notification) -> Bool {
        let keys: [ModelContext.NotificationKey] = [
            .insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers,
        ]
        return keys.contains { key in
            let identifiers = notification.userInfo?[key.rawValue] as? [PersistentIdentifier] ?? []
            return identifiers.contains { isCatalogEntity(named: $0.entityName) }
        }
    }
}

nonisolated enum WorkoutIntentCatalogWorker {
    static func load(in container: ModelContainer) async throws -> WorkoutIntentCatalogSnapshot {
        let worker = Task.detached(priority: .utility) {
            try makeSnapshot(in: container)
        }
        return try await withTaskCancellationHandler(
            operation: { try await worker.value },
            onCancel: { worker.cancel() }
        )
    }

    private static func makeSnapshot(
        in container: ModelContainer
    ) throws -> WorkoutIntentCatalogSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try Task.checkCancellation()

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>(
            sortBy: [SortDescriptor(\.name)]
        ))
        let availableExerciseIDs = Set(
            exercises.lazy.filter { $0.deletedAt == nil }.map(\.id)
        )
        let availableExerciseNames = Set(
            exercises.lazy
                .filter { $0.deletedAt == nil }
                .map { $0.name.lowercased() }
        )
        try Task.checkCancellation()

        let routineRows = try context.fetch(FetchDescriptor<RoutineModel>(
            sortBy: [SortDescriptor(\.position)]
        ))
        let routines = RoutineDeduplicator.canonicalRoutines(routineRows)
        try Task.checkCancellation()
        let yogaFlows = try context.fetch(FetchDescriptor<YogaFlowModel>(
            sortBy: [SortDescriptor(\.position)]
        ))
        try Task.checkCancellation()
        let conditioningPresets = try context.fetch(FetchDescriptor<IntervalPresetModel>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        try Task.checkCancellation()

        var revisionEntries: [WorkoutIntentCatalogRevisionEntry] = []
        revisionEntries.reserveCapacity(
            routines.count + exercises.count + yogaFlows.count + conditioningPresets.count
        )
        var routineSnapshots: [WorkoutIntentCatalogSnapshot.Routine] = []
        routineSnapshots.reserveCapacity(routines.count)
        for routine in routines {
            try Task.checkCancellation()
            let isAvailable = WorkoutIntentAvailability.routine(
                routine,
                availableExerciseIDs: availableExerciseIDs
            )
            routineSnapshots.append(.init(
                id: routine.id,
                name: routine.name,
                deletedAt: routine.deletedAt,
                archivedAt: routine.archivedAt,
                isAvailableForWorkoutStart: isAvailable
            ))
            revisionEntries.append(.init(
                kind: .routine,
                id: routine.id,
                name: routine.name,
                updatedAt: routine.updatedAt,
                deletedAt: routine.deletedAt,
                archivedAt: routine.archivedAt,
                detail: "\(routine.position)|\(routine.conditioningPlanJSON ?? "")|\(isAvailable)"
            ))
        }

        var exerciseSnapshots: [WorkoutIntentCatalogSnapshot.Exercise] = []
        exerciseSnapshots.reserveCapacity(exercises.count)
        for exercise in exercises {
            try Task.checkCancellation()
            exerciseSnapshots.append(.init(
                id: exercise.id,
                name: exercise.name,
                deletedAt: exercise.deletedAt,
                primaryMuscle: exercise.primaryMuscles.first,
                equipment: exercise.equipment
            ))
            revisionEntries.append(.init(
                kind: .exercise,
                id: exercise.id,
                name: exercise.name,
                updatedAt: exercise.updatedAt,
                deletedAt: exercise.deletedAt,
                archivedAt: nil,
                detail: [
                    exercise.primaryMuscles.first ?? "",
                    exercise.equipment ?? "",
                    exercise.modalityRaw ?? "",
                    exercise.cardioKindRaw ?? "",
                ].joined(separator: "|")
            ))
        }

        var yogaSnapshots: [WorkoutIntentCatalogSnapshot.YogaFlow] = []
        yogaSnapshots.reserveCapacity(yogaFlows.count)
        for flow in yogaFlows {
            try Task.checkCancellation()
            let hasSteps = YogaFlowPlan.decode(from: flow.planJSON)?.hasSteps == true
            yogaSnapshots.append(.init(
                id: flow.id,
                name: flow.name,
                deletedAt: flow.deletedAt,
                hasSteps: hasSteps
            ))
            revisionEntries.append(.init(
                kind: .yogaFlow,
                id: flow.id,
                name: flow.name,
                updatedAt: flow.updatedAt,
                deletedAt: flow.deletedAt,
                archivedAt: nil,
                detail: "\(flow.position)|\(flow.styleRaw)|\(flow.planJSON)"
            ))
        }

        var presetSnapshots: [WorkoutIntentCatalogSnapshot.ConditioningPresetRecord] = []
        presetSnapshots.reserveCapacity(conditioningPresets.count)
        for preset in conditioningPresets {
            try Task.checkCancellation()
            presetSnapshots.append(.init(
                id: preset.id,
                name: preset.name,
                planJSON: preset.planJSON,
                deletedAt: preset.deletedAt
            ))
            revisionEntries.append(.init(
                kind: .conditioningPreset,
                id: preset.id,
                name: preset.name,
                updatedAt: preset.updatedAt,
                deletedAt: preset.deletedAt,
                archivedAt: nil,
                detail: preset.planJSON
            ))
        }

        return WorkoutIntentCatalogSnapshot(
            revision: WorkoutIntentCatalogRevision.fingerprint(revisionEntries),
            routines: routineSnapshots,
            exercises: exerciseSnapshots,
            yogaFlows: yogaSnapshots,
            conditioningPresetRecords: presetSnapshots,
            availableExerciseIDs: availableExerciseIDs,
            availableExerciseNames: availableExerciseNames
        )
    }
}

/// Publishes App Intent and Spotlight choices without retaining catalog
/// `@Query` arrays in the SwiftUI tree. Initial and changed catalogs wait for
/// an idle window, then a fresh context performs all fetches, relationship
/// traversal, DTO projection, and fingerprinting off the main actor.
@MainActor
struct WorkoutIntentCatalogObserver: View, Equatable {
    @Environment(\.modelContext) private var modelContext
    @State private var performanceGate = LiveWorkoutPerformanceGate.shared
    @State private var publicationRequestRevision = 0
    @State private var lastPublishedCatalogRevision: Int?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: "\(publicationRequestRevision)|\(performanceGate.transitionRevision)") {
                guard performanceGate.allowsNonWorkoutWork else { return }
                do {
                    try await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled,
                          performanceGate.allowsNonWorkoutWork else { return }
                    let snapshot = try await WorkoutIntentCatalogWorker.load(
                        in: modelContext.container
                    )
                    guard !Task.isCancelled,
                          performanceGate.allowsNonWorkoutWork,
                          snapshot.revision != lastPublishedCatalogRevision else { return }
                    await ForgeFitIntentSurfacePublisher.publish(snapshot: snapshot)
                    guard !Task.isCancelled else { return }
                    lastPublishedCatalogRevision = snapshot.revision
                } catch is CancellationError {
                    // A catalog save or live-workout transition owns the retry.
                } catch {
                    // App Intents query the live repository as a backstop; a
                    // later relevant save/foreground transition retries.
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ModelContext.didSave,
                    object: modelContext
                )
            ) { notification in
                guard WorkoutIntentCatalogInvalidationPolicy.containsCatalogChange(notification) else {
                    return
                }
                publicationRequestRevision &+= 1
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
                    .receive(on: DispatchQueue.main)
            ) { _ in
                // CloudKit imports need not originate from an app-created
                // ModelContext. The worker fingerprint makes this broad wakeup
                // cheap when the remote change did not affect intent content.
                publicationRequestRevision &+= 1
            }
    }

    static func == (_: Self, _: Self) -> Bool { true }
}
