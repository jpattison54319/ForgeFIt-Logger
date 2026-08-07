import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// The share sync pipeline's service half: which workouts qualify
/// (`SocialBackfill`), the durable outbox (`enqueueShare`/`drainShareOutbox`),
/// and the anti-entropy converge pass (`reconcileSharedWorkouts`). Runs
/// entirely against mocks — the CloudKit path can't run in the simulator.
@MainActor
@Suite struct SocialBackfillTests {

    private let userID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// A completed ForgeFit strength workout with one exercise.
    private func liveWorkout(endedAt: Date) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            startedAt: endedAt.addingTimeInterval(-3600),
            endedAt: endedAt,
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID())]
        )
    }

    // MARK: - Eligibility

    @Test func onlyCompletedNonImportedForgeFitWorkoutsQualify() {
        let live = liveWorkout(endedAt: epoch)

        let unfinished = liveWorkout(endedAt: epoch)
        unfinished.endedAt = nil

        let deleted = liveWorkout(endedAt: epoch)
        deleted.deletedAt = epoch

        let empty = WorkoutModel(userID: userID, endedAt: epoch)

        // One workout per import channel — every provenance marker excludes.
        let csvImport = liveWorkout(endedAt: epoch)
        csvImport.importBatchID = UUID()
        let fingerprinted = liveWorkout(endedAt: epoch)
        fingerprinted.importFingerprint = "hevy|bench|123"
        let external = liveWorkout(endedAt: epoch)
        external.externalSource = "hevy"
        let healthKit = liveWorkout(endedAt: epoch)
        healthKit.sourceDevice = "healthkit-import"

        // A live workout logged from the watch stays eligible: `sourceDevice`
        // only excludes when it marks an import channel.
        let watch = liveWorkout(endedAt: epoch.addingTimeInterval(60))
        watch.sourceDevice = "apple-watch"

        let all = [live, unfinished, deleted, empty, csvImport, fingerprinted, external, healthKit, watch]
        let items = SocialBackfill.items(from: all, exerciseNames: [:])
        #expect(items.map(\.dto.id) == [live.id, watch.id])

        // The filter-only view agrees with the item builder (modulo the
        // empty-content rule, which needs the mapped DTO to evaluate).
        #expect(SocialBackfill.eligibleWorkouts(all).map(\.id) == [live.id, empty.id, watch.id])
    }

    @Test func itemsStampTrainingOrderAndTheLocalClock() {
        let ended = epoch.addingTimeInterval(12345)
        let workout = liveWorkout(endedAt: ended)
        workout.updatedAt = ended.addingTimeInterval(999)

        let items = SocialBackfill.items(from: [workout], exerciseNames: [:])

        #expect(items.count == 1)
        // publishedAt = end time → profiles read in training order.
        #expect(items[0].publishedAt == ended)
        // sourceUpdatedAt = the local clock → the drift watermark.
        #expect(items[0].sourceUpdatedAt == workout.updatedAt)
        #expect(items[0].summary.kind == "strength")
    }

    // MARK: - Harness

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func snapshot() -> ProfileSnapshot {
        ProfileSnapshot(totalXP: 0, workoutCount: 0, lifetimeHours: 0, stats: SocialStats(), now: epoch)
    }

    private func dto(_ id: UUID, minute: Int) -> SharedWorkoutDTO {
        SharedWorkoutDTO(
            id: id, title: "W\(minute)",
            startedAt: epoch, endedAt: epoch.addingTimeInterval(Double(minute) * 60), exercises: []
        )
    }

    private func item(_ id: UUID, minute: Int, updatedAt: Date? = nil) -> SocialBackfillItem {
        let dto = dto(id, minute: minute)
        return SocialBackfillItem(
            dto: dto, summary: dto.summary,
            publishedAt: dto.endedAt!, sourceUpdatedAt: updatedAt ?? dto.endedAt!
        )
    }

    private func stamp(_ id: UUID, at date: Date) -> SocialShareStamp {
        SocialShareStamp(id: id, updatedAt: date)
    }

    private func makeService(_ backend: some SocialBackend, defaultsName: String) async throws -> (SocialService, UserDefaults) {
        let defaults = isolatedDefaults(defaultsName)
        let service = SocialService(backend: backend, isDemo: false, defaults: defaults)
        try await service.optIn(handle: "james", displayName: "James", visibility: .everyone, stats: snapshot())
        return (service, defaults)
    }

    private func remoteRefs(_ backend: InstrumentedSocialBackend) async -> [SocialWorkoutRef] {
        await backend.inner.recentWorkouts(for: SocialUserID("me"), limit: 1000, before: nil)
    }

    private func remoteIDs(_ backend: InstrumentedSocialBackend) async -> Set<UUID> {
        Set(await remoteRefs(backend).map(\.id))
    }

    private func outbox(in defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: SocialService.shareOutboxKey) as? [String: String] ?? [:]
    }

    // MARK: - Outbox contract

    @Test func unpublishIsTerminalOverQueuedPublish() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, defaults) = try await makeService(backend, defaultsName: "outbox-terminal")
        let w = UUID()

        service.enqueueShare([w: .publish])
        service.enqueueShare([w: .unpublish])
        service.enqueueShare([w: .publish])   // must not resurrect the share
        #expect(outbox(in: defaults) == [w.uuidString: "unpublish"])

        await service.drainShareOutbox { _ in
            Issue.record("no publish intents should survive")
            return []
        }
        #expect(await backend.publishCount == 0)
        #expect(outbox(in: defaults).isEmpty)
    }

    @Test func drainExecutesQueuedIntentsAndClears() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, defaults) = try await makeService(backend, defaultsName: "outbox-executes")
        let w = UUID()

        service.enqueueShare([w: .publish])
        await service.drainShareOutbox { ids in
            #expect(ids == [w])
            return [item(w, minute: 1)]
        }

        #expect(await remoteIDs(backend) == [w])
        #expect(outbox(in: defaults).isEmpty)
    }

    @Test func drainKeepsFailedIntentsForTheNextPass() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, defaults) = try await makeService(backend, defaultsName: "outbox-retries")
        let w = UUID()
        try await backend.inner.publishWorkout(dto(w, minute: 1), summary: dto(w, minute: 1).summary, publishedAt: epoch)

        // Offline delete: the intent survives the failed drain…
        await backend.setFailUnpublish(true)
        service.enqueueShare([w: .unpublish])
        await service.drainShareOutbox { _ in [] }
        #expect(outbox(in: defaults) == [w.uuidString: "unpublish"])
        #expect(await remoteIDs(backend) == [w])

        // …and executes when connectivity returns.
        await backend.setFailUnpublish(false)
        await service.drainShareOutbox { _ in [] }
        #expect(await remoteIDs(backend).isEmpty)
        #expect(outbox(in: defaults).isEmpty)
    }

    @Test func drainDropsPublishIntentsTheBuilderNoLongerYields() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, defaults) = try await makeService(backend, defaultsName: "outbox-drops-ineligible")

        // Queued, then the workout was emptied/deleted before the drain ran.
        service.enqueueShare([UUID(): .publish])
        await service.drainShareOutbox { _ in [] }

        #expect(await backend.publishCount == 0)
        #expect(outbox(in: defaults).isEmpty)
    }

    @Test func legacyTombstonesMigrateIntoTheOutbox() async throws {
        let backend = InstrumentedSocialBackend()
        let defaults = isolatedDefaults("outbox-migration")
        let service = SocialService(backend: backend, isDemo: false, defaults: defaults)
        // Opted-in install with a pre-outbox tombstone on disk.
        try await service.optIn(handle: "james", displayName: "James", visibility: .everyone, stats: snapshot())
        let w = UUID()
        try await backend.inner.publishWorkout(dto(w, minute: 1), summary: dto(w, minute: 1).summary, publishedAt: epoch)
        defaults.set([w.uuidString], forKey: SocialService.legacyPendingUnpublishKey)

        await service.drainShareOutbox { _ in [] }

        #expect(await remoteIDs(backend).isEmpty)
        #expect(defaults.stringArray(forKey: SocialService.legacyPendingUnpublishKey) == nil)
        #expect(outbox(in: defaults).isEmpty)
    }

    @Test func deletingProfileClearsQueuedIntents() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, defaults) = try await makeService(backend, defaultsName: "outbox-profile-delete")
        service.enqueueShare([UUID(): .unpublish])
        #expect(!outbox(in: defaults).isEmpty)

        try await service.deleteProfile()

        // The wipe took every share with it — no intent survives to fire later.
        #expect(outbox(in: defaults).isEmpty)
    }

    // MARK: - Reconcile contract

    /// The founder contract in one test: an offline finish (locally eligible,
    /// absent remotely) publishes on reconcile, existing shares aren't
    /// republished, and DTOs are built only for the workouts that need it.
    @Test func reconcilePublishesOnlyWorkoutsMissingRemotely() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, _) = try await makeService(backend, defaultsName: "reconcile-missing")
        let shared = UUID(), offlineFinish = UUID()
        try await backend.inner.publishWorkout(dto(shared, minute: 1), summary: dto(shared, minute: 1).summary, publishedAt: epoch)

        var askedFor: Set<UUID>?
        await service.reconcileSharedWorkouts(
            eligible: [stamp(shared, at: epoch), stamp(offlineFinish, at: epoch)],
            deletedIDs: [], force: true
        ) { missing in
            askedFor = missing
            return [item(offlineFinish, minute: 2)]
        }

        #expect(askedFor == [offlineFinish])
        #expect(await backend.publishCount == 1)
        #expect(await remoteIDs(backend) == [shared, offlineFinish])
    }

    /// Editing an already-shared workout: the local clock outruns the remote
    /// watermark, so reconcile republishes in place — same `publishedAt`
    /// (profile order undisturbed), advanced `sourceUpdatedAt` (converged,
    /// so the next pass is a no-op).
    @Test func reconcileRepublishesEditedWorkoutsInPlace() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, _) = try await makeService(backend, defaultsName: "reconcile-drift")
        let w = UUID()
        try await backend.inner.publishWorkout(
            dto(w, minute: 0), summary: dto(w, minute: 0).summary,
            publishedAt: epoch, sourceUpdatedAt: epoch
        )

        let edited = epoch.addingTimeInterval(300)
        let stamps = [stamp(w, at: edited)]
        await service.reconcileSharedWorkouts(eligible: stamps, deletedIDs: [], force: true) { missing in
            #expect(missing == [w])
            return [item(w, minute: 0, updatedAt: edited)]
        }

        let ref = await remoteRefs(backend).first
        #expect(await backend.publishCount == 1)
        #expect(ref?.publishedAt == epoch)          // didn't jump the order
        #expect(ref?.sourceUpdatedAt == edited)     // watermark advanced

        await service.reconcileSharedWorkouts(eligible: stamps, deletedIDs: [], force: true) { _ in
            Issue.record("already converged — nothing should rebuild")
            return []
        }
        #expect(await backend.publishCount == 1)
    }

    @Test func reconcileUnpublishesLocallyDeletedShares() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, _) = try await makeService(backend, defaultsName: "reconcile-deleted")
        let deleted = UUID(), kept = UUID()
        try await backend.inner.publishWorkout(dto(deleted, minute: 1), summary: dto(deleted, minute: 1).summary, publishedAt: epoch)
        try await backend.inner.publishWorkout(dto(kept, minute: 2), summary: dto(kept, minute: 2).summary, publishedAt: epoch.addingTimeInterval(60))

        await service.reconcileSharedWorkouts(
            eligible: [stamp(kept, at: epoch.addingTimeInterval(60))],
            deletedIDs: [deleted], force: true
        ) { _ in [] }

        #expect(await remoteIDs(backend) == [kept])
    }

    /// Workouts live in a local-only store, so a fresh install sees an empty
    /// log next to a populated profile. Absence alone must never unpublish —
    /// only deletion evidence may.
    @Test func remoteSharesSurviveAFreshDeviceWithNoLocalHistory() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, _) = try await makeService(backend, defaultsName: "reconcile-fresh-device")
        let shared = UUID()
        try await backend.inner.publishWorkout(dto(shared, minute: 1), summary: dto(shared, minute: 1).summary, publishedAt: epoch)

        await service.reconcileSharedWorkouts(eligible: [], deletedIDs: [], force: true) { _ in [] }

        #expect(await remoteIDs(backend) == [shared])
        #expect(await backend.unpublishCount == 0)
    }

    @Test func remoteFetchFailureAbortsWithoutTouchingAnything() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, _) = try await makeService(backend, defaultsName: "reconcile-fetch-fail")
        await backend.setFailFetch(true)

        await service.reconcileSharedWorkouts(
            eligible: [stamp(UUID(), at: epoch)], deletedIDs: [UUID()], force: true
        ) { _ in
            Issue.record("makeItems must not run on a failed remote fetch")
            return []
        }

        #expect(await backend.publishCount == 0)
        #expect(await backend.unpublishCount == 0)
    }

    /// Paging proof: with more remote refs than one page, a correct walk finds
    /// every id and republishes nothing; a broken walk would see phantom
    /// "missing" workouts.
    @Test func reconcileWalksEveryRemotePage() async throws {
        let backend = InstrumentedSocialBackend()
        let (service, _) = try await makeService(backend, defaultsName: "reconcile-paging")
        var stamps: [SocialShareStamp] = []
        for minute in 0...(SocialService.reconcilePageSize) {
            let id = UUID()
            let publishedAt = epoch.addingTimeInterval(Double(minute) * 60)
            stamps.append(stamp(id, at: publishedAt))
            try await backend.inner.publishWorkout(dto(id, minute: minute), summary: dto(id, minute: minute).summary, publishedAt: publishedAt)
        }

        await service.reconcileSharedWorkouts(eligible: stamps, deletedIDs: [], force: true) { missing in
            Issue.record("nothing is missing — makeItems must not run (saw \(missing.count))")
            return []
        }

        #expect(await backend.publishCount == 0)
    }
}
