import Foundation
import Testing
import ForgeData
@testable import ForgeFit

/// The likes row's presentation contract: the most recent liker leads, the
/// rest collapse to a count, and a liker whose profile is gone never fakes
/// a name while still counting toward the total.
@MainActor
struct WorkoutHeartsRowTests {

    @Test func countRemainsVisibleAtZero() {
        #expect(WorkoutHeartsRow.countText(0) == "0 likes")
        #expect(WorkoutHeartsRow.countText(1) == "1 like")
        #expect(WorkoutHeartsRow.countText(2) == "2 likes")
    }

    @Test func singleHeartShowsJustTheName() {
        #expect(WorkoutHeartsRow.likersLine(leadName: "Mia Chen", total: 1) == "Mia Chen")
    }

    @Test func multipleHeartsCollapseToOverflowCount() {
        #expect(WorkoutHeartsRow.likersLine(leadName: "Mia Chen", total: 3) == "Mia Chen +2")
        #expect(WorkoutHeartsRow.likersLine(leadName: "Mia Chen", total: 2) == "Mia Chen +1")
    }

    @Test func deletedLeadProfileShowsNoNameButKeepsTheCount() {
        // nil lead name = that liker's profile is gone. The row still
        // renders the count; it just can't attribute the most recent one.
        #expect(WorkoutHeartsRow.likersLine(leadName: nil, total: 4).isEmpty)
    }

    @Test func accessibilitySummaryReadsAsASentence() {
        #expect(WorkoutHeartsRow.accessibilitySummary(leadName: "Mia Chen", total: 1)
                == "1 like, from Mia Chen")
        #expect(WorkoutHeartsRow.accessibilitySummary(leadName: "Mia Chen", total: 2)
                == "2 likes, most recently from Mia Chen and 1 other")
        #expect(WorkoutHeartsRow.accessibilitySummary(leadName: "Mia Chen", total: 5)
                == "5 likes, most recently from Mia Chen and 4 others")
        // Gone profile: no fabricated attribution.
        #expect(WorkoutHeartsRow.accessibilitySummary(leadName: nil, total: 3) == "3 likes")
    }
}

/// The likes row uses the same eligibility predicate as publishing and is
/// additionally gated by the user's community opt-in state in the view.
@MainActor
struct HeartsEligibilityGateTests {

    private let userID = UUID()

    private func workout(ended: Bool, deleted: Bool = false, imported: Bool = false) -> WorkoutModel {
        let w = WorkoutModel(
            userID: userID,
            startedAt: Date().addingTimeInterval(-3600),
            endedAt: ended ? Date() : nil
        )
        if deleted { w.deletedAt = Date() }
        if imported { w.externalSource = "hevy" }
        return w
    }

    @Test func onlyFinishedLiveWorkoutsCanShowHearts() {
        #expect(SocialBackfill.isEligible(workout(ended: true)))
        // In progress: nothing published yet, so nothing to heart.
        #expect(!SocialBackfill.isEligible(workout(ended: false)))
        // Deleted: unpublished, must not advertise hearts.
        #expect(!SocialBackfill.isEligible(workout(ended: true, deleted: true)))
        // Imported history is never shared as ForgeFit training.
        #expect(!SocialBackfill.isEligible(workout(ended: true, imported: true)))
    }

    @Test func gateMatchesTheBulkFilterExactly() {
        let all = [
            workout(ended: true),
            workout(ended: false),
            workout(ended: true, deleted: true),
            workout(ended: true, imported: true),
        ]
        // The row's per-workout gate and the publish pipeline's bulk filter
        // are the same predicate — this is the anti-drift guard.
        #expect(SocialBackfill.eligibleWorkouts(all).map(\.id) == all.filter(SocialBackfill.isEligible).map(\.id))
    }
}
