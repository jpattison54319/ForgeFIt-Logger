import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Photos and a written description for one exercise, edited inside the
/// exercise form.
///
/// A visible mode choice makes the two supported outcomes explicit: one photo
/// can represent the exercise, or a start/end pair can play the movement.
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
    @State private var processingSlot: ExercisePhotoSlot?
    @State private var mode: ExercisePhotoMode
    @State private var showingSinglePhotoChoice = false

    init(photos: Binding<ExercisePhotoSet>, notes: Binding<String>) {
        _photos = photos
        _notes = notes
        _mode = State(initialValue: .inferred(from: photos.wrappedValue))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                FieldLabel("Photo")

                Picker("Photo style", selection: $mode) {
                    ForEach(ExercisePhotoMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("exercise-photo-mode")

                Group {
                    if mode == .single {
                        HStack(alignment: .top, spacing: Space.md) {
                            slotColumn(.start, title: "Photo", identifier: "single")
                            Spacer(minLength: 0)
                        }
                    } else {
                        HStack(alignment: .top, spacing: Space.md) {
                            ForEach(ExercisePhotoSlot.allCases, id: \.self) { slot in
                                slotColumn(slot, title: slot.title, identifier: slot.rawValue)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                Text("Start + end animates the movement. Photos stay on this device.")
                    .font(.footnote)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if loadFailed {
                    Text("That image could not be read. Try a different one.")
                        .font(.footnote.bold())
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
        .onAppear {
            if mode == .single {
                photos = photos.normalizedSinglePhoto
            }
        }
        .onChange(of: mode) { oldMode, newMode in
            guard oldMode != newMode else { return }
            if newMode == .single, photos.animates {
                mode = oldMode
                showingSinglePhotoChoice = true
            } else if newMode == .single {
                photos = photos.normalizedSinglePhoto
            }
        }
        .confirmationDialog(
            "Use one photo?",
            isPresented: $showingSinglePhotoChoice,
            titleVisibility: .visible
        ) {
            Button("Keep Start Photo") {
                photos = photos.singlePhoto(keeping: .start)
                mode = .single
            }
            Button("Keep End Photo") {
                photos = photos.singlePhoto(keeping: .end)
                mode = .single
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The other photo will be removed when you save.")
        }
    }

    private func slotColumn(
        _ slot: ExercisePhotoSlot,
        title: String,
        identifier: String
    ) -> some View {
        VStack(spacing: 6) {
            tile(slot, title: title, identifier: identifier)
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(photos[slot] == nil ? theme.textSecondary : theme.textPrimary)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tile(
        _ slot: ExercisePhotoSlot,
        title: String,
        identifier: String
    ) -> some View {
        if processingSlot == slot {
            ProgressView()
                .tint(theme.accent)
                .frame(width: 84, height: 84)
                .background(theme.surfaceElevated)
                .clipShape(.rect(cornerRadius: Radius.control))
                .accessibilityLabel("Preparing \(title.lowercased())")
        } else if let photo = photos[slot] {
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
                ExercisePhotoDraftPreview(photo: photo)
                    .frame(width: 84, height: 84)
                    .clipShape(.rect(cornerRadius: Radius.control))
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
            .accessibilityLabel(title == "Photo" ? "Exercise photo" : "\(title) photo")
            .accessibilityHint("Replace or remove this photo")
            .accessibilityIdentifier("exercise-photo-\(identifier)")
        } else {
            Button {
                pickerSlot = slot
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Add")
                        .font(.caption.bold())
                }
                .foregroundStyle(theme.accentForeground)
                .frame(width: 84, height: 84)
                .background(theme.surfaceElevated)
                .clipShape(.rect(cornerRadius: Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title == "Photo" ? "Add exercise photo" : "Add \(title.lowercased()) position photo")
            .accessibilityIdentifier("add-exercise-photo-\(identifier)")
        }
    }

    private func load(_ item: PhotosPickerItem, into slot: ExercisePhotoSlot) async {
        defer {
            selection = nil
            pickerSlot = nil
            processingSlot = nil
        }
        processingSlot = slot
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            loadFailed = true
            return
        }
        guard let prepared = await CustomExerciseMedia.preparedForStorage(data) else {
            loadFailed = true
            return
        }
        loadFailed = false
        withAnimation(Motion.stateChange) { photos[slot] = .prepared(prepared) }
    }
}

private struct ExercisePhotoDraftPreview: View {
    @Environment(\.theme) private var theme
    let photo: ExercisePhotoDraft

    #if canImport(UIKit)
    @State private var image: UIImage?
    #endif

    var body: some View {
        ZStack {
            theme.surfaceElevated
            #if canImport(UIKit)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(theme.accent)
            }
            #endif
        }
        #if canImport(UIKit)
        .task(id: photo.kind) {
            image = await CustomExerciseMedia.previewImage(for: photo, maxPixelSize: 84 * 3)
        }
        #endif
    }
}
