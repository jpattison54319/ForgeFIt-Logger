import ForgeData
import SwiftData
import SwiftUI

/// Edits the note that belongs to the workout as a whole rather than to one
/// exercise. Removing it restores the compact "Add Workout Note" action.
struct WorkoutNoteEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Bindable var workout: WorkoutModel

    @State private var draft: String
    @FocusState private var focused: Bool

    init(workout: WorkoutModel) {
        self.workout = workout
        _draft = State(initialValue: workout.notes ?? "")
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Label("Workout note", systemImage: "note.text")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("Delete workout note", systemImage: "xmark", action: remove)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 44, height: 44)
                }

                TextField("How did the workout feel?", text: $draft, axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .lineLimit(2...6)
                    .accessibilityLabel("Workout note")
                    .accessibilityIdentifier("workout-note-editor")
                    .onChange(of: draft) { _, newValue in
                        workout.notes = newValue
                        persist()
                    }
            }
        }
        .onAppear {
            if draft.isEmpty { focused = true }
        }
    }

    private func remove() {
        workout.notes = nil
        persist()
    }

    private func persist() {
        workout.updatedAt = .now
        modelContext.saveUserChanges()
    }
}
