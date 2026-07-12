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
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var changed = 0
        for seed in seeds {
            let id = deterministicID(for: seed.slug)
            let isCardio = seed.category == "cardio"
            let kind = CardioKind.infer(name: seed.name, equipment: seed.equipment)
            // Cardio exercises get proper muscles-worked from their modality,
            // including the cardiovascular system, and are updated on reseed.
            // Lifts get broad shoulders/chest tags refined into taxonomy
            // sub-muscles from the name (side delts, upper chest, ...).
            let refined = MuscleRefinement.refine(
                name: seed.name,
                primaryMuscles: seed.primaryMuscles,
                secondaryMuscles: seed.secondaryMuscles)
            let primary = isCardio ? kind.musclesWorked : refined.primary
            let model = existingByID[id] ?? ExerciseLibraryModel(id: id, name: seed.name)
            var modelChanged = false

            if existingByID[id] == nil {
                context.insert(model)
                modelChanged = true
            } else if model.userModified {
                continue
            }

            func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ExerciseLibraryModel, Value>, _ value: Value) {
                guard model[keyPath: keyPath] != value else { return }
                model[keyPath: keyPath] = value
                modelChanged = true
            }

            set(\.ownerID, nil)
            set(\.name, seed.name)
            set(\.movementPattern, isCardio ? "cardio" : seed.force)
            set(\.primaryMuscles, primary)
            set(\.secondaryMuscles, isCardio ? seed.secondaryMuscles.filter { $0 != "cardiorespiratory" } : refined.secondary)
            set(\.equipment, seed.equipment)
            set(\.isUnilateral, false)
            let desiredWeightMode = isCardio ? WeightMode.bodyweight : weightMode(equipment: seed.equipment, name: seed.name)
            if model.defaultWeightMode != desiredWeightMode {
                model.defaultWeightMode = desiredWeightMode
                modelChanged = true
            }
            set(\.difficulty, seed.level)
            set(\.isCardio, isCardio)
            set(\.mediaSlug, seed.image)
            set(\.category, seed.category)
            set(\.force, seed.force)
            set(\.mechanic, seed.mechanic)
            set(\.instructions, seed.instructions ?? [])

            if modelChanged {
                model.updatedAt = Date()
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
    }

    // MARK: - Filter taxonomy for the picker

    static let muscleGroups = [
        "cardiovascular", "abdominals", "biceps", "triceps", "chest", "shoulders", "back", "lats",
        "middle back", "upper back", "lower back", "traps", "quadriceps", "hamstrings",
        "glutes", "calves", "forearms", "abductors", "adductors", "neck",
        // Pseudo-regions for yoga/mobility work, following the
        // `cardiovascular` precedent: broad stretch targets the strict muscle
        // list can't express.
        "hips", "spine"
    ]

    /// The picker's grouped view of `muscleGroups`: parents that drill down
    /// into sub-muscles (via `MuscleTaxonomy`), everything else standalone.
    /// A parent is selectable on its own — broad tagging stays valid.
    static let muscleHierarchy: [(group: String, children: [String])] = {
        var seen = Set<String>()
        var result: [(group: String, children: [String])] = []
        for muscle in muscleGroups {
            let parent = MuscleTaxonomy.parent(of: muscle)
            guard seen.insert(parent).inserted else { continue }
            result.append((group: parent, children: MuscleTaxonomy.children[parent] ?? []))
        }
        return result
    }()

    static let equipmentTypes = [
        "treadmill", "bike", "rower", "elliptical", "stair", "barbell", "dumbbell",
        "machine", "cable", "body only", "kettlebells", "bands", "medicine ball",
        "exercise ball", "e-z curl bar", "foam roll", "other"
    ]

    /// Equipment you actually do cardio on (plus bodyweight, for outdoor runs
    /// and calisthenic-style conditioning). Ordered for the cardio editor.
    static let cardioEquipmentTypes = [
        "treadmill", "bike", "rower", "elliptical", "stair", "body only"
    ]

    /// Resistance-training equipment. Ordered for the lift editor.
    static let strengthEquipmentTypes = [
        "barbell", "dumbbell", "machine", "cable", "body only", "kettlebells",
        "bands", "medicine ball", "exercise ball", "e-z curl bar", "foam roll"
    ]

    /// Yoga props. Ordered for the pose editor; poses are body-only by
    /// default with props as the exception.
    static let yogaEquipmentTypes = [
        "body only", "block", "strap", "bolster"
    ]

    /// The primary equipment set for a given exercise type — used to decide
    /// whether a selection is "on-discipline" (e.g. keeping the picker's
    /// current value coherent when the user flips Lift ⇄ Cardio ⇄ Yoga).
    static func primaryEquipment(isCardio: Bool) -> [String] {
        isCardio ? cardioEquipmentTypes : strengthEquipmentTypes
    }

    static func primaryEquipment(modality: Modality) -> [String] {
        switch modality {
        case .strength: strengthEquipmentTypes
        case .cardio: cardioEquipmentTypes
        case .yoga: yogaEquipmentTypes
        }
    }

    /// Equipment options for the exercise editor, ordered by relevance to the
    /// chosen type: the matching discipline's equipment first, then the other
    /// discipline's kept at the bottom (a kettlebell cardio circuit, a treadmill
    /// finisher — uncommon but real), then "other" last. Nothing is removed, so
    /// every edge case stays reachable — just out of the way.
    static func equipmentOptions(isCardio: Bool) -> [String] {
        equipmentOptions(modality: isCardio ? .cardio : .strength)
    }

    static func equipmentOptions(modality: Modality) -> [String] {
        let primary = primaryEquipment(modality: modality)
        // Yoga keeps its list tight — props plus bodyweight cover real
        // practice; the machine/barbell tail would just be noise.
        guard modality != .yoga else { return primary + ["other"] }
        let secondary = modality == .cardio ? strengthEquipmentTypes : cardioEquipmentTypes
        var seen = Set(primary)
        let crossover = secondary.filter { seen.insert($0).inserted }
        return primary + crossover + ["other"]
    }

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
            if exercise.isYoga {
                yogaArt
            } else {
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
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }

    /// Pose line-art: a bundled template asset (`yoga_<slug>`, tintable) when
    /// present, else the pose's SF Symbol stand-in from the catalog.
    private var yogaArt: some View {
        ZStack {
            theme.surfaceElevated
            YogaPoseArt(exercise: exercise, size: size * 0.62)
        }
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

/// The pose illustration used across rows, cards, and the guided player:
/// prefers a bundled line-art template asset named `yoga_<slug>` (theme
/// tinted), falling back to the catalog's SF Symbol. Custom poses (no
/// catalog slug) always use the generic symbol.
struct YogaPoseArt: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel?
    var slug: String?
    var size: CGFloat = 46

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

    var body: some View {
        Group {
            if let slug, let uiImage = Self.asset(for: slug) {
                Image(uiImage: uiImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: YogaPoseCatalog.pose(forSlug: slug)?.symbol ?? "figure.yoga")
                    .font(.system(size: size * 0.72, weight: .medium))
            }
        }
        .foregroundStyle(theme.accent)
    }

    #if canImport(UIKit)
    private static func asset(for slug: String) -> UIImage? {
        UIImage(named: "yoga_" + slug.replacingOccurrences(of: "-", with: "_"))
    }
    #else
    private static func asset(for slug: String) -> UIImage? { nil }
    #endif
}
