import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct PostWorkoutCompletionPolicyTests {
    @Test("Only the latest share request may present a result")
    func shareRequestGateRejectsCancelledAndSupersededWork() {
        var gate = PostWorkoutShareRequestGate()

        let first = gate.begin()
        #expect(gate.shouldApply(first))

        let replacement = gate.begin()
        #expect(replacement.generation > first.generation)
        #expect(!gate.shouldApply(first))
        #expect(gate.shouldApply(replacement))
        let didFinishFirst = gate.finish(first)
        let didFinishReplacement = gate.finish(replacement)
        #expect(!didFinishFirst)
        #expect(didFinishReplacement)

        let cancelled = gate.begin()
        gate.cancel()
        #expect(!gate.shouldApply(cancelled))
    }

    @Test("A canonical routine tombstone suppresses the update prompt")
    func deletedCanonicalRoutineIsNotPromptEligible() {
        let routineID = UUID()
        let userID = UUID()
        let staleLive = RoutineModel(
            id: routineID,
            userID: userID,
            name: "Upper",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let tombstone = RoutineModel(
            id: routineID,
            userID: userID,
            name: "Upper",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            deletedAt: Date(timeIntervalSinceReferenceDate: 200)
        )

        #expect(PostWorkoutRoutineUpdatePolicy.liveCanonicalRoutine(
            in: [staleLive, tombstone]
        ) == nil)
        #expect(PostWorkoutRoutineUpdatePolicy.liveCanonicalRoutine(
            in: [tombstone, staleLive]
        ) == nil)
    }

    @Test("A newer live authored routine remains prompt eligible")
    func liveCanonicalRoutineRemainsPromptEligible() {
        let routineID = UUID()
        let userID = UUID()
        let oldTombstone = RoutineModel(
            id: routineID,
            userID: userID,
            name: "Upper",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 200),
            deletedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let liveExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300)
        )
        let newerLive = RoutineModel(
            id: routineID,
            userID: userID,
            name: "Upper revised",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            updatedAt: Date(timeIntervalSinceReferenceDate: 300),
            exercises: [liveExercise]
        )

        let resolved = PostWorkoutRoutineUpdatePolicy.liveCanonicalRoutine(
            in: [oldTombstone, newerLive]
        )
        #expect(resolved === newerLive)
    }
}
