import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// The change-feed half of the sync pipeline, end to end against a real
/// SwiftData container: a plain `context.save()` — no explicit sync call
/// anywhere — must flow through `SyncCoordinator`'s save observer, route to
/// the outbox, and land on (or leave) the backend. Debounce is zero so each
/// test drives one save and awaits the pipeline settling.
@MainActor
@Suite struct SyncCoordinatorTests {

    private struct Pipeline {
        let container: ModelContainer
        let context: ModelContext
        let backend: InstrumentedSocialBackend
        let service: SocialService
        let coordinator: SyncCoordinator
    }

    private let userID = UUID()

    private func makePipeline(_ name: String) async throws -> Pipeline {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let backend = InstrumentedSocialBackend()
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let service = SocialService(backend: backend, isDemo: false, defaults: defaults)
        try await service.optIn(
            handle: "james", displayName: "James", visibility: .everyone,
            stats: ProfileSnapshot(totalXP: 0, workoutCount: 0, lifetimeHours: 0, stats: SocialStats(), now: Date(timeIntervalSince1970: 1_700_000_000))
        )
        let coordinator = SyncCoordinator(social: service, container: container, debounce: .zero)
        coordinator.start(monitorConnectivity: false)
        return Pipeline(container: container, context: context, backend: backend, service: service, coordinator: coordinator)
    }

    /// Drives the main-actor queue until `condition` holds (bounded — a
    /// broken pipeline fails fast instead of hanging the suite).
    private func settles(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await condition() { return true }
            await Task.yield()
        }
        return await condition()
    }

    private func remoteRefs(_ backend: InstrumentedSocialBackend) async -> [SocialWorkoutRef] {
        await backend.inner.recentWorkouts(for: SocialUserID("me"), limit: 100, before: nil)
    }

    private func insertFinishedWorkout(in context: ModelContext, endedAt: Date = .now) -> WorkoutModel {
        let workout = WorkoutModel(
            userID: userID,
            startedAt: endedAt.addingTimeInterval(-3600),
            endedAt: endedAt,
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [SetModel(userID: userID, position: 0)])]
        )
        context.insert(workout)
        return workout
    }

    @Test func finishedWorkoutSaveFlowsToTheCommunity() async throws {
        let pipeline = try await makePipeline("sync-pipeline-finish")
        defer { _ = pipeline.container }

        let workout = insertFinishedWorkout(in: pipeline.context)
        try pipeline.context.save()

        let published = await settles { await remoteRefs(pipeline.backend).map(\.id) == [workout.id] }
        #expect(published, "a finished workout's save alone must publish the share")
        // The share is ordered by training time, not upload time.
        #expect(await remoteRefs(pipeline.backend).first?.publishedAt == workout.endedAt)
    }

    @Test func softDeleteSaveWithdrawsTheShare() async throws {
        let pipeline = try await makePipeline("sync-pipeline-delete")
        defer { _ = pipeline.container }
        let workout = insertFinishedWorkout(in: pipeline.context)
        try pipeline.context.save()
        #expect(await settles { await !remoteRefs(pipeline.backend).isEmpty })

        workout.updatedAt = Date()
        workout.deletedAt = Date()
        try pipeline.context.save()

        let withdrawn = await settles { await remoteRefs(pipeline.backend).isEmpty }
        #expect(withdrawn, "soft-deleting a shared workout must unpublish it")
    }

    @Test func childSetEditRepublishesWithAdvancedWatermark() async throws {
        let pipeline = try await makePipeline("sync-pipeline-edit")
        defer { _ = pipeline.container }
        let workout = insertFinishedWorkout(in: pipeline.context)
        try pipeline.context.save()
        #expect(await settles { await !remoteRefs(pipeline.backend).isEmpty })
        let firstWatermark = try #require(await remoteRefs(pipeline.backend).first?.sourceUpdatedAt)

        // Edit a SET — three relationship hops from the workout. Only the
        // change feed connects this save to the share.
        let set = try #require(workout.exercises.first?.sets.first)
        set.reps = 8
        set.updatedAt = Date()
        try pipeline.context.save()

        let republished = await settles {
            guard let mark = await remoteRefs(pipeline.backend).first?.sourceUpdatedAt else { return false }
            return mark > firstWatermark
        }
        #expect(republished, "a child-row edit must republish the workout with an advanced watermark")
        // Republishing refreshed content in place — the order key held still.
        #expect(await remoteRefs(pipeline.backend).first?.publishedAt == workout.endedAt)
    }

    @Test func importedAndInProgressWorkoutsNeverPublish() async throws {
        let pipeline = try await makePipeline("sync-pipeline-ineligible")
        defer { _ = pipeline.container }

        let imported = insertFinishedWorkout(in: pipeline.context)
        imported.importBatchID = UUID()
        let inProgress = insertFinishedWorkout(in: pipeline.context)
        inProgress.endedAt = nil
        // The live one proves the pipeline ran for this same save.
        let live = insertFinishedWorkout(in: pipeline.context)
        try pipeline.context.save()

        let settled = await settles { await remoteRefs(pipeline.backend).map(\.id) == [live.id] }
        #expect(settled, "only the live completed workout may publish — imported and in-progress stay local")
    }
}
