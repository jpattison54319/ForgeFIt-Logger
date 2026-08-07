import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct BlockSetPrefillPolicyTests {
    private let userID = ForgeFitDemo.userID

    @Test func workingGhostCarriesIntoMyoWhenMyoHistoryIsAbsent() {
        // 50 lb persisted as kilograms was a hidden routine target. The row
        // visibly showed 72.5 kg from Working history, so that is what the
        // Myo-rep activation must materialize.
        let set = SetModel(userID: userID, setType: .myoRep, reps: 5, weight: 22.6796)

        BlockSetPrefillPolicy.apply(
            to: set,
            visibleWeight: 72.5,
            visibleReps: 8,
            previousBlock: nil,
            preservesEnteredWeight: false,
            preservesEnteredReps: false
        )

        #expect(set.weight == 72.5)
        #expect(set.reps == 8)
    }

    @Test func priorMyoActivationWinsOverWorkingGhost() {
        let previousMyo = SetModel(
            userID: userID,
            setType: .myoRep,
            reps: 12,
            weight: 67.5
        )
        let set = SetModel(userID: userID, setType: .myoRep, weight: 22.6796)

        BlockSetPrefillPolicy.apply(
            to: set,
            visibleWeight: 72.5,
            visibleReps: 8,
            previousBlock: previousMyo,
            preservesEnteredWeight: false,
            preservesEnteredReps: false
        )

        #expect(set.weight == 67.5)
        #expect(set.reps == 12)
        #expect(set.miniReps.isEmpty)
    }

    @Test func explicitEntriesSurviveATypeChange() {
        let previousMyo = SetModel(
            userID: userID,
            setType: .myoRep,
            reps: 12,
            weight: 67.5
        )
        let set = SetModel(userID: userID, setType: .myoRep, reps: 9, weight: 75)

        BlockSetPrefillPolicy.apply(
            to: set,
            visibleWeight: 75,
            visibleReps: 9,
            previousBlock: previousMyo,
            preservesEnteredWeight: true,
            preservesEnteredReps: true
        )

        #expect(set.weight == 75)
        #expect(set.reps == 9)
    }

    @Test func assistedActivationUsesTheModeSpecificField() {
        let previousMyo = SetModel(
            userID: userID,
            setType: .myoRep,
            weightMode: .bodyweightAssisted,
            reps: 9,
            assistanceWeight: 20
        )
        let set = SetModel(
            userID: userID,
            setType: .myoRep,
            weightMode: .bodyweightAssisted,
            assistanceWeight: 25
        )

        BlockSetPrefillPolicy.apply(
            to: set,
            visibleWeight: 25,
            visibleReps: 8,
            previousBlock: previousMyo,
            preservesEnteredWeight: false,
            preservesEnteredReps: false
        )

        #expect(set.assistanceWeight == 20)
        #expect(set.weight == nil)
        #expect(set.reps == 9)
    }
}
