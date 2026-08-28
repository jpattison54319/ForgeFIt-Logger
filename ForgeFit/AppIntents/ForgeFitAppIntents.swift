import AppIntents
import CoreSpotlight
import ForgeCore
import ForgeData
import Foundation
import SwiftData

// MARK: - Runtime access

final class ForgeFitIntentRepository: @unchecked Sendable {
    private let container: ModelContainer

    nonisolated init(container: ModelContainer) {
        self.container = container
    }

    @MainActor
    func workoutChoices() -> [WorkoutChoiceRecord] {
        let context = container.mainContext
        let routines = RoutineDeduplicator.canonicalRoutines(
            (try? context.fetch(FetchDescriptor<RoutineModel>())) ?? []
        )
        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let yogaFlows = (try? context.fetch(FetchDescriptor<YogaFlowModel>())) ?? []
        let presets = (try? context.fetch(FetchDescriptor<IntervalPresetModel>())) ?? []
        return ForgeFitIntentCatalog.workoutChoices(
            routines: routines,
            exercises: exercises,
            yogaFlows: yogaFlows,
            conditioningPresetRecords: presets
        )
    }

    @MainActor
    func routines() -> [ForgeFitRoutineEntity] {
        let context = container.mainContext
        return RoutineDeduplicator.canonicalRoutines(
            (try? context.fetch(FetchDescriptor<RoutineModel>())) ?? []
        )
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map { ForgeFitRoutineEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func exercises() -> [ForgeFitExerciseEntity] {
        let context = container.mainContext
        return ((try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? [])
            .filter { $0.deletedAt == nil }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map {
                ForgeFitExerciseEntity(
                    id: $0.id,
                    name: $0.name,
                    detail: [$0.primaryMuscles.first?.capitalized, $0.equipment?.capitalized]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
            }
    }

    @MainActor
    func nextTrackedWorkout(now: Date = .now) -> TrackedMicrocycleNextResolution {
        let context = container.mainContext
        let routines = RoutineDeduplicator.canonicalRoutines(
            (try? context.fetch(FetchDescriptor<RoutineModel>())) ?? []
        )
        return TrackedMicrocycleNextResolver.resolve(
            trackings: (try? context.fetch(FetchDescriptor<MicrocycleTrackingModel>())) ?? [],
            windows: (try? context.fetch(FetchDescriptor<MicrocycleWindowModel>())) ?? [],
            routines: routines,
            alternations: (try? context.fetch(FetchDescriptor<RoutineAlternationModel>())) ?? [],
            workouts: (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? [],
            now: now
        )
    }
}

private extension WorkoutChoiceRecord {
    static let nextIntentChoice = WorkoutChoiceRecord(
        id: WorkoutChoiceTarget.next.identifier,
        title: "Next Workout",
        subtitle: "From your active tracked microcycle",
        systemImageName: "forward.fill"
    )

    static let emptyIntentChoice = WorkoutChoiceRecord(
        id: WorkoutChoiceTarget.empty.identifier,
        title: "Empty Workout",
        subtitle: "Build a workout as you train",
        systemImageName: "square.and.pencil"
    )
}

@MainActor
enum ForgeFitIntentCatalog {
    static func workoutChoices(
        routines: [RoutineModel],
        exercises: [ExerciseLibraryModel],
        yogaFlows: [YogaFlowModel],
        conditioningPresetRecords: [IntervalPresetModel]
    ) -> [WorkoutChoiceRecord] {
        var records = [
            WorkoutChoiceRecord.nextIntentChoice,
            WorkoutChoiceRecord.emptyIntentChoice,
        ]

        records += RoutineDeduplicator.canonicalRoutines(routines)
            .filter { $0.isAvailableForWorkoutStart(exercises: exercises) }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map {
                WorkoutChoiceRecord(
                    id: WorkoutChoiceTarget.routine($0.id).identifier,
                    title: $0.name,
                    subtitle: "Saved routine",
                    systemImageName: "list.bullet.clipboard"
                )
            }

        records += CardioModality.allCases.map {
            WorkoutChoiceRecord(
                id: WorkoutChoiceTarget.cardio($0.rawValue).identifier,
                title: $0.title,
                subtitle: "Cardio",
                systemImageName: $0.systemImage
            )
        }

        records += YogaFlowCatalog.load().map {
            WorkoutChoiceRecord(
                id: WorkoutChoiceTarget.yogaBuiltIn($0.slug).identifier,
                title: $0.name,
                subtitle: "Guided yoga · \($0.style.title)",
                systemImageName: $0.style.systemImage
            )
        }
        records += yogaFlows
            .filter { $0.deletedAt == nil && $0.plan?.hasSteps == true }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .map {
                WorkoutChoiceRecord(
                    id: WorkoutChoiceTarget.yogaSaved($0.id).identifier,
                    title: $0.name,
                    subtitle: "Saved yoga flow",
                    systemImageName: "figure.yoga"
                )
            }

        let visibleBuiltIns = ConditioningPresetStore.visibleBuiltIns(
            from: conditioningPresetRecords
        )
        records += visibleBuiltIns.compactMap { preset in
            let selection = ConditioningPresetSelection.builtIn(preset)
            guard selection.resolvedSection(in: exercises) != nil else { return nil }
            return WorkoutChoiceRecord(
                id: WorkoutChoiceTarget.conditioningBuiltIn(preset.id).identifier,
                title: preset.title,
                subtitle: "Conditioning · \(preset.summary)",
                systemImageName: "figure.cross.training"
            )
        }
        records += ConditioningPresetStore.savedPresets(from: conditioningPresetRecords)
            .compactMap { selection -> WorkoutChoiceRecord? in
                guard case .saved(let id, let name, let section) = selection else { return nil }
                let availableIDs = Set(exercises.lazy.filter { $0.deletedAt == nil }.map(\.id))
                guard !section.movements.isEmpty,
                      section.movements.allSatisfy({ availableIDs.contains($0.exerciseID) }) else {
                    return nil
                }
                return WorkoutChoiceRecord(
                    id: WorkoutChoiceTarget.conditioningSaved(id).identifier,
                    title: name,
                    subtitle: "Saved conditioning preset",
                    systemImageName: "figure.cross.training"
                )
            }

        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Workout choice

struct ForgeFitWorkoutChoiceEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Workout",
        numericFormat: "\(placeholder: .int) workouts"
    )
    static let defaultQuery = ForgeFitWorkoutChoiceQuery()

    let id: String
    let name: String
    let detail: String
    let systemImageName: String

    init(_ record: WorkoutChoiceRecord) {
        id = record.id
        name = record.title
        detail = record.subtitle
        systemImageName = record.systemImageName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(detail)",
            image: .init(systemName: systemImageName)
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet()
        attributes.title = name
        attributes.contentDescription = detail
        attributes.keywords = WorkoutChoiceNameMatcher.spokenAliases(for: name)
        return attributes
    }

    var record: WorkoutChoiceRecord {
        WorkoutChoiceRecord(
            id: id,
            title: name,
            subtitle: detail,
            systemImageName: systemImageName
        )
    }
}

struct ForgeFitWorkoutChoiceQuery: EntityStringQuery, EnumerableEntityQuery {
    func entities(for identifiers: [String]) async throws -> [ForgeFitWorkoutChoiceEntity] {
        let requested = Set(identifiers)
        return WorkoutChoiceCatalogStore.load()
            .filter { requested.contains($0.id) }
            .map(ForgeFitWorkoutChoiceEntity.init)
    }

    func entities(matching string: String) async throws -> [ForgeFitWorkoutChoiceEntity] {
        let records = WorkoutChoiceCatalogStore.load()
        let matches = WorkoutChoiceNameMatcher.matches(
            query: string,
            in: records
        )
        await WorkoutIntentDiagnosticStore.shared.recordQuery(
            string,
            matches: matches
        )
        return matches
            .map(\.record)
            .map(ForgeFitWorkoutChoiceEntity.init)
    }

    func allEntities() async throws -> [ForgeFitWorkoutChoiceEntity] {
        WorkoutChoiceCatalogStore.load().map(ForgeFitWorkoutChoiceEntity.init)
    }
}

struct StartForgeFitWorkoutIntent: StartWorkoutIntent {
    static let title: LocalizedStringResource = "Start Workout"
    static let description = IntentDescription(
        "Starts a specific saved ForgeFit workout."
    )
    static let openAppWhenRun = true
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Workout")
    var workoutStyle: ForgeFitWorkoutChoiceEntity

    @Dependency private var navigator: ForgeFitIntentNavigator

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$workoutStyle)")
    }

    static var suggestedWorkouts: [Self] {
        var records = WorkoutChoiceCatalogStore.load()
        if !records.contains(where: { $0.id == WorkoutChoiceTarget.next.identifier }) {
            records.insert(.nextIntentChoice, at: 0)
        }
        if !records.contains(where: { $0.id == WorkoutChoiceTarget.empty.identifier }) {
            records.insert(.emptyIntentChoice, at: min(1, records.endIndex))
        }
        return records.map {
            Self(style: ForgeFitWorkoutChoiceEntity($0))
        }
    }

    var displayRepresentation: DisplayRepresentation {
        workoutStyle.displayRepresentation
    }

    init() {}

    init(style: ForgeFitWorkoutChoiceEntity) {
        workoutStyle = style
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let records = WorkoutChoiceCatalogStore.load()
        guard let selected = records.first(where: { $0.id == workoutStyle.id }),
              let target = WorkoutChoiceTarget(identifier: workoutStyle.id) else {
            await WorkoutIntentDiagnosticStore.shared.recordExecution(
                selected: nil,
                outcome: .unavailable
            )
            navigator.navigate(
                to: .chooseWorkout(
                    message: "That workout is no longer available. Choose another workout in ForgeFit."
                )
            )
            return .result(
                dialog: "That workout is no longer available. Choose another workout in ForgeFit."
            )
        }
        switch target {
        case .next:
            await WorkoutIntentDiagnosticStore.shared.recordExecution(
                selected: selected,
                outcome: .nextWorkout
            )
            navigator.navigate(to: .startNextWorkout)
            return .result(dialog: "Opening your next tracked workout.")
        case .empty:
            await WorkoutIntentDiagnosticStore.shared.recordExecution(
                selected: selected,
                outcome: .emptyWorkout
            )
        default:
            await WorkoutIntentDiagnosticStore.shared.recordExecution(
                selected: selected,
                outcome: .namedWorkout
            )
        }
        navigator.navigate(to: .startWorkout(choiceID: selected.id))
        return .result(dialog: "Opening \(selected.title).")
    }
}

struct StartNextForgeFitWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start My Next Workout"
    static let description = IntentDescription(
        "Starts the next incomplete routine in your active tracked microcycle."
    )
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var repository: ForgeFitIntentRepository
    @Dependency private var navigator: ForgeFitIntentNavigator

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch repository.nextTrackedWorkout() {
        case .routine(let id, let title):
            let selected = WorkoutChoiceCatalogStore.load().first {
                $0.id == WorkoutChoiceTarget.next.identifier
            }
            await WorkoutIntentDiagnosticStore.shared.recordExecution(
                selected: selected,
                outcome: .nextWorkout
            )
            navigator.navigate(
                to: .startWorkout(
                    choiceID: WorkoutChoiceTarget.routine(id).identifier
                )
            )
            return .result(dialog: "Opening \(title), your next tracked workout.")
        case .chooseWorkout(let message):
            await WorkoutIntentDiagnosticStore.shared.recordExecution(
                selected: nil,
                outcome: .unavailable
            )
            navigator.navigate(to: .chooseWorkout(message: message))
            return .result(dialog: "\(message)")
        }
    }
}

struct StartEmptyForgeFitWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Empty Workout"
    static let description = IntentDescription(
        "Starts a blank ForgeFit workout so you can add exercises while training."
    )
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var navigator: ForgeFitIntentNavigator

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let selected = WorkoutChoiceCatalogStore.load().first {
            $0.id == WorkoutChoiceTarget.empty.identifier
        }
        await WorkoutIntentDiagnosticStore.shared.recordExecution(
            selected: selected,
            outcome: .emptyWorkout
        )
        navigator.navigate(
            to: .startWorkout(choiceID: WorkoutChoiceTarget.empty.identifier)
        )
        return .result(dialog: "Opening an empty workout.")
    }
}

struct ResumeForgeFitWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Active Workout"
    static let description = IntentDescription("Opens the workout already in progress.")
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Dependency private var navigator: ForgeFitIntentNavigator

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        navigator.navigate(to: .resumeWorkout)
        return .result(dialog: "Opening your active workout.")
    }
}

// MARK: - Searchable routines and exercises

struct ForgeFitRoutineEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Routine",
        numericFormat: "\(placeholder: .int) routines"
    )
    static let defaultQuery = ForgeFitRoutineQuery()
    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "ForgeFit routine",
            image: .init(systemName: "list.bullet.clipboard")
        )
    }
}

struct ForgeFitRoutineQuery: EntityStringQuery, EnumerableEntityQuery {
    @Dependency private var repository: ForgeFitIntentRepository

    func entities(for identifiers: [UUID]) async throws -> [ForgeFitRoutineEntity] {
        let requested = Set(identifiers)
        return await repository.routines().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ForgeFitRoutineEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return await repository.routines().filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
    }

    func allEntities() async throws -> [ForgeFitRoutineEntity] {
        await repository.routines()
    }
}

struct OpenForgeFitRoutineIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Routine"
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Routine")
    var target: ForgeFitRoutineEntity

    @Dependency private var navigator: ForgeFitIntentNavigator

    init() {}

    init(target: ForgeFitRoutineEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        navigator.navigate(to: .routine(target.id))
        return .result()
    }
}

struct ForgeFitExerciseEntity: IndexedEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Exercise",
        numericFormat: "\(placeholder: .int) exercises"
    )
    static let defaultQuery = ForgeFitExerciseQuery()
    let id: UUID
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: detail.isEmpty ? "ForgeFit exercise" : "\(detail)",
            image: .init(systemName: "figure.strengthtraining.traditional")
        )
    }
}

struct ForgeFitExerciseQuery: EntityStringQuery, EnumerableEntityQuery {
    @Dependency private var repository: ForgeFitIntentRepository

    func entities(for identifiers: [UUID]) async throws -> [ForgeFitExerciseEntity] {
        let requested = Set(identifiers)
        return await repository.exercises().filter { requested.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ForgeFitExerciseEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return await repository.exercises().filter {
            query.isEmpty
                || $0.name.localizedStandardContains(query)
                || $0.detail.localizedStandardContains(query)
        }
    }

    func allEntities() async throws -> [ForgeFitExerciseEntity] {
        await repository.exercises()
    }
}

struct OpenForgeFitExerciseIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Exercise"
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "Exercise")
    var target: ForgeFitExerciseEntity

    @Dependency private var navigator: ForgeFitIntentNavigator

    init() {}

    init(target: ForgeFitExerciseEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        navigator.navigate(to: .exercise(target.id))
        return .result()
    }
}

// MARK: - Shortcuts and Spotlight publication

nonisolated struct ForgeFitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartForgeFitWorkoutIntent(),
            phrases: [
                "Start \(\.$workoutStyle) in \(.applicationName)",
                "Start \(\.$workoutStyle) with \(.applicationName)",
                "Start my \(\.$workoutStyle) workout in \(.applicationName)",
                "Start my \(\.$workoutStyle) workout on \(.applicationName)",
                "Start my \(\.$workoutStyle) routine in \(.applicationName)",
                "Start my routine \(\.$workoutStyle) in \(.applicationName)",
                "Begin \(\.$workoutStyle) in \(.applicationName)",
            ],
            shortTitle: "Start Named Workout",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StartNextForgeFitWorkoutIntent(),
            phrases: [
                "Start my next workout in \(.applicationName)",
                "Start the next tracked workout in \(.applicationName)",
                "Begin my next workout with \(.applicationName)",
            ],
            shortTitle: "Start Next Workout",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: StartEmptyForgeFitWorkoutIntent(),
            phrases: [
                "Start an empty workout in \(.applicationName)",
                "Start a blank workout in \(.applicationName)",
                "Begin an empty workout with \(.applicationName)",
            ],
            shortTitle: "Start Empty Workout",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: ResumeForgeFitWorkoutIntent(),
            phrases: [
                "Resume my \(.applicationName) workout",
                "Open my active workout in \(.applicationName)",
            ],
            shortTitle: "Resume Workout",
            systemImageName: "arrow.up.forward.app.fill"
        )
        AppShortcut(
            intent: OpenForgeFitRoutineIntent(),
            phrases: ["Open \(\.$target) in \(.applicationName)"],
            shortTitle: "Open Routine",
            systemImageName: "list.bullet.clipboard"
        )
        AppShortcut(
            intent: OpenForgeFitExerciseIntent(),
            phrases: ["Show \(\.$target) in \(.applicationName)"],
            shortTitle: "Open Exercise",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: GetForgeFitActiveWorkoutStatusIntent(),
            phrases: [
                "What's next in my \(.applicationName) workout",
                "What is my current set in \(.applicationName)",
                "How is my \(.applicationName) workout going",
                "Get my active workout status in \(.applicationName)",
            ],
            shortTitle: "Workout Status",
            systemImageName: "list.number"
        )
        AppShortcut(
            intent: ManageForgeFitSetIntent(),
            phrases: [
                "\(\.$action) my current set in \(.applicationName)",
                "Complete \(\.$targetSet) in \(.applicationName)",
                "Log my current set in \(.applicationName)",
                "Mark my current set complete in \(.applicationName)",
                "Update my last set in \(.applicationName)",
                "Reopen my last set in \(.applicationName)",
            ],
            shortTitle: "Manage Workout Set",
            systemImageName: "checkmark.circle.fill"
        )
        AppShortcut(
            intent: ControlForgeFitRestIntent(),
            phrases: [
                "\(\.$action) my rest timer in \(.applicationName)",
                "How much rest time is left in \(.applicationName)",
                "Check my rest timer in \(.applicationName)",
            ],
            shortTitle: "Control Rest Timer",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: FinishForgeFitWorkoutIntent(),
            phrases: [
                "Finish my workout in \(.applicationName)",
                "End my active workout in \(.applicationName)",
                "Save and finish my workout in \(.applicationName)",
            ],
            shortTitle: "Finish Workout",
            systemImageName: "flag.checkered"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}

@MainActor
enum ForgeFitIntentSurfacePublisher {
    private static let workoutChoiceIndex = CSSearchableIndex(
        name: "ForgeFit_WorkoutChoices"
    )

    static func publish(
        routines: [RoutineModel],
        exercises: [ExerciseLibraryModel],
        yogaFlows: [YogaFlowModel],
        conditioningPresetRecords: [IntervalPresetModel]
    ) async {
        let choices = ForgeFitIntentCatalog.workoutChoices(
            routines: routines,
            exercises: exercises,
            yogaFlows: yogaFlows,
            conditioningPresetRecords: conditioningPresetRecords
        )
        WorkoutChoiceCatalogStore.save(choices)
        StartForgeFitWorkoutIntent.invalidateSuggestedWorkouts()
        ForgeFitShortcuts.updateAppShortcutParameters()

        let workoutChoiceEntities = choices.map(ForgeFitWorkoutChoiceEntity.init)
        do {
            try await workoutChoiceIndex.deleteAppEntities(
                ofType: ForgeFitWorkoutChoiceEntity.self
            )
            try await workoutChoiceIndex.indexAppEntities(workoutChoiceEntities)
        } catch {
            // String queries remain authoritative if Spotlight is temporarily
            // unavailable; indexing only improves system discoverability.
        }

        let searchableRoutines = routines
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
            .map { ForgeFitRoutineEntity(id: $0.id, name: $0.name) }
        let searchableExercises = exercises
            .filter { $0.deletedAt == nil }
            .map {
                ForgeFitExerciseEntity(
                    id: $0.id,
                    name: $0.name,
                    detail: [$0.primaryMuscles.first?.capitalized, $0.equipment?.capitalized]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
            }
        let index = CSSearchableIndex.default()
        do {
            try await index.deleteAppEntities(ofType: ForgeFitRoutineEntity.self)
            try await index.deleteAppEntities(ofType: ForgeFitExerciseEntity.self)
            try await index.indexAppEntities(searchableRoutines)
            try await index.indexAppEntities(searchableExercises)
        } catch {
            // Search indexing is opportunistic. Intents continue to query the
            // live repository even when Spotlight temporarily rejects work.
        }
    }
}
