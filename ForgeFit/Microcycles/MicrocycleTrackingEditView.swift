import ForgeData
import SwiftUI

struct MicrocycleTrackingEditView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let tracking: MicrocycleTrackingModel
    let onSave: (Int) throws -> Void

    @State private var durationDays: Int
    @State private var errorMessage: String?

    init(
        tracking: MicrocycleTrackingModel,
        onSave: @escaping (Int) throws -> Void
    ) {
        self.tracking = tracking
        self.onSave = onSave
        _durationDays = State(initialValue: tracking.durationDays)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Card {
                        VStack(alignment: .leading, spacing: Space.md) {
                            LabeledContent("Day target") {
                                Stepper(
                                    "\(durationDays) days",
                                    value: $durationDays,
                                    in: 1...31
                                )
                                .labelsHidden()
                                Text("\(durationDays) days")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                            }

                            Text("The current cycle keeps every day already reached. Future cycles use this target; previous cycles stay unchanged.")
                                .font(.subheadline)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    PrimaryButton(
                        title: "Save Changes",
                        systemImage: "checkmark",
                        action: save
                    )
                    .accessibilityIdentifier("save-microcycle-day-target")
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
            }
            .scrollIndicators(.hidden)
            .background(theme.background)
            .navigationTitle("Edit Day Target")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
            }
            .alert("Couldn't update microcycle", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func save() {
        do {
            try onSave(durationDays)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
