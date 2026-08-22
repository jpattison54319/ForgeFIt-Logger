import SwiftUI

struct MyoRepIntegerStepper: View {
    @Environment(\.theme) private var theme
    @Binding var value: Int
    let label: String
    let focus: FocusState<MyoRepInputFocus?>.Binding
    let focusValue: MyoRepInputFocus
    var submitLabel: SubmitLabel = .done
    let onSubmit: () -> Void
    var minimum = 1
    var accessibilityIdentifier: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(label)
                .font(.bodyStrong)
                .foregroundStyle(theme.textSecondary)

            HStack(spacing: Space.md) {
                MyoStepperButton(
                    systemImage: "minus",
                    accessibilityLabel: "Decrease \(label)"
                ) {
                    value = max(minimum, value - 1)
                }
                .disabled(value <= minimum)

                TextField(label, value: $value, format: .number)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .submitLabel(submitLabel)
                    .focused(focus, equals: focusValue)
                    .onSubmit(onSubmit)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(theme.surfaceElevated)
                    .clipShape(.rect(cornerRadius: Radius.control))
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")
                    .quickIncrementable(
                        options: QuickIncrementController.repsOptions(),
                        onBegin: { focus.wrappedValue = nil },
                        base: { Double(value) },
                        apply: { value = max(minimum, Int($0.rounded())) }
                    )

                MyoStepperButton(
                    systemImage: "plus",
                    accessibilityLabel: "Increase \(label)"
                ) {
                    value += 1
                }
            }
        }
    }
}
