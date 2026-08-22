import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Photos and a written description for one exercise, edited inside the
/// exercise form.
///
/// Two labelled slots rather than a gallery: an exercise photo answers "what
/// does this look like at the start" and "what does it look like at the end",
/// and filling both is what makes the exercise screen play the movement. Each
/// slot stands alone — one photo of the machine is a complete answer.
///
/// Changes are staged, not written: the form's Save commits them and its
/// Cancel discards them, the same contract the name and muscle fields have.
struct ExerciseMediaEditorCard: View {
    @Environment(\.theme) private var theme
    @Binding var photos: ExercisePhotoSet
    @Binding var notes: String

    @State private var pickerSlot: ExercisePhotoSlot?
    @State private var selection: PhotosPickerItem?
    @State private var loadFailed = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                FieldLabel("Photos")

                HStack(alignment: .top, spacing: Space.md) {
                    ForEach(ExercisePhotoSlot.allCases, id: \.self) { slot in
                        slotColumn(slot)
                    }
                    Spacer(minLength: 0)
                }

                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if loadFailed {
                    Text("That image could not be read. Try a different one.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("exercise-photo-error")
                }

                Divider().overlay(theme.separator)

                FieldLabel("Description")
                DarkTextField(
                    text: $notes,
                    placeholder: "Seat height 4, handles wide, feet flat",
                    axis: .vertical,
                    accessibilityIdentifier: "exercise-description"
                )
                .lineLimit(3...8)
            }
        }
        .photosPicker(
            isPresented: Binding(get: { pickerSlot != nil }, set: { if !$0 { pickerSlot = nil } }),
            selection: $selection,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selection) { _, item in
            guard let item, let slot = pickerSlot else { return }
            Task { await load(item, into: slot) }
        }
    }

    /// Says what filling the second slot buys, because that consequence is not
    /// visible from an empty tile — and stops once both are filled.
    private var caption: String {
        if photos.animates {
            return "Both positions saved — the exercise plays through the movement. Stays on this device."
        }
        if photos.isEmpty {
            return "Add a start and an end position to play through the movement. Your photos stay on this device."
        }
        return "Add the other position to play through the movement. Stays on this device."
    }

    private func slotColumn(_ slot: ExercisePhotoSlot) -> some View {
        VStack(spacing: 6) {
            tile(slot)
            Text(slot.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(photos[slot] == nil ? theme.textSecondary : theme.textPrimary)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tile(_ slot: ExercisePhotoSlot) -> some View {
        if let photo = photos[slot] {
            Menu {
                Button("Replace photo", systemImage: "photo") { pickerSlot = slot }
                if photos.animates {
                    Button("Swap start and end", systemImage: "arrow.left.arrow.right") {
                        withAnimation(Motion.stateChange) {
                            let start = photos.start
                            photos.start = photos.end
                            photos.end = start
                        }
                    }
                }
                Button("Remove photo", systemImage: "trash", role: .destructive) {
                    withAnimation(Motion.stateChange) { photos[slot] = nil }
                }
            } label: {
                preview(photo)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    // A photo that opens a menu has to look like it does. The
                    // badge is the affordance; the menu is the mechanic.
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(theme.onAccent, theme.accent)
                            .padding(4)
                    }
            }
            .accessibilityLabel("\(slot.title) photo")
            .accessibilityHint("Replace or remove this photo")
            .accessibilityIdentifier("exercise-photo-\(slot.rawValue)")
        } else {
            Button {
                pickerSlot = slot
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Add")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(theme.accentForeground)
                .frame(width: 84, height: 84)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(slot.title.lowercased()) position photo")
            .accessibilityIdentifier("add-exercise-photo-\(slot.rawValue)")
        }
    }

    @ViewBuilder
    private func preview(_ photo: ExercisePhotoDraft) -> some View {
        #if canImport(UIKit)
        if let image = downsampledPreview(photo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            theme.surfaceElevated
        }
        #else
        theme.surfaceElevated
        #endif
    }

    #if canImport(UIKit)
    /// Decoded down to tile size. A camera original is several megabytes; a
    /// full-resolution decode to draw 84 points is the per-row hitch this app
    /// already avoids everywhere else it shows an image.
    private func downsampledPreview(_ photo: ExercisePhotoDraft) -> UIImage? {
        switch photo.kind {
        case .stored(let url):
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return CustomExerciseMedia.downsampled(data: data, maxPixelSize: 84 * 3)
        case .new(let data):
            return CustomExerciseMedia.downsampled(data: data, maxPixelSize: 84 * 3)
        }
    }
    #endif

    private func load(_ item: PhotosPickerItem, into slot: ExercisePhotoSlot) async {
        defer {
            selection = nil
            pickerSlot = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            loadFailed = true
            return
        }
        loadFailed = false
        withAnimation(Motion.stateChange) { photos[slot] = .new(data) }
    }
}
