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
        NotificationCenter.default.post(name: .forgeFitAccountResetDidComplete, object: nil)
    }

    static func deleteAllLocalModels(in context: ModelContext) throws {
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
        WatchLink.shared.clearLiveMetrics()
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
            NotificationScheduler.NotificationID.intervalCue
        ] + NotificationScheduler.NotificationID.allReminderIDs)
    }

    private static func clearAppDefaults() {
        let defaults = UserDefaults.standard
        [
            "didOnboard",
            "initialTab",
            "autoStartRoutine",
            "openSettings",
            "activeMacroFolderID",
            "activeMesoFolderID",
            ThemeManager.modeDefaultsKey,
            "profileDisplayName",
            "liveSyncEnabled",
            "healthWriteEnabled",
            "weightUnitRaw",
            "distanceUnitRaw",
            "showRPEInLogger",
            "reminderWeekdays",
            "reminderMinutes",
            "streakNudgeEnabled",
            PlateInventoryStore.key(for: .lb),
            PlateInventoryStore.key(for: .kg)
        ].forEach(defaults.removeObject(forKey:))
        Fmt.unit = .lb
        Fmt.distanceUnit = .km
    }
}
