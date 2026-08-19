import Foundation
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Alternating routine slot presentation")
struct AlternatingRoutineSlotResolverTests {
    @Test("An unpaired routine keeps its own slot")
    func keepsUnpairedRoutineInPlace() {
        let routine = routine("Unpaired")

        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: routine, state: nil).id == routine.id)
    }

    @Test("A routine outside the pair is never displaced")
    func keepsUnrelatedRoutineInPlace() {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let unrelated = routine("Push")
        let state = alternationState(owner: owner, partner: partner, due: partner)

        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: unrelated, state: state).id == unrelated.id)
    }

    @Test("The due routine occupies the owner slot and the other routine occupies the partner slot")
    func swapsPresentedRoutinesWhenThePartnerIsDue() {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let state = alternationState(owner: owner, partner: partner, due: partner)

        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: owner, state: state).id == partner.id)
        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: partner, state: state).id == owner.id)
    }

    @Test("The pair returns to its original slots when the owner is due")
    func restoresPresentedRoutinesWhenTheOwnerIsDue() {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let state = alternationState(owner: owner, partner: partner, due: owner)

        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: owner, state: state).id == owner.id)
        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: partner, state: state).id == partner.id)
    }

    @Test("Completed workouts drive a full owner-partner-owner presentation cycle")
    func followsCompletionHistoryThroughBothSwapDirections() throws {
        let owner = routine("AX400")
        let partner = routine("Cindy")
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let alternation = RoutineAlternationModel(
            userID: owner.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: base
        )

        let initial = try #require(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: []
        ))
        expectSlots(owner: owner, partner: partner, state: initial, ownerSlot: owner, partnerSlot: partner)

        let ownerCompletion = workout(routine: owner, endedAt: base.addingTimeInterval(100))
        let afterOwner = try #require(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: [ownerCompletion]
        ))
        expectSlots(owner: owner, partner: partner, state: afterOwner, ownerSlot: partner, partnerSlot: owner)

        let repeatedOwner = workout(routine: owner, endedAt: base.addingTimeInterval(200))
        let afterStartingOtherInstead = try #require(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: [ownerCompletion, repeatedOwner]
        ))
        expectSlots(
            owner: owner,
            partner: partner,
            state: afterStartingOtherInstead,
            ownerSlot: partner,
            partnerSlot: owner
        )

        let partnerCompletion = workout(routine: partner, endedAt: base.addingTimeInterval(300))
        let afterPartner = try #require(RoutineAlternationService.state(
            for: alternation,
            routines: [owner, partner],
            workouts: [ownerCompletion, repeatedOwner, partnerCompletion]
        ))
        expectSlots(owner: owner, partner: partner, state: afterPartner, ownerSlot: owner, partnerSlot: partner)
    }

    private func alternationState(
        owner: RoutineModel,
        partner: RoutineModel,
        due: RoutineModel
    ) -> RoutineAlternationService.State {
        RoutineAlternationService.State(
            alternation: RoutineAlternationModel(
                userID: owner.userID,
                ownerRoutineID: owner.id,
                partnerRoutineID: partner.id
            ),
            owner: owner,
            partner: partner,
            due: due
        )
    }

    private func routine(_ name: String) -> RoutineModel {
        RoutineModel(userID: ForgeFitDemo.userID, name: name)
    }

    private func workout(routine: RoutineModel, endedAt: Date) -> WorkoutModel {
        WorkoutModel(
            userID: routine.userID,
            routineID: routine.id,
            title: routine.name,
            startedAt: endedAt.addingTimeInterval(-1_800),
            endedAt: endedAt
        )
    }

    private func expectSlots(
        owner: RoutineModel,
        partner: RoutineModel,
        state: RoutineAlternationService.State,
        ownerSlot: RoutineModel,
        partnerSlot: RoutineModel
    ) {
        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: owner, state: state).id == ownerSlot.id)
        #expect(AlternatingRoutineSlotResolver.presentedRoutine(for: partner, state: state).id == partnerSlot.id)
    }
}
