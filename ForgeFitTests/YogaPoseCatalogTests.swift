import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// The bundled yoga pose catalog: content integrity, deterministic IDs, and
/// idempotent seeding into the exercise library.
@MainActor
struct YogaPoseCatalogTests {

    /// In-memory container; the caller must retain the container — the
    /// context holds it weakly.
    private func makeContainer() throws -> (ModelContainer, ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    @Test func catalogLoadsAndIsInternallyConsistent() {
        let poses = YogaPoseCatalog.load()
        #expect(poses.count >= 40)

        var slugs = Set<String>()
        for pose in poses {
            #expect(slugs.insert(pose.slug).inserted, "duplicate slug \(pose.slug)")
            #expect(!pose.name.isEmpty)
            #expect(!pose.sanskrit.isEmpty)
            #expect(!pose.primaryMuscles.isEmpty)
            #expect(pose.defaultHoldSeconds > 0)
            #expect(pose.breathCadence > 0)
            #expect(!pose.cues.entry.isEmpty)
            #expect(!pose.cues.hold.isEmpty)
            #expect(!pose.cues.exit.isEmpty)
            // Every region must be a known picker group so filters find poses.
            for muscle in pose.primaryMuscles + pose.secondaryMuscles {
                #expect(ExerciseCatalog.muscleGroups.contains(muscle), "\(pose.slug): unknown region \(muscle)")
            }
        }
    }

    @Test func poseIDsAreNamespacedAndCollisionFree() {
        let poses = YogaPoseCatalog.load()
        var ids = Set<UUID>()
        for pose in poses {
            let id = YogaPoseCatalog.id(forSlug: pose.slug)
            #expect(ids.insert(id).inserted)
            // The yoga/ namespace guarantees no overlap with the exercise
            // catalog's slug-derived IDs.
            #expect(id != ExerciseCatalog.deterministicID(for: pose.slug))
            // Stable across calls.
            #expect(id == YogaPoseCatalog.id(forSlug: pose.slug))
        }
    }

    @Test func seedIsIdempotentAndTagsRowsAsYoga() throws {
        let (container, context) = try makeContainer()

        YogaPoseCatalog.seed(into: context)
        YogaPoseCatalog.seed(into: context)

        let poses = YogaPoseCatalog.load()
        let rows = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let aliases = try context.fetch(FetchDescriptor<ExerciseAliasModel>())
        #expect(rows.count == poses.count)
        #expect(aliases.count == poses.count)

        for row in rows {
            #expect(row.modality == .yoga)
            #expect(row.isYoga)
            #expect(!row.isCardio)
            #expect(row.category == "yoga")
            #expect(row.defaultWeightMode == .bodyweight)
            #expect(row.defaultHoldSeconds != nil)
            #expect(YogaPoseCatalog.slug(for: row) != nil)
        }
        _ = container
    }

    @Test func seedRespectsUserModifiedRows() throws {
        let (container, context) = try makeContainer()
        YogaPoseCatalog.seed(into: context)

        let id = YogaPoseCatalog.id(forSlug: "pigeon-pose")
        let rows = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let pigeon = try #require(rows.first { $0.id == id })
        pigeon.name = "My Pigeon"
        pigeon.userModified = true
        try context.save()

        YogaPoseCatalog.seed(into: context)
        #expect(pigeon.name == "My Pigeon")
        _ = container
    }

    @Test func sanskritAliasResolvesInSearch() throws {
        let (container, context) = try makeContainer()
        YogaPoseCatalog.seed(into: context)

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).map(\.domainInfo)
        let aliases = try context.fetch(FetchDescriptor<ExerciseAliasModel>()).map(\.domainAlias)
        let snapshot = ExerciseLibrarySnapshot(exercises: exercises, aliases: aliases)

        let result = try #require(snapshot.search("Balasana").first)
        #expect(result.exercise.id == YogaPoseCatalog.id(forSlug: "childs-pose"))
        _ = container
    }

    /// Yoga poses and free-exercise-db stretches with similar names get
    /// different deterministic IDs, so the launch deduplicator never groups
    /// (and never merges) them.
    @Test func yogaPosesSurviveDeduplicationAlongsideStretches() throws {
        let (container, context) = try makeContainer()

        // Simulate the free-exercise-db "Child's Pose" stretching row.
        let stretchRow = ExerciseLibraryModel(
            id: ExerciseCatalog.deterministicID(for: "Childs_Pose"),
            name: "Child's Pose"
        )
        stretchRow.category = "stretching"
        context.insert(stretchRow)
        YogaPoseCatalog.seed(into: context)
        try context.save()

        let summary = try ExerciseLibraryDeduplicator.removeDuplicates(in: context)
        #expect(summary.isEmpty)

        let rows = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let childs = rows.filter { $0.name.localizedCaseInsensitiveContains("child") }
        #expect(childs.count == 2)
        _ = container
    }
}
