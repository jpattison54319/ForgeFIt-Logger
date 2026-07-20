import ForgeData
import Foundation

/// Delegates to `MockSocialBackend`, adding call counters and switchable
/// failures for the fetch/publish/unpublish legs — the offline dials the
/// sync-pipeline tests turn. Shared by the outbox/reconcile suite and the
/// SyncCoordinator suite.
actor InstrumentedSocialBackend: SocialBackend {
    struct Failure: Error {}
    let inner = MockSocialBackend(me: SocialUserID("me"))
    private(set) var publishCount = 0
    private(set) var unpublishCount = 0
    private var failFetch = false
    private var failUnpublish = false
    private var failPublish = false
    private var failFollow = false

    func setFailFetch(_ fail: Bool) { failFetch = fail }
    func setFailUnpublish(_ fail: Bool) { failUnpublish = fail }
    func setFailPublish(_ fail: Bool) { failPublish = fail }
    func setFailFollow(_ fail: Bool) { failFollow = fail }

    func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date, sourceUpdatedAt: Date) async throws {
        if failPublish { throw Failure() }
        publishCount += 1
        await inner.publishWorkout(dto, summary: summary, publishedAt: publishedAt, sourceUpdatedAt: sourceUpdatedAt)
    }
    func unpublishWorkout(id: UUID) async throws {
        if failUnpublish { throw Failure() }
        unpublishCount += 1
        await inner.unpublishWorkout(id: id)
    }
    func recentWorkouts(for id: SocialUserID, limit: Int, before: Date?) async throws -> [SocialWorkoutRef] {
        if failFetch { throw Failure() }
        return await inner.recentWorkouts(for: id, limit: limit, before: before)
    }

    func currentUserID() async throws -> SocialUserID { await inner.currentUserID() }
    func upsertMyProfile(_ profile: SocialProfile) async throws { await inner.upsertMyProfile(profile) }
    func profile(for id: SocialUserID) async throws -> SocialProfile? { await inner.profile(for: id) }
    func profile(forHandle handle: String) async throws -> SocialProfile? { await inner.profile(forHandle: handle) }
    func claimHandle(_ handle: String) async throws -> Bool { try await inner.claimHandle(handle) }
    func workoutDetail(id: UUID) async throws -> SharedWorkoutDTO? { await inner.workoutDetail(id: id) }
    func follow(_ id: SocialUserID) async throws {
        if failFollow { throw Failure() }
        await inner.follow(id)
    }
    func unfollow(_ id: SocialUserID) async throws {
        if failFollow { throw Failure() }
        await inner.unfollow(id)
    }
    func following() async throws -> [SocialUserID] { await inner.following() }
    func isFollowing(_ id: SocialUserID) async throws -> Bool { await inner.isFollowing(id) }
    func setLike(_ liked: Bool, workoutID: UUID) async throws { await inner.setLike(liked, workoutID: workoutID) }
    func likeCount(workoutID: UUID) async throws -> Int { await inner.likeCount(workoutID: workoutID) }
    func hasLiked(workoutID: UUID) async throws -> Bool { await inner.hasLiked(workoutID: workoutID) }
    func likers(workoutID: UUID) async throws -> [SocialLike] { await inner.likers(workoutID: workoutID) }
    func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int) async throws -> [SocialLeaderboardEntry] {
        await inner.leaderboard(metric: metric, scope: scope, limit: limit)
    }
    func deleteAllMyData() async throws { await inner.deleteAllMyData() }
}
