import SwiftUI

struct MyoRepActivationCard: View {
    @Environment(\.theme) private var theme
    let side: Int
    let isLogged: Bool
    let showWeight: Bool
    let isPrimarySide: Bool
    let displayUnit: WeightUnit
    let sharedWeight: Double
    @Binding var weightDraft: Double
    @Binding var repsDraft: Int
    @Binding var isEditing: Bool
    let focus: FocusState<MyoRepInputFocus?>.Binding
    let onWeightSubmit: () -> Void
    let onRepsSubmit: () -> Void
    let onLog: () -> Void

    var body: some View {
        Card(padding: Space.lg, fill: isLogged ? theme.success.opacity(0.10) : nil) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    Image(systemName: isLogged ? "checkmark.circle.fill" : "bolt.fill")
                        .font(.title3.bold())
                        .foregroundStyle(isLogged ? theme.success : theme.accent)
                        .accessibilityHidden(true)
                    Text(isLogged ? "Activation logged" : "Activation set")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if isLogged {
                        Button(isEditing ? "Cancel" : "Edit") {
                            isEditing.toggle()
                        }
                        .font(.bodyStrong)
                        .frame(minHeight: 44)
                    }
                }

                if !isLogged || isEditing {
                    if showWeight {
                        if isPrimarySide {
                            MyoRepWeightStepper(
                                value: $weightDraft,
                                displayUnit: displayUnit,
                                focus: focus,
                                focusValue: .activeWeight,
                                onSubmit: onWeightSubmit,
                                accessibilityIdentifier: "myo-activation-weight"
                            )
                        } else {
                            LabeledContent("Activation weight") {
                                Text("\(sharedWeight.formatted(.number.precision(.fractionLength(0...2)))) \(displayUnit.shortSuffix)")
                                    .font(.title3.bold())
                                    .monospacedDigit()
                            }
                            .foregroundStyle(theme.textSecondary)
                        }
                    }

                    MyoRepIntegerStepper(
                        value: $repsDraft,
                        label: "Activation reps",
                        focus: focus,
                        focusValue: .activeActivation(side: side),
                        onSubmit: onRepsSubmit,
                        accessibilityIdentifier: "myo-activation-reps-\(side)"
                    )

                    PrimaryButton(
                        title: isLogged ? "Save Activation" : "Log Activation",
                        systemImage: isLogged ? "checkmark" : "bolt.fill",
                        action: onLog
                    )
                    .accessibilityIdentifier("myo-log-activation-\(side)")
                } else {
                    LabeledContent("Logged") {
                        Text(loggedSummary)
                            .font(.title3.bold())
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                    }
                    .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var loggedSummary: String {
        let reps = "\(repsDraft) reps"
        guard showWeight else { return reps }
        return "\(sharedWeight.formatted(.number.precision(.fractionLength(0...2)))) \(displayUnit.shortSuffix) × \(repsDraft)"
    }
}
