import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

struct ActivationSuggestionMaterializerTests {
    @Test func typedRepsStillMaterializeSuggestedWeight() {
        let previous = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 12,
            weight: 100
        )
        let current = SetModel(
            userID: ForgeFitDemo.userID,
            setType: .myoRep,
            reps: 10
        )

        let didMaterialize = ActivationSuggestionMaterializer.materialize(
            set: current,
            previous: previous,
            side: 1,
            showsWeight: true
        )

        #expect(didMaterialize)
        #expect(current.reps == 10)
        #expect(current.weight == 100)
    }

    @Test func untouchedActivationMaterializesBothGhosts() {
        let previous = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 12,
            weight: 100
        )
        let current = SetModel(
            userID: ForgeFitDemo.userID,
            setType: .myoRep
        )

        let didMaterialize = ActivationSuggestionMaterializer.materialize(
            set: current,
            previous: previous,
            side: 1,
            showsWeight: true
        )

        #expect(didMaterialize)
        #expect(current.reps == 12)
        #expect(current.weight == 100)
    }

    @Test func typedWeightStillMaterializesSuggestedReps() {
        let previous = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 12,
            weight: 100
        )
        let current = SetModel(
            userID: ForgeFitDemo.userID,
            setType: .myoRep,
            weight: 105
        )

        let didMaterialize = ActivationSuggestionMaterializer.materialize(
            set: current,
            previous: previous,
            side: 1,
            showsWeight: true
        )

        #expect(didMaterialize)
        #expect(current.reps == 12)
        #expect(current.weight == 105)
    }

    @Test func assistedActivationMaterializesAssistanceInsteadOfExternalWeight() {
        let previous = SetModel(
            userID: ForgeFitDemo.userID,
            weightMode: .bodyweightAssisted,
            reps: 9,
            assistanceWeight: 20
        )
        let current = SetModel(
            userID: ForgeFitDemo.userID,
            setType: .myoRep,
            weightMode: .bodyweightAssisted
        )

        let didMaterialize = ActivationSuggestionMaterializer.materialize(
            set: current,
            previous: previous,
            side: 1,
            showsWeight: true
        )

        #expect(didMaterialize)
        #expect(current.reps == 9)
        #expect(current.assistanceWeight == 20)
        #expect(current.weight == nil)
    }
}
