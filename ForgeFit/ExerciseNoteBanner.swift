import ForgeData
import SwiftUI

struct ExerciseNoteBanner: View {
    enum Context {
        case workout
        case routine

        var title: String {
            switch self {
            case .workout: "Loaded setup note"
            case .routine: "Saved setup note"
            }
        }
    }

    let note: UserExerciseNoteModel
    let context: Context

    /// Dismissing hides the banner for THIS viewing only (no persistence) —
    /// it clears clutter once you've read it during a session, but a pain
    /// flag still surfaces fresh every time you come back to the exercise,
    /// rather than being silenced for good.
    @State private var dismissed = false

    private var setupFields: [(label: String, value: String)] {
        [
            note.seatHeight.map { ("Seat", $0) },
            note.grip.map { ("Grip", $0) },
            note.stance.map { ("Stance", $0) },
        ].compactMap { $0 }
    }

    var body: some View {
        if !dismissed {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label(context.title, systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    if note.painFlag {
                        Label("Pain flag — review before loading", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(.white)
                            .background(Color.red)
                            .clipShape(Capsule())
                            .accessibilityLabel("Pain flag. Review this exercise before loading.")
                            .accessibilityIdentifier("pain-flag-label")
                    }
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { dismissed = true }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss note")
                }

                Text(note.note)
                    .font(.body)

                // Empty setup fields add nothing but clutter — only show what
                // was actually recorded.
                if !setupFields.isEmpty {
                    ForEach(setupFields, id: \.label) { field in
                        LabeledContent(field.label, value: field.value)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier(context == .workout ? "workout-note-banner" : "routine-note-banner")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

struct EntryField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, text: $value)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }
}
