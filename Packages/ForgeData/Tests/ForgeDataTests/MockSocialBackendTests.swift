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

    @Test func recentWorkoutsPaginatesByPublishedAtKeyset() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        // Nine workouts a minute apart, published out of order to prove the
        // pages come from the sorted list, not insertion order.
        for minute in [4, 8, 0, 6, 2, 7, 1, 5, 3] {
            try await backend.publishWorkout(
                dto(UUID(), "W\(minute)"), summary: summary,
                publishedAt: epoch.addingTimeInterval(Double(minute) * 60)
            )
        }
        let me = SocialUserID("me")

        let page1 = try await backend.recentWorkouts(for: me, limit: 4, before: nil)
        #expect(page1.map(\.title) == ["W8", "W7", "W6", "W5"])

        let page2 = try await backend.recentWorkouts(for: me, limit: 4, before: page1.last?.publishedAt)
        #expect(page2.map(\.title) == ["W4", "W3", "W2", "W1"])

        // Final short page, then an empty one past the end.
        let page3 = try await backend.recentWorkouts(for: me, limit: 4, before: page2.last?.publishedAt)
        #expect(page3.map(\.title) == ["W0"])
        #expect(try await backend.recentWorkouts(for: me, limit: 4, before: page3.last?.publishedAt).isEmpty)

        // `before` is strict: a boundary equal to a ref's publishedAt excludes it.
        let strict = try await backend.recentWorkouts(for: me, limit: 9, before: epoch.addingTimeInterval(8 * 60))
        #expect(strict.map(\.title).first == "W7")
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

    @Test func likersReturnNewestFirstWithStableTiebreak() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        let w = UUID()
        // Deliberately seeded out of order; the newest heart must lead.
        await backend.seedLike(workoutID: w, by: SocialUserID("older"), at: epoch)
        await backend.seedLike(workoutID: w, by: SocialUserID("newest"), at: epoch.addingTimeInterval(600))
        await backend.seedLike(workoutID: w, by: SocialUserID("middle"), at: epoch.addingTimeInterval(300))

        let likers = try await backend.likers(workoutID: w)
        #expect(likers.map(\.userID.rawValue) == ["newest", "middle", "older"])
        #expect(try await backend.likeCount(workoutID: w) == 3)

        // Identical timestamps break on userID so ordering never flickers.
        let tie = UUID()
        await backend.seedLike(workoutID: tie, by: SocialUserID("bravo"), at: epoch)
        await backend.seedLike(workoutID: tie, by: SocialUserID("alpha"), at: epoch)
        #expect(try await backend.likers(workoutID: tie).map(\.userID.rawValue) == ["alpha", "bravo"])
    }

    @Test func unlikeRemovesLikerFromList() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        let w = UUID()
        await backend.seedLike(workoutID: w, by: SocialUserID("friend"), at: epoch)
        try await backend.setLike(true, workoutID: w)
        #expect(try await backend.likers(workoutID: w).count == 2)

        try await backend.setLike(false, workoutID: w)
        let remaining = try await backend.likers(workoutID: w)
        // Unliking removes only my heart; the friend's survives.
        #expect(remaining.map(\.userID.rawValue) == ["friend"])
        #expect(try await backend.hasLiked(workoutID: w) == false)
    }

    @Test func likersIsEmptyForUnheartedWorkout() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        #expect(try await backend.likers(workoutID: UUID()).isEmpty)
    }

    @Test func deleteAllMyDataRemovesOnlyMineAndFreesHandle() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        try await backend.upsertMyProfile(profile("me", handle: "james"))
        #expect(try await backend.claimHandle("james") == true)
        let mine = UUID()
        try await backend.publishWorkout(dto(mine, "Push"), summary: summary, publishedAt: epoch)
        let friendWorkout = UUID()
        await backend.seed(profile: profile("friend", handle: "friendly"),
                           workouts: [(dto: dto(friendWorkout, "Legs"), summary: summary, publishedAt: epoch)],
                           follow: true)
        try await backend.setLike(true, workoutID: friendWorkout)

        try await backend.deleteAllMyData()

        // Everything the user created is gone…
        #expect(try await backend.profile(for: SocialUserID("me")) == nil)
        #expect(try await backend.profile(forHandle: "james") == nil)
        #expect(try await backend.recentWorkouts(for: SocialUserID("me"), limit: 10).isEmpty)
        #expect(try await backend.workoutDetail(id: mine) == nil)
        #expect(try await backend.following().isEmpty)
        #expect(try await backend.hasLiked(workoutID: friendWorkout) == false)
        // …the friend's presence is untouched…
        #expect(try await backend.profile(forHandle: "friendly") != nil)
        #expect(try await backend.workoutDetail(id: friendWorkout) != nil)
        // …and the handle is free to claim again.
        #expect(try await backend.claimHandle("james") == true)
    }

    @Test func deleteAllMyDataIsIdempotent() async throws {
        let backend = MockSocialBackend(me: SocialUserID("me"))
        try await backend.deleteAllMyData() // nothing to delete — must not trap
        try await backend.upsertMyProfile(profile("me", handle: "james"))
        try await backend.deleteAllMyData()
        try await backend.deleteAllMyData() // second pass after a full delete
        #expect(try await backend.profile(for: SocialUserID("me")) == nil)
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
