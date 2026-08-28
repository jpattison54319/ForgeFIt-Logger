import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

enum ExerciseNotePolicy {
    /// Blank or whitespace-only text is not a note. Keeping that distinction
    /// at the model boundary prevents an empty editor from being resurrected
    /// when a lazy workout card scrolls back on screen.
    static func authoredText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func pinStateAfterToggle(currentlyPinned: Bool, draft: String?) -> Bool {
        authoredText(draft) != nil && !currentlyPinned
    }
}

/// A yellow sticky note attached to an exercise during a workout. The pin button
/// (top-left) persists the note to the exercise so it reappears in future
/// workouts (mirrored into `UserExerciseNoteModel`); unpinning keeps it on this
/// session only. The note can be removed entirely and re-added.
struct StickyNoteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Bindable var workoutExercise: WorkoutExerciseModel
    let exerciseID: UUID
    let pinnedNote: UserExerciseNoteModel?
    var focusRequested = false
    var onFocusHandled: () -> Void = {}
    var onPinnedNoteChanged: (UserExerciseNoteModel?) -> Void = { _ in }
    var pendingDrafts: PendingDraftCoordinator? = nil
    /// Live strength cards inject the logger-owned coordinator. Other callers
    /// retain the existing direct-save behavior at commit boundaries.
    var onSaveRequested: (() -> Void)? = nil

    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var draftDirty = false
    @State private var draftToken = UUID()
    @State private var currentPinnedNote: UserExerciseNoteModel?
    @State private var didResolvePinnedNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Button(action: togglePin) {
                    Image(systemName: workoutExercise.notePinned ? "pin.fill" : "pin")
                        .font(.system(size: 14, weight: .bold))
                        .rotationEffect(.degrees(workoutExercise.notePinned ? 0 : 30))
                        .foregroundStyle(workoutExercise.notePinned ? theme.danger : theme.stickyInk.opacity(0.6))
                        .frame(width: 44, height: 44)   // HIG minimum touch target
                        .background(.black.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(workoutExercise.notePinned ? "Unpin note" : "Pin note to exercise")

                Text(workoutExercise.notePinned ? "Pinned to exercise" : "This workout only")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.stickyInk.opacity(0.55))

                Spacer()

                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.stickyInk.opacity(0.6))
                        .frame(width: 44, height: 44)   // HIG minimum touch target
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove note")
            }

            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Write a note…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.stickyInk.opacity(0.55))
                        .allowsHitTesting(false)
                }

                TextField("", text: Binding(
                    get: { draft },
                    set: {
                        draft = $0
                        draftDirty = true
                    }
                ), axis: .vertical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.stickyInk)
                .tint(theme.stickyInk)
                .focused($focused)
                .lineLimit(1...6)
                .accessibilityLabel("Workout note")
                .accessibilityIdentifier("workout-note-banner")
            }
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.stickyFill.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.stickyInk.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: theme.stickyInk.opacity(0.18), radius: 4, x: 0, y: 2)
                .shadow(color: .black.opacity(0.24), radius: 12, x: 0, y: 8)
        )
        .rotationEffect(.degrees(-0.6))
        .onAppear {
            resolvePinnedNote()
            synchronizeUntouchedDraft()
            pendingDrafts?.register(draftToken, commit: commitDraft)
            if focusRequested {
                focusIfRequested()
            } else {
                discardEmptyNoteIfNeeded()
            }
        }
        .onChange(of: focusRequested) { _, requested in
            if requested { focusIfRequested() }
        }
        .onChange(of: workoutExercise.notes) { synchronizeUntouchedDraft() }
        .onChange(of: focused) { wasFocused, isFocused in
            if wasFocused && !isFocused { commitDraft() }
        }
        .onDisappear {
            commitDraft()
            pendingDrafts?.unregister(draftToken)
        }
    }

    private func togglePin() {
        let shouldPin = ExerciseNotePolicy.pinStateAfterToggle(
            currentlyPinned: workoutExercise.notePinned,
            draft: draft
        )
        commitDraft()
        resolvePinnedNote()
        // Committing a newly blank draft removes the note and forces unpinned.
        // Do not blindly toggle that forced-false value back to an empty pin.
        workoutExercise.notePinned = shouldPin
        if workoutExercise.notePinned {
            upsertPinnedNote()
        } else {
            if let persistedPinnedNote { modelContext.delete(persistedPinnedNote) }
            currentPinnedNote = nil
            onPinnedNoteChanged(nil)
        }
        workoutExercise.updatedAt = .now
        requestSave()
    }

    private func syncPinnedIfNeeded() {
        guard workoutExercise.notePinned else { return }
        upsertPinnedNote()
    }

    private func upsertPinnedNote() {
        resolvePinnedNote()
        guard let text = ExerciseNotePolicy.authoredText(workoutExercise.notes) else {
            if let persistedPinnedNote { modelContext.delete(persistedPinnedNote) }
            currentPinnedNote = nil
            onPinnedNoteChanged(nil)
            return
        }
        if let persistedPinnedNote {
            persistedPinnedNote.note = text
            persistedPinnedNote.updatedAt = .now
        } else {
            let note = UserExerciseNoteModel(
                userID: ForgeFitDemo.userID,
                exerciseID: exerciseID,
                note: text
            )
            modelContext.insert(note)
            currentPinnedNote = note
            onPinnedNoteChanged(note)
        }
    }

    private var persistedPinnedNote: UserExerciseNoteModel? {
        didResolvePinnedNote ? currentPinnedNote : pinnedNote
    }

    private func resolvePinnedNote() {
        guard !didResolvePinnedNote else { return }
        currentPinnedNote = pinnedNote
        didResolvePinnedNote = true
    }

    private func focusIfRequested() {
        guard focusRequested else { return }
        focused = true
        onFocusHandled()
    }

    private func discardEmptyNoteIfNeeded() {
        guard workoutExercise.notes != nil,
              ExerciseNotePolicy.authoredText(draft) == nil else { return }
        remove()
    }

    private func commitDraft() {
        guard LocalTextDraftPolicy.shouldCommit(
            draft: draft,
            modelText: workoutExercise.notes,
            isDirty: draftDirty
        ) else {
            draftDirty = false
            synchronizeUntouchedDraft()
            return
        }
        guard ExerciseNotePolicy.authoredText(draft) != nil else {
            draftDirty = false
            discardEmptyNoteIfNeeded()
            return
        }
        workoutExercise.notes = draft
        draftDirty = false
        workoutExercise.updatedAt = .now
        syncPinnedIfNeeded()
        requestSave()
    }

    private func remove() {
        resolvePinnedNote()
        focused = false
        draft = ""
        draftDirty = false
        workoutExercise.notes = nil
        if workoutExercise.notePinned {
            if let persistedPinnedNote { modelContext.delete(persistedPinnedNote) }
            currentPinnedNote = nil
            onPinnedNoteChanged(nil)
        }
        workoutExercise.notePinned = false
        workoutExercise.updatedAt = .now
        requestSave()
    }

    private func synchronizeUntouchedDraft() {
        draft = LocalTextDraftPolicy.synchronizedDraft(
            currentDraft: draft,
            modelText: workoutExercise.notes,
            isDirty: draftDirty
        )
    }

    private func requestSave() {
        if let onSaveRequested {
            onSaveRequested()
        } else {
            modelContext.saveUserChanges()
        }
    }
}

// MARK: - Keyboard dismissal

#if canImport(UIKit)
import UIKit

extension View {
    /// Dismiss the keyboard when tapping outside an editable field.
    func dismissKeyboardOnTap() -> some View {
        onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif
