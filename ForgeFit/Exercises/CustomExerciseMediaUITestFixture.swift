#if DEBUG
import ForgeData
import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// `--seed-custom-exercise-media`: gives one library exercise a photo and a
/// description so the acceptance flows can drive the surfaces that show them
/// without depending on the system photo picker, which runs out of process and
/// carries whatever images the simulator happens to hold.
///
/// The photo is generated, not bundled: a flat colour with the exercise's
/// initial, which is unmistakable in a screenshot and impossible to confuse
/// with a bundled illustration.
enum CustomExerciseMediaUITestFixture {
    static let launchArgument = "--seed-custom-exercise-media"
    /// The exercise the fixture attaches to. Present in the seeded library and
    /// reachable from search, routines, and a live workout.
    static let exerciseName = "Machine Chest Press"
    static let description = "Seat height 4, handles wide, feet flat."

    @MainActor
    static func seed(in context: ModelContext) throws {
        #if canImport(UIKit)
        let media = CustomExerciseMedia.shared
        // Files under Application Support survive `--reset-store`, so a run
        // must not inherit the previous flow's photos.
        media.deleteEverything()

        // Every row carrying the name, not just the first found: the library
        // is seeded from more than one catalog and a name can briefly exist as
        // more than one row, of which the picker may show either.
        let matches = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
            .filter { $0.name == exerciseName && $0.deletedAt == nil }
        guard !matches.isEmpty,
              let start = swatch(label: "START", barOffset: 0.72),
              let end = swatch(label: "END", barOffset: 0.28) else { return }
        for exercise in matches {
            try media.apply(ExercisePhotoSet(start: .new(start), end: .new(end)), for: exercise.id)
            try media.setNotes(description, for: exercise.id)
        }
        #endif
    }

    #if canImport(UIKit)
    /// Two frames of the same fake movement: a bar low for the start, high for
    /// the end. A crossfade between them is unmistakable in a screenshot and
    /// impossible to confuse with a bundled illustration.
    private static func swatch(label: String, barOffset: CGFloat) -> Data? {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 80, y: size.height * barOffset - 24, width: 440, height: 48))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 96, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let text = label as NSString
            let bounds = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: 40), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.9)
    }
    #endif
}
#endif
