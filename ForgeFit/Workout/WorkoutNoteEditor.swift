import ForgeData
import SwiftUI

/// Edits the note that belongs to the workout as a whole rather than to one
/// exercise. Removing it restores the compact "Add Workout Note" action.
struct WorkoutNoteEditor: View {
    @Environment(\.theme) private var theme
    @Bindable var workout: WorkoutModel
    let pendingDrafts: PendingDraftCoordinator
    let onSaveRequested: () -> Void

    @State private var draft: String
    @State private var draftDirty = false
    @State private var removed = false
    @State private var draftToken = UUID()
    @FocusState private var focused: Bool

    init(
        workout: WorkoutModel,
        pendingDrafts: PendingDraftCoordinator,
        onSaveRequested: @escaping () -> Void
    ) {
        self.workout = workout
        self.pendingDrafts = pendingDrafts
        self.onSaveRequested = onSaveRequested
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

                TextField("How did the workout feel?", text: Binding(
                    get: { draft },
                    set: {
                        draft = $0
                        draftDirty = true
                    }
                ), axis: .vertical)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                    .focused($focused)
                    .lineLimit(2...6)
                    .accessibilityLabel("Workout note")
                    .accessibilityIdentifier("workout-note-editor")
            }
        }
        .onAppear {
            synchronizeUntouchedDraft()
            pendingDrafts.register(draftToken, commit: commitDraft)
            if draft.isEmpty { focused = true }
        }
        .onChange(of: focused) { wasFocused, isFocused in
            if wasFocused, !isFocused { commitDraft() }
        }
        .onChange(of: workout.notes) { synchronizeUntouchedDraft() }
        .onDisappear {
            commitDraft()
            pendingDrafts.unregister(draftToken)
        }
    }

    private func remove() {
        removed = true
        focused = false
        draft = ""
        draftDirty = false
        workout.notes = nil
        WorkoutMutationContract.stampParentForNestedMutation(workout)
        onSaveRequested()
    }

    private func commitDraft() {
        guard !removed,
              LocalTextDraftPolicy.shouldCommit(
                draft: draft,
                modelText: workout.notes,
                isDirty: draftDirty
              ) else {
            draftDirty = false
            synchronizeUntouchedDraft()
            return
        }
        workout.notes = draft
        draftDirty = false
        WorkoutMutationContract.stampParentForNestedMutation(workout)
        onSaveRequested()
    }

    private func synchronizeUntouchedDraft() {
        draft = LocalTextDraftPolicy.synchronizedDraft(
            currentDraft: draft,
            modelText: workout.notes,
            isDirty: draftDirty
        )
    }
}
