import SwiftUI

struct MyoRepWeightStepper: View {
    @Environment(\.theme) private var theme
    @Binding var value: Double
    let displayUnit: WeightUnit
    let focus: FocusState<MyoRepInputFocus?>.Binding
    let focusValue: MyoRepInputFocus
    var submitLabel: SubmitLabel = .next
    let onSubmit: () -> Void
    var accessibilityIdentifier: String? = nil

    private var step: Double { displayUnit == .lb ? 5 : 2.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Activation weight")
                .font(.bodyStrong)
                .foregroundStyle(theme.textSecondary)

            HStack(spacing: Space.md) {
                MyoStepperButton(
                    systemImage: "minus",
                    accessibilityLabel: "Decrease activation weight"
                ) {
                    value = max(0, value - step)
                }
                .disabled(value <= 0)

                HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                    TextField(
                        "Activation weight",
                        value: $value,
                        format: .number.precision(.fractionLength(0...2))
                    )
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .keyboardType(.decimalPad)
                    .submitLabel(submitLabel)
                    .focused(focus, equals: focusValue)
                    .onSubmit(onSubmit)
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")

                    Text(displayUnit.shortSuffix)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, Space.md)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(theme.surfaceElevated)
                .clipShape(.rect(cornerRadius: Radius.control))
                .quickIncrementable(
                    options: QuickIncrementController.weightOptions(unit: displayUnit),
                    onBegin: { focus.wrappedValue = nil },
                    base: { value },
                    apply: { value = max(0, $0) }
                )

                MyoStepperButton(
                    systemImage: "plus",
                    accessibilityLabel: "Increase activation weight"
                ) {
                    value += step
                }
            }
        }
    }
}
