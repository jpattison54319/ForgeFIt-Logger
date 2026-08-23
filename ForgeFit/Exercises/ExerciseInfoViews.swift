import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ExerciseAnimationView: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let exercise: ExerciseLibraryModel
    var cornerRadius: CGFloat = Radius.card

    @State private var showEnd = false
    @State private var isPaused = false

    #if canImport(UIKit)
    @State private var userStart: UIImage?
    @State private var userEnd: UIImage?

    /// The athlete's own photos replace the illustration entirely when they
    /// exist — they photographed this machine because the stock drawing wasn't
    /// the thing in front of them. Their start/end pair drives the same
    /// crossfade the bundled two-frame illustrations use, so one photo is a
    /// still and two play the movement.
    private var media: CustomExerciseMedia { CustomExerciseMedia.shared }
    private var hasUserPhoto: Bool { media.hasPhotos(for: exercise.id) }
    private var startImage: UIImage? {
        if hasUserPhoto { return userStart ?? userEnd }
        return ExerciseCatalog.localThumbnail(path: exercise.mediaSlug)
    }
    private var endImage: UIImage? {
        if hasUserPhoto { return userStart != nil ? userEnd : nil }
        return ExerciseCatalog.localThumbnail(path: ExerciseCatalog.frameOnePath(from: exercise.mediaSlug))
    }
    #endif

    var body: some View {
        ZStack {
            Color(white: 0.96)
            #if canImport(UIKit)
            // A photographed exercise is never rendered as a pose drawing:
            // the athlete's own frames win over the generic art.
            if exercise.isYoga, !hasUserPhoto {
                ViewThatFits {
                    YogaPoseArt(exercise: exercise, size: 320)
                    YogaPoseArt(exercise: exercise, size: 280)
                    YogaPoseArt(exercise: exercise, size: 240)
                    YogaPoseArt(exercise: exercise, size: 200)
                }
                .padding(10)
            } else if let startImage {
                Image(uiImage: startImage)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
                if let endImage {
                    Image(uiImage: endImage)
                        .resizable()
                        .scaledToFit()
                        .padding(10)
                        .opacity(showEnd ? 1 : 0)
                }
            } else {
                fallback
            }
            #else
            fallback
            #endif

            if animates {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: changePlayback) {
                            Image(systemName: playbackSymbol)
                                .font(.body.bold())
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.62))
                                .clipShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playbackLabel)
                        .accessibilityIdentifier("exercise-photo-playback")
                    }
                }
                .padding(12)
            }
        }
        .aspectRatio(exercise.isYoga && !hasUserPhotoOnThisPlatform ? 1 : 4 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(theme.separator, lineWidth: 1)
        }
        .task(id: mediaLoadID) {
            await loadUserFrames()
        }
        .task(id: "\(animates)-\(reduceMotion)") {
            guard animates, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(0.9))
                guard !Task.isCancelled, !isPaused else { continue }
                withAnimation(.easeInOut(duration: 0.45)) {
                    showEnd.toggle()
                }
            }
        }
        // Keep the media itself and its playback button as distinct elements:
        // VoiceOver should announce whose photos these are without swallowing
        // the control nested inside the same visual card.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mediaAccessibilityLabel)
        .accessibilityHint(mediaAccessibilityHint)
        .accessibilityIdentifier(hasUserPhotoOnThisPlatform ? "exercise-user-photos" : "")
    }

    /// Whether this view is currently crossfading two frames — the athlete's
    /// start/end pair, or a bundled two-frame illustration.
    private var animates: Bool {
        #if canImport(UIKit)
        return startImage != nil && endImage != nil
        #else
        return false
        #endif
    }

    private var hasUserPhotoOnThisPlatform: Bool {
        #if canImport(UIKit)
        return hasUserPhoto
        #else
        return false
        #endif
    }

    /// Says whose picture this is. A user's own photos are described as theirs,
    /// and a still is never announced as a demonstration that can be paused.
    private var mediaAccessibilityLabel: String {
        if hasUserPhotoOnThisPlatform {
            return animates
                ? "Your start and end photos for \(exercise.name)"
                : "Your photo of \(exercise.name)"
        }
        return exercise.isYoga ? "\(exercise.name) pose demonstration" : "Exercise demonstration"
    }

    private var playbackSymbol: String {
        if reduceMotion { return "arrow.left.arrow.right" }
        return isPaused ? "play.fill" : "pause.fill"
    }

    private var playbackLabel: String {
        if reduceMotion {
            return showEnd ? "Show start position" : "Show end position"
        }
        return isPaused ? "Play photo movement" : "Pause photo movement"
    }

    private var mediaAccessibilityHint: String {
        if exercise.isYoga, !hasUserPhotoOnThisPlatform {
            return "Use the instructor control below to change the model"
        }
        return ""
    }

    private func changePlayback() {
        if reduceMotion {
            showEnd.toggle()
        } else {
            isPaused.toggle()
        }
    }

    private var mediaLoadID: String {
        #if canImport(UIKit)
        return "\(exercise.id)-\(media.revision)"
        #else
        return exercise.id.uuidString
        #endif
    }

    private func loadUserFrames() async {
        #if canImport(UIKit)
        userStart = nil
        userEnd = nil
        showEnd = false
        isPaused = false

        let startURL = media.photoURL(for: exercise.id, slot: .start)
        let endURL = media.photoURL(for: exercise.id, slot: .end)
        async let loadedStart = loadFrame(at: startURL)
        async let loadedEnd = loadFrame(at: endURL)
        let frames = await (loadedStart, loadedEnd)
        guard !Task.isCancelled else { return }
        userStart = frames.0
        userEnd = frames.1
        #endif
    }

    #if canImport(UIKit)
    private func loadFrame(at url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await CustomExerciseMedia.downsampled(url: url, maxPixelSize: 1600)
    }
    #endif

    private var fallback: some View {
        Image(systemName: exercise.isCardio ? "figure.run" : "dumbbell.fill")
            .font(.system(size: 46, weight: .semibold))
            .foregroundStyle(theme.accentForeground)
    }
}

struct ExerciseInfoCard: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel

    @State private var showingPoseConsiderations = false

    private var chips: [(String, Color)] {
        [
            exercise.difficulty.map { ($0.capitalized, theme.accent) },
            exercise.mechanic.map { ($0.capitalized, theme.secondaryAccent) },
            exercise.force.map { ($0.capitalized, theme.textSecondary) },
            exercise.equipment.map { ($0.capitalized, theme.textSecondary) }
        ]
        .compactMap { $0 }
    }

    private var muscles: [String] {
        var seen = Set<String>()
        return (exercise.primaryMuscles + exercise.secondaryMuscles).filter { seen.insert($0).inserted }
    }

    private var poseConsiderations: [String] {
        guard exercise.isYoga,
              !YogaPoseCatalog.isSessionExercise(exercise),
              let slug = YogaPoseCatalog.slug(for: exercise) else { return [] }
        return YogaGuidanceCatalog.guidance(forSlug: slug)?.considerations ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ExerciseAnimationView(exercise: exercise)

            if exercise.isYoga {
                YogaInstructorPicker()
            }

            if !chips.isEmpty {
                WrappingChips(chips: chips)
            }

            if !muscles.isEmpty {
                MuscleChips(muscles: muscles)
            }

            if let userNotes = CustomExerciseMedia.shared.notes(for: exercise.id) {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Your description")
                        .font(.sectionTitle)
                        .foregroundStyle(theme.textPrimary)
                    Card(padding: Space.md) {
                        Text(userNotes)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("exercise-user-description")
                }
            }

            if !exercise.instructions.isEmpty {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text("How to perform")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        if !poseConsiderations.isEmpty {
                            Button {
                                showingPoseConsiderations = true
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.warmup)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Pose considerations")
                            .accessibilityIdentifier("pose-considerations")
                            .alert("Pose considerations", isPresented: $showingPoseConsiderations) {
                                Button("OK", role: .cancel) {}
                            } message: {
                                Text(poseConsiderations.joined(separator: " "))
                            }
                        }
                    }
                    Card(padding: Space.md) {
                        VStack(alignment: .leading, spacing: Space.md) {
                            ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                                HStack(alignment: .top, spacing: Space.md) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundStyle(theme.onAccent)
                                        .frame(width: 24, height: 24)
                                        .background(theme.accent)
                                        .clipShape(Circle())
                                    Text(instruction)
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            } else if CustomExerciseMedia.shared.notes(for: exercise.id) == nil {
                // Only an exercise with nothing written about it at all is
                // missing its how-to; the user's own description is one.
                Card(padding: Space.md) {
                    Text("No step-by-step instructions are available for this exercise yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }
}

private struct WrappingChips: View {
    @Environment(\.theme) private var theme
    let chips: [(String, Color)]

    var body: some View {
        FlexibleWrap(spacing: 8, rowSpacing: 8) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Tag(text: chip.0, color: chip.1, background: chip.1.opacity(0.14))
            }
        }
    }
}

private struct FlexibleWrap: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, proposal: proposal)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private func arrange(subviews: Subviews, proposal: ProposedViewSize) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if current.width > 0, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.items.append(Item(subview: subview, size: size))
            current.width += (current.items.count == 1 ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}
