import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One row of the bundled `yoga_poses.json` — ForgeFit's own authored pose
/// library (names and sequences aren't copyrightable; the cue scripts and
/// illustrations are ours). The pose's *dynamic* identity (name, target
/// regions, hold default) is seeded into `ExerciseLibraryModel` rows; the
/// *static* class content stays in the app bundle, looked up by slug, so it
/// never bloats CloudKit. `cues` and `contraindications` remain here only for
/// decoding the original catalog schema; guided classes use the separately
/// reviewed `yoga_guidance.json` content.
nonisolated struct YogaPoseSeed: Decodable, Sendable {
    nonisolated struct Cues: Decodable, Sendable {
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
    /// Final fallback when neither a bundled instructor photo nor authored
    /// line art is available.
    let symbol: String
    let cues: Cues
    /// Seconds per breath phase, for spoken "inhale… exhale" pacing.
    let breathCadence: Int
    let contraindications: [String]
}

/// Immutable projection consumed by the isolated persistence worker. Reviewed
/// guidance is resolved before crossing actors so no MainActor-owned catalog
/// cache or SwiftData model ever enters the detached transaction.
private nonisolated struct YogaPosePersistenceSeed: Sendable {
    let slug: String
    let name: String
    let sanskrit: String
    let primaryMuscles: [String]
    let secondaryMuscles: [String]
    let unilateral: Bool
    let difficulty: String
    let defaultHoldSeconds: Int
    let instructions: [String]
}

enum YogaPoseCatalog {
    nonisolated enum PersistenceError: LocalizedError, Sendable {
        case bundledCatalogUnavailable

        var errorDescription: String? {
            "ForgeFit couldn't load its bundled yoga pose catalog."
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

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
        let decoded = decodeBundledSeeds()
        cached = decoded
        return decoded
    }

    /// Bundle I/O and JSON decoding are pure value work. Keep the cache itself
    /// MainActor-owned, but allow launch to populate it without blocking a
    /// frame.
    private nonisolated static func decodeBundledSeeds() -> [YogaPoseSeed] {
        guard let url = Bundle.main.url(forResource: "yoga_poses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([YogaPoseSeed].self, from: data) else {
            return []
        }
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
    nonisolated static func id(forSlug slug: String) -> UUID {
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

    /// Slugs of poses that ship with complete female and male instructor art.
    /// The bundled catalog only carries poses we can show properly, so this
    /// currently equals the full pose list and drives stale-pose pruning.
    static var catalogSlugs: Set<String> { Set(load().map(\.slug)) }

    /// Launch-only seed + prune transaction. The caller keeps its existing
    /// MainActor context while a fresh worker context performs both full-table
    /// reads, every model mutation, and the single durable save off-main.
    /// Cancellation rolls the unsaved worker context back, so a cancelled
    /// launch cannot leave a half-seeded catalog.
    @MainActor
    static func seedAndPruneCooperatively(into context: ModelContext) async throws {
        try Task.checkCancellation()

        let seeds: [YogaPoseSeed]
        if let cached {
            seeds = cached
        } else {
            let decodeTask = Task.detached(priority: .userInitiated) {
                decodeBundledSeeds()
            }
            let decoded = await withTaskCancellationHandler(
                operation: { await decodeTask.value },
                onCancel: { decodeTask.cancel() }
            )
            try Task.checkCancellation()
            cached = decoded
            seeds = decoded
        }
        guard !seeds.isEmpty else { throw PersistenceError.bundledCatalogUnavailable }

        let persistenceSeeds = persistenceSeeds(from: seeds)
        let container = context.container
        let task = Task.detached(priority: .utility) {
            try seedAndPrunePersisted(persistenceSeeds, in: container)
        }
        try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    /// Remove yoga poses that used to be seeded but are no longer in the
    /// bundled catalog (e.g. poses without finished artwork that were trimmed
    /// out). Only touches ForgeFit's own seeded rows — identified by the
    /// `yoga/<slug>` media slug — and never user-created or user-modified
    /// poses. CloudKit-safe: deletions sync like any other. Idempotent.
    @MainActor
    static func pruneUnavailablePoses(
        into context: ModelContext,
        persist: Bool = true,
        save: @escaping SaveOperation = { try $0.save() }
    ) throws {
        let transaction = persist ? ModelContext(context.container) : context
        if persist { transaction.autosaveEnabled = false }
        let validIDs = Set(catalogSlugs.map { id(forSlug: $0) }).union([sessionExerciseID])
        let rows = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let aliases = try transaction.fetch(FetchDescriptor<ExerciseAliasModel>())
        let changed = try stagePrune(
            validIDs: validIDs,
            existing: rows,
            aliases: aliases,
            in: transaction
        )
        if persist, changed > 0 {
            do {
                try save(transaction)
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    /// Insert or update the pose library. Idempotent; respects `userModified`
    /// the same way `ExerciseCatalog.seed` does.
    @MainActor
    static func seed(
        into context: ModelContext,
        persist: Bool = true,
        save: @escaping SaveOperation = { try $0.save() }
    ) throws {
        let transaction = persist ? ModelContext(context.container) : context
        if persist { transaction.autosaveEnabled = false }
        let decodedSeeds = load()
        guard !decodedSeeds.isEmpty else { throw PersistenceError.bundledCatalogUnavailable }
        let seeds = persistenceSeeds(from: decodedSeeds)

        let existing = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let aliases = try transaction.fetch(FetchDescriptor<ExerciseAliasModel>())
        let changed = try stageSeed(
            seeds,
            existing: existing,
            aliases: aliases,
            in: transaction
        )
        if persist, changed > 0 {
            do {
                try save(transaction)
            } catch {
                transaction.rollback()
                throw error
            }
        }
    }

    private static func persistenceSeeds(
        from seeds: [YogaPoseSeed]
    ) -> [YogaPosePersistenceSeed] {
        seeds.map { seed in
            let reviewedInstructions = YogaGuidanceCatalog.guidance(forSlug: seed.slug)?
                .cues.technique
                .map { YogaGuidanceCatalog.resolvedForLibrary($0) }
            return YogaPosePersistenceSeed(
                slug: seed.slug,
                name: seed.name,
                sanskrit: seed.sanskrit,
                primaryMuscles: seed.primaryMuscles,
                secondaryMuscles: seed.secondaryMuscles,
                unilateral: seed.unilateral,
                difficulty: seed.difficulty,
                defaultHoldSeconds: seed.defaultHoldSeconds,
                instructions: reviewedInstructions ?? (seed.cues.entry + seed.cues.hold + [seed.cues.exit])
            )
        }
    }

    private nonisolated static func seedAndPrunePersisted(
        _ seeds: [YogaPosePersistenceSeed],
        in container: ModelContainer
    ) throws {
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            try Task.checkCancellation()
            let existing = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>())
            let aliases = try transaction.fetch(FetchDescriptor<ExerciseAliasModel>())
            var changed = try stageSeed(
                seeds,
                existing: existing,
                aliases: aliases,
                in: transaction
            )
            let validIDs = Set(seeds.map { id(forSlug: $0.slug) }).union([sessionExerciseID])
            changed += try stagePrune(
                validIDs: validIDs,
                existing: existing,
                aliases: aliases,
                in: transaction
            )
            try Task.checkCancellation()
            if changed > 0 {
                try transaction.save()
            }
        } catch {
            transaction.rollback()
            throw error
        }
    }

    private nonisolated static func stageSeed(
        _ seeds: [YogaPosePersistenceSeed],
        existing: [ExerciseLibraryModel],
        aliases: [ExerciseAliasModel],
        in transaction: ModelContext
    ) throws -> Int {
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let aliasesByID = Dictionary(
            aliases.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var changed = 0
        let session = existingByID[sessionExerciseID]
            ?? ExerciseLibraryModel(id: sessionExerciseID, name: "Yoga Session")
        if existingByID[sessionExerciseID] == nil {
            transaction.insert(session)
            changed += 1
        }
        if upsertSessionFields(on: session) {
            changed += 1
        }

        for seed in seeds {
            try Task.checkCancellation()
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
                transaction.insert(ExerciseAliasModel(id: aliasID, exerciseID: id, alias: seed.sanskrit))
                changed += 1
            }

            if existingByID[id] == nil {
                transaction.insert(model)
                modelChanged = true
            } else if model.userModified {
                continue
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
            set(\.mediaSlug, idNamespace + seed.slug)
            set(\.instructions, seed.instructions)
            if model.defaultWeightMode != .bodyweight {
                model.defaultWeightMode = .bodyweight
                modelChanged = true
            }

            if modelChanged {
                model.updatedAt = Date()
                changed += 1
            }
        }
        return changed
    }

    private nonisolated static func stagePrune(
        validIDs: Set<UUID>,
        existing: [ExerciseLibraryModel],
        aliases: [ExerciseAliasModel],
        in transaction: ModelContext
    ) throws -> Int {
        let staleRows = existing.filter { row in
            guard let media = row.mediaSlug, media.hasPrefix(idNamespace) else { return false }
            return !validIDs.contains(row.id) && !row.userModified
        }
        guard !staleRows.isEmpty else { return 0 }

        let staleIDs = Set(staleRows.map(\.id))
        var changed = 0
        for alias in aliases where staleIDs.contains(alias.exerciseID) {
            try Task.checkCancellation()
            transaction.delete(alias)
            changed += 1
        }
        for row in staleRows {
            try Task.checkCancellation()
            transaction.delete(row)
            changed += 1
        }
        return changed
    }

    @discardableResult
    private nonisolated static func upsertSessionFields(on model: ExerciseLibraryModel) -> Bool {
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
