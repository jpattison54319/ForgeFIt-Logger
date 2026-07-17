import ForgeCore
import ForgeData
import Foundation
import SwiftData
import UserNotifications
#if canImport(WidgetKit)
import WidgetKit
#endif

extension Notification.Name {
    static let forgeFitAccountResetDidComplete = Notification.Name("forgefit.accountResetDidComplete")
}

@MainActor
enum AccountResetService {
    static func resetAllAppData(in context: ModelContext) throws {
        clearLiveSurfaces()
        cancelAppNotifications()
        try deleteAllLocalModels(in: context)
        clearAppDefaults()
        try ExerciseSeedRepository.seedGlobalLibrary(in: context)
        ExerciseCatalog.seed(into: context)
        try context.save()
        // The privacy policy promises reset also removes the iCloud Drive
        // backup. Best-effort — offline just means the files outlive the
        // reset until the user deletes them in Files.
        Task { await BackupExporter.shared.deleteAllBackups() }
        NotificationCenter.default.post(name: .forgeFitAccountResetDidComplete, object: nil)
    }

    static func deleteAllLocalModels(in context: ModelContext) throws {
        try deleteAll(SavedInsightModel.self, in: context)
        try deleteAll(CoachingWeekOverrideModel.self, in: context)
        try deleteAll(CoachedProgramModel.self, in: context)
        try deleteAll(CoachingProfileModel.self, in: context)
        try deleteAll(ProgressionSuggestionModel.self, in: context)
        try deleteAll(DailyCheckinModel.self, in: context)
        try deleteAll(CardioRoutePointModel.self, in: context)
        try deleteAll(CardioSplitModel.self, in: context)
        try deleteAll(CardioSessionModel.self, in: context)
        try deleteAll(SetModel.self, in: context)
        try deleteAll(WorkoutExerciseModel.self, in: context)
        try deleteAll(WorkoutModel.self, in: context)
        try deleteAll(WorkoutImportBatchModel.self, in: context)
        try deleteAll(WorkoutXPEventModel.self, in: context)
        try deleteAll(UserProgressModel.self, in: context)
        try deleteAll(WrappedReportModel.self, in: context)
        try deleteAll(IntervalPresetModel.self, in: context)
        try deleteAll(YogaFlowModel.self, in: context)
        try deleteAll(RoutineSetModel.self, in: context)
        try deleteAll(RoutineExerciseModel.self, in: context)
        try deleteAll(RoutineModel.self, in: context)
        try deleteAll(RoutineFolderModel.self, in: context)
        try deleteAll(UserExerciseNoteModel.self, in: context)
        try deleteAll(ExerciseAliasModel.self, in: context)
        try deleteAll(ExerciseLibraryModel.self, in: context)
        try context.save()
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }

    private static func clearLiveSurfaces() {
        WorkoutActivityController.shared.end()
        RestTimerController.shared.skip()
        IntervalRunnerHub.shared.stop()
        YogaFlowRunnerHub.shared.stop()
        LiveMetricsHub.shared.endSession()
        WatchLink.shared.sendCommand(.discardWorkout)
        WatchLink.shared.publishState()
        ForgeFitWidgetSnapshotStore.save(ForgeFitWidgetSnapshot(mode: .idle))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    private static func cancelAppNotifications() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
            NotificationScheduler.NotificationID.restTimer,
            NotificationScheduler.NotificationID.streakNudge,
            NotificationScheduler.NotificationID.intervalCue,
            NotificationScheduler.NotificationID.wrappedReady
        ] + NotificationScheduler.NotificationID.allReminderIDs)
    }

    private static func clearAppDefaults() {
        // The canonical key lists live in AppPreferenceKeys, shared with the
        // iCloud backup exporter — one list, so reset and backup can't drift.
        // (Clearing the seed stamp makes the next launch re-run the full
        // catalog seed against the freshly-reset store.)
        let defaults = UserDefaults.standard
        AppPreferenceKeys.allResettable.forEach(defaults.removeObject(forKey:))
        // HR-zone config lives in the app-group suite (health-derived —
        // never backed up, but reset must still clear it).
        UserDefaults(suiteName: ForgeFitWidgetSnapshotStore.suiteName)?
            .removeObject(forKey: HRZoneConfigStore.key)
        Fmt.unit = .lb
        Fmt.distanceUnit = .km
    }
}
