import Foundation
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine alternation draft")
struct RoutineAlternationDraftTests {
    @Test("The draft canonicalizes membership and stages additions")
    func canonicalizesAndAddsMembers() {
        let first = UUID()
        let second = UUID()
        let draft = RoutineAlternationDraft(memberIDs: [first, second, first])

        #expect(draft.memberIDs == [first, second])
        #expect(!draft.hasChanges)
        #expect(!draft.add(first))
        #expect(draft.add(UUID()))
        #expect(draft.hasChanges)
    }

    @Test("Reordering immediately updates the next member")
    func reorderUpdatesDueMember() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let draft = RoutineAlternationDraft(
            memberIDs: [first, second, third],
            latestCompletionByMemberID: [
                first: .init(endedAt: Date(timeIntervalSince1970: 100), workoutID: UUID())
            ]
        )

        #expect(draft.dueMemberID == second)
        draft.move(from: IndexSet(integer: 1), to: 3)
        #expect(draft.memberIDs == [first, third, second])
        #expect(draft.dueMemberID == third)
    }

    @Test("Removing the latest completed member falls back to remaining history")
    func removalUsesLatestRemainingCompletion() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let draft = RoutineAlternationDraft(
            memberIDs: [first, second, third, fourth],
            latestCompletionByMemberID: [
                first: .init(endedAt: Date(timeIntervalSince1970: 200), workoutID: UUID()),
                third: .init(endedAt: Date(timeIntervalSince1970: 100), workoutID: UUID())
            ]
        )

        #expect(draft.dueMemberID == second)
        #expect(draft.remove(first))
        #expect(draft.memberIDs == [second, third, fourth])
        #expect(draft.dueMemberID == fourth)
    }

    @Test("A new draft can remove an added partner but keeps one seed member")
    func draftKeepsOneSeedMember() {
        let first = UUID()
        let second = UUID()
        let draft = RoutineAlternationDraft(memberIDs: [first, second])

        #expect(draft.remove(second))
        #expect(draft.memberIDs == [first])
        #expect(!draft.remove(first))
        #expect(!draft.canSave)
        #expect(draft.hasChanges)
    }

    @Test("A new cycle starts with its first configured member")
    func newCycleStartsAtFirstMember() {
        let first = UUID()
        let second = UUID()
        let draft = RoutineAlternationDraft(memberIDs: [first, second])

        #expect(draft.dueMemberID == first)
    }
}
