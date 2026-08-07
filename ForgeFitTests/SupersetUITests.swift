import Testing
@testable import ForgeFit

@MainActor
struct SupersetUITests {
    @Test func paletteStartsWithDistinctNamedGroups() {
        #expect(SupersetUI.menuLabel(for: 0) == "Superset A · Purple")
        #expect(SupersetUI.menuLabel(for: 1) == "Superset B · Red")
        #expect(SupersetUI.menuLabel(for: 2) == "Superset C · Blue")
    }

    @Test func menuShowsColorsForCreateAndAssignmentChoices() {
        let items = SupersetUI.scrollSafeMenuItems(
            currentGroup: 0,
            availableGroups: [0, 1],
            onAssign: { _ in },
            onCreate: {},
            onUngroup: { _ in }
        )

        #expect(items[0].title == "Create Superset C · Blue")
        #expect(items[0].systemImage == "circle.fill")
        #expect(items[0].iconColor != nil)

        let addToSuperset = items.first { $0.title == "Add to Superset" }
        #expect(addToSuperset?.children.map(\.title) == ["Superset A · Purple", "Superset B · Red"])
        #expect(addToSuperset?.children.allSatisfy { $0.systemImage == "circle.fill" && $0.iconColor != nil } == true)
    }

    @Test func nextGroupAndCreateMenuReuseTheFirstAvailableIdentity() {
        let availableGroups = [0, 2]
        let nextGroup = SupersetUI.nextGroup(excluding: availableGroups)
        let items = SupersetUI.scrollSafeMenuItems(
            currentGroup: nil,
            availableGroups: availableGroups,
            onAssign: { _ in },
            onCreate: {},
            onUngroup: { _ in }
        )

        #expect(nextGroup == 1)
        #expect(items[0].title == "Create Superset B · Red")
    }
}
