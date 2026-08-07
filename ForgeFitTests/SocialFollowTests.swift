import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// The follow write path must be honest: a rejected backend write reaches the
/// caller as an error instead of being swallowed. The old `try?` passthrough
/// plus an optimistic button flip produced the field bug where "Following"
/// appeared, nothing persisted, and the button reverted on the next visit.
@MainActor
@Suite struct SocialFollowTests {

    private func makeService(_ backend: InstrumentedSocialBackend, name: String) async throws -> SocialService {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let service = SocialService(backend: backend, isDemo: false, defaults: defaults)
        try await service.optIn(
            handle: "james", displayName: "James", visibility: .everyone,
            stats: ProfileSnapshot(totalXP: 0, workoutCount: 0, lifetimeHours: 0, stats: SocialStats(), now: Date(timeIntervalSince1970: 1_700_000_000))
        )
        return service
    }

    @Test func successfulFollowRoundTrips() async throws {
        let backend = InstrumentedSocialBackend()
        let service = try await makeService(backend, name: "follow-roundtrip")
        let friend = SocialUserID("friend")

        try await service.follow(friend)
        #expect(await service.isFollowing(friend))
        #expect(await service.following() == [friend])

        try await service.unfollow(friend)
        #expect(await !service.isFollowing(friend))
    }

    @Test func rejectedFollowWriteReachesTheCaller() async throws {
        let backend = InstrumentedSocialBackend()
        let service = try await makeService(backend, name: "follow-rejected")
        await backend.setFailFollow(true)

        // The button handler only flips to "Following" when this DOESN'T
        // throw — a silent failure here is the not-actually-following loop.
        await #expect(throws: InstrumentedSocialBackend.Failure.self) {
            try await service.follow(SocialUserID("friend"))
        }
        #expect(await !service.isFollowing(SocialUserID("friend")))
    }
}
