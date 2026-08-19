import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine block titles")
struct RoutineBlockPresentationTests {
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
        let plan = ConditioningPlan(
            sections: sectionNames.map { ConditioningSection(name: $0, format: .amrap) }
        )
        return RoutineBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planJSON: plan.encodedJSON()
        )
    }
}
