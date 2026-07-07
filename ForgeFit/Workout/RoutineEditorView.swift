import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Editing surface for a routine: rename, add/remove exercises, and tune target
/// sets. Kept dark and card-based to match the rest of the app.
struct RoutineEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    @State private var showPicker = false
    @State private var entrySnapshot: RoutineSnapshot?
    @State private var showDiscardConfirm = false
    @State private var reordering = false
    @State private var replaceTarget: RoutineExerciseModel?
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var allWorkouts: [WorkoutModel]

    private var sortedExercises: [RoutineExerciseModel] { routine.exercises.sorted { $0.position < $1.position } }
    private var supersetGroups: [Int] {
        Array(Set(routine.exercises.compactMap(\.supersetGroup))).sorted()
    }
    /// Library entries for the routine's current exercises — the picker's
    /// suggestion context (lots of chest work → chest & push suggested first).
    private var exercisesInRoutine: [ExerciseLibraryModel] {
        routine.exercises.compactMap { re in exercises.first { $0.id == re.exerciseID } }
    }

    var body: some View {
        Group {
            if reordering {
                VStack(spacing: 0) {
                    header.padding(.horizontal, Space.lg)
                    reorderList
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        header

                        Card {
                            VStack(alignment: .leading, spacing: Space.md) {
                                FieldLabel("Routine name")
                                DarkTextField(text: $routine.name, placeholder: "Routine name")
                                FieldLabel("Notes")
                                DarkTextField(text: Binding(
                                    get: { routine.notes ?? "" },
                                    set: { routine.notes = $0.isEmpty ? nil : $0 }
                                ), placeholder: "Add notes", axis: .vertical)
                            }
                        }

                        SectionHeader("Exercises") {
                            if sortedExercises.count > 1 {
                                Button("Reorder") { withAnimation { reordering = true } }
                                    .font(.bodyStrong).foregroundStyle(theme.accent)
                                    .accessibilityIdentifier("reorder-exercises-button")
                            }
                        }

                        ForEach(sortedExercises) { re in
                            ExerciseEditRow(
                                routineExercise: re,
                                exercise: exercises.first { $0.id == re.exerciseID },
                                availableSupersetGroups: supersetGroups,
                                onAssignSuperset: { assignSuperset($0, to: re) },
                                onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: re) },
                                onUngroupSuperset: { ungroupSuperset($0) },
                                onReplace: { replaceTarget = re },
                                onRemove: { remove(re) }
                            )
                        }

                        SecondaryButton(title: "Add Exercise", systemImage: "plus") { showPicker = true }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.tabBarClearance)
                }
                .background(theme.background)
            }
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .onAppear {
            if entrySnapshot == nil { entrySnapshot = RoutineSnapshot(of: routine) }
        }
        .confirmationDialog("Unsaved changes", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Save Changes") { save(); dismiss() }
            Button("Discard Changes", role: .destructive) {
                if let entrySnapshot { entrySnapshot.restore(onto: routine, in: modelContext) }
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You've made changes to this routine.")
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerView(context: exercisesInRoutine, history: allWorkouts) { added in added.forEach(add) }
        }
        .sheet(item: $replaceTarget) { target in
            ExercisePickerView(singleSelection: true, context: exercisesInRoutine, history: allWorkouts) { picked in
                if let first = picked.first { replace(target, with: first) }
            }
        }
        .navigationDestination(for: UUID.self) { exerciseID in
            ExerciseDetailView(exerciseID: exerciseID, workouts: allWorkouts, exercises: exercises)
        }
    }

    private var header: some View {
        HStack {
            if reordering {
                Text("Reorder").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Done") { withAnimation { reordering = false } }
                    .font(.bodyStrong).foregroundStyle(theme.accent)
                    .accessibilityIdentifier("reorder-done-button")
            } else {
                // Back offers to save or discard when the routine changed — it no
                // longer silently saves, so Save actually means something.
                CircleIconButton(systemImage: "chevron.left") {
                    if let entrySnapshot, entrySnapshot != RoutineSnapshot(of: routine) {
                        showDiscardConfirm = true
                    } else {
                        dismiss()
                    }
                }
                Spacer()
                Text("Edit Routine").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Save") { save(); dismiss() }
                    .font(.bodyStrong).foregroundStyle(theme.accent)
            }
        }
        .padding(.top, Space.sm)
    }

    /// Drag-to-reorder list, mirroring the live logger's reorder mode so the
    /// gesture is consistent app-wide.
    private var reorderList: some View {
        List {
            ForEach(sortedExercises) { re in
                HStack(spacing: Space.md) {
                    if let ex = exercises.first(where: { $0.id == re.exerciseID }) {
                        ExerciseThumbnail(exercise: ex, size: 40)
                        Text(ex.name).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)
                .listRowSeparatorTint(theme.separator)
            }
            .onMove(perform: moveExercises)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .environment(\.editMode, .constant(.active))
    }

    private func moveExercises(from offsets: IndexSet, to destination: Int) {
        var rows = sortedExercises
        rows.move(fromOffsets: offsets, toOffset: destination)
        for (index, row) in rows.enumerated() { row.position = index }
        save()
    }

    /// Swap the exercise while keeping set targets when they still make sense
    /// (strength → strength keeps reps/weight/RPE); duration vs rep-based
    /// targets don't carry over, so a cardio/strength swap resets to a fresh
    /// default set.
    private func replace(_ target: RoutineExerciseModel, with exercise: ExerciseLibraryModel) {
        let wasCardio = exercises.first { $0.id == target.exerciseID }?.isCardio == true
        target.exerciseID = exercise.id
        target.updatedAt = Date()
        if exercise.isCardio != wasCardio {
            target.sets.forEach(modelContext.delete)
            let fresh = exercise.isCardio
                ? RoutineSetModel(userID: ForgeFitDemo.userID, position: 0, targetDurationSeconds: 1_800)
                : RoutineSetModel(userID: ForgeFitDemo.userID, position: 0)
            modelContext.insert(fresh)
            target.sets = [fresh]
        }
        save()
    }

    private func add(_ exercise: ExerciseLibraryModel) {
        let re = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            position: routine.exercises.count
        )
        let target = exercise.isCardio
            ? RoutineSetModel(userID: ForgeFitDemo.userID, position: 0, targetDurationSeconds: 1_800)
            : RoutineSetModel(userID: ForgeFitDemo.userID, position: 0)
        modelContext.insert(re)
        modelContext.insert(target)
        re.sets = [target]
        routine.exercises.append(re)
        save()
    }

    private func remove(_ re: RoutineExerciseModel) {
        modelContext.delete(re)
        for (i, e) in sortedExercises.filter({ $0.id != re.id }).enumerated() { e.position = i }
        save()
    }

    private func save() {
        routine.updatedAt = Date()
        try? modelContext.save()
    }

    private func nextSupersetGroup() -> Int {
        var candidate = 0
        let used = Set(supersetGroups)
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    private func assignSuperset(_ group: Int?, to re: RoutineExerciseModel) {
        re.supersetGroup = group
        re.updatedAt = Date()
        compactSupersetPositions()
        save()
    }

    private func ungroupSuperset(_ group: Int) {
        for exercise in routine.exercises where exercise.supersetGroup == group {
            exercise.supersetGroup = nil
            exercise.updatedAt = Date()
        }
        compactSupersetPositions()
        save()
    }

    private func compactSupersetPositions() {
        let rows = sortedExercises
        var output: [RoutineExerciseModel] = []
        var seenGroups = Set<Int>()

        for row in rows {
            guard let group = row.supersetGroup else {
                output.append(row)
                continue
            }
            guard !seenGroups.contains(group) else { continue }
            seenGroups.insert(group)
            output.append(contentsOf: rows.filter { $0.supersetGroup == group })
        }

        for (index, row) in output.enumerated() {
            row.position = index
            row.updatedAt = Date()
        }
    }
}

// MARK: - Exercise edit row

private struct ExerciseEditRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Bindable var routineExercise: RoutineExerciseModel
    let exercise: ExerciseLibraryModel?
    let availableSupersetGroups: [Int]
    let onAssignSuperset: (Int?) -> Void
    let onCreateSuperset: () -> Void
    let onUngroupSuperset: (Int) -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void

    @State private var showIntervalBuilder = false

    private var sortedSets: [RoutineSetModel] { routineExercise.sets.sorted { $0.position < $1.position } }
    private var isCardio: Bool { exercise?.isCardio == true }
    private var displayUnit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if let exercise {
                            NavigationLink(value: exercise.id) {
                                HStack(spacing: 4) {
                                    Text(exercise.name).font(.bodyStrong)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .foregroundStyle(theme.accent)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Exercise").font(.bodyStrong).foregroundStyle(theme.accent)
                        }
                        if let group = routineExercise.supersetGroup {
                            SupersetChip(group: group)
                        }
                    }
                    Spacer()
                    Menu {
                        SupersetMenuItems(
                            currentGroup: routineExercise.supersetGroup,
                            availableGroups: availableSupersetGroups,
                            onAssign: onAssignSuperset,
                            onCreate: onCreateSuperset,
                            onUngroup: onUngroupSuperset
                        )
                        Divider()
                        Button("Add Warm-up Set", systemImage: "flame") { addSet(type: .warmup) }
                        Button("Add Working Set", systemImage: "plus") { addSet(type: .working) }
                        Divider()
                        Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                        Button("Remove Exercise", systemImage: "trash", role: .destructive, action: onRemove)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)   // HIG minimum touch target
                    }
                    .accessibilityIdentifier("routine-exercise-menu-\(exercise?.name ?? "")")
                }

                if isCardio {
                    cardioTargetEditor
                    if let exercise {
                        MuscleChips(muscles: CardioKind.infer(name: exercise.name, equipment: exercise.equipment).musclesWorked)
                    }
                } else {
                    strengthSetEditor
                }
            }
        }
    }

    private var strengthSetEditor: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("SET").frame(width: 40, alignment: .leading)
                Text("REPS").frame(maxWidth: .infinity, alignment: .leading)
                Text(displayUnit.suffix.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
                Text("RPE").frame(width: 48, alignment: .leading)
                Image(systemName: "trash").opacity(0).frame(width: 32)
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textTertiary)

            ForEach(Array(sortedSets.enumerated()), id: \.element.id) { index, set in
                SetTargetEditRow(
                    set: set,
                    workingNumber: workingNumber(upTo: index),
                    displayUnit: displayUnit,
                    onChange: save,
                    onSetType: { changeType(of: set, to: $0, index: index) },
                    onAddDrop: { addDropSet(below: set, index: index) },
                    onDelete: { deleteSet(set) }
                )
                if set.setType.countsAsWorkingVolume && set.setType != .drop {
                    HStack {
                        Spacer()
                        Button {
                            addDropSet(below: set, index: index)
                        } label: {
                            Label("Drop set", systemImage: "arrow.down.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.accent)
                    }
                    .padding(.trailing, 40)
                }
            }

            Button(action: { addSet(type: .working) }) {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("Add Set") }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private var cardioTargetEditor: some View {
        let kind = CardioKind.infer(name: exercise?.name ?? "Cardio", equipment: exercise?.equipment)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.secondaryAccent)
                Text("Cardio target")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }

            if let first = sortedSets.first {
                CardioDurationTargetRow(set: first)
            }

            // Structured intervals: warmup → N × (work/recover) → cooldown.
            Button {
                showIntervalBuilder = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 12, weight: .bold))
                    if let plan = IntervalPlan.decode(from: routineExercise.intervalPlanJSON) {
                        let workCount = plan.steps.count { $0.kind == .work }
                        Text("Intervals: \(workCount)× · \(Fmt.durationShort(plan.totalSeconds)) total")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text("Add structured intervals")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.7)
                    Spacer()
                }
                .foregroundStyle(theme.secondaryAccent)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showIntervalBuilder) {
                IntervalPlanBuilderView(routineExercise: routineExercise)
            }

            Text(kind.metricLabels.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryAccent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: ensureCardioTarget)
    }

    private func addSet(type: SetType) {
        guard !isCardio else { return }
        let last = sortedSets.last
        let carriedType = type == .working ? (last?.setType.isBlockType == true ? last!.setType : type) : type
        let set = RoutineSetModel(
            userID: ForgeFitDemo.userID, position: routineExercise.sets.count,
            setType: carriedType,
            targetRepsLow: last?.targetRepsLow,
            targetRepsHigh: last?.targetRepsHigh,
            targetWeight: last?.targetWeight,
            targetRPE: last?.targetRPE
        )
        modelContext.insert(set)
        routineExercise.sets.append(set)
        save()
    }

    private func addDropSet(below set: RoutineSetModel, index: Int) {
        let drop = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            setType: .drop,
            targetRepsLow: nil,
            targetRepsHigh: nil,
            targetWeight: set.targetWeight.map(droppedWeight),
            targetRPE: set.targetRPE
        )
        modelContext.insert(drop)
        routineExercise.sets.append(drop)
        var rows = sortedSets.filter { $0.id != drop.id }
        rows.insert(drop, at: min(index + 1, rows.count))
        renumber(rows)
        save()
    }

    private func changeType(of set: RoutineSetModel, to type: SetType, index: Int) {
        if type == .drop, index > 0, let above = sortedSets[index - 1].targetWeight {
            if set.targetWeight == nil || set.targetWeight == above {
                set.targetWeight = droppedWeight(above)
            }
        }
        set.setType = type
        save()
    }

    private func deleteSet(_ set: RoutineSetModel) {
        modelContext.delete(set)
        renumber(sortedSets.filter { $0.id != set.id })
        save()
    }

    private func workingNumber(upTo index: Int) -> Int {
        sortedSets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
    }

    private func renumber(_ rows: [RoutineSetModel]) {
        for (index, row) in rows.enumerated() { row.position = index }
    }

    private func droppedWeight(_ weight: Double) -> Double {
        let displayed = displayUnit.displayValue(fromKilograms: weight)
        let step = displayUnit == .lb ? 5.0 : 2.5
        let minimum = displayUnit == .lb ? 5.0 : 2.5
        let dropped = max(minimum, (displayed * 0.75 / step).rounded() * step)
        return displayUnit.kilograms(fromDisplayValue: dropped)
    }

    private func ensureCardioTarget() {
        if sortedSets.isEmpty {
            let set = RoutineSetModel(userID: ForgeFitDemo.userID, position: 0, targetDurationSeconds: 1_800)
            modelContext.insert(set)
            routineExercise.sets = [set]
            save()
        }
    }

    private func save() {
        routineExercise.updatedAt = Date()
        routineExercise.routine?.updatedAt = Date()
        try? modelContext.save()
    }
}

/// One editable target-set row. Split into its own view so `@Bindable`
/// projects bindings for the numeric fields.
private struct SetTargetEditRow: View {
    @Environment(\.theme) private var theme
    @Bindable var set: RoutineSetModel
    let workingNumber: Int
    let displayUnit: WeightUnit
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    let onAddDrop: () -> Void
    let onDelete: () -> Void

    private var style: SetTypeStyle { SetTypeStyle.of(self.set.setType) }
    private var isDrop: Bool { self.set.setType == .drop }

    var body: some View {
        HStack(spacing: 8) {
            if isDrop {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(style.color.opacity(0.7))
                    .frame(width: 16)
            }

            Menu {
                ForEach(SetType.allCases, id: \.self) { type in
                    Button {
                        onSetType(type)
                    } label: {
                        Label(SetTypeStyle.of(type).label, systemImage: set.setType == type ? "checkmark" : "")
                    }
                }
                Divider()
                Button("Add Drop Set Below", systemImage: "arrow.down.right", action: onAddDrop)
            } label: {
                let hasBadge = !style.badge.isEmpty
                Text(style.numbered ? "\(workingNumber)\(style.badge)" : style.badge)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(hasBadge ? style.color : theme.textPrimary)
                    .frame(width: isDrop ? 32 : 40, height: 30)
                    .background(hasBadge ? style.color.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .accessibilityLabel("Set type")

            OptionalRepsTargetField(
                low: $set.targetRepsLow,
                high: $set.targetRepsHigh,
                onChange: onChange
            )
            OptionalLoadField(placeholder: displayUnit.suffix, value: $set.targetWeight, unit: displayUnit, onChange: onChange)
            OptionalDoubleField(placeholder: "RPE", value: $set.targetRPE, width: 48, onChange: onChange)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.danger.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .background(theme.danger.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Delete set \(workingNumber)")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct CardioDurationTargetRow: View {
    @Environment(\.theme) private var theme
    @Bindable var set: RoutineSetModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Goal")
                .font(.rowValue)
                .foregroundStyle(theme.secondaryAccent)
                .frame(width: 52, alignment: .leading)
            OptionalIntField(placeholder: "Minutes", value: Binding(
                get: { set.targetDurationSeconds.map { $0 / 60 } },
                set: { set.targetDurationSeconds = $0.map { $0 * 60 } }
            ))
            Text("min")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 36, alignment: .leading)
        }
    }
}

// MARK: - Shared dark form fields

struct FieldLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.label).foregroundStyle(theme.textSecondary)
    }
}

struct DarkTextField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var placeholder: String
    var axis: Axis = .horizontal

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 13).padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct OptionalIntField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Int?
    var width: CGFloat? = nil
    var onChange: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value.map(String.init) ?? "" },
            set: { value = Int($0); onChange() }
        ))
        .keyboardType(.numberPad)
        .font(.system(size: 16, weight: .semibold))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct OptionalRepsTargetField: View {
    @Environment(\.theme) private var theme
    @Binding var low: Int?
    @Binding var high: Int?
    var onChange: () -> Void = {}
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Reps", text: Binding(
            get: { isFocused ? draft : formattedValue },
            set: { text in
                draft = text
                parse(text)
            }
        ))
        .focused($isFocused)
        .keyboardType(.numbersAndPunctuation)
        .font(.system(size: 16, weight: .semibold))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear { draft = formattedValue }
        .onChange(of: isFocused) { _, focused in
            if focused {
                draft = formattedValue
            } else {
                draft = formattedValue
            }
        }
        .onChange(of: low) { _, _ in
            if !isFocused { draft = formattedValue }
        }
        .onChange(of: high) { _, _ in
            if !isFocused { draft = formattedValue }
        }
    }

    private var formattedValue: String {
        if let low, let high, high != low { return "\(low)-\(high)" }
        return low.map(String.init) ?? ""
    }

    private func parse(_ text: String) {
        let normalized = text.replacingOccurrences(of: "–", with: "-")
        let rawParts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = rawParts.map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            low = parts[0].isEmpty ? nil : Int(parts[0])
            high = parts[1].isEmpty ? nil : Int(parts[1])
        } else {
            let value = Int(normalized.trimmingCharacters(in: .whitespaces))
            low = value
            high = value
        }
        onChange()
    }
}

struct OptionalDoubleField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Double?
    var width: CGFloat? = nil
    var onChange: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "" },
            set: { value = Double($0); onChange() }
        ))
        .keyboardType(.decimalPad)
        .font(.system(size: 16, weight: .semibold))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct OptionalLoadField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Double?
    let unit: WeightUnit
    var width: CGFloat? = nil
    var onChange: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value.map { Fmt.load($0, unit: unit) } ?? "" },
            set: { value = Fmt.loadKilograms(from: $0, unit: unit); onChange() }
        ))
        .keyboardType(.decimalPad)
        .font(.system(size: 16, weight: .semibold))
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
