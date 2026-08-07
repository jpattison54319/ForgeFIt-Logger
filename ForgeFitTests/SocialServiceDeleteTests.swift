import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// `SocialService.deleteProfile()` orchestration over mocked backends — the
/// CloudKit path can't run in the simulator (no iCloud account), so these pin
/// the state-machine contract: success returns the hub to the opt-in gate and
/// clears the backend; failure leaves the account opted-in so the deletion
/// UI stays reachable for a retry.
@MainActor
@Suite struct SocialServiceDeleteTests {

    private func snapshot() -> ProfileSnapshot {
        ProfileSnapshot(
            totalXP: 1200, workoutCount: 10, lifetimeHours: 12,
            stats: SocialStats(lifetimeVolumeKg: 5000),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func deleteProfileClearsLocalStateAndBackendData() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        let service = SocialService(backend: backend, isDemo: false)
        try await service.optIn(handle: "james", displayName: "James", visibility: .everyone, stats: snapshot())
        #expect(service.isOptedIn)

        try await service.deleteProfile()

        #expect(!service.isOptedIn)
        #expect(service.status == .notOptedIn)
        #expect(await backend.profile(for: SocialUserID("me")) == nil)
        // The handle was released — opting back in with it succeeds.
        try await service.optIn(handle: "james", displayName: "James", visibility: .approveFollowers, stats: snapshot())
        #expect(service.isOptedIn)
    }

    @Test func failedDeletionLeavesAccountOptedInForRetry() async throws {
        let service = SocialService(backend: FailingDeleteBackend(), isDemo: false)
        try await service.optIn(handle: "james", displayName: "James", visibility: .everyone, stats: snapshot())

        await #expect(throws: FailingDeleteBackend.Failure.self) {
            try await service.deleteProfile()
        }

        #expect(service.isOptedIn)
        #expect(service.status == .active)
        #expect(service.myProfile?.handle == "james")
    }
}

/// Delegates everything to `MockSocialBackend` (so opt-in works normally)
/// but fails `deleteAllMyData()` — models the offline / partial-failure path.
private struct FailingDeleteBackend: SocialBackend {
    struct Failure: Error {}
    let inner = MockSocialBackend(me: SocialUserID("me"))

    func currentUserID() async throws -> SocialUserID { await inner.currentUserID() }
    func upsertMyProfile(_ profile: SocialProfile) async throws { await inner.upsertMyProfile(profile) }
    func profile(for id: SocialUserID) async throws -> SocialProfile? { await inner.profile(for: id) }
    func profile(forHandle handle: String) async throws -> SocialProfile? { await inner.profile(forHandle: handle) }
    func claimHandle(_ handle: String) async throws -> Bool { try await inner.claimHandle(handle) }
    func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date, sourceUpdatedAt: Date) async throws {
        await inner.publishWorkout(dto, summary: summary, publishedAt: publishedAt, sourceUpdatedAt: sourceUpdatedAt)
    }
    func unpublishWorkout(id: UUID) async throws { await inner.unpublishWorkout(id: id) }
    func recentWorkouts(for id: SocialUserID, limit: Int, before: Date?) async throws -> [SocialWorkoutRef] {
        await inner.recentWorkouts(for: id, limit: limit, before: before)
    }
    func workoutDetail(id: UUID) async throws -> SharedWorkoutDTO? { await inner.workoutDetail(id: id) }
    func follow(_ id: SocialUserID) async throws { await inner.follow(id) }
    func unfollow(_ id: SocialUserID) async throws { await inner.unfollow(id) }
    func following() async throws -> [SocialUserID] { await inner.following() }
    func isFollowing(_ id: SocialUserID) async throws -> Bool { await inner.isFollowing(id) }
    func setLike(_ liked: Bool, workoutID: UUID) async throws { await inner.setLike(liked, workoutID: workoutID) }
    func likeCount(workoutID: UUID) async throws -> Int { await inner.likeCount(workoutID: workoutID) }
    func hasLiked(workoutID: UUID) async throws -> Bool { await inner.hasLiked(workoutID: workoutID) }
    func likers(workoutID: UUID) async throws -> [SocialLike] { await inner.likers(workoutID: workoutID) }
    func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int) async throws -> [SocialLeaderboardEntry] {
        await inner.leaderboard(metric: metric, scope: scope, limit: limit)
    }
    func deleteAllMyData() async throws { throw Failure() }
}
