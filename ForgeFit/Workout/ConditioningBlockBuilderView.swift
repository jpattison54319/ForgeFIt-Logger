import ForgeCore
import ForgeData
import SwiftUI

private struct BlockSectionSelection: Identifiable {
    let id: UUID
}

private struct BlockMovementSelection: Identifiable {
    let sectionID: UUID
    let movementID: UUID
    var id: UUID { movementID }
}

/// Value-backed conditioning builder shared by routine and live-workout
/// blocks. It edits one block without mutating either parent until Save.
struct ConditioningBlockBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let exercises: [ExerciseLibraryModel]
    let workouts: [WorkoutModel]
    let historySnapshot: ExercisePickerHistorySnapshot?
    let navigationTitle: String
    let allowsMultipleSections: Bool
    let showsPresetActions: Bool
    private let saveAction: (String) throws -> Bool

    @State private var plan: ConditioningPlan
    @State private var addMovementSection: BlockSectionSelection?
    @State private var replaceMovement: BlockMovementSelection?
    @State private var presetError: String?
    @State private var saveError: String?

    init(
        planJSON: String?,
        exercises: [ExerciseLibraryModel],
        workouts: [WorkoutModel],
        historySnapshot: ExercisePickerHistorySnapshot? = nil,
        navigationTitle: String = "Conditioning Block",
        allowsMultipleSections: Bool = true,
        showsPresetActions: Bool = true,
        onSave: @escaping (String) throws -> Void
    ) {
        self.exercises = exercises
        self.workouts = workouts
        self.historySnapshot = historySnapshot
        self.navigationTitle = navigationTitle
        self.allowsMultipleSections = allowsMultipleSections
        self.showsPresetActions = showsPresetActions
        saveAction = { json in
            try onSave(json)
            return true
        }
        let decoded = ConditioningPlan.decode(from: planJSON)
        _plan = State(initialValue: decoded ?? ConditioningPlan(sections: [Self.emptySection(index: 0)]))
    }

    init(
        planJSON: String?,
        exercises: [ExerciseLibraryModel],
        workouts: [WorkoutModel],
        historySnapshot: ExercisePickerHistorySnapshot? = nil,
        navigationTitle: String = "Conditioning Block",
        allowsMultipleSections: Bool = true,
        showsPresetActions: Bool = true,
        commit: @escaping (String) -> Bool
    ) {
        self.exercises = exercises
        self.workouts = workouts
        self.historySnapshot = historySnapshot
        self.navigationTitle = navigationTitle
        self.allowsMultipleSections = allowsMultipleSections
        self.showsPresetActions = showsPresetActions
        saveAction = commit
        let decoded = ConditioningPlan.decode(from: planJSON)
        _plan = State(initialValue: decoded ?? ConditioningPlan(sections: [Self.emptySection(index: 0)]))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Space.lg) {
                        ForEach($plan.sections) { $section in
                            ConditioningSectionEditor(
                                section: $section,
                                exercises: exercises,
                                workouts: workouts,
                                historySnapshot: historySnapshot,
                                onChange: {},
                                onApplyPreset: { apply($0, to: section.id) },
                                onAddMovement: {
                                    addMovementSection = BlockSectionSelection(id: section.id)
                                },
                                onReplaceMovement: {
                                    replaceMovement = BlockMovementSelection(
                                        sectionID: section.id,
                                        movementID: $0.id
                                    )
                                },
                                onRemoveMovement: { removeMovement($0.id, from: section.id) },
                                onMoveMovement: { moveMovement($0.id, by: $1, in: section.id) },
                                onDelete: { deleteSection(section.id) },
                                showsPresetActions: showsPresetActions
                            )
                        }

                        if allowsMultipleSections {
                            SecondaryButton(title: "Add Section", systemImage: "plus", action: addSection)
                                .accessibilityIdentifier("add-conditioning-block-section")
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.md)
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(plan.isEmpty)
                        .accessibilityIdentifier(allowsMultipleSections ? "save-conditioning-block" : "save-conditioning-preset")
                }
            }
        }
        .sheet(item: $addMovementSection) { selection in
            let sectionExercises = exerciseModels(in: selection.id)
            ExercisePickerView(
                excludeYoga: true,
                context: sectionExercises,
                history: workouts,
                historySnapshot: historySnapshot,
                navigationTitle: "Add Movement",
                excludedIDs: Set(sectionExercises.map(\.id))
            ) { selected in
                addMovements(selected, to: selection.id)
            }
        }
        .sheet(item: $replaceMovement) { selection in
            if let current = exerciseForMovement(selection) {
                ExerciseSwapSheet(
                    current: current,
                    allExercises: exercises.filter { !$0.isYoga },
                    inUseIDs: movementExerciseIDs(in: selection.sectionID),
                    history: workouts,
                    historySnapshot: historySnapshot
                ) { replacement in
                    replace(selection, with: replacement)
                }
            }
        }
        .alert("Couldn't Apply Preset", isPresented: Binding(
            get: { presetError != nil },
            set: { if !$0 { presetError = nil } }
        )) {
        } message: {
            Text(presetError ?? "The preset is unavailable.")
        }
        .alert("Couldn't Save Preset", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
        } message: {
            Text(saveError ?? "The preset couldn't be saved.")
        }
    }

    private static func emptySection(index: Int) -> ConditioningSection {
        ConditioningSection(
            name: index == 0 ? "AMRAP" : "Section \(index + 1)",
            format: .amrap,
            durationSeconds: 1_200
        )
    }

    private func save() {
        guard let json = plan.encodedJSON(), !plan.isEmpty else { return }
        do {
            if try saveAction(json) {
                dismiss()
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func addSection() {
        plan.sections.append(Self.emptySection(index: plan.sections.count))
    }

    private func deleteSection(_ id: UUID) {
        plan.sections.removeAll { $0.id == id }
        if plan.sections.isEmpty { addSection() }
    }

    private func apply(_ preset: ConditioningPresetSelection, to sectionID: UUID) {
        do {
            try ConditioningPlanCoordinator.apply(
                preset,
                to: sectionID,
                in: &plan,
                catalog: exercises
            )
        } catch {
            presetError = error.localizedDescription
        }
    }

    private func addMovements(_ selected: [ExerciseLibraryModel], to sectionID: UUID) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let existing = Set(plan.sections[sectionIndex].movements.map(\.exerciseID))
        plan.sections[sectionIndex].movements.append(contentsOf: selected
            .filter { !existing.contains($0.id) && !$0.isYoga }
            .map(makeMovement))
    }

    private func replace(_ selection: BlockMovementSelection, with exercise: ExerciseLibraryModel) {
        guard !exercise.isYoga,
              let sectionIndex = plan.sections.firstIndex(where: { $0.id == selection.sectionID }),
              let movementIndex = plan.sections[sectionIndex].movements.firstIndex(where: { $0.id == selection.movementID }) else { return }
        plan.sections[sectionIndex].movements[movementIndex].exerciseID = exercise.id
        plan.sections[sectionIndex].movements[movementIndex].targetLoad = nil
        plan.sections[sectionIndex].movements[movementIndex].weightMode = exercise.defaultWeightMode
        plan.sections[sectionIndex].movements[movementIndex].targetUnit = exercise.isCardio ? .seconds : .reps
    }

    private func removeMovement(_ movementID: UUID, from sectionID: UUID) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        plan.sections[sectionIndex].movements.removeAll { $0.id == movementID }
    }

    private func moveMovement(_ movementID: UUID, by offset: Int, in sectionID: UUID) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }),
              let index = plan.sections[sectionIndex].movements.firstIndex(where: { $0.id == movementID }) else { return }
        let destination = max(0, min(plan.sections[sectionIndex].movements.count - 1, index + offset))
        guard destination != index else { return }
        let movement = plan.sections[sectionIndex].movements.remove(at: index)
        plan.sections[sectionIndex].movements.insert(movement, at: destination)
    }

    private func makeMovement(_ exercise: ExerciseLibraryModel) -> ConditioningMovement {
        ConditioningMovement(
            exerciseID: exercise.id,
            targetValue: exercise.isCardio ? 60 : 10,
            targetUnit: exercise.isCardio ? .seconds : .reps,
            weightMode: exercise.defaultWeightMode
        )
    }

    private func exerciseModels(in sectionID: UUID) -> [ExerciseLibraryModel] {
        guard let section = plan.sections.first(where: { $0.id == sectionID }) else { return [] }
        let byID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return section.movements.compactMap { byID[$0.exerciseID] }
    }

    private func movementExerciseIDs(in sectionID: UUID) -> Set<UUID> {
        Set(plan.sections.first(where: { $0.id == sectionID })?.movements.map(\.exerciseID) ?? [])
    }

    private func exerciseForMovement(_ selection: BlockMovementSelection) -> ExerciseLibraryModel? {
        guard let movement = plan.sections
            .first(where: { $0.id == selection.sectionID })?
            .movements.first(where: { $0.id == selection.movementID }) else { return nil }
        return exercises.first { $0.id == movement.exerciseID }
    }
}
