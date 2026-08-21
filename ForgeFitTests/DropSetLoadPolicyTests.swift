import ForgeCore
import Testing
@testable import ForgeFit

@MainActor
struct DropSetLoadPolicyTests {
    @Test func visibleGhostWinsOverHiddenRoutineTarget() {
        let source = DropSetLoadPolicy.visibleSourceWeight(
            enteredWeightKg: 5,
            suggestedWeightKg: 10,
            isShowingSuggestion: true
        )
        let assistedDrop = DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: source,
            mode: .bodyweightAssisted,
            bodyweightKg: 80,
            displayUnit: .kg
        )

        #expect(source == 10)
        #expect(assistedDrop == 27.5)
    }

    @Test func enteredLoadWinsWhenTheFieldIsNotShowingAGhost() {
        #expect(DropSetLoadPolicy.visibleSourceWeight(
            enteredWeightKg: 12.5,
            suggestedWeightKg: 10,
            isShowingSuggestion: false
        ) == 12.5)
    }

    @Test func externalAndAddedLoadsDecrease() {
        let external = DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: 100,
            mode: .external,
            bodyweightKg: nil,
            displayUnit: .kg
        )
        let added = DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: 10,
            mode: .bodyweightAdded,
            bodyweightKg: 80,
            displayUnit: .kg
        )

        #expect(external == 75)
        #expect(added == 7.5)
    }

    @Test func assistedLoadIncreasesAssistanceToReduceEffectiveLoad() {
        // The logger renders this stored 10 kg assistance under a "-KG"
        // heading. A 25% effective-load drop from 70 kg to 52.5 kg therefore
        // needs 27.5 kg of assistance — visibly a larger negative number.
        let assisted = DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: 10,
            mode: .bodyweightAssisted,
            bodyweightKg: 80,
            displayUnit: .kg
        )

        #expect(assisted == 27.5)
    }

    @Test func assistedLoadStillMovesInTheRightDirectionWithoutBodyweight() {
        let assisted = DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: 10,
            mode: .bodyweightAssisted,
            bodyweightKg: nil,
            displayUnit: .kg
        )

        #expect(assisted == 12.5)
    }

    @Test func pureBodyweightHasNoNumericDropPrefill() {
        #expect(DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: 10,
            mode: .bodyweight,
            bodyweightKg: 80,
            displayUnit: .kg
        ) == nil)
    }

    @Test func poundSuggestionsRoundInPoundSteps() {
        let sourceKg = WeightUnit.lb.kilograms(fromDisplayValue: 100)
        let resultKg = DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: sourceKg,
            mode: .external,
            bodyweightKg: nil,
            displayUnit: .lb
        )

        #expect(resultKg != nil)
        #expect(abs(WeightUnit.lb.displayValue(fromKilograms: resultKg!) - 75) < 0.0001)
    }
}
