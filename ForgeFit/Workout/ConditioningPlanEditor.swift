import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

private struct ConditioningSectionSelection: Identifiable {
    let id: UUID
}

private struct ConditioningMovementSelection: Identifiable {
    let sectionID: UUID
    let movementID: UUID
    var id: UUID { movementID }
}

struct ConditioningPlanEditor: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Bindable var routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let workouts: [WorkoutModel]
    let onAddYoga: () -> Void
    let onChange: () -> Void

    @State private var plan = ConditioningPlan(sections: [])
    @State private var addMovementSection: ConditioningSectionSelection?
    @State private var replaceMovement: ConditioningMovementSelection?
    @State private var presetError = ""
    @State private var showPresetError = false

    var body: some View {
        Group {
            if plan.sections.isEmpty {
                RoutineFormatPills(
                    onAddConditioning: addSection,
                    onAddYoga: onAddYoga
                )
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack {
                            Label("Conditioning", systemImage: "stopwatch")
                                .font(.cardTitle)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Menu("Conditioning options", systemImage: "ellipsis.circle") {
                                Button("Remove Conditioning", systemImage: "trash", role: .destructive, action: removePlan)
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("conditioning-options")
                        }

                        ForEach($plan.sections) { $section in
                            ConditioningSectionEditor(
                                section: $section,
                                exercises: exercises,
                                onChange: persist,
                                onApplyPreset: { apply($0, to: section.id) },
                                onAddMovement: {
                                    addMovementSection = ConditioningSectionSelection(id: section.id)
                                },
                                onReplaceMovement: {
                                    replaceMovement = ConditioningMovementSelection(
                                        sectionID: section.id,
                                        movementID: $0.id
                                    )
                                },
                                onRemoveMovement: { removeMovement($0.id, from: section.id) },
                                onMoveMovement: { moveMovement($0.id, by: $1, in: section.id) },
                                onDelete: { deleteSection(section.id) }
                            )
                        }
                        SecondaryButton(title: "Add Section", systemImage: "plus", action: addSection)
                            .accessibilityIdentifier("add-conditioning-section")
                    }
                }
            }
        }
        .task { loadPlan() }
        .sheet(item: $addMovementSection) { selection in
            let sectionExercises = exerciseModels(in: selection.id)
            ExercisePickerView(
                excludeYogaPoses: true,
                context: sectionExercises,
                history: workouts,
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
                    allExercises: exercises,
                    inUseIDs: movementExerciseIDs(in: selection.sectionID),
                    history: workouts
                ) { replacement in
                    replace(selection, with: replacement)
                }
            }
        }
        .alert("Couldn't Apply Preset", isPresented: $showPresetError) {
        } message: {
            Text(presetError)
        }
    }

    private func loadPlan() {
        plan = ConditioningPlan.decode(from: routine.conditioningPlanJSON)
            ?? ConditioningPlan(sections: [])
    }

    private func addSection() {
        let movements = plan.sections.isEmpty
            ? routine.exercises.sorted { $0.position < $1.position }.map(makeMovement)
            : []
        plan.sections.append(ConditioningSection(
            name: plan.sections.isEmpty ? "AMRAP" : "Section \(plan.sections.count + 1)",
            format: .amrap,
            durationSeconds: 1_200,
            movements: movements
        ))
        persistStructure()
    }

    private func deleteSection(_ id: UUID) {
        plan.sections.removeAll { $0.id == id }
        persistStructure()
    }

    private func removePlan() {
        plan.sections.removeAll()
        persist()
    }

    private func makeMovement(_ routineExercise: RoutineExerciseModel) -> ConditioningMovement {
        let exercise = exercises.first { $0.id == routineExercise.exerciseID }
        let targetSet = routineExercise.sets.sorted { $0.position < $1.position }.first
        let unit: ConditioningTargetUnit = exercise?.isCardio == true ? .seconds : .reps
        let value = exercise?.isCardio == true
            ? Double(targetSet?.targetDurationSeconds ?? 60)
            : Double(targetSet?.targetRepsLow ?? 10)
        return ConditioningMovement(
            exerciseID: routineExercise.exerciseID,
            targetValue: value,
            targetUnit: unit,
            targetLoad: targetSet?.targetWeight,
            weightMode: exercise?.defaultWeightMode ?? .external
        )
    }

    private func persist() {
        routine.conditioningPlanJSON = plan.sections.isEmpty ? nil : plan.encodedJSON()
        routine.updatedAt = .now
        onChange()
    }

    private func persistStructure() {
        ConditioningPlanCoordinator.reconcileRoutineExercises(
            with: plan,
            routine: routine,
            in: modelContext
        )
        persist()
    }

    private func apply(_ preset: ConditioningPreset, to sectionID: UUID) {
        do {
            try ConditioningPlanCoordinator.apply(
                preset,
                to: sectionID,
                in: &plan,
                to: routine,
                catalog: exercises,
                in: modelContext
            )
            onChange()
        } catch {
            presetError = error.localizedDescription
            showPresetError = true
        }
    }

    private func addMovements(_ selected: [ExerciseLibraryModel], to sectionID: UUID) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        let existing = Set(plan.sections[sectionIndex].movements.map(\.exerciseID))
        plan.sections[sectionIndex].movements.append(contentsOf: selected
            .filter { !existing.contains($0.id) }
            .map(makeMovement))
        persistStructure()
    }

    private func replace(_ selection: ConditioningMovementSelection, with exercise: ExerciseLibraryModel) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == selection.sectionID }),
              let movementIndex = plan.sections[sectionIndex].movements.firstIndex(where: { $0.id == selection.movementID }) else { return }
        plan.sections[sectionIndex].movements[movementIndex].exerciseID = exercise.id
        plan.sections[sectionIndex].movements[movementIndex].targetLoad = nil
        plan.sections[sectionIndex].movements[movementIndex].weightMode = exercise.defaultWeightMode
        persistStructure()
    }

    private func removeMovement(_ movementID: UUID, from sectionID: UUID) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }) else { return }
        plan.sections[sectionIndex].movements.removeAll { $0.id == movementID }
        persistStructure()
    }

    private func moveMovement(_ movementID: UUID, by offset: Int, in sectionID: UUID) {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }),
              let index = plan.sections[sectionIndex].movements.firstIndex(where: { $0.id == movementID }) else { return }
        let destination = max(0, min(plan.sections[sectionIndex].movements.count - 1, index + offset))
        guard destination != index else { return }
        let movement = plan.sections[sectionIndex].movements.remove(at: index)
        plan.sections[sectionIndex].movements.insert(movement, at: destination)
        persist()
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

    private func exerciseForMovement(_ selection: ConditioningMovementSelection) -> ExerciseLibraryModel? {
        guard let movement = plan.sections
            .first(where: { $0.id == selection.sectionID })?
            .movements.first(where: { $0.id == selection.movementID }) else { return nil }
        return exercises.first { $0.id == movement.exerciseID }
    }
}

private struct ConditioningSectionEditor: View {
    @Environment(\.theme) private var theme
    @Binding var section: ConditioningSection
    let exercises: [ExerciseLibraryModel]
    let onChange: () -> Void
    let onApplyPreset: (ConditioningPreset) -> Void
    let onAddMovement: () -> Void
    let onReplaceMovement: (ConditioningMovement) -> Void
    let onRemoveMovement: (ConditioningMovement) -> Void
    let onMoveMovement: (ConditioningMovement, Int) -> Void
    let onDelete: () -> Void

    @State private var pendingPreset: ConditioningPreset?
    @State private var showPresetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                TextField("Section name", text: $section.name)
                    .font(.bodyStrong)
                    .onChange(of: section.name) { _, _ in onChange() }
                Menu("Preset", systemImage: "square.grid.2x2") {
                    ForEach(ConditioningPreset.allCases) { preset in
                        Button(preset.menuTitle) { choose(preset) }
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(theme.accent)
                .accessibilityIdentifier("conditioning-section-preset-\(section.id.uuidString)")
                .confirmationDialog(
                    "Replace this section?",
                    isPresented: $showPresetConfirmation,
                    presenting: pendingPreset
                ) { preset in
                    Button("Use \(preset.title)", role: .destructive) { onApplyPreset(preset) }
                    Button("Cancel", role: .cancel) {}
                } message: { preset in
                    Text("\(preset.title) replaces only this section's format, movements, and targets.")
                }
                Menu("Section options", systemImage: "ellipsis") {
                    Button("Delete Section", systemImage: "trash", role: .destructive, action: onDelete)
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("conditioning-section-options")
            }

            Picker("Format", selection: $section.format) {
                ForEach(ConditioningFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: section.format) { _, format in applyDefaults(for: format) }

            HStack(spacing: Space.md) {
                if section.format == .amrap {
                    numericField("Minutes", value: Binding(
                        get: { max(1, (section.durationSeconds ?? 1_200) / 60) },
                        set: { section.durationSeconds = max(1, $0) * 60 }
                    ))
                }
                if section.format == .forTime || section.format == .ladder {
                    numericField("Rounds", value: Binding(
                        get: { max(1, section.rounds ?? section.repScheme.count) },
                        set: { section.rounds = max(1, $0) }
                    ))
                }
                if section.format == .maxLoad {
                    numericField("Attempts", value: Binding(
                        get: { max(1, section.rounds ?? 5) },
                        set: { section.rounds = max(1, $0) }
                    ))
                }
                if section.format == .emom {
                    numericField("Minutes", value: Binding(
                        get: { max(1, section.rounds ?? 20) },
                        set: { section.rounds = max(1, $0) }
                    ))
                    numericField("Every sec", value: Binding(
                        get: { max(10, section.intervalSeconds ?? 60) },
                        set: { section.intervalSeconds = max(10, $0) }
                    ))
                }
                if section.format == .intervals {
                    numericField("Rounds", value: Binding(
                        get: { max(1, section.rounds ?? 8) },
                        set: { section.rounds = max(1, $0) }
                    ))
                    numericField("Work", value: Binding(
                        get: { max(1, section.workSeconds ?? 20) },
                        set: { section.workSeconds = max(1, $0); updateIntervalDuration() }
                    ))
                    numericField("Rest", value: Binding(
                        get: { max(0, section.restSeconds ?? 10) },
                        set: { section.restSeconds = max(0, $0); updateIntervalDuration() }
                    ))
                }
            }

            if section.format == .forTime || section.format == .ladder {
                HStack(spacing: Space.md) {
                    numericField("Time cap min", value: Binding(
                        get: { max(0, (section.timeCapSeconds ?? 0) / 60) },
                        set: { section.timeCapSeconds = $0 > 0 ? $0 * 60 : nil }
                    ))
                    if section.format == .ladder {
                        numericField("Step", value: Binding(
                            get: { max(1, section.ladderStep ?? 1) },
                            set: { section.ladderStep = max(1, $0) }
                        ))
                    }
                }
            }

            if section.format == .forTime {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Rep scheme (optional)").font(.label).foregroundStyle(theme.textSecondary)
                    TextField("21-15-9", text: repSchemeBinding)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                }
            }

            Picker("Order", selection: $section.ordering) {
                ForEach(ConditioningOrdering.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: section.ordering) { _, _ in onChange() }

            VStack(spacing: 0) {
                ForEach($section.movements) { $movement in
                    let index = section.movements.firstIndex { $0.id == movement.id } ?? 0
                    ConditioningMovementEditor(
                        movement: $movement,
                        exercise: exercises.first { $0.id == movement.exerciseID },
                        canMoveUp: index > 0,
                        canMoveDown: index < section.movements.count - 1,
                        onChange: onChange,
                        onReplace: { onReplaceMovement(movement) },
                        onRemove: { onRemoveMovement(movement) },
                        onMoveUp: { onMoveMovement(movement, -1) },
                        onMoveDown: { onMoveMovement(movement, 1) }
                    )
                    if movement.id != section.movements.last?.id { Divider().overlay(theme.separator) }
                }
            }
            .background(theme.surfaceElevated)
            .clipShape(.rect(cornerRadius: Radius.control))

            SecondaryButton(title: "Add Movement", systemImage: "plus", action: onAddMovement)
                .accessibilityIdentifier("add-conditioning-movement-\(section.id.uuidString)")
        }
        .padding(Space.md)
        .background(theme.surfaceHighlight)
        .clipShape(.rect(cornerRadius: Radius.control))
    }

    private func numericField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).font(.label).foregroundStyle(theme.textSecondary)
            TextField(label, value: value, format: .number)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .onChange(of: value.wrappedValue) { _, _ in onChange() }
        }
    }

    private func applyDefaults(for format: ConditioningFormat) {
        switch format {
        case .amrap:
            section.durationSeconds = section.durationSeconds ?? 1_200
        case .forTime:
            section.rounds = section.rounds ?? 1
        case .emom:
            section.rounds = section.rounds ?? 20
            section.intervalSeconds = section.intervalSeconds ?? 60
        case .intervals:
            section.durationSeconds = section.durationSeconds ?? 240
            section.workSeconds = section.workSeconds ?? 20
            section.restSeconds = section.restSeconds ?? 10
        case .ladder:
            section.rounds = section.rounds ?? 10
            section.ladderStep = section.ladderStep ?? 1
        case .maxLoad:
            section.rounds = section.rounds ?? 5
        }
        onChange()
    }

    private var repSchemeBinding: Binding<String> {
        Binding(
            get: { section.repScheme.map(String.init).joined(separator: "-") },
            set: { text in
                section.repScheme = text
                    .split(whereSeparator: { !$0.isNumber })
                    .compactMap { Int($0) }
                if !section.repScheme.isEmpty { section.rounds = section.repScheme.count }
                onChange()
            }
        )
    }

    private func updateIntervalDuration() {
        section.durationSeconds = (section.rounds ?? 8) * ((section.workSeconds ?? 20) + (section.restSeconds ?? 10))
    }

    private func choose(_ preset: ConditioningPreset) {
        if section.movements.isEmpty {
            onApplyPreset(preset)
        } else {
            pendingPreset = preset
            showPresetConfirmation = true
        }
    }
}

private struct ConditioningMovementEditor: View {
    @Environment(\.theme) private var theme
    @Binding var movement: ConditioningMovement
    let exercise: ExerciseLibraryModel?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onChange: () -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Button(action: onReplace) {
                    HStack(spacing: Space.xs) {
                        Text(exercise?.name ?? "Exercise")
                            .font(.bodyStrong)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.label)
                    }
                    .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .accessibilityLabel("Replace \(exercise?.name ?? "exercise")")
                Spacer()
                Menu("Movement options", systemImage: "ellipsis") {
                    Button("Move Up", systemImage: "arrow.up", action: onMoveUp)
                        .disabled(!canMoveUp)
                    Button("Move Down", systemImage: "arrow.down", action: onMoveDown)
                        .disabled(!canMoveDown)
                    Divider()
                    Button("Remove Movement", systemImage: "trash", role: .destructive, action: onRemove)
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("conditioning-movement-options-\(exercise?.name ?? movement.id.uuidString)")
            }

            HStack(spacing: Space.sm) {
                Text("Target")
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                TextField("Target", value: $movement.targetValue, format: .number)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .onChange(of: movement.targetValue) { _, _ in onChange() }
                    .accessibilityIdentifier("conditioning-target-\(exercise?.name ?? movement.id.uuidString)")
                Picker("Unit", selection: $movement.targetUnit) {
                    ForEach(ConditioningTargetUnit.allCases, id: \.self) { unit in
                        Text(unit.shortLabel).tag(unit)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize(horizontal: true, vertical: false)
                .onChange(of: movement.targetUnit) { _, _ in onChange() }
                .accessibilityIdentifier("conditioning-unit-\(exercise?.name ?? movement.id.uuidString)")
            }
            if movement.weightMode != .bodyweight {
                HStack(spacing: Space.sm) {
                    Text(movement.weightMode == .bodyweightAssisted ? "Assistance" : "Load")
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    TextField("Optional", value: $movement.targetLoad, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onChange(of: movement.targetLoad) { _, _ in onChange() }
                    Text(exercise?.effectiveWeightUnit.suffix ?? Fmt.unit.suffix)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .padding(Space.md)
    }
}
