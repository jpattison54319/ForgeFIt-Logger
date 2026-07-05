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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(context.title, systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                if note.painFlag {
                    Text("Pain flag")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(Color.red)
                        .clipShape(Capsule())
                        .accessibilityLabel("Pain flag. Review this exercise before loading.")
                        .accessibilityIdentifier("pain-flag-label")
                }
            }

            Text(note.note)
                .font(.body)

            LabeledContent("Seat", value: note.seatHeight ?? "-")
            LabeledContent("Grip", value: note.grip ?? "-")
            LabeledContent("Stance", value: note.stance ?? "-")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(context == .workout ? "workout-note-banner" : "routine-note-banner")
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
