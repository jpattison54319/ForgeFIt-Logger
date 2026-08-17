import SwiftUI

struct MyoRepMiniSetEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let edit: MyoRepMiniSetEdit
    let onSave: (Int) -> Void
    let onRemove: () -> Void

    @State private var reps: Int
    @State private var quickIncrement = QuickIncrementController(metrics: .guidedMyoRep)
    @FocusState private var focusedInput: MyoRepInputFocus?

    init(
        edit: MyoRepMiniSetEdit,
        onSave: @escaping (Int) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.edit = edit
        self.onSave = onSave
        self.onRemove = onRemove
        _reps = State(initialValue: edit.reps)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenBackground()
                VStack(spacing: Space.lg) {
                    Card(padding: Space.lg) {
                        MyoRepIntegerStepper(
                            value: $reps,
                            label: "Reps",
                            focus: $focusedInput,
                            focusValue: .miniEditor(side: edit.side, index: edit.index),
                            onSubmit: dismissKeyboard,
                            accessibilityIdentifier: "edit-myo-mini-reps-\(edit.side)-\(edit.index + 1)"
                        )
                    }

                    Button("Remove Mini-set", systemImage: "trash", role: .destructive, action: remove)
                        .font(.bodyStrong)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityIdentifier("myo-remove-mini-\(edit.side)-\(edit.index + 1)")

                    Spacer()
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: Space.md) {
                    CircleIconButton(systemImage: "xmark", label: "Cancel mini-set edits", action: dismiss.callAsFunction)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Edit Mini-set \(edit.index + 1)")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Side \(edit.side)")
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
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
                            Button("Done", action: dismissKeyboard)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.accentForeground)
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                        }
                    }

                    PrimaryButton(title: "Save Changes", systemImage: "checkmark", action: save)
                        .accessibilityIdentifier("save-myo-mini-edits")
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
    }

    private func dismissKeyboard() {
        focusedInput = nil
    }

    private func save() {
        onSave(max(1, reps))
        dismiss()
    }

    private func remove() {
        onRemove()
        dismiss()
    }
}
