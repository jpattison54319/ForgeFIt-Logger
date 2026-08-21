import ForgeData
import SwiftUI

struct MyoRepSetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var set: SetModel
    let exerciseName: String
    let displayUnit: WeightUnit
    let showsWeight: Bool
    let isUnilateral: Bool
    /// Resolved by the logger from name AND equipment; deriving it here from
    /// the name alone would miss exercises tagged `bands` without "band" in
    /// their name, offering the picker on the row but not in this editor.
    let supportsResistanceBands: Bool
    let onSave: () -> Void

    @State private var draft: MyoRepEditDraft
    @State private var miniSetEdit: MyoRepMiniSetEdit?
    @State private var quickIncrement = QuickIncrementController(metrics: .guidedMyoRep)
    @FocusState private var focusedInput: MyoRepInputFocus?

    init(
        set: SetModel,
        exerciseName: String,
        displayUnit: WeightUnit,
        showsWeight: Bool,
        isUnilateral: Bool,
        supportsResistanceBands: Bool = false,
        onSave: @escaping () -> Void
    ) {
        self.set = set
        self.exerciseName = exerciseName
        self.displayUnit = displayUnit
        self.showsWeight = showsWeight
        self.isUnilateral = isUnilateral
        self.supportsResistanceBands = supportsResistanceBands
        self.onSave = onSave
        _draft = State(initialValue: MyoRepEditDraft(set: set, displayUnit: displayUnit))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: Space.lg) {
                        LiveLoadPrescriptionStrip(set: set, unit: displayUnit)

                        if showsWeight {
                            Card(padding: Space.lg) {
                                VStack(alignment: .leading, spacing: Space.md) {
                                    if supportsResistanceBands {
                                        HStack {
                                            Text("Band color")
                                                .font(.bodyStrong)
                                                .foregroundStyle(theme.textPrimary)
                                            Spacer()
                                            ResistanceBandLoadMenu(
                                                selectedWeightKilograms: displayUnit.kilograms(fromDisplayValue: draft.weightDisplay),
                                                unit: displayUnit,
                                                onSelect: { kilograms in
                                                    focusedInput = nil
                                                    draft.weightDisplay = displayUnit.displayValue(fromKilograms: kilograms)
                                                }
                                            )
                                        }
                                    }

                                    MyoRepWeightStepper(
                                        value: $draft.weightDisplay,
                                        displayUnit: displayUnit,
                                        focus: $focusedInput,
                                        focusValue: .editorWeight,
                                        onSubmit: focusFirstActivation,
                                        accessibilityIdentifier: "edit-myo-activation-weight"
                                    )
                                }
                            }
                        }

                        MyoRepEditorSideCard(
                            side: 1,
                            activationReps: $draft.side1ActivationReps,
                            miniReps: $draft.side1MiniReps,
                            focus: $focusedInput,
                            activationSubmitLabel: isUnilateral ? .next : .done,
                            onActivationSubmit: { finishActivationEntry(side: 1) },
                            onEditMiniSet: { beginMiniSetEdit(side: 1, index: $0) },
                            onAddMiniSet: { addMiniSet(side: 1) }
                        )

                        if isUnilateral {
                            MyoRepEditorSideCard(
                                side: 2,
                                activationReps: $draft.side2ActivationReps,
                                miniReps: $draft.side2MiniReps,
                                focus: $focusedInput,
                                activationSubmitLabel: .done,
                                onActivationSubmit: { finishActivationEntry(side: 2) },
                                onEditMiniSet: { beginMiniSetEdit(side: 2, index: $0) },
                                onAddMiniSet: { addMiniSet(side: 2) }
                            )
                        }
                    }
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, 110)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: Space.md) {
                    CircleIconButton(systemImage: "xmark", label: "Cancel Myo-rep edits") {
                        dismiss()
                    }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Edit Myo-rep Set")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(exerciseName)
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .font(.tag)
                        .foregroundStyle(theme.success)
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
                            if focusedInput == .editorWeight || focusedInput == .editorActivation(side: 1) && isUnilateral {
                                Button("Next", action: advanceKeyboardFocus)
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.accentForeground)
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.large)
                            }
                            Button("Done", action: dismissKeyboard)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.accentForeground)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                        }
                    }

                    PrimaryButton(title: "Save Changes", systemImage: "checkmark", action: save)
                        .accessibilityIdentifier("save-myo-rep-edits")
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.md)
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
    }

    private func save() {
        draft.apply(
            to: set,
            displayUnit: displayUnit,
            showsWeight: showsWeight,
            isUnilateral: isUnilateral
        )
        onSave()
        dismiss()
    }

    private func dismissKeyboard() {
        focusedInput = nil
    }

    private func focusFirstActivation() {
        focusedInput = .editorActivation(side: 1)
    }

    private func finishActivationEntry(side: Int) {
        if side == 1, isUnilateral {
            focusedInput = .editorActivation(side: 2)
        } else {
            dismissKeyboard()
        }
    }

    private func advanceKeyboardFocus() {
        switch focusedInput {
        case .editorWeight:
            focusFirstActivation()
        case .editorActivation(side: 1) where isUnilateral:
            focusedInput = .editorActivation(side: 2)
        default:
            dismissKeyboard()
        }
    }

    private func beginMiniSetEdit(side: Int, index: Int) {
        let reps = side == 2 ? draft.side2MiniReps : draft.side1MiniReps
        guard reps.indices.contains(index) else { return }
        miniSetEdit = MyoRepMiniSetEdit(side: side, index: index, reps: reps[index])
    }

    private func addMiniSet(side: Int) {
        if side == 2 {
            draft.side2MiniReps.append(draft.side2MiniReps.last ?? draft.side1MiniReps.first ?? 1)
        } else {
            draft.side1MiniReps.append(draft.side1MiniReps.last ?? 1)
        }
    }

    private func saveMiniSetEdit(_ edit: MyoRepMiniSetEdit, reps: Int) {
        if edit.side == 2 {
            guard draft.side2MiniReps.indices.contains(edit.index) else { return }
            draft.side2MiniReps[edit.index] = max(1, reps)
        } else {
            guard draft.side1MiniReps.indices.contains(edit.index) else { return }
            draft.side1MiniReps[edit.index] = max(1, reps)
        }
    }

    private func removeMiniSet(_ edit: MyoRepMiniSetEdit) {
        if edit.side == 2 {
            guard draft.side2MiniReps.indices.contains(edit.index) else { return }
            draft.side2MiniReps.remove(at: edit.index)
        } else {
            guard draft.side1MiniReps.indices.contains(edit.index) else { return }
            draft.side1MiniReps.remove(at: edit.index)
        }
    }
}
