import ForgeData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The pose visual shared by rows, detail screens, and the guided player.
/// Catalog poses use the selected instructor photo; custom or missing poses
/// retain the authored line-art/SF Symbol fallback.
struct YogaPoseArt: View {
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale
    @AppStorage(YogaInstructor.preferenceKey) private var instructorRaw = YogaInstructor.female.rawValue

    let exercise: ExerciseLibraryModel?
    var slug: String?
    var size: CGFloat = 46

    #if canImport(UIKit)
    @State private var loadedImage: UIImage?
    @State private var loadedImageKey = ""
    #endif

    init(exercise: ExerciseLibraryModel?, size: CGFloat = 46) {
        self.exercise = exercise
        self.slug = exercise.flatMap(YogaPoseCatalog.slug(for:))
        self.size = size
    }

    init(slug: String?, size: CGFloat = 46) {
        self.exercise = nil
        self.slug = slug
        self.size = size
    }

    private var instructor: YogaInstructor {
        YogaInstructor.resolved(from: instructorRaw)
    }

    private var imageLoadKey: String {
        "\(slug ?? "custom")|\(instructor.rawValue)|\(Int(ceil(size * displayScale)))"
    }

    var body: some View {
        #if canImport(UIKit)
        Group {
            if loadedImageKey == imageLoadKey, let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFit()
            } else if let figure = YogaPoseFigureCatalog.figure(forSlug: slug) {
                YogaPoseFigureView(figure: figure, size: size)
            } else {
                Image(systemName: YogaPoseCatalog.pose(forSlug: slug)?.symbol ?? "figure.yoga")
                    .font(.system(size: size * 0.72, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(theme.accent)
        .accessibilityHidden(true)
        .task(id: imageLoadKey, priority: .userInitiated) {
            await loadImage()
        }
        #else
        Group {
            if let figure = YogaPoseFigureCatalog.figure(forSlug: slug) {
                YogaPoseFigureView(figure: figure, size: size)
            } else {
                Image(systemName: YogaPoseCatalog.pose(forSlug: slug)?.symbol ?? "figure.yoga")
                    .font(.system(size: size * 0.72, weight: .medium))
            }
        }
        .frame(width: size, height: size)
        .foregroundStyle(theme.accent)
        .accessibilityHidden(true)
        #endif
    }

    #if canImport(UIKit)
    private func loadImage() async {
        guard let slug else { return }
        let expectedKey = imageLoadKey
        guard let image = await YogaPoseImageStore.image(
            slug: slug,
            instructor: instructor,
            requestedPixelSize: size * displayScale
        ), !Task.isCancelled else { return }
        loadedImage = image
        loadedImageKey = expectedKey
    }
    #endif
}
