import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct AccountResetServiceTests {
    @Test func deleteAllLocalModelsRemovesUserDataAndProgress() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let userID = ForgeFitDemo.userID

        let exercise = ExerciseLibraryModel(ownerID: userID, name: "Custom Press")
        let alias = ExerciseAliasModel(exerciseID: exercise.id, ownerID: userID, alias: "Press")
        let note = UserExerciseNoteModel(userID: userID, exerciseID: exercise.id, note: "Seat 4")
        let folder = RoutineFolderModel(userID: userID, name: "Plan")
        let routineSet = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8)
        let routineExercise = RoutineExerciseModel(userID: userID, exerciseID: exercise.id, position: 0, sets: [routineSet])
        let routine = RoutineModel(userID: userID, name: "Push", folderID: folder.id, exercises: [routineExercise])
        let workoutSet = SetModel(userID: userID, position: 0, reps: 8, weight: 80, completedAt: .now)
        let workoutExercise = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: [workoutSet])
        let cardio = CardioSessionModel(userID: userID, modality: CardioKind.run.rawValue)
        let route = CardioRoutePointModel(
            userID: userID,
            cardioSessionID: cardio.id,
            timestamp: .now,
            latitude: 1,
            longitude: 1
        )
        let split = CardioSplitModel(
            userID: userID,
            cardioSessionID: cardio.id,
            index: 0,
            distanceMeters: 1_000,
            durationSeconds: 300,
            paceSecondsPerKm: 300,
            startedAt: .now,
            endedAt: .now
        )
        cardio.routePoints = [route]
        cardio.splits = [split]
        let workout = WorkoutModel(userID: userID, exercises: [workoutExercise], cardioSessions: [cardio])
        let batch = WorkoutImportBatchModel(userID: userID, source: "hevy", fileName: "workouts.csv")
        let progress = UserProgressModel(userID: userID, totalXP: 500, level: 3)
        let xpEvent = WorkoutXPEventModel(userID: userID, workoutID: workout.id, amount: 120)

        context.insert(exercise)
        context.insert(alias)
        context.insert(note)
        context.insert(folder)
        context.insert(routine)
        context.insert(workout)
        context.insert(batch)
        context.insert(progress)
        context.insert(xpEvent)
        try context.save()

        try AccountResetService.deleteAllLocalModels(in: context)

        #expect(try context.fetch(FetchDescriptor<WorkoutModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RoutineModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkoutImportBatchModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<UserProgressModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CardioRoutePointModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CardioSplitModel>()).isEmpty)
    }
}
