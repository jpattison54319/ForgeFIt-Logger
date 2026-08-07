import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct RoutineDetailPresentationTests {
    private let userID = ForgeFitDemo.userID

    @Test func everySetTypeHasItsSavedRoutineBadgeAndName() {
        let types = SetType.allCases
        let sets = types.enumerated().map { index, type in
            RoutineSetModel(userID: userID, position: index, setType: type)
        }
        let expectedBadges = ["W", "1", "D", "R", "2B", "3A", "M", "C"]
        let expectedNames = [
            "Warm-up", "Working", "Drop set", "Rest-pause",
            "Back-off", "AMRAP", "Myo-reps", "Cluster"
        ]

        #expect(zip(sets.indices, sets).map {
            RoutineSetPresentation.badgeText(for: $0.1, at: $0.0, in: sets)
        } == expectedBadges)
        #expect(types.map { SetTypeStyle.of($0).label } == expectedNames)
    }

    @Test func structuredShapesAndEffortAreReadable() {
        let myo = RoutineSetModel(
            userID: userID,
            setType: .myoRep,
            targetRPE: 8.5,
            plannedMiniSetCount: 3
        )
        let cluster = RoutineSetModel(
            userID: userID,
            setType: .cluster,
            targetRIR: 2,
            plannedMiniRepsJSON: "[3,3,2]"
        )
        let amrap = RoutineSetModel(
            userID: userID,
            setType: .amrap,
            targetDurationSeconds: 60
        )

        #expect(RoutineSetPresentation.repsText(for: myo) == "Activation + 3 minis")
        #expect(RoutineSetPresentation.effortText(for: myo) == "RPE 8.5")
        #expect(RoutineSetPresentation.repsText(for: cluster) == "3+3+2")
        #expect(RoutineSetPresentation.effortText(for: cluster) == "2 RIR")
        #expect(RoutineSetPresentation.repsText(for: amrap) == "Max reps in 1min")
    }

    @Test func liveMyoConversionPreservesItsPerformedShapeInRoutine() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let (routine, workout, target, performed) = try seed(in: context)
        performed.setType = .myoRep
        performed.miniReps = [4, 4, 3]

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)

        #expect(target.setType == .myoRep)
        #expect(target.plannedMiniSetCount == 3)
        #expect(target.targetRepsLow == 8)
        #expect(target.targetRepsHigh == 12)
    }

    @Test func otherStructuredConversionsPreserveTheirPlanShape() throws {
        let (clusterContainer, clusterContext) = try TestStore.make()
        defer { withExtendedLifetime(clusterContainer) {} }
        let (clusterRoutine, clusterWorkout, clusterTarget, clusterPerformed) = try seed(in: clusterContext)
        clusterPerformed.setType = .cluster
        clusterPerformed.miniReps = [3, 3, 2]
        let clusterPlan = RoutineChangeSync.detect(workout: clusterWorkout, routine: clusterRoutine)
        RoutineChangeSync.apply(clusterPlan, to: clusterRoutine, from: clusterWorkout, in: clusterContext)

        #expect(clusterTarget.setType == .cluster)
        #expect(clusterTarget.plannedMiniReps == [3, 3, 2])

        let (amrapContainer, amrapContext) = try TestStore.make()
        defer { withExtendedLifetime(amrapContainer) {} }
        let (amrapRoutine, amrapWorkout, amrapTarget, amrapPerformed) = try seed(in: amrapContext)
        amrapPerformed.setType = .amrap
        amrapPerformed.durationSeconds = 75
        let amrapPlan = RoutineChangeSync.detect(workout: amrapWorkout, routine: amrapRoutine)
        RoutineChangeSync.apply(amrapPlan, to: amrapRoutine, from: amrapWorkout, in: amrapContext)

        #expect(amrapTarget.setType == .amrap)
        #expect(amrapTarget.targetDurationSeconds == 75)
    }

    @Test func convertingBackToAFlatSetClearsTheOldStructuredShape() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let (routine, workout, target, performed) = try seed(in: context)
        target.setType = .amrap
        target.targetDurationSeconds = 60
        performed.setType = .working

        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        RoutineChangeSync.apply(plan, to: routine, from: workout, in: context)

        #expect(target.setType == .working)
        #expect(target.targetDurationSeconds == nil)
        #expect(target.plannedMiniSetCount == nil)
        #expect(target.plannedMiniReps.isEmpty)
    }

    private func seed(
        in context: ModelContext
    ) throws -> (RoutineModel, WorkoutModel, RoutineSetModel, SetModel) {
        let target = RoutineSetModel(
            userID: userID,
            position: 0,
            targetRepsLow: 8,
            targetRepsHigh: 12,
            targetWeight: 60,
            targetRPE: 8
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            position: 0,
            sets: [target]
        )
        let routine = RoutineModel(userID: userID, name: "Push", exercises: [routineExercise])
        let performed = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            sourceRoutineSetID: target.id
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: routineExercise.exerciseID,
            position: 0,
            sourceRoutineExerciseID: routineExercise.id,
            sets: [performed]
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            title: routine.name,
            exercises: [workoutExercise]
        )
        context.insert(routine)
        context.insert(workout)
        try context.save()
        return (routine, workout, target, performed)
    }
}
