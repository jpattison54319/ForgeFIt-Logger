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

    @Test func catalogLoadsAndIsInternallyConsistent() {
        let poses = YogaPoseCatalog.load()
        // The catalog ships only fully-illustrated poses; every one must have
        // a bundled `yoga_pose_<slug>` image asset (checked in-app), so the
        // count tracks the illustrated set rather than a large target.
        #expect(poses.count >= 12)

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

    /// The guided player must show every catalog pose graphically — the
    /// line-art figure catalog can never fall behind the pose catalog.
    @Test func everyPoseHasALineArtFigure() {
        let poses = YogaPoseCatalog.load()
        let figures = YogaPoseFigureCatalog.load()
        #expect(!figures.isEmpty)

        for pose in poses {
            guard let figure = figures[pose.slug] else {
                Issue.record("\(pose.slug): no line-art figure — add it to yoga_pose_figures.json")
                continue
            }
            // A head and at least a torso + two limbs; all geometry inside
            // the 100×100 authoring space.
            #expect(figure.head.count == 3, "\(pose.slug): head must be [cx, cy, r]")
            #expect(figure.lines.count >= 3, "\(pose.slug): too few limb lines to depict a body")
            for line in figure.lines {
                #expect(line.count >= 2, "\(pose.slug): degenerate polyline")
                for point in line {
                    #expect(point.count == 2, "\(pose.slug): point must be [x, y]")
                    for value in point {
                        #expect(value >= 0 && value <= YogaPoseFigure.space, "\(pose.slug): point out of bounds")
                    }
                }
            }
            if let ground = figure.ground {
                #expect(ground.count == 3, "\(pose.slug): ground must be [x1, x2, y]")
            }
        }

        // No orphans: a figure for a slug that left the catalog is stale.
        let poseSlugs = Set(poses.map(\.slug))
        for slug in figures.keys {
            #expect(poseSlugs.contains(slug), "figure \(slug) has no catalog pose")
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
        let (container, context) = try TestStore.make()

        YogaPoseCatalog.seed(into: context)
        YogaPoseCatalog.seed(into: context)

        let poses = YogaPoseCatalog.load()
        let rows = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let aliases = try context.fetch(FetchDescriptor<ExerciseAliasModel>())
        #expect(rows.count == poses.count + 1)
        #expect(aliases.count == poses.count)

        let session = try #require(rows.first { YogaPoseCatalog.isSessionExercise($0) })
        #expect(session.name == "Yoga Session")
        #expect(session.defaultHoldSeconds == nil)

        for row in rows {
            #expect(row.modality == .yoga)
            #expect(row.isYoga)
            #expect(!row.isCardio)
            #expect(row.category == "yoga")
            #expect(row.defaultWeightMode == .bodyweight)
            if !YogaPoseCatalog.isSessionExercise(row) {
                #expect(row.defaultHoldSeconds != nil)
                #expect(YogaPoseCatalog.slug(for: row) != nil)
            }
        }
        _ = container
    }

    @Test func seedRespectsUserModifiedRows() throws {
        let (container, context) = try TestStore.make()
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
        let (container, context) = try TestStore.make()
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
        let (container, context) = try TestStore.make()

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

    /// Every built-in flow must reference only poses that exist in the trimmed
    /// catalog — otherwise the player would silently drop steps.
    @Test func builtInFlowsReferenceOnlyCatalogPoses() {
        let catalog = YogaPoseCatalog.catalogSlugs
        let flows = YogaFlowCatalog.load()
        #expect(!flows.isEmpty)
        for flow in flows {
            #expect(!flow.steps.isEmpty, "\(flow.slug) has no steps")
            for step in flow.steps {
                #expect(catalog.contains(step.poseSlug),
                        "\(flow.slug): pose \(step.poseSlug) is not in the catalog")
            }
            // Resolving the plan must keep every step (none dropped).
            let plan = YogaFlowCatalog.plan(for: flow)
            #expect(plan.steps.count == flow.steps.count, "\(flow.slug): a step failed to resolve")
        }
    }

    /// Poses seeded from an older, larger catalog are pruned on launch, while
    /// current poses, the session anchor, user-created poses, and
    /// user-modified rows all survive.
    @Test func pruneRemovesDeprecatedPosesOnly() throws {
        let (container, context) = try TestStore.make()
        YogaPoseCatalog.seed(into: context)

        // A pose from a previous catalog version (no longer bundled).
        let deprecatedSlug = "eagle-pose"
        #expect(!YogaPoseCatalog.catalogSlugs.contains(deprecatedSlug),
                "test premise broken: \(deprecatedSlug) is back in the catalog — pick another deprecated slug")
        let deprecatedID = YogaPoseCatalog.id(forSlug: deprecatedSlug)
        let deprecated = ExerciseLibraryModel(id: deprecatedID, name: "Eagle Pose")
        deprecated.mediaSlug = "yoga/eagle-pose"
        deprecated.modalityRaw = Modality.yoga.rawValue
        context.insert(deprecated)
        context.insert(ExerciseAliasModel(
            id: ExerciseCatalog.deterministicID(for: "yoga-alias/eagle-pose"),
            exerciseID: deprecatedID,
            alias: "Garudasana"
        ))

        // A user-modified deprecated pose — must be preserved.
        let keptCustomID = YogaPoseCatalog.id(forSlug: "goddess-pose")
        let keptCustom = ExerciseLibraryModel(id: keptCustomID, name: "My Goddess")
        keptCustom.mediaSlug = "yoga/goddess-pose"
        keptCustom.userModified = true
        context.insert(keptCustom)

        // A user-created pose (no catalog media slug) — must be preserved.
        let userPose = ExerciseLibraryModel(id: UUID(), name: "My Own Pose")
        userPose.modalityRaw = Modality.yoga.rawValue
        context.insert(userPose)
        try context.save()

        YogaPoseCatalog.pruneUnavailablePoses(into: context)

        let rows = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let ids = Set(rows.map(\.id))
        #expect(!ids.contains(deprecatedID), "deprecated pose should be pruned")
        #expect(ids.contains(keptCustomID), "user-modified pose should survive")
        #expect(ids.contains(userPose.id), "user-created pose should survive")
        #expect(rows.contains { YogaPoseCatalog.isSessionExercise($0) }, "session anchor should survive")
        // Every remaining catalog pose is still present.
        for slug in YogaPoseCatalog.catalogSlugs {
            #expect(ids.contains(YogaPoseCatalog.id(forSlug: slug)))
        }
        // The orphaned alias for the pruned pose is gone.
        let aliases = try context.fetch(FetchDescriptor<ExerciseAliasModel>())
        #expect(!aliases.contains { $0.exerciseID == deprecatedID })

        // Idempotent: a second prune changes nothing.
        let before = rows.count
        YogaPoseCatalog.pruneUnavailablePoses(into: context)
        let after = try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).count
        #expect(after == before)
        _ = container
    }
}
