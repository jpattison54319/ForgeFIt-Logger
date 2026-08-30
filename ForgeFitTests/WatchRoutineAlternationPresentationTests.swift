import ForgeData
import Testing
@testable import ForgeFit

@MainActor
@Suite("Watch routine alternation presentation")
struct WatchRoutineAlternationPresentationTests {
    @Test("Every member exposes its cyclic successor and exactly one member is due")
    func projectsOrderedCycle() {
        let userID = ForgeFitDemo.userID
        let first = RoutineModel(userID: userID, name: "A")
        let second = RoutineModel(userID: userID, name: "B")
        let third = RoutineModel(userID: userID, name: "C")
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: first.id,
            partnerRoutineID: second.id,
            memberRoutineIDs: [first.id, second.id, third.id]
        )
        let state = RoutineAlternationService.State(
            alternation: alternation,
            owner: first,
            members: [first, second, third],
            due: second
        )

        let presentations = WatchLink.routineAlternationPresentations(states: [state])

        #expect(presentations[first.id]?.nextName == "B")
        #expect(presentations[second.id]?.nextName == "C")
        #expect(presentations[third.id]?.nextName == "A")
        #expect(presentations.values.count(where: { $0.isDue }) == 1)
        #expect(presentations[second.id]?.isDue == true)
    }
}
