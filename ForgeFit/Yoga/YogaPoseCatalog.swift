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
    /// Sequencing role for the flow generator (warmup/standing/…/resting).
    /// Optional so older bundles without it still decode.
    let category: String?
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
    nonisolated private static let idNamespace = "yoga/"
    nonisolated private static let aliasIDNamespace = "yoga-alias/"
    nonisolated static let sessionExerciseSlug = "session"
    nonisolated static let sessionMediaSlug = idNamespace + sessionExerciseSlug
    nonisolated static let sessionExerciseID = ExerciseCatalog.deterministicID(for: sessionMediaSlug)

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

    nonisolated static func isSessionExercise(_ exercise: ExerciseLibraryModel?) -> Bool {
        guard let exercise else { return false }
        return exercise.id == sessionExerciseID || exercise.mediaSlug == sessionMediaSlug
    }

    /// Stable UUID for a pose slug — same scheme as the exercise catalog,
    /// under a `yoga/` namespace.
    static func id(forSlug slug: String) -> UUID {
        ExerciseCatalog.deterministicID(for: idNamespace + slug)
    }

    /// The catalog slug a library row was seeded from ("yoga/<slug>" is
    /// stored in `mediaSlug`); nil for custom poses.
    nonisolated static func slug(for exercise: ExerciseLibraryModel) -> String? {
        guard let mediaSlug = exercise.mediaSlug, mediaSlug.hasPrefix(idNamespace) else { return nil }
        return String(mediaSlug.dropFirst(idNamespace.count))
    }

    @MainActor
    static func sessionExercise(in context: ModelContext) -> ExerciseLibraryModel {
        let existing = ((try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? [])
            .first { isSessionExercise($0) }
        let model = existing ?? ExerciseLibraryModel(id: sessionExerciseID, name: "Yoga Session")
        if existing == nil {
            context.insert(model)
        }
        upsertSessionFields(on: model)
        return model
    }

    /// Slugs of poses that ship with a real illustration. The bundled catalog
    /// only carries poses we can show properly, so this currently equals the
    /// full pose list — but it's the single source of truth for "do we have
    /// art for this pose," used to prune poses dropped from the catalog.
    static var catalogSlugs: Set<String> { Set(load().map(\.slug)) }

    /// Remove yoga poses that used to be seeded but are no longer in the
    /// bundled catalog (e.g. poses without finished artwork that were trimmed
    /// out). Only touches ForgeFit's own seeded rows — identified by the
    /// `yoga/<slug>` media slug — and never user-created or user-modified
    /// poses. CloudKit-safe: deletions sync like any other. Idempotent.
    @MainActor
    static func pruneUnavailablePoses(into context: ModelContext) {
        let validIDs = Set(catalogSlugs.map { id(forSlug: $0) }).union([sessionExerciseID])
        let rows = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let staleRows = rows.filter { row in
            guard let media = row.mediaSlug, media.hasPrefix(idNamespace) else { return false }
            return !validIDs.contains(row.id) && !row.userModified
        }
        guard !staleRows.isEmpty else { return }

        let staleIDs = Set(staleRows.map(\.id))
        let aliases = (try? context.fetch(FetchDescriptor<ExerciseAliasModel>())) ?? []
        for alias in aliases where staleIDs.contains(alias.exerciseID) {
            context.delete(alias)
        }
        for row in staleRows {
            context.delete(row)
        }
        try? context.save()
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
        let session = existingByID[sessionExerciseID] ?? ExerciseLibraryModel(id: sessionExerciseID, name: "Yoga Session")
        if existingByID[sessionExerciseID] == nil {
            context.insert(session)
            changed += 1
        }
        if upsertSessionFields(on: session) {
            changed += 1
        }

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

    @MainActor
    @discardableResult
    private static func upsertSessionFields(on model: ExerciseLibraryModel) -> Bool {
        guard !model.userModified else { return false }
        var changed = false
        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<ExerciseLibraryModel, Value>, _ value: Value) {
            guard model[keyPath: keyPath] != value else { return }
            model[keyPath: keyPath] = value
            changed = true
        }

        set(\.ownerID, nil)
        set(\.name, "Yoga Session")
        set(\.modalityRaw, Modality.yoga.rawValue)
        set(\.isCardio, false)
        set(\.movementPattern, "yoga")
        set(\.category, "yoga")
        set(\.primaryMuscles, ["spine", "hips", "shoulders"])
        set(\.secondaryMuscles, ["hamstrings", "quadriceps", "chest"])
        set(\.equipment, "body only")
        set(\.isUnilateral, false)
        set(\.difficulty, "beginner")
        set(\.defaultHoldSeconds, nil)
        set(\.mediaSlug, sessionMediaSlug)
        set(\.instructions, [
            "Configure this session with poses or a curated flow.",
            "Follow the guided player for visual pose reference, spoken cues, and timing."
        ])
        if model.defaultWeightMode != .bodyweight {
            model.defaultWeightMode = .bodyweight
            changed = true
        }
        if changed { model.updatedAt = Date() }
        return changed
    }
}
