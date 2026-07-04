import CryptoKit
import Foundation
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// One row of the bundled `exercises.json` (derived from the open-source
/// free-exercise-db). Illustrations are loaded remotely from the same project.
struct SeedExercise: Decodable {
    let slug: String
    let name: String
    let force: String?
    let level: String?
    let mechanic: String?
    let equipment: String?
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let category: String?
    let image: String?
    let instructions: [String]?
}

enum ExerciseCatalog {
    /// Base URL for exercise illustrations (free-exercise-db raw images).
    private static let imageBase = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/"

    static func imageURL(path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + path)
    }

    static func localThumbnailURL(path: String?) -> URL? {
        guard let name = thumbnailResourceName(path: path) else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "ExerciseThumbnails")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg")
    }

    static func thumbnailResourceName(path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let stem = path.replacingOccurrences(of: ".jpg", with: "")
        let mapped = stem.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return String(mapped)
    }

    static func frameOnePath(from path: String?) -> String? {
        guard let path, path.hasSuffix("/0.jpg") else { return nil }
        return String(path.dropLast("0.jpg".count)) + "1.jpg"
    }

    #if canImport(UIKit)
    private static let thumbnailCache = NSCache<NSString, UIImage>()

    static func localThumbnail(path: String?) -> UIImage? {
        guard let name = thumbnailResourceName(path: path) else { return nil }
        if let cached = thumbnailCache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "ExerciseThumbnails")
                ?? Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnailCache.setObject(image, forKey: name as NSString)
        return image
    }
    #endif

    /// Stable UUID derived from the exercise slug so re-seeding is idempotent and
    /// IDs are consistent across installs.
    static func deterministicID(for slug: String) -> UUID {
        let digest = SHA256.hash(data: Data(slug.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version marker
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { $0.copyBytes(from: bytes) }
        return UUID(uuid: uuid)
    }

    private static var cached: [SeedExercise]?

    static func load() -> [SeedExercise] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SeedExercise].self, from: data) else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    private static func weightMode(equipment: String?, name: String) -> WeightMode {
        let n = name.lowercased()
        if n.contains("assisted") { return .bodyweightAssisted }
        switch equipment {
        case "body only": return n.contains("weighted") ? .bodyweightAdded : .bodyweight
        default: return .external
        }
    }

    /// Insert any catalog exercises not already present. Idempotent.
    @MainActor
    static func seed(into context: ModelContext) {
        let seeds = load()
        guard !seeds.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        var inserted = 0
        for seed in seeds {
            let id = deterministicID(for: seed.slug)
            let isCardio = seed.category == "cardio"
            let kind = CardioKind.infer(name: seed.name, equipment: seed.equipment)
            // Cardio exercises get proper muscles-worked from their modality,
            // including the cardiovascular system, and are updated on reseed.
            let primary = isCardio ? kind.musclesWorked : seed.primaryMuscles
            let model = existingByID[id] ?? ExerciseLibraryModel(id: id, name: seed.name)
            model.ownerID = nil
            model.name = seed.name
            model.movementPattern = isCardio ? "cardio" : seed.force
            model.primaryMuscles = primary
            model.secondaryMuscles = isCardio ? seed.secondaryMuscles.filter { $0 != "cardiorespiratory" } : seed.secondaryMuscles
            model.equipment = seed.equipment
            model.isUnilateral = false
            model.defaultWeightMode = isCardio ? .bodyweight : weightMode(equipment: seed.equipment, name: seed.name)
            model.difficulty = seed.level
            model.isCardio = isCardio
            model.mediaSlug = seed.image
            model.category = seed.category
            model.force = seed.force
            model.mechanic = seed.mechanic
            model.instructions = seed.instructions ?? []
            model.updatedAt = Date()
            if existingByID[id] == nil {
                context.insert(model)
                inserted += 1
            }
        }
        if inserted > 0 || seeds.contains(where: { $0.category == "cardio" }) { try? context.save() }
    }

    // MARK: - Filter taxonomy for the picker

    static let muscleGroups = [
        "cardiovascular", "abdominals", "biceps", "triceps", "chest", "shoulders", "lats",
        "middle back", "upper back", "lower back", "traps", "quadriceps", "hamstrings",
        "glutes", "calves", "forearms", "abductors", "adductors", "neck"
    ]

    static let equipmentTypes = [
        "treadmill", "bike", "rower", "elliptical", "stair", "barbell", "dumbbell",
        "machine", "cable", "body only", "kettlebells", "bands", "medicine ball",
        "exercise ball", "e-z curl bar", "foam roll", "other"
    ]

    /// Equipment loaded by stacking plates on a bar — the plate calculator
    /// only makes sense for these.
    static func isBarbellLoaded(_ equipment: String?) -> Bool {
        equipment == "barbell" || equipment == "e-z curl bar"
    }
}

/// Bundled exercise illustration with a graceful icon fallback. Illustrations
/// sit on a light plate so they read on the dark theme.
struct ExerciseThumbnail: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            #if canImport(UIKit)
            if let image = ExerciseCatalog.localThumbnail(path: exercise.mediaSlug) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                .background(Color(white: 0.96))
            } else {
                fallback
            }
            #else
            fallback
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            theme.surfaceElevated
            Image(systemName: exercise.isCardio ? "figure.run" : "dumbbell.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
    }
}
