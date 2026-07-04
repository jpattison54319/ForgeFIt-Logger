import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

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

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Button(action: togglePin) {
                    Image(systemName: workoutExercise.notePinned ? "pin.fill" : "pin")
                        .font(.system(size: 14, weight: .bold))
                        .rotationEffect(.degrees(workoutExercise.notePinned ? 0 : 30))
                        .foregroundStyle(workoutExercise.notePinned ? theme.danger : theme.stickyInk.opacity(0.6))
                        .frame(width: 30, height: 30)
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
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove note")
            }

            ZStack(alignment: .topLeading) {
                if (workoutExercise.notes ?? "").isEmpty {
                    Text("Write a note…")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.stickyInk.opacity(0.55))
                        .allowsHitTesting(false)
                }

                TextField("", text: Binding(
                    get: { workoutExercise.notes ?? "" },
                    set: { workoutExercise.notes = $0; syncPinnedIfNeeded(); try? modelContext.save() }
                ), axis: .vertical)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.stickyInk)
                .tint(theme.stickyInk)
                .focused($focused)
                .lineLimit(1...6)
                .accessibilityLabel("Workout note")
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
        .onAppear { if (workoutExercise.notes ?? "").isEmpty { focused = true } }
    }

    private func togglePin() {
        workoutExercise.notePinned.toggle()
        if workoutExercise.notePinned {
            upsertPinnedNote()
        } else if let pinnedNote {
            modelContext.delete(pinnedNote)
        }
        try? modelContext.save()
    }

    private func syncPinnedIfNeeded() {
        guard workoutExercise.notePinned else { return }
        upsertPinnedNote()
    }

    private func upsertPinnedNote() {
        let text = workoutExercise.notes ?? ""
        if let pinnedNote {
            pinnedNote.note = text
            pinnedNote.updatedAt = Date()
        } else {
            let note = UserExerciseNoteModel(
                userID: ForgeFitDemo.userID,
                exerciseID: exerciseID,
                note: text
            )
            modelContext.insert(note)
        }
    }

    private func remove() {
        workoutExercise.notes = nil
        if workoutExercise.notePinned, let pinnedNote {
            modelContext.delete(pinnedNote)
        }
        workoutExercise.notePinned = false
        try? modelContext.save()
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
