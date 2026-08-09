import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct AccountResetServiceTests {
    @Test
    func resetOwnsPendingExperimentRoutes() {
        #expect(AppPreferenceKeys.localOnly.contains(
            ExperimentNotificationRoute.pendingURLDefaultsKey
        ))
        #expect(AppPreferenceKeys.localOnly.contains(
            ExperimentNotificationRoute.pendingExperimentIDDefaultsKey
        ))
    }

    @Test func deleteAllLocalModelsRemovesUserDataAndProgress() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
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
        let coachingProfile = CoachingProfileModel(userID: userID, focusRaw: "strength", goalRaw: "build-muscle", experienceRaw: "beginner")
        let coachedProgram = CoachedProgramModel(userID: userID, folderID: folder.id, startDate: .now)
        let weekOverride = CoachingWeekOverrideModel(userID: userID, kindRaw: "progressionHold", weekStart: .now)
        let tracking = MicrocycleTrackingModel(
            userID: userID,
            folderID: folder.id,
            folderName: folder.name,
            anchorDate: .now,
            durationDays: 10
        )
        let window = MicrocycleWindowModel(
            userID: userID,
            trackingID: tracking.id,
            folderID: folder.id,
            folderName: folder.name,
            index: 0,
            startsAt: .now,
            endsAt: Date().addingTimeInterval(10 * 86_400),
            timeZoneIdentifier: "UTC",
            routines: []
        )
        let restDay = RestDayModel(userID: userID, date: .now)

        context.insert(exercise)
        context.insert(alias)
        context.insert(note)
        context.insert(folder)
        context.insert(routine)
        context.insert(workout)
        context.insert(batch)
        context.insert(progress)
        context.insert(xpEvent)
        context.insert(coachingProfile)
        context.insert(coachedProgram)
        context.insert(weekOverride)
        context.insert(tracking)
        context.insert(window)
        context.insert(restDay)
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
        #expect(try context.fetch(FetchDescriptor<CoachingProfileModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CoachedProgramModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CoachingWeekOverrideModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MicrocycleTrackingModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<RestDayModel>()).isEmpty)
    }

    /// Schema-derived completeness: one row of EVERY registered model type
    /// goes in, reset runs, every type must count zero. A future model that
    /// is registered but missing from the factory or the delete list fails
    /// this test by construction — this is how ProgressionSuggestionModel
    /// and DailyCheckinModel slipped through the hand-maintained list.
    @Test func resetDeletesEveryRegisteredModelType() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let userID = ForgeFitDemo.userID

        for modelType in ForgeDataSchema.models {
            insertSample(of: modelType, userID: userID, in: context)
        }
        try context.save()
        for modelType in ForgeDataSchema.models {
            #expect(try count(modelType, in: context) > 0, "factory produced no row for \(modelType)")
        }

        try AccountResetService.deleteAllLocalModels(in: context)

        for modelType in ForgeDataSchema.models {
            #expect(try count(modelType, in: context) == 0, "\(modelType) survives Erase All Data")
        }
    }

    private func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    /// One minimal row per model type. The `default` branch fails loudly:
    /// registering a 22nd model without teaching this factory (and the
    /// reset list) is a test failure, not a silent gap.
    private func insertSample(of modelType: any PersistentModel.Type, userID: UUID, in context: ModelContext) {
        switch modelType {
        case is ExerciseLibraryModel.Type:
            context.insert(ExerciseLibraryModel(name: "Sample"))
        case is ExerciseAliasModel.Type:
            context.insert(ExerciseAliasModel(exerciseID: UUID(), alias: "Sample"))
        case is UserExerciseNoteModel.Type:
            context.insert(UserExerciseNoteModel(userID: userID, exerciseID: UUID(), note: "Sample"))
        case is RoutineFolderModel.Type:
            context.insert(RoutineFolderModel(userID: userID, name: "Sample"))
        case is RoutineModel.Type:
            context.insert(RoutineModel(userID: userID, name: "Sample"))
        case is RoutineBlockModel.Type:
            context.insert(RoutineBlockModel(userID: userID, kind: .conditioning))
        case is RoutineExerciseModel.Type:
            context.insert(RoutineExerciseModel(userID: userID, exerciseID: UUID()))
        case is RoutineSetModel.Type:
            context.insert(RoutineSetModel(userID: userID, position: 0))
        case is WorkoutModel.Type:
            context.insert(WorkoutModel(userID: userID))
        case is WorkoutBlockModel.Type:
            context.insert(WorkoutBlockModel(userID: userID, kind: .conditioning))
        case is WorkoutExerciseModel.Type:
            context.insert(WorkoutExerciseModel(userID: userID, exerciseID: UUID()))
        case is SetModel.Type:
            context.insert(SetModel(userID: userID, position: 0))
        case is WorkoutImportBatchModel.Type:
            context.insert(WorkoutImportBatchModel(userID: userID, source: "sample", fileName: "s.csv"))
        case is UserProgressModel.Type:
            context.insert(UserProgressModel(userID: userID))
        case is WorkoutXPEventModel.Type:
            context.insert(WorkoutXPEventModel(userID: userID, workoutID: UUID(), amount: 1))
        case is CardioSessionModel.Type:
            context.insert(CardioSessionModel(userID: userID, modality: "run"))
        case is CardioRoutePointModel.Type:
            context.insert(CardioRoutePointModel(userID: userID, cardioSessionID: UUID(), timestamp: .now, latitude: 0, longitude: 0))
        case is CardioSplitModel.Type:
            context.insert(CardioSplitModel(userID: userID, cardioSessionID: UUID(), index: 0, distanceMeters: 1, durationSeconds: 1, paceSecondsPerKm: 1, startedAt: .now, endedAt: .now))
        case is WrappedReportModel.Type:
            context.insert(WrappedReportModel(userID: userID, reportTypeRaw: "monthly", year: 2026, month: 6, payloadJSON: "{}"))
        case is IntervalPresetModel.Type:
            context.insert(IntervalPresetModel(userID: userID, name: "Sample", planJSON: "{}"))
        case is YogaFlowModel.Type:
            context.insert(YogaFlowModel(userID: userID, name: "Sample"))
        case is ProgressionSuggestionModel.Type:
            context.insert(ProgressionSuggestionModel(userID: userID, exerciseID: UUID(), workoutID: UUID(), workoutExerciseID: UUID(), kindRaw: "hold"))
        case is DailyCheckinModel.Type:
            context.insert(DailyCheckinModel(userID: userID, date: .now, tags: ["sore"]))
        case is ExperimentModel.Type:
            context.insert(ExperimentModel(
                userID: userID,
                name: "Sample",
                plannedEndAt: Date().addingTimeInterval(86_400)
            ))
        case is ExperimentTrackerModel.Type:
            context.insert(ExperimentTrackerModel(
                userID: userID,
                experimentID: UUID(),
                label: "Sample",
                type: .number
            ))
        case is ExperimentEntryModel.Type:
            context.insert(ExperimentEntryModel(
                userID: userID,
                experimentID: UUID(),
                trackerID: UUID(),
                value: .number(1)
            ))
        case is MicrocycleTrackingModel.Type:
            context.insert(MicrocycleTrackingModel(
                userID: userID,
                folderID: UUID(),
                folderName: "Sample",
                anchorDate: .now,
                durationDays: 10
            ))
        case is MicrocycleWindowModel.Type:
            context.insert(MicrocycleWindowModel(
                userID: userID,
                trackingID: UUID(),
                folderID: UUID(),
                folderName: "Sample",
                index: 0,
                startsAt: .now,
                endsAt: Date().addingTimeInterval(10 * 86_400),
                timeZoneIdentifier: "UTC",
                routines: []
            ))
        case is RestDayModel.Type:
            context.insert(RestDayModel(userID: userID, date: .now))
        case is SavedInsightModel.Type:
            context.insert(SavedInsightModel(userID: userID, name: "Sample", recipeJSON: "{}"))
        case is CoachingProfileModel.Type:
            context.insert(CoachingProfileModel(userID: userID, focusRaw: "strength", goalRaw: "build-muscle", experienceRaw: "beginner"))
        case is CoachedProgramModel.Type:
            context.insert(CoachedProgramModel(userID: userID, startDate: .now))
        case is CoachingWeekOverrideModel.Type:
            context.insert(CoachingWeekOverrideModel(userID: userID, weekStart: .now))
        default:
            Issue.record("No sample factory for \(modelType) — add one AND a deleteAll entry in AccountResetService")
        }
    }
}
