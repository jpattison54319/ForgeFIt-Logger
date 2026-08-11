import Testing
@testable import ForgeFit

@MainActor
struct MyoRepSetFlowTests {
    @Test func detectsProgressAcrossEitherSide() {
        #expect(!MyoRepSetFlow.hasStarted(
            side1ActivationReps: nil,
            side1MiniReps: [],
            side2ActivationReps: nil,
            side2MiniReps: []
        ))
        #expect(MyoRepSetFlow.hasStarted(
            side1ActivationReps: 12,
            side1MiniReps: [],
            side2ActivationReps: nil,
            side2MiniReps: []
        ))
        #expect(MyoRepSetFlow.hasStarted(
            side1ActivationReps: nil,
            side1MiniReps: [],
            side2ActivationReps: nil,
            side2MiniReps: [4]
        ))
    }

    @Test func resumesAtTheFirstUnloggedRequiredSide() {
        #expect(MyoRepSetFlow.startingSide(
            isUnilateral: true,
            side1ActivationReps: nil,
            side2ActivationReps: nil
        ) == 1)
        #expect(MyoRepSetFlow.startingSide(
            isUnilateral: true,
            side1ActivationReps: 12,
            side2ActivationReps: nil
        ) == 2)
        #expect(MyoRepSetFlow.startingSide(
            isUnilateral: true,
            side1ActivationReps: 12,
            side2ActivationReps: 11,
            preferredSide: 2
        ) == 2)
        #expect(MyoRepSetFlow.startingSide(
            isUnilateral: false,
            side1ActivationReps: 12,
            side2ActivationReps: nil,
            preferredSide: 2
        ) == 1)
    }

    @Test func finishRequiresEveryActivationTheExerciseUses() {
        #expect(!MyoRepSetFlow.canFinish(
            isUnilateral: false,
            side1ActivationReps: nil,
            side2ActivationReps: nil
        ))
        #expect(MyoRepSetFlow.canFinish(
            isUnilateral: false,
            side1ActivationReps: 12,
            side2ActivationReps: nil
        ))
        #expect(!MyoRepSetFlow.canFinish(
            isUnilateral: true,
            side1ActivationReps: 12,
            side2ActivationReps: nil
        ))
        #expect(MyoRepSetFlow.canFinish(
            isUnilateral: true,
            side1ActivationReps: 12,
            side2ActivationReps: 11
        ))
    }

    @Test func nextMiniDefaultsFromTheMostRelevantPerformedSeries() {
        #expect(MyoRepSetFlow.nextMiniReps(
            logged: [5, 4],
            mirrored: [6],
            previous: [7]
        ) == 4)
        #expect(MyoRepSetFlow.nextMiniReps(
            logged: [],
            mirrored: [5, 4],
            previous: [7]
        ) == 5)
        #expect(MyoRepSetFlow.nextMiniReps(
            logged: [],
            mirrored: [],
            previous: [6, 5]
        ) == 6)
        #expect(MyoRepSetFlow.nextMiniReps(
            logged: [],
            mirrored: [],
            previous: []
        ) == 1)
    }

    @Test func totalRepsIncludesEveryMiniSet() {
        #expect(MyoRepSetFlow.totalReps(activationReps: 12, miniReps: [5, 4, 4]) == 25)
        #expect(MyoRepSetFlow.totalReps(activationReps: nil, miniReps: [3, 3]) == 6)
    }
}
