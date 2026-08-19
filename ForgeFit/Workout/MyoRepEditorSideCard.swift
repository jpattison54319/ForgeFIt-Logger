import SwiftUI

struct MyoRepEditorSideCard: View {
    @Environment(\.theme) private var theme
    let side: Int
    @Binding var activationReps: Int
    @Binding var miniReps: [Int]
    let focus: FocusState<MyoRepInputFocus?>.Binding
    let activationSubmitLabel: SubmitLabel
    let onActivationSubmit: () -> Void
    let onEditMiniSet: (Int) -> Void
    let onAddMiniSet: () -> Void

    var body: some View {
        Card(padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Text("Side \(side)")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(MyoRepSetFlow.totalReps(activationReps: activationReps, miniReps: miniReps)) total reps")
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                }

                MyoRepIntegerStepper(
                    value: $activationReps,
                    label: "Activation reps",
                    focus: focus,
                    focusValue: .editorActivation(side: side),
                    submitLabel: activationSubmitLabel,
                    onSubmit: onActivationSubmit,
                    accessibilityIdentifier: "edit-myo-activation-reps-\(side)"
                )

                Divider().overlay(theme.separator)

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Mini-sets")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.sm) {
                            ForEach(Array(miniReps.enumerated()), id: \.offset) { index, reps in
                                MyoRepMiniSetCircle(side: side, index: index, reps: reps) {
                                    onEditMiniSet(index)
                                }
                            }

                            Button("Add mini-set", systemImage: "plus", action: onAddMiniSet)
                                .labelStyle(.iconOnly)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 50, height: 50)
                                .contentShape(Circle())
                                .overlay {
                                    Circle().strokeBorder(
                                        theme.textTertiary.opacity(0.55),
                                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                    )
                                }
                                .accessibilityIdentifier("edit-myo-add-mini-\(side)")
                        }
                    }
                }
            }
        }
    }
}
