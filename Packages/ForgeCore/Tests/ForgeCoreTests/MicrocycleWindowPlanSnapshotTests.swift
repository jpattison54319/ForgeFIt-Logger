import Foundation
import Testing
@testable import ForgeCore

struct MicrocycleWindowPlanSnapshotTests {
    private let a = MicrocycleRoutineSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
        name: "A",
        position: 0
    )
    private let b = MicrocycleRoutineSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
        name: "B",
        position: 1
    )
    private let c = MicrocycleRoutineSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
        name: "C",
        position: 2
    )
    private let restID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!

    @Test func legacyRoutineArrayDecodesWithoutRestDays() throws {
        let json = String(
            data: try JSONEncoder().encode([a, b]),
            encoding: .utf8
        )!

        let plan = MicrocycleWindowPlanSnapshot.decode(from: json)

        #expect(plan.routines == [a, b])
        #expect(plan.plannedRestDays.isEmpty)
    }

    @Test func addingAndMovingRestPreservesFolderRoutineOrder() {
        let added = MicrocycleWindowPlanSnapshot(routines: [a, b, c])
            .addingRestDay(id: restID)
        let moved = added.movingRestDay(id: restID, to: 1)

        #expect(moved.orderedItems.map(\.id) == [a.id, restID, b.id, c.id])
        #expect(moved.routines == [a, b, c])
        #expect(moved.plannedRestDays == [.init(id: restID, position: 1)])
    }

    @Test func replacingFolderRoutinesKeepsRestAtItsInjectedIndex() {
        let original = MicrocycleWindowPlanSnapshot(
            routines: [a, b, c],
            plannedRestDays: [.init(id: restID, position: 2)]
        )

        let replaced = original.replacingRoutines([c, a, b])

        #expect(replaced.orderedItems.map(\.id) == [a.id, b.id, restID, c.id])
        #expect(replaced.routines == [c, a, b])
    }

    @Test func encodedPlanRoundTripsAndRemovalLeavesRoutinesUntouched() throws {
        let plan = MicrocycleWindowPlanSnapshot(routines: [a, b])
            .addingRestDay(id: restID)
            .movingRestDay(id: restID, to: 0)
        let json = try #require(plan.encodedJSON())

        let decoded = MicrocycleWindowPlanSnapshot.decode(from: json)
        let removed = decoded.removingRestDay(id: restID)

        #expect(decoded == plan)
        #expect(removed.orderedItems.map(\.id) == [a.id, b.id])
        #expect(removed.routines == [a, b])
    }
}
