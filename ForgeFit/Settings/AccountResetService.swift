import ForgeCore
import ForgeData
import Foundation
import SwiftData
import UserNotifications

extension Notification.Name {
    static let forgeFitAccountResetDidComplete = Notification.Name("forgefit.accountResetDidComplete")
}

@MainActor
enum AccountResetService {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    /// Result of a full reset. The local wipe is all-or-nothing and throws on
    /// failure; the iCloud backup deletion is awaited and reported separately
    /// so the confirmation can never claim a deletion that did not happen.
    enum ResetOutcome: Equatable, Sendable {
        /// Local reset completed and the backup was removed.
        case completed
        /// Backup deletion failed; the backup may still exist in iCloud Drive.
        /// The user must be told the consequence before the shell transitions.
        case backupDeletionFailed(String)
        /// Backup deletion was interrupted; the backup may still exist.
        case backupDeletionCancelled
        /// The ubiquity container could not be resolved (signed out, offline,
        /// or inaccessible), so the backup's fate is UNKNOWN and it may still
        /// exist. Not success: the user must acknowledge the consequence.
        case backupDeletionUnavailable
    }

    static func resetAllAppData(
        in context: ModelContext,
        backupDeleter: any BackupDeleting = BackupExporter.shared,
        databaseSave: SaveOperation = { try $0.save() }
    ) async throws -> ResetOutcome {
        // Delete and reseed inside one private transaction. Until this single
        // save commits, the user's durable models, defaults, live devices, and
        // backups are untouched; a seed/save failure therefore leaves a fully
        // retryable pre-reset app instead of a half-wiped one.
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        try stageAllLocalModelDeletes(in: transaction)
        try ExerciseSeedRepository.seedGlobalLibrary(
            in: transaction,
            persist: false
        )
        try ExerciseCatalog.seed(into: transaction, persist: false)
        try YogaPoseCatalog.seed(into: transaction, persist: false)
        try YogaPoseCatalog.pruneUnavailablePoses(into: transaction, persist: false)
        try databaseSave(transaction)

        // The private commit supersedes any stale or unsaved rows retained by
        // the keep-resident UI context. Reset intentionally discards them so a
        // later autosave cannot resurrect pre-reset user data.
        context.rollback()
        clearLiveSurfaces()
        cancelAppNotifications()
        ExperimentExportService.cleanupAll()
        clearAppDefaults()
        // `clearLiveSurfaces` published to the Watch while the health stores
        // were still populated. Publish again now they are empty, so the wrist
        // is not left holding the readiness the reset just removed.
        WatchLink.shared.publishState(policy: .immediate)
        // The privacy policy promises reset also removes the iCloud Drive
        // backup. Await the deletion: the reset must not be declared complete
        // (and the shell must not move to onboarding) until we know whether
        // the backup is actually gone.
        switch await backupDeleter.deleteAllBackups() {
        case .deleted:
            NotificationCenter.default.post(name: .forgeFitAccountResetDidComplete, object: nil)
            return .completed
        case .failed(let message):
            return .backupDeletionFailed(message)
        case .cancelled:
            return .backupDeletionCancelled
        case .unavailable:
            // A missing/inaccessible ubiquity container does NOT prove the
            // backup is gone — it only proves we could not look. Treat it as
            // an unresolved consequence the user must acknowledge.
            return .backupDeletionUnavailable
        }
    }

    /// Called AFTER the user has acknowledged a consequence-stated backup
    /// deletion outcome (failure, interruption, or unresolved/unavailable).
    /// The local reset already happened, so the shell still has to return to
    /// onboarding — but never before the consequence was shown.
    static func finishResetAfterBackupDeletionFailure() {
        NotificationCenter.default.post(name: .forgeFitAccountResetDidComplete, object: nil)
    }

    static func deleteAllLocalModels(in context: ModelContext) throws {
        DeferredWorkoutEnrichmentCoordinator.shared.cancelAll()
        ExerciseAIClassifier.cancelAll()
        WorkoutFinisher.cancelLiveRuntime()
        try stageAllLocalModelDeletes(in: context)
        try context.save()
    }

    private static func stageAllLocalModelDeletes(in context: ModelContext) throws {
        try deleteAll(RestDayModel.self, in: context)
        try deleteAll(MicrocycleWindowModel.self, in: context)
        try deleteAll(MicrocycleTrackingModel.self, in: context)
        try deleteAll(ExperimentEntryModel.self, in: context)
        try deleteAll(ExperimentTrackerModel.self, in: context)
        try deleteAll(ExperimentModel.self, in: context)
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
        try deleteAll(WorkoutBlockModel.self, in: context)
        try deleteAll(WorkoutModel.self, in: context)
        try deleteAll(WorkoutImportBatchModel.self, in: context)
        try deleteAll(WorkoutXPEventModel.self, in: context)
        try deleteAll(UserProgressModel.self, in: context)
        try deleteAll(WrappedReportModel.self, in: context)
        try deleteAll(IntervalPresetModel.self, in: context)
        try deleteAll(YogaFlowModel.self, in: context)
        try deleteAll(RoutineSetModel.self, in: context)
        try deleteAll(RoutineExerciseModel.self, in: context)
        try deleteAll(RoutineBlockModel.self, in: context)
        try deleteAll(RoutineAlternationModel.self, in: context)
        try deleteAll(RoutineModel.self, in: context)
        try deleteAll(RoutineFolderModel.self, in: context)
        try deleteAll(UserExerciseNoteModel.self, in: context)
        try deleteAll(ExerciseAliasModel.self, in: context)
        try deleteAll(ExerciseLibraryModel.self, in: context)
    }

    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<T>()) {
            context.delete(row)
        }
    }

    private static func clearLiveSurfaces() {
        WorkoutFinisher.cancelLiveRuntime()
        // Pairing is device-local and deliberately excluded from backup. A full
        // reset must also stop a standing reconnect and forget its identifiers.
        BLEHeartRateService.shared.forget()
        WatchLink.shared.sendCommand(.discardWorkout(workoutID: nil))
        WatchLink.shared.publishState()
    }

    private static func cancelAppNotifications() {
        NotificationScheduler.shared.cancelAllRestEnds()
        ExperimentNotificationScheduler.cancelEveryExperimentNotification()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
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
        // These health-derived stores are local-only. Clear through the stores
        // as well as the canonical key list so their live singleton state
        // cannot survive the reset until the next process launch.
        SleepOverrideStore.shared.clearAll()
        RecoverySnapshotStore.shared.clearAll()
        YogaRuntimeCheckpointStore.clearAll(defaults: defaults)
        // HR-zone config lives in the app-group suite (health-derived —
        // never backed up, but reset must still clear it).
        UserDefaults(suiteName: ForgeFitWidgetSnapshotStore.suiteName)?
            .removeObject(forKey: HRZoneConfigStore.key)
        // The readiness snapshot shares that suite and is equally
        // health-derived. It used to be wiped incidentally, by the blank
        // snapshot `cancelLiveRuntime` wrote; now that idle publishes preserve
        // a same-day score, the reset has to say so itself.
        ReadinessSurfacePublisher.clear()
        ForgeThemePreferenceStore.reset()
        Fmt.unit = .lb
        Fmt.distanceUnit = .km
    }
}
