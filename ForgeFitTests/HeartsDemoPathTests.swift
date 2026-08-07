import Foundation
import Testing
import ForgeData
@testable import ForgeFit

/// Proves the demo hearts path end-to-end at the service layer: seeded
/// profile → opted in → publish → friends heart → row data resolves.
/// The UI test drives the same path through real screens; this one localizes
/// any break to the service rather than the view.
@MainActor
struct HeartsDemoPathTests {

    private func service() -> (SocialService, MockSocialBackend) {
        let mock = MockSocialBackend(me: SocialUserID("demo-me"))
        let defaults = UserDefaults(suiteName: "hearts-demo-\(UUID().uuidString)")!
        return (SocialService(backend: mock, isDemo: true, defaults: defaults), mock)
    }

    @Test func seededProfileOptsTheDemoUserIn() async {
        let (social, mock) = service()
        #expect(social.isOptedIn == false)

        await SocialDemoData.seedMyProfile(into: mock)
        await social.refresh()

        // Publishing (and therefore hearts) requires a profile.
        #expect(social.isOptedIn == true)
        #expect(social.myUserID == SocialUserID("demo-me"))
    }

    @Test func heartsResolveLeadNameAndCount() async {
        let (social, mock) = service()
        await SocialDemoData.seedMyProfile(into: mock)
        await social.refresh()

        let workoutID = UUID()
        let now = Date()
        await mock.seed(
            profile: SocialProfile(
                userID: SocialUserID("friend-mia"), handle: "miaruns", displayName: "Mia Chen",
                totalXP: 100, workoutCount: 1, lifetimeHours: 1,
                stats: SocialStats(lifetimeVolumeKg: 0, bestE1RMKg: 0, cardioDistanceMeters: 0, cardioMinutes: 0, yogaMinutes: 0),
                updatedAt: now),
            workouts: [], follow: true)
        // Newest heart must lead the row.
        await mock.seedLike(workoutID: workoutID, by: SocialUserID("friend-alex"), at: now.addingTimeInterval(-7200))
        await mock.seedLike(workoutID: workoutID, by: SocialUserID("friend-mia"), at: now)

        let hearts = await social.hearts(workoutID: workoutID)
        #expect(hearts?.count == 2)
        #expect(hearts?.leadName == "Mia Chen")
        #expect(WorkoutHeartsRow.likersLine(leadName: hearts?.leadName, total: hearts?.count ?? 0) == "Mia Chen +1")
    }

    @Test func ownHeartReadsAsYouNotYourDisplayName() async {
        let (social, mock) = service()
        await SocialDemoData.seedMyProfile(into: mock)
        await social.refresh()

        let workoutID = UUID()
        await mock.setLike(true, workoutID: workoutID)

        let hearts = await social.hearts(workoutID: workoutID)
        #expect(hearts?.count == 1)
        #expect(hearts?.leadName == "You")
    }

    @Test func noHeartsResolvesToAnEmptyListNotNil() async {
        let (social, mock) = service()
        await SocialDemoData.seedMyProfile(into: mock)
        await social.refresh()

        // Distinguishes "fetched, nobody hearted it" from a failed fetch —
        // both render nothing, but only the former is a real answer.
        let hearts = await social.hearts(workoutID: UUID())
        #expect(hearts?.count == 0)
        #expect(hearts?.leadName == nil)
    }
}
