import Foundation
import Testing
@testable import ForgeData

@Suite struct MockSocialBackendTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func dto(_ id: UUID, _ title: String) -> SharedWorkoutDTO {
        SharedWorkoutDTO(id: id, title: title, startedAt: epoch, endedAt: nil, exercises: [])
    }
    private let summary = SharedWorkoutSummary(volumeKg: 1000, workingSets: 10, reps: 80, durationSeconds: 3600, exerciseCount: 4)
    private func profile(_ id: String, handle: String, volume: Double = 0, xp: Int = 0) -> SocialProfile {
        SocialProfile(userID: SocialUserID(id), handle: handle, displayName: id.capitalized,
                      totalXP: xp, stats: SocialStats(lifetimeVolumeKg: volume), updatedAt: epoch)
    }

    @Test func handleClaimIsIdempotentForOwnerAndRejectsTaken() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        try await backend.upsertMyProfile(profile("me", handle: "james"))
        #expect(try await backend.claimHandle("james") == true)
        #expect(try await backend.claimHandle("@JAMES ") == true) // normalizes to same
        // A friend already holds "taken".
        await backend.seed(profile: profile("friend", handle: "taken"), workouts: [], follow: false)
        #expect(try await backend.claimHandle("taken") == false)
    }

    @Test func invalidHandleThrows() async throws {
        let backend = MockSocialBackend()
        await #expect(throws: SocialError.invalidHandle) { try await backend.claimHandle("no") }        // too short
        await #expect(throws: SocialError.invalidHandle) { try await backend.claimHandle("1abc") }      // must start with letter
        await #expect(throws: SocialError.invalidHandle) { try await backend.claimHandle("a b c") }     // space
    }

    @Test func followGraph() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        let friend = SocialUserID("friend")
        #expect(try await backend.isFollowing(friend) == false)
        try await backend.follow(friend)
        #expect(try await backend.isFollowing(friend) == true)
        #expect(try await backend.following() == [friend])
        // Can't follow yourself.
        try await backend.follow(SocialUserID("me"))
        #expect(try await backend.following() == [friend])
        try await backend.unfollow(friend)
        #expect(try await backend.following().isEmpty)
    }

    @Test func publishOrdersNewestFirstAndDetailRoundTrips() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        let older = UUID(), newer = UUID()
        try await backend.publishWorkout(dto(older, "Old"), summary: summary, publishedAt: epoch)
        try await backend.publishWorkout(dto(newer, "New"), summary: summary, publishedAt: epoch.addingTimeInterval(60))
        let recent = try await backend.recentWorkouts(for: SocialUserID("me"), limit: 10)
        #expect(recent.map(\.title) == ["New", "Old"])
        #expect(try await backend.workoutDetail(id: newer)?.title == "New")
        // Unpublish removes both the ref and the payload.
        try await backend.unpublishWorkout(id: newer)
        #expect(try await backend.recentWorkouts(for: SocialUserID("me"), limit: 10).map(\.title) == ["Old"])
        #expect(try await backend.workoutDetail(id: newer) == nil)
    }

    @Test func likesToggle() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        let w = UUID()
        #expect(try await backend.hasLiked(workoutID: w) == false)
        try await backend.setLike(true, workoutID: w)
        #expect(try await backend.hasLiked(workoutID: w) == true)
        #expect(try await backend.likeCount(workoutID: w) == 1)
        try await backend.setLike(false, workoutID: w)
        #expect(try await backend.likeCount(workoutID: w) == 0)
    }

    @Test func friendsLeaderboardExcludesNonFriendsButIncludesSelf() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        try await backend.upsertMyProfile(profile("me", handle: "me", volume: 500))
        await backend.seed(profile: profile("a", handle: "a", volume: 1000), workouts: [], follow: true)
        await backend.seed(profile: profile("b", handle: "b", volume: 800), workouts: [], follow: true)
        await backend.seed(profile: profile("c", handle: "c", volume: 2000), workouts: [], follow: false)

        let friends = try await backend.leaderboard(metric: .totalVolume, scope: .friends, limit: 10)
        #expect(friends.map(\.profile.handle) == ["a", "b", "me"]) // c excluded, self included
        #expect(friends.map(\.rank) == [1, 2, 3])

        let global = try await backend.leaderboard(metric: .totalVolume, scope: .global, limit: 10)
        #expect(global.first?.profile.handle == "c") // 2000 tops the global board
    }
}
