import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct SetTypeRetirementBackfillTests {
    @Test func cooperativeBackfillIsDurableIdempotentAndStampsParents() async throws {
        let (container, callerContext) = try TestStore.make()
        callerContext.autosaveEnabled = false
        let userID = ForgeFitDemo.userID
        let oldStamp = Date.distantPast

        let workoutSet = SetModel(userID: userID, setType: .restPause, reps: 10)
        workoutSet.updatedAt = oldStamp
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            sets: [workoutSet]
        )
        workoutExercise.updatedAt = oldStamp
        let workout = WorkoutModel(
            userID: userID,
            title: "Legacy rest-pause",
            endedAt: .now,
            updatedAt: oldStamp,
            exercises: [workoutExercise]
        )

        let routineSet = RoutineSetModel(userID: userID, setType: .restPause)
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            updatedAt: oldStamp,
            sets: [routineSet]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Legacy routine",
            updatedAt: oldStamp,
            exercises: [routineExercise]
        )
        callerContext.insert(workout)
        callerContext.insert(routine)
        try callerContext.save()

        await SetTypeRetirementBackfill.runCooperatively(in: callerContext)

        var verification = ModelContext(container)
        var persistedWorkoutSet = try #require(
            try verification.fetch(FetchDescriptor<SetModel>()).first
        )
        var persistedRoutineSet = try #require(
            try verification.fetch(FetchDescriptor<RoutineSetModel>()).first
        )
        var persistedWorkout = try #require(
            try verification.fetch(FetchDescriptor<WorkoutModel>()).first
        )
        var persistedRoutine = try #require(
            try verification.fetch(FetchDescriptor<RoutineModel>()).first
        )
        #expect(persistedWorkoutSet.setType == .myoRep)
        #expect(persistedRoutineSet.setType == .myoRep)
        #expect(persistedWorkout.updatedAt > oldStamp)
        #expect(persistedRoutine.updatedAt > oldStamp)
        #expect(!callerContext.hasChanges)
        let workoutStamp = persistedWorkout.updatedAt
        let routineStamp = persistedRoutine.updatedAt

        await SetTypeRetirementBackfill.runCooperatively(in: callerContext)

        verification = ModelContext(container)
        persistedWorkoutSet = try #require(try verification.fetch(FetchDescriptor<SetModel>()).first)
        persistedRoutineSet = try #require(try verification.fetch(FetchDescriptor<RoutineSetModel>()).first)
        persistedWorkout = try #require(try verification.fetch(FetchDescriptor<WorkoutModel>()).first)
        persistedRoutine = try #require(try verification.fetch(FetchDescriptor<RoutineModel>()).first)
        #expect(persistedWorkoutSet.setType == .myoRep)
        #expect(persistedRoutineSet.setType == .myoRep)
        #expect(persistedWorkout.updatedAt == workoutStamp)
        #expect(persistedRoutine.updatedAt == routineStamp)
    }
}
