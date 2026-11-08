import ForgeCore
import SwiftUI

struct StrengthHoldDurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int
    @State private var seconds: Int
    let onSave: (Int) -> Void

    init(seconds: Int, onSave: @escaping (Int) -> Void) {
        let duration = StrengthHold.validSeconds(seconds) ?? StrengthHold.defaultSeconds
        _minutes = State(initialValue: duration / 60)
        _seconds = State(initialValue: duration % 60)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: Space.md) {
                VStack {
                    Text("Minutes").font(.headline)
                    Picker("Minutes", selection: $minutes) {
                        ForEach(0...59, id: \.self) { Text($0.formatted()).tag($0) }
                    }
                    .accessibilityIdentifier("hold-minutes")
                }
                VStack {
                    Text("Seconds").font(.headline)
                    Picker("Seconds", selection: $seconds) {
                        ForEach(0...59, id: \.self) { Text($0.formatted()).tag($0) }
                    }
                    .accessibilityIdentifier("hold-seconds")
                }
            }
            .padding(.horizontal, Space.lg)
            .pickerStyle(.wheel)
            .navigationTitle("Duration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: save)
                        .disabled(minutes == 0 && seconds == 0)
                        .accessibilityIdentifier("save-hold-duration")
                }
            }
        }
    }

    private func save() {
        guard let duration = StrengthHold.validSeconds(minutes * 60 + seconds) else { return }
        onSave(duration)
        dismiss()
    }
}
