import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One row of the bundled `yoga_poses.json` — ForgeFit's own authored pose
/// library (names and sequences aren't copyrightable; the cue scripts and
/// illustrations are ours). The pose's *dynamic* identity (name, target
/// regions, hold default) is seeded into `ExerciseLibraryModel` rows; the
/// *static* class content (Sanskrit name, spoken cues, contraindications)
/// stays in this catalog, looked up by slug, so it never bloats CloudKit.
struct YogaPoseSeed: Decodable {
    struct Cues: Decodable {
        let entry: [String]
        let hold: [String]
        let exit: String
    }

    let slug: String
    let name: String
    let sanskrit: String
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let unilateral: Bool
    let difficulty: String
    let defaultHoldSeconds: Int
    /// SF Symbol used until dedicated line-art ships; the art pipeline looks
    /// for an asset named `yoga_<slug>` first and falls back to this.
    let symbol: String
    let cues: Cues
    /// Seconds per breath phase, for spoken "inhale… exhale" pacing.
    let breathCadence: Int
    let contraindications: [String]
}

enum YogaPoseCatalog {
    /// Namespace prefixed onto slugs before hashing so pose IDs can never
    /// collide with the free-exercise-db catalog's slug-derived IDs.
    private static let idNamespace = "yoga/"
    private static let aliasIDNamespace = "yoga-alias/"

    private static var cached: [YogaPoseSeed]?

    static func load() -> [YogaPoseSeed] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "yoga_poses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([YogaPoseSeed].self, from: data) else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    private static var bySlug: [String: YogaPoseSeed] {
        Dictionary(load().map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func pose(forSlug slug: String?) -> YogaPoseSeed? {
        guard let slug else { return nil }
        return bySlug[slug]
    }

    /// Stable UUID for a pose slug — same scheme as the exercise catalog,
    /// under a `yoga/` namespace.
    static func id(forSlug slug: String) -> UUID {
        ExerciseCatalog.deterministicID(for: idNamespace + slug)
    }

    /// The catalog slug a library row was seeded from ("yoga/<slug>" is
    /// stored in `mediaSlug`); nil for custom poses.
    static func slug(for exercise: ExerciseLibraryModel) -> String? {
        guard let mediaSlug = exercise.mediaSlug, mediaSlug.hasPrefix(idNamespace) else { return nil }
        return String(mediaSlug.dropFirst(idNamespace.count))
    }

    /// Insert or update the pose library. Idempotent; respects `userModified`
    /// the same way `ExerciseCatalog.seed` does.
    @MainActor
    static func seed(into context: ModelContext) {
        let seeds = load()
        guard !seeds.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let aliases = (try? context.fetch(FetchDescriptor<ExerciseAliasModel>())) ?? []
        let aliasesByID = Dictionary(
            aliases.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var changed = 0
        for seed in seeds {
            let id = id(forSlug: seed.slug)
            let model = existingByID[id] ?? ExerciseLibraryModel(id: id, name: seed.name)
            var modelChanged = false

            // Alias upsert runs for every pose — including user-modified ones,
            // whose ATTRIBUTES are protected but whose Sanskrit search alias
            // should still exist/heal.
            let aliasID = ExerciseCatalog.deterministicID(for: aliasIDNamespace + seed.slug)
            if let alias = aliasesByID[aliasID] {
                if alias.alias != seed.sanskrit || alias.exerciseID != id {
                    alias.alias = seed.sanskrit
                    alias.exerciseID = id
                    changed += 1
                }
            } else {
                context.insert(ExerciseAliasModel(id: aliasID, exerciseID: id, alias: seed.sanskrit))
                changed += 1
            }

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
            set(\.modalityRaw, Modality.yoga.rawValue)
            set(\.isCardio, false)
            set(\.movementPattern, "yoga")
            set(\.category, "yoga")
            set(\.primaryMuscles, seed.primaryMuscles)
            set(\.secondaryMuscles, seed.secondaryMuscles)
            set(\.equipment, "body only")
            set(\.isUnilateral, seed.unilateral)
            set(\.difficulty, seed.difficulty)
            set(\.defaultHoldSeconds, seed.defaultHoldSeconds)
            // "yoga/<slug>" both links the row back to this catalog and maps
            // to the future art asset name (yoga_<slug>).
            set(\.mediaSlug, idNamespace + seed.slug)
            set(\.instructions, seed.cues.entry + seed.cues.hold + [seed.cues.exit])
            if model.defaultWeightMode != .bodyweight {
                model.defaultWeightMode = .bodyweight
                modelChanged = true
            }

            if modelChanged {
                model.updatedAt = Date()
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
    }
}
