import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine block titles")
struct RoutineBlockPresentationTests {
    @Test("A completed one-section block keeps its exact conditioning name")
    func conditioningPlanTitle() {
        let named = plan(sectionNames: ["  AX400  "])

        #expect(ConditioningPlanPresentation.title(for: named) == "AX400")
        #expect(ConditioningPlanPresentation.accessibilityLabel(for: named) == "AX400 conditioning block")
    }

    @Test("Historical conditioning has safe generic title fallbacks")
    func conditioningPlanTitleFallbacks() {
        #expect(ConditioningPlanPresentation.title(for: nil) == "Conditioning")
        #expect(ConditioningPlanPresentation.title(for: plan(sectionNames: ["  \n "])) == "Conditioning")
        #expect(ConditioningPlanPresentation.title(for: plan(sectionNames: ["Strength", "Finisher"])) == "Conditioning")
        #expect(ConditioningPlanPresentation.accessibilityLabel(for: nil) == "Conditioning block")
    }

    @Test("A single named conditioning section uses its actual name")
    func namedConditioningSection() {
        let block = conditioningBlock(sectionNames: ["AX400"])

        #expect(RoutineBlockPresentation.title(for: block) == "AX400")
    }

    @Test("Conditioning keeps a generic fallback when no single useful name exists")
    func conditioningFallbacks() {
        let unnamed = conditioningBlock(sectionNames: ["  \n "])
        let multiSection = conditioningBlock(sectionNames: ["Strength", "Finisher"])
        let invalid = RoutineBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planJSON: "not-json"
        )

        #expect(RoutineBlockPresentation.title(for: unnamed) == "Conditioning")
        #expect(RoutineBlockPresentation.title(for: multiSection) == "Conditioning")
        #expect(RoutineBlockPresentation.title(for: invalid) == "Conditioning")
    }

    @Test("Non-conditioning blocks retain their kind title")
    func nonConditioningTitle() {
        let block = RoutineBlockModel(userID: ForgeFitDemo.userID, kind: .yoga)

        #expect(RoutineBlockPresentation.title(for: block) == "Yoga")
    }

    private func conditioningBlock(sectionNames: [String]) -> RoutineBlockModel {
        let plan = plan(sectionNames: sectionNames)
        return RoutineBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planJSON: plan.encodedJSON()
        )
    }

    private func plan(sectionNames: [String]) -> ConditioningPlan {
        ConditioningPlan(
            sections: sectionNames.map { ConditioningSection(name: $0, format: .amrap) }
        )
    }
}
