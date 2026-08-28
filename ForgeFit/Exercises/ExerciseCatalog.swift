import CryptoKit
import Foundation
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
#if canImport(UIKit)
import ImageIO
import UIKit
#endif

/// One row of the bundled `exercises.json` (derived from the open-source
/// free-exercise-db). Illustrations are loaded remotely from the same project.
nonisolated struct SeedExercise: Decodable, Sendable {
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

    /// Full-resolution decode for the exercise DETAIL card (two one-off
    /// images — a sync decode is fine there). Row thumbnails must NOT use
    /// this: see `cachedThumbnail`/`primeThumbnail`.
    static func localThumbnail(path: String?) -> UIImage? {
        guard let name = thumbnailResourceName(path: path) else { return nil }
        if let cached = thumbnailCache.object(forKey: name as NSString) { return cached }
        guard let url = thumbnailURL(named: name),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        thumbnailCache.setObject(image, forKey: name as NSString)
        return image
    }

    /// Cache-only lookup for row thumbnails — never decodes. First-scroll
    /// decoding of the full-res JPEGs on the main thread was a per-row hitch;
    /// rows render a placeholder and call `primeThumbnail` instead.
    static func cachedThumbnail(path: String?) -> UIImage? {
        guard let name = thumbnailResourceName(path: path) else { return nil }
        return thumbnailCache.object(forKey: ("thumb:" + name) as NSString)
    }

    /// Decode + downsample off-main via ImageIO (rows render at ≤46 pt, so a
    /// full-res decode wasted CPU and memory), then prime the cache. Cached
    /// under a separate key from `localThumbnail` so the detail card never
    /// receives a downsampled image.
    static func primeThumbnail(path: String?, maxPixelSize: CGFloat = 46 * 3) async -> UIImage? {
        guard let name = thumbnailResourceName(path: path) else { return nil }
        let key = ("thumb:" + name) as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let url = thumbnailURL(named: name) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
        if let image { thumbnailCache.setObject(image, forKey: key) }
        return image
    }

    private static func thumbnailURL(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "ExerciseThumbnails")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg")
    }
    #endif

    /// Stable UUID derived from the exercise slug so re-seeding is idempotent and
    /// IDs are consistent across installs.
    nonisolated static func deterministicID(for slug: String) -> UUID {
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
        let decoded = decodeBundledSeeds()
        cached = decoded
        return decoded
    }

    /// Bundle I/O and decoding are pure work and safe to perform away from the
    /// main actor during first launch. Keep the cache itself main-actor owned.
    private nonisolated static func decodeBundledSeeds() -> [SeedExercise] {
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SeedExercise].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Pure classifier corpus used by detached import maintenance. Decoding and
    /// muscle refinement stay off MainActor; callers that already own the
    /// cached seed values can use the overload to avoid duplicate bundle I/O.
    nonisolated static func classificationSeedCorpusForWorker() -> [ExerciseInfo] {
        classificationSeedCorpus(from: decodeBundledSeeds())
    }

    nonisolated static func classificationSeedCorpus(
        from seeds: [SeedExercise]
    ) -> [ExerciseInfo] {
        seeds.map { seed in
            let refined = MuscleRefinement.refine(
                name: seed.name,
                primaryMuscles: seed.primaryMuscles,
                secondaryMuscles: seed.secondaryMuscles
            )
            return ExerciseInfo(
                id: deterministicID(for: seed.slug),
                name: seed.name,
                movementPattern: seed.force,
                primaryMuscles: refined.primary,
                secondaryMuscles: refined.secondary,
                equipment: seed.equipment
            )
        }
    }

    private nonisolated static func weightMode(equipment: String?, name: String) -> WeightMode {
        let n = name.lowercased()
        if n.contains("assisted") { return .bodyweightAssisted }
        switch equipment {
        case "body only": return n.contains("weighted") ? .bodyweightAdded : .bodyweight
        default: return .external
        }
    }

    /// Insert any catalog exercises not already present. Idempotent.
    @MainActor
    static func seed(into context: ModelContext, persist: Bool = true) throws {
        let seeds = load()
        guard !seeds.isEmpty else { return }

        // A failed read is not an empty catalog. Propagate the error so we do
        // not manufacture duplicate logical IDs after a transient store fault.
        let existing = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let changed = seeds.count {
            upsert($0, existingByID: existingByID, into: context)
        }
        if persist, changed > 0 { try context.save() }
    }

    /// First-install variant that keeps the exact same single-save semantics
    /// while confining the ~900-row fetch/upsert/save transaction to an
    /// isolated SwiftData context. Only immutable seed values cross actors.
    /// `persist: false` retains caller-context semantics for focused tests and
    /// tools, using bounded yields because those unsaved models cannot move.
    @MainActor
    static func seedCooperatively(
        into context: ModelContext,
        persist: Bool = true,
        batchSize: Int = 12
    ) async throws {
        let seeds: [SeedExercise]
        if let cached {
            seeds = cached
        } else {
            let decoded = await Task.detached(priority: .userInitiated) {
                decodeBundledSeeds()
            }.value
            cached = decoded
            seeds = decoded
        }
        guard !seeds.isEmpty else { return }

        if persist {
            let container = context.container
            let task = Task.detached(priority: .utility) {
                try seedPersisted(seeds, in: container)
            }
            try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
            await Task.yield()
            return
        }

        try Task.checkCancellation()
        await Task.yield()
        let existing = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        await Task.yield()
        let boundedBatchSize = max(1, batchSize)
        var changed = 0
        for (index, seed) in seeds.enumerated() {
            if upsert(seed, existingByID: existingByID, into: context) {
                changed += 1
            }
            if (index + 1).isMultiple(of: boundedBatchSize) {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        _ = changed
    }

    private nonisolated static func seedPersisted(
        _ seeds: [SeedExercise],
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var changed = 0
        for seed in seeds {
            try Task.checkCancellation()
            if upsert(seed, existingByID: existingByID, into: context) {
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
    }

    private nonisolated static func upsert(
        _ seed: SeedExercise,
        existingByID: [UUID: ExerciseLibraryModel],
        into context: ModelContext
    ) -> Bool {
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
            secondaryMuscles: seed.secondaryMuscles
        )
        let primary = isCardio ? kind.musclesWorked : refined.primary
        let model = existingByID[id] ?? ExerciseLibraryModel(id: id, name: seed.name)
        var modelChanged = false

        if existingByID[id] == nil {
            context.insert(model)
            modelChanged = true
        } else if model.userModified {
            return false
        }

        func set<Value: Equatable>(
            _ keyPath: ReferenceWritableKeyPath<ExerciseLibraryModel, Value>,
            _ value: Value
        ) {
            guard model[keyPath: keyPath] != value else { return }
            model[keyPath: keyPath] = value
            modelChanged = true
        }

        set(\.ownerID, nil)
        set(\.name, seed.name)
        set(\.movementPattern, isCardio ? "cardio" : seed.force)
        set(\.primaryMuscles, primary)
        set(
            \.secondaryMuscles,
            isCardio
                ? seed.secondaryMuscles.filter { $0 != "cardiorespiratory" }
                : refined.secondary
        )
        set(\.equipment, seed.equipment)
        set(\.isUnilateral, false)
        let desiredWeightMode = isCardio
            ? WeightMode.bodyweight
            : weightMode(equipment: seed.equipment, name: seed.name)
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
        }
        return modelChanged
    }

    // MARK: - Muscle picker taxonomy

    /// Recognized training targets for exercise filters and classification.
    /// `hips` and `spine` remain recognized as legacy stored regions below,
    /// but new exercises use anatomically meaningful muscle groups instead.
    static let muscleGroups = [
        "abdominals", "abductors", "adductors", "back", "biceps", "calves",
        "cardiovascular", "chest", "forearms", "glutes", "hamstrings", "hip flexors",
        "lats", "lower back", "middle back", "neck", "obliques", "quadriceps",
        "shoulders", "traps", "triceps", "upper back",
    ]

    /// Assignment excludes Cardiovascular because it is a training-system
    /// category, not a muscle. Cardio exercises derive that target from their
    /// modality; filters and classification still retain it above.
    static let selectableMuscleGroups = muscleGroups.filter { $0 != "cardiovascular" }

    /// Old yoga and custom-exercise data can still be read and displayed. The
    /// values are intentionally absent from new-exercise picker choices.
    static let legacyMuscleRegions = ["hips", "spine"]

    static let recognizedMuscleTags = Set(
        muscleGroups + legacyMuscleRegions + MuscleTaxonomy.children.values.flatMap { $0 }
    )

    /// Broad taxonomy parents drill down to their existing children. Hips is
    /// a navigation-only grouping: it exposes concrete targets but cannot be
    /// stored as though it were one muscle.
    static let muscleHierarchy = makeMuscleHierarchy(from: muscleGroups)

    static let selectableMuscleHierarchy = makeMuscleHierarchy(from: selectableMuscleGroups)

    private static func makeMuscleHierarchy(
        from muscles: [String]
    ) -> [ExerciseMusclePickerEntry] {
        let hipChildren = ["abductors", "adductors", "glutes", "hip flexors"]
        let hipChildSet = Set(hipChildren)
        var seen = Set<String>()
        var result: [ExerciseMusclePickerEntry] = []
        for muscle in muscles where !hipChildSet.contains(muscle) {
            let parent = MuscleTaxonomy.parent(of: muscle)
            guard seen.insert(parent).inserted else { continue }
            result.append(ExerciseMusclePickerEntry(
                group: parent,
                children: alphabeticallySorted(MuscleTaxonomy.children[parent] ?? []),
                allowsGroupSelection: true
            ))
        }
        result.append(ExerciseMusclePickerEntry(
            group: "hips",
            children: alphabeticallySorted(hipChildren),
            allowsGroupSelection: false
        ))
        return result.sorted { displayComesBefore($0.group, $1.group) }
    }

    nonisolated private static func alphabeticallySorted(_ muscles: [String]) -> [String] {
        muscles.sorted(by: displayComesBefore)
    }

    nonisolated private static func displayComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        MuscleTaxonomy.displayName(lhs).localizedStandardCompare(
            MuscleTaxonomy.displayName(rhs)
        ) == .orderedAscending
    }

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

/// Exercise illustration with a graceful icon fallback: the user's own photo
/// when they added one, then the bundled illustration, then an icon.
/// Illustrations sit on a light plate so they read on the dark theme.
struct ExerciseThumbnail: View {
    @Environment(\.theme) private var theme
    let exercise: ExerciseLibraryModel
    var size: CGFloat = 46

    #if canImport(UIKit)
    /// Primed asynchronously — rows show the icon placeholder for a frame or
    /// two on first scroll instead of decoding JPEGs on the main thread.
    @State private var loadedThumbnail: UIImage?
    @State private var userPhoto: UIImage?
    private var media: CustomExerciseMedia { CustomExerciseMedia.shared }
    #endif

    var body: some View {
        ZStack {
            #if canImport(UIKit)
            // A photo the user took of the machine they actually use beats any
            // stock illustration of it, so it wins everywhere — including for
            // a pose, whose art is generic by definition.
            if let image = media.cachedThumbnail(for: exercise.id) ?? userPhoto {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .background(Color(white: 0.96))
                    // A row that sets its own identifier (the routine card
                    // does) overrides a child's, so identity also rides on the
                    // label — which is worth saying out loud anyway: it tells
                    // a VoiceOver user this exercise carries their own photo
                    // rather than stock art. Kept to two words; the row's own
                    // label already names the exercise.
                    .accessibilityIdentifier("exercise-photo-thumbnail")
                    .accessibilityLabel("Your photo")
            } else if exercise.isYoga {
                yogaArt
            } else if let image = ExerciseCatalog.cachedThumbnail(path: exercise.mediaSlug) ?? loadedThumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .background(Color(white: 0.96))
            } else {
                fallback
                    .task(id: exercise.mediaSlug) {
                        guard let primed = await ExerciseCatalog.primeThumbnail(path: exercise.mediaSlug) else { return }
                        withAnimation(.easeIn(duration: 0.15)) { loadedThumbnail = primed }
                    }
            }
            #else
            if exercise.isYoga { yogaArt } else { fallback }
            #endif
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        #if canImport(UIKit)
        // Keyed on the store's revision as well as the exercise, so adding or
        // removing a photo repaints every row already on screen.
        .task(id: "\(exercise.id)-\(media.revision)") {
            let primed = await media.primeThumbnail(for: exercise.id, maxPixelSize: size * 3)
            guard primed != nil || userPhoto != nil else { return }
            withAnimation(.easeIn(duration: 0.15)) { userPhoto = primed }
        }
        #endif
    }

    /// Pose photo for the selected instructor, with authored line art as the
    /// instantaneous loading and custom-pose fallback.
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
                .foregroundStyle(theme.accentForeground)
        }
    }
}
