import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct MyoRepEditDraftTests {
    private let userID = ForgeFitDemo.userID

    @Test func savePreservesCompletionAndRecomputesBilateralVolume() {
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let set = SetModel(
            userID: userID,
            setType: .myoRep,
            reps: 10,
            weight: 50,
            completedAt: completedAt
        )
        set.miniReps = [4, 4]
        var draft = MyoRepEditDraft(set: set, displayUnit: .kg)
        draft.weightDisplay = 55
        draft.side1ActivationReps = 12
        draft.side1MiniReps = [5, 4, 3]

        draft.apply(to: set, displayUnit: .kg, showsWeight: true, isUnilateral: false)

        #expect(set.completedAt == completedAt)
        #expect(set.modeWeight == 55)
        #expect(set.reps == 12)
        #expect(set.miniReps == [5, 4, 3])
        #expect(set.side2Reps == nil)
        #expect(set.side2MiniReps.isEmpty)
        #expect(abs((set.totalVolume ?? 0) - 55 * 24) < 0.001)
    }

    @Test func saveConvertsDisplayWeightThroughTheSelectedUnit() {
        let set = SetModel(
            userID: userID,
            setType: .myoRep,
            weightMode: .bodyweightAssisted,
            reps: 8,
            assistanceWeight: 9.0718474
        )
        var draft = MyoRepEditDraft(set: set, displayUnit: .lb)
        draft.weightDisplay = 25

        draft.apply(to: set, displayUnit: .lb, showsWeight: true, isUnilateral: false)

        #expect(set.weight == nil)
        #expect(set.assistanceWeight != nil)
        #expect(abs((set.assistanceWeight ?? 0) - 11.33980925) < 0.0001)
    }

    @Test func unilateralSaveKeepsBothPerformedSeries() {
        let set = SetModel(
            userID: userID,
            setType: .myoRep,
            reps: 10,
            weight: 20
        )
        var draft = MyoRepEditDraft(set: set, displayUnit: .kg)
        draft.side1ActivationReps = 11
        draft.side1MiniReps = [4, 3]
        draft.side2ActivationReps = 10
        draft.side2MiniReps = [4, 3, 3]

        draft.apply(to: set, displayUnit: .kg, showsWeight: true, isUnilateral: true)

        #expect(set.reps == 11)
        #expect(set.miniReps == [4, 3])
        #expect(set.side2Reps == 10)
        #expect(set.side2MiniReps == [4, 3, 3])
        #expect(abs((set.totalVolume ?? 0) - 20 * 38) < 0.001)
    }

    @Test func weightlessExerciseDoesNotOverwriteStoredModeWeight() {
        let set = SetModel(
            userID: userID,
            setType: .myoRep,
            reps: 8,
            weight: 35
        )
        var draft = MyoRepEditDraft(set: set, displayUnit: .kg)
        draft.weightDisplay = 99
        draft.side1ActivationReps = 10

        draft.apply(to: set, displayUnit: .kg, showsWeight: false, isUnilateral: false)

        #expect(set.modeWeight == 35)
        #expect(set.reps == 10)
    }
}
