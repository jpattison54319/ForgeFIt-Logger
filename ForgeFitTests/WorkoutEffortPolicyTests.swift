import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

struct WorkoutEffortPolicyTests {
    private let userID = ForgeFitDemo.userID

    @Test func initialEffortHonorsVisibilityAndFailurePreferences() {
        let hidden = WorkoutEffortPolicy.initialEffort(
            setType: .working,
            targetRPE: 8,
            targetRIR: 2,
            preferences: .init(logsEffort: false, defaultsToFailure: false)
        )
        #expect(hidden.rpe == nil)
        #expect(hidden.rir == nil)

        let failure = WorkoutEffortPolicy.initialEffort(
            setType: .working,
            targetRPE: 8,
            targetRIR: 2,
            preferences: .init(logsEffort: true, defaultsToFailure: true)
        )
        #expect(failure.rpe == nil)
        #expect(failure.rir == nil)

        let failureWarmup = WorkoutEffortPolicy.initialEffort(
            setType: .warmup,
            targetRPE: 5,
            targetRIR: nil,
            preferences: .init(logsEffort: true, defaultsToFailure: true)
        )
        #expect(failureWarmup.rpe == 5)
    }

    @Test func hiddenEffortIsRemovedFromEverySet() {
        let completed = SetModel(userID: userID, rpe: 9, rir: 1, completedAt: .now)
        let pending = SetModel(userID: userID, rpe: 8, rir: 2)
        let workout = workout(with: [completed, pending])

        let changed = WorkoutEffortPolicy.prepareForFinish(
            workout,
            preferences: .init(logsEffort: false, defaultsToFailure: false)
        )

        #expect(changed)
        #expect(completed.rpe == nil && completed.rir == nil)
        #expect(pending.rpe == nil && pending.rir == nil)
    }

    @Test func failureDefaultsCompletedWorkButPreservesWarmupsManualRatingsAndPendingSets() {
        let working = SetModel(userID: userID, setType: .working, completedAt: .now)
        let drop = SetModel(userID: userID, setType: .drop, completedAt: .now)
        let warmup = SetModel(userID: userID, setType: .warmup, completedAt: .now)
        let manual = SetModel(userID: userID, setType: .working, rpe: 8, rir: 2, completedAt: .now)
        let pending = SetModel(userID: userID, setType: .working)
        let workout = workout(with: [working, drop, warmup, manual, pending])

        WorkoutEffortPolicy.prepareForFinish(
            workout,
            preferences: .init(logsEffort: true, defaultsToFailure: true)
        )

        #expect(working.rpe == 10 && working.rir == 0)
        #expect(drop.rpe == 10 && drop.rir == 0)
        #expect(warmup.rpe == nil && warmup.rir == nil)
        #expect(manual.rpe == 8 && manual.rir == 2)
        #expect(pending.rpe == nil && pending.rir == nil)
    }

    private func workout(with sets: [SetModel]) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: .init(), sets: sets)]
        )
    }
}
