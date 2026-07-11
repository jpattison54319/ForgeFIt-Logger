import Foundation
import Testing
@testable import ForgeCore

struct CoachingPolicyTests {

    private let weekStart = Date(timeIntervalSince1970: 1_700_000_000)
    private let squatID = UUID()
    private let benchID = UUID()

    private func summary(
        sessionsCompleted: Int = 3,
        sessionsTarget: Int = 3,
        blockWeek: Int? = nil,
        blockLength: Int? = nil,
        lifts: [LiftWeekOutcome] = []
    ) -> WeekSummary {
        WeekSummary(
            weekStart: weekStart, sessionsCompleted: sessionsCompleted, sessionsTarget: sessionsTarget,
            blockWeek: blockWeek, blockLength: blockLength, lifts: lifts
        )
    }

    @Test func fullyOnTrackWeekStaysCourse() {
        let proposals = CoachingPolicy.review(summary())
        #expect(proposals.count == 1)
        #expect(proposals.first?.kind == .stayCourse)
    }

    @Test func liftHeldAfterTwoConsecutiveUnderTargetSessions() {
        let lift = LiftWeekOutcome(exerciseID: squatID, name: "Barbell Squat", consecutiveUnderTarget: 2)
        let proposals = CoachingPolicy.review(summary(lifts: [lift]))
        #expect(proposals.contains { $0.kind == .progressionHold(exerciseID: squatID, name: "Barbell Squat") })
        // A hold fired, so "stay the course" must not also appear.
        #expect(!proposals.contains { $0.kind == .stayCourse })
    }

    @Test func singleUnderTargetSessionDoesNotHold() {
        let lift = LiftWeekOutcome(exerciseID: squatID, name: "Barbell Squat", consecutiveUnderTarget: 1)
        let proposals = CoachingPolicy.review(summary(lifts: [lift]))
        #expect(!proposals.contains { if case .progressionHold = $0.kind { return true }; return false })
        #expect(proposals.contains { $0.kind == .stayCourse })
    }

    @Test func multipleStalledLiftsEachGetTheirOwnHold() {
        let squat = LiftWeekOutcome(exerciseID: squatID, name: "Barbell Squat", consecutiveUnderTarget: 3)
        let bench = LiftWeekOutcome(exerciseID: benchID, name: "Bench Press", consecutiveUnderTarget: 2)
        let proposals = CoachingPolicy.review(summary(lifts: [squat, bench]))
        #expect(proposals.contains { $0.kind == .progressionHold(exerciseID: squatID, name: "Barbell Squat") })
        #expect(proposals.contains { $0.kind == .progressionHold(exerciseID: benchID, name: "Bench Press") })
        #expect(proposals.count == 2)
    }

    @Test func partialWeekCarriesForwardMissedSessions() {
        let proposals = CoachingPolicy.review(summary(sessionsCompleted: 2, sessionsTarget: 4))
        guard let carry = proposals.first(where: { if case .carryForward = $0.kind { return true }; return false }) else {
            Issue.record("expected a carryForward proposal")
            return
        }
        #expect(carry.kind == .carryForward(missedSessions: 2))
        #expect(carry.reason.lowercased().contains("crammed"))
    }

    @Test func zeroCompletedSessionsDoesNotCarryForward() {
        // Spec: carryForward requires 0 < sessionsCompleted < sessionsTarget.
        // A totally missed week (0 completed) is a different situation and
        // isn't proposed as a carry-forward.
        let proposals = CoachingPolicy.review(summary(sessionsCompleted: 0, sessionsTarget: 4))
        #expect(!proposals.contains { if case .carryForward = $0.kind { return true }; return false })
    }

    @Test func overTargetSessionsDoesNotCarryForward() {
        let proposals = CoachingPolicy.review(summary(sessionsCompleted: 5, sessionsTarget: 4))
        #expect(!proposals.contains { if case .carryForward = $0.kind { return true }; return false })
        #expect(proposals.contains { $0.kind == .stayCourse })
    }

    @Test func deloadOfferedOnceBlockWeekExceedsBlockLength() {
        let proposals = CoachingPolicy.review(summary(blockWeek: 5, blockLength: 4))
        #expect(proposals.contains { $0.kind == .deloadWeek })
    }

    @Test func deloadNotOfferedWithinBlock() {
        let proposals = CoachingPolicy.review(summary(blockWeek: 3, blockLength: 4))
        #expect(!proposals.contains { $0.kind == .deloadWeek })
    }

    @Test func deloadRequiresBothBlockWeekAndLength() {
        #expect(!CoachingPolicy.review(summary(blockWeek: 5, blockLength: nil)).contains { $0.kind == .deloadWeek })
        #expect(!CoachingPolicy.review(summary(blockWeek: nil, blockLength: 4)).contains { $0.kind == .deloadWeek })
    }

    @Test func multipleProposalsCoexist() {
        let squat = LiftWeekOutcome(exerciseID: squatID, name: "Barbell Squat", consecutiveUnderTarget: 2)
        let bench = LiftWeekOutcome(exerciseID: benchID, name: "Bench Press", consecutiveUnderTarget: 2)
        let proposals = CoachingPolicy.review(summary(
            sessionsCompleted: 2, sessionsTarget: 4,
            blockWeek: 6, blockLength: 5,
            lifts: [squat, bench]
        ))
        #expect(proposals.count == 4)
        #expect(proposals.contains { $0.kind == .deloadWeek })
        #expect(proposals.contains { $0.kind == .carryForward(missedSessions: 2) })
        #expect(proposals.contains { $0.kind == .progressionHold(exerciseID: squatID, name: "Barbell Squat") })
        #expect(proposals.contains { $0.kind == .progressionHold(exerciseID: benchID, name: "Bench Press") })
    }

    /// Privacy invariant: reason strings sync verbatim via CloudKit, so they
    /// must never leak a Health-derived signal (readiness/HRV/sleep).
    @Test func reasonsNeverMentionHealthDerivedSignals() {
        let banned = ["readiness", "hrv", "sleep", "recovery score", "heart rate"]
        let allProposals = CoachingPolicy.review(summary(
            sessionsCompleted: 1, sessionsTarget: 4,
            blockWeek: 7, blockLength: 4,
            lifts: [LiftWeekOutcome(exerciseID: squatID, name: "Barbell Squat", consecutiveUnderTarget: 4)]
        ))
        for proposal in allProposals {
            let lowered = proposal.reason.lowercased()
            for word in banned {
                #expect(!lowered.contains(word), "reason leaked a health-derived term: \(word)")
            }
        }
    }

    @Test func reviewIsDeterministic() {
        let s = summary(
            sessionsCompleted: 2, sessionsTarget: 3, blockWeek: 5, blockLength: 4,
            lifts: [LiftWeekOutcome(exerciseID: squatID, name: "Barbell Squat", consecutiveUnderTarget: 2)]
        )
        #expect(CoachingPolicy.review(s) == CoachingPolicy.review(s))
    }
}
