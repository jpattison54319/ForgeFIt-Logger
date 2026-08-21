import ForgeCore
import ForgeData
import SwiftUI

struct MyoRepActiveSetView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var set: SetModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let exerciseName: String
    /// Resolved by the logger from name AND equipment — see the editor.
    let supportsResistanceBands: Bool
    let blockNumber: Int
    let previous: SetModel?
    let showsWeight: Bool
    let displayUnit: WeightUnit
    let isUnilateral: Bool
    let completionDate: Date?
    let usesSuggestedValues: Bool
    let suggestedWeight: Double?
    let suggestedReps: Int?
    let editedFields: Set<SetInputField>
    let onChange: () -> Void
    let onCompletionChange: (Bool) -> Void
    let onMaterializeSuggestion: (Set<SetInputField>) -> Void
    let onCompleted: () -> Void

    @State private var selectedSide: Int
    @State private var weightDraft: Double
    @State private var activationRepsDraft: Int
    @State private var miniRepsDraft: Int
    @State private var editingActivation = false
    @State private var miniSetEdit: MyoRepMiniSetEdit?
    @State private var quickIncrement = QuickIncrementController(metrics: .guidedMyoRep)
    @State private var completionHapticTrigger = 0
    @FocusState private var focusedInput: MyoRepInputFocus?

    private var timer: RestTimerController { RestTimerController.shared }
    private var microRest: Int {
        workoutExercise.microRestSeconds ?? SetType.myoRep.defaultMicroRestSeconds ?? 15
    }
    private var activationIsLogged: Bool { sideActivationReps(selectedSide) != nil }
    private var currentMiniReps: [Int] { sideMiniReps(selectedSide) }
    private var canFinish: Bool {
        MyoRepSetFlow.canFinish(
            isUnilateral: isUnilateral,
            side1ActivationReps: set.reps,
            side2ActivationReps: set.side2Reps
        )
    }

    init(
        set: SetModel,
        workoutExercise: WorkoutExerciseModel,
        exerciseName: String,
        supportsResistanceBands: Bool = false,
        blockNumber: Int,
        previous: SetModel?,
        showsWeight: Bool,
        displayUnit: WeightUnit,
        isUnilateral: Bool,
        completionDate: Date?,
        usesSuggestedValues: Bool,
        suggestedWeight: Double?,
        suggestedReps: Int?,
        editedFields: Set<SetInputField>,
        onChange: @escaping () -> Void,
        onCompletionChange: @escaping (Bool) -> Void,
        onMaterializeSuggestion: @escaping (Set<SetInputField>) -> Void,
        onCompleted: @escaping () -> Void
    ) {
        self.set = set
        self.workoutExercise = workoutExercise
        self.exerciseName = exerciseName
        self.supportsResistanceBands = supportsResistanceBands
        self.blockNumber = blockNumber
        self.previous = previous
        self.showsWeight = showsWeight
        self.displayUnit = displayUnit
        self.isUnilateral = isUnilateral
        self.completionDate = completionDate
        self.usesSuggestedValues = usesSuggestedValues
        self.suggestedWeight = suggestedWeight
        self.suggestedReps = suggestedReps
        self.editedFields = editedFields
        self.onChange = onChange
        self.onCompletionChange = onCompletionChange
        self.onMaterializeSuggestion = onMaterializeSuggestion
        self.onCompleted = onCompleted

        let side = MyoRepSetFlow.startingSide(
            isUnilateral: isUnilateral,
            side1ActivationReps: set.reps,
            side2ActivationReps: set.side2Reps
        )
        let visibleWeight = usesSuggestedValues
            ? (suggestedWeight ?? set.modeWeight ?? previous?.modeWeight)
            : (set.modeWeight ?? suggestedWeight ?? previous?.modeWeight)
        let initialActivation = Self.initialActivationReps(
            side: side,
            set: set,
            previous: previous,
            suggestedReps: suggestedReps
        )
        let logged = side == 2 ? set.side2MiniReps : set.miniReps
        let mirrored = side == 2 ? set.miniReps : []
        let previousMinis = side == 2
            ? (previous?.side2MiniReps ?? previous?.miniReps ?? [])
            : (previous?.miniReps ?? [])

        _selectedSide = State(initialValue: side)
        _weightDraft = State(initialValue: visibleWeight.map(displayUnit.displayValue(fromKilograms:)) ?? 0)
        _activationRepsDraft = State(initialValue: initialActivation)
        _miniRepsDraft = State(initialValue: MyoRepSetFlow.nextMiniReps(
            logged: logged,
            mirrored: mirrored,
            previous: previousMinis
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Space.lg) {
                        if isUnilateral {
                            Picker("Myo-rep side", selection: $selectedSide) {
                                Text("Side 1").tag(1)
                                Text("Side 2").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .frame(minHeight: TouchTarget.minimum)
                            .accessibilityIdentifier("myo-side-picker")
                        }

                        HStack(alignment: .center, spacing: Space.md) {
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(isUnilateral ? "SIDE \(selectedSide)" : "MYO-REP SET")
                                    .font(.tag)
                                    .foregroundStyle(theme.accentForeground)
                                Text(activationIsLogged ? "Mini-sets" : "Activation set")
                                    .font(.screenTitle)
                                    .foregroundStyle(theme.textPrimary)
                            }
                            Spacer()
                            HStack(spacing: Space.sm) {
                                LiveWorkoutHeartRateChip()

                                RestDurationMenu(
                                    options: [10, 15, 20, 30, 45, 60],
                                    allowsOff: false,
                                    selected: microRest,
                                    onPick: updateMicroRest
                                ) {
                                    Label("\(microRest)s", systemImage: "timer")
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.accentForeground)
                                        .padding(.horizontal, Space.md)
                                        .frame(minHeight: TouchTarget.minimum)
                                        .background(theme.surfaceElevated)
                                        .clipShape(.capsule)
                                }
                            }
                        }

                        LiveLoadPrescriptionStrip(set: set, unit: displayUnit)

                        if showsWeight, supportsResistanceBands {
                            Card {
                                HStack {
                                    Text("Band color")
                                        .font(.bodyStrong)
                                        .foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    ResistanceBandLoadMenu(
                                        selectedWeightKilograms: selectedBandWeight,
                                        unit: displayUnit,
                                        onSelect: applyBandWeight
                                    )
                                }
                            }
                        }

                        MyoRepActivationCard(
                            side: selectedSide,
                            isLogged: activationIsLogged,
                            showWeight: showsWeight,
                            isPrimarySide: selectedSide == 1,
                            displayUnit: displayUnit,
                            sharedWeight: loggedWeightDisplay,
                            weightDraft: $weightDraft,
                            repsDraft: $activationRepsDraft,
                            isEditing: $editingActivation,
                            focus: $focusedInput,
                            onWeightSubmit: focusActivationReps,
                            onRepsSubmit: logActivationFromKeyboard,
                            onLog: logActivation
                        )

                        if activationIsLogged {
                            MyoRepTimerCard(setID: set.id)

                            MyoRepMiniSetCard(
                                side: selectedSide,
                                loggedReps: currentMiniReps,
                                plannedCount: set.plannedMiniSetCount,
                                repsDraft: $miniRepsDraft,
                                focus: $focusedInput,
                                onSubmit: logMiniSetFromKeyboard,
                                onLog: logMiniSet,
                                onEdit: beginEditingMiniSet
                            )
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, 130)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: Space.md) {
                    CircleIconButton(
                        systemImage: "chevron.down",
                        label: "Save Myo-rep progress and return to workout",
                        action: dismiss.callAsFunction
                    )
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Myo-rep Set")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(exerciseName)
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Set \(blockNumber)")
                        .font(.tag)
                        .foregroundStyle(theme.accentForeground)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 6)
                        .background(theme.accentSoft)
                        .clipShape(.capsule)
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if focusedInput != nil {
                        KeyboardAccessoryBar {
                            CircleIconButton(
                                systemImage: "keyboard.chevron.compact.down",
                                label: "Dismiss keyboard",
                                action: dismissKeyboard
                            )
                            Spacer()
                            if focusedInput == .activeWeight {
                                Button("Next", action: focusActivationReps)
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.accentForeground)
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.large)
                            }
                            Button(keyboardCompleteTitle, action: completeFromKeyboard)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.accentForeground)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                        }
                    }

                    if activationIsLogged {
                        Group {
                            if isUnilateral, selectedSide == 1 {
                                SecondaryButton(title: "Continue to Side 2", systemImage: "arrow.right") {
                                    selectedSide = 2
                                }
                                .accessibilityIdentifier("continue-myo-side-2")
                            } else {
                                PrimaryButton(title: "Finish Myo-rep Set", systemImage: "checkmark", action: finishSet)
                                    .disabled(!canFinish)
                                    .accessibilityIdentifier("finish-myo-rep-set")
                            }
                        }
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
                    }
                }
                .background(.bar)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .overlay { QuickIncrementOverlay() }
        .environment(quickIncrement)
        .coordinateSpace(name: QuickIncrementController.spaceName)
        .interactiveDismissDisabled()
        .sheet(item: $miniSetEdit) { edit in
            MyoRepMiniSetEditSheet(
                edit: edit,
                onSave: { saveMiniSetEdit(edit, reps: $0) },
                onRemove: { removeMiniSet(edit) }
            )
        }
        .onChange(of: selectedSide) { _, side in
            reloadDrafts(for: side)
        }
        .sensoryFeedback(.success, trigger: completionHapticTrigger)
    }

    private var loggedWeightDisplay: Double {
        // `self.` is required: a computed-property body whose first token is
        // `set` parses as a setter accessor.
        self.set.modeWeight.map(displayUnit.displayValue(fromKilograms:)) ?? weightDraft
    }

    private func sideActivationReps(_ side: Int) -> Int? {
        side == 2 ? set.side2Reps : set.reps
    }

    private func setSideActivationReps(_ reps: Int, side: Int) {
        if side == 2 { set.side2Reps = reps } else { set.reps = reps }
    }

    private func sideMiniReps(_ side: Int) -> [Int] {
        side == 2 ? set.side2MiniReps : set.miniReps
    }

    private func setSideMiniReps(_ reps: [Int], side: Int) {
        if side == 2 { set.side2MiniReps = reps } else { set.miniReps = reps }
    }

    private func previousActivationReps(for side: Int) -> Int? {
        side == 2 ? (previous?.side2Reps ?? previous?.reps) : previous?.reps
    }

    private func previousMiniReps(for side: Int) -> [Int] {
        if side == 2 { return previous?.side2MiniReps ?? previous?.miniReps ?? [] }
        return previous?.miniReps ?? []
    }

    private func reloadDrafts(for side: Int) {
        activationRepsDraft = Self.initialActivationReps(
            side: side,
            set: set,
            previous: previous,
            suggestedReps: suggestedReps
        )
        miniRepsDraft = MyoRepSetFlow.nextMiniReps(
            logged: sideMiniReps(side),
            mirrored: side == 2 ? set.miniReps : [],
            previous: previousMiniReps(for: side)
        )
        editingActivation = false
        focusedInput = nil
    }

    private func logActivation() {
        focusedInput = nil
        let wasLogged = activationIsLogged
        if selectedSide == 1 {
            onMaterializeSuggestion(editedFields)
            if showsWeight {
                set.setModeWeight(displayUnit.kilograms(fromDisplayValue: weightDraft))
            }
        }
        setSideActivationReps(max(1, activationRepsDraft), side: selectedSide)
        set.recomputeDerivedMetrics()
        editingActivation = false
        onChange()
        if !wasLogged {
            timer.start(
                seconds: microRest,
                label: miniRestLabel(side: selectedSide, count: 1),
                micro: true,
                ownerID: set.id
            )
        }
    }

    private var selectedBandWeight: Double? {
        self.set.modeWeight ?? displayUnit.kilograms(fromDisplayValue: weightDraft)
    }

    private func applyBandWeight(_ kilograms: Double) {
        focusedInput = nil
        weightDraft = displayUnit.displayValue(fromKilograms: kilograms)
        set.setModeWeight(kilograms)
        set.recomputeDerivedMetrics()
        onChange()
    }

    private func beginEditingMiniSet(_ index: Int) {
        guard currentMiniReps.indices.contains(index) else { return }
        miniSetEdit = MyoRepMiniSetEdit(side: selectedSide, index: index, reps: currentMiniReps[index])
    }

    private func logMiniSet() {
        focusedInput = nil
        var minis = currentMiniReps
        let value = max(1, miniRepsDraft)
        minis.append(value)
        timer.start(
            seconds: microRest,
            label: miniRestLabel(side: selectedSide, count: minis.count + 1),
            micro: true,
            ownerID: set.id
        )
        setSideMiniReps(minis, side: selectedSide)
        set.recomputeDerivedMetrics()
        miniRepsDraft = MyoRepSetFlow.nextMiniReps(
            logged: minis,
            mirrored: selectedSide == 2 ? set.miniReps : [],
            previous: previousMiniReps(for: selectedSide)
        )
        onChange()
    }

    private func saveMiniSetEdit(_ edit: MyoRepMiniSetEdit, reps: Int) {
        var minis = sideMiniReps(edit.side)
        guard minis.indices.contains(edit.index) else { return }
        minis[edit.index] = max(1, reps)
        setSideMiniReps(minis, side: edit.side)
        set.recomputeDerivedMetrics()
        refreshMiniDraft(after: minis, side: edit.side)
        onChange()
    }

    private func removeMiniSet(_ edit: MyoRepMiniSetEdit) {
        var minis = sideMiniReps(edit.side)
        guard minis.indices.contains(edit.index) else { return }
        minis.remove(at: edit.index)
        setSideMiniReps(minis, side: edit.side)
        set.recomputeDerivedMetrics()
        refreshMiniDraft(after: minis, side: edit.side)
        onChange()
    }

    private func refreshMiniDraft(after minis: [Int], side: Int) {
        guard side == selectedSide else { return }
        miniRepsDraft = MyoRepSetFlow.nextMiniReps(
            logged: minis,
            mirrored: side == 2 ? set.miniReps : [],
            previous: previousMiniReps(for: side)
        )
    }

    private var keyboardCompleteTitle: String {
        switch focusedInput {
        case .activeMini: "Log"
        default: "Log Activation"
        }
    }

    private func dismissKeyboard() {
        focusedInput = nil
    }

    private func focusActivationReps() {
        focusedInput = .activeActivation(side: selectedSide)
    }

    private func logActivationFromKeyboard() {
        dismissKeyboard()
        logActivation()
    }

    private func logMiniSetFromKeyboard() {
        dismissKeyboard()
        logMiniSet()
    }

    private func completeFromKeyboard() {
        switch focusedInput {
        case .activeMini:
            logMiniSetFromKeyboard()
        case .activeWeight, .activeActivation:
            logActivationFromKeyboard()
        default:
            dismissKeyboard()
        }
    }

    private func finishSet() {
        guard canFinish else { return }
        onMaterializeSuggestion(editedFields)
        set.completedAt = completionDate ?? .now
        HealthMetricsStore.shared.fillBodyweight(set)
        set.recomputeDerivedMetrics()
        if timer.microOwnerID == set.id { timer.skip() }
        onCompletionChange(true)
        onCompleted()
        completionHapticTrigger += 1
        dismiss()
    }

    private func updateMicroRest(_ picked: Int?) {
        workoutExercise.microRestSeconds = picked
        onChange()
    }

    private func miniRestLabel(side: Int, count: Int) -> String {
        isUnilateral ? "S\(side) mini-set \(count)" : "Mini-set \(count)"
    }

    private static func initialActivationReps(
        side: Int,
        set: SetModel,
        previous: SetModel?,
        suggestedReps: Int?
    ) -> Int {
        let value = side == 2
            ? (set.side2Reps ?? set.reps ?? previous?.side2Reps ?? previous?.reps ?? suggestedReps)
            : (set.reps ?? suggestedReps ?? previous?.reps)
        return max(1, value ?? 1)
    }
}
