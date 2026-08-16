import SwiftUI

struct SleepTargetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let onSave: (Int) -> Void
    @State private var selectedMinutes: Int

    init(initialMinutes: Int, onSave: @escaping (Int) -> Void) {
        self.onSave = onSave
        _selectedMinutes = State(initialValue: SleepTargetPreference.normalized(initialMinutes))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.md) {
                Picker("Sleep target", selection: $selectedMinutes) {
                    ForEach(targetOptions, id: \.self) { minutes in
                        Text(SleepMetricPresentation.duration(minutes))
                            .tag(minutes)
                    }
                }
                .pickerStyle(.wheel)
                .accessibilityIdentifier("sleep-target-picker")

                Text("Used for sleep progress and recovery comparisons. Recorded sleep never changes your target automatically.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.lg)
            }
            .navigationTitle("Sleep target")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .bold()
                        .accessibilityIdentifier("sleep-target-save")
                }
            }
        }
    }

    private var targetOptions: [Int] {
        Array(
            stride(
                from: SleepTargetPreference.allowedMinutes.lowerBound,
                through: SleepTargetPreference.allowedMinutes.upperBound,
                by: SleepTargetPreference.incrementMinutes
            )
        )
    }

    private func save() {
        onSave(selectedMinutes)
        dismiss()
    }
}
