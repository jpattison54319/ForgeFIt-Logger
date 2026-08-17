import ForgeCore
import Foundation

/// Single source of truth for every user-preference UserDefaults key the
/// app owns, so "Erase All Data" and the iCloud backup can never drift
/// apart again (the reset previously missed ~18 keys added over time).
///
/// - `backedUp`: preferences worth carrying to a new iPhone in the
///   sanitized iCloud Drive backup. NOTHING health-derived belongs here.
/// - `localOnly`: bookkeeping/state that is cleared on reset but never
///   exported (device-specific timing, one-shot flags, migration stamps).
///
/// Deliberately in NEITHER list: the HR-zone config
/// (`HRZoneConfigStore`, app-group suite) — it encodes max/resting heart
/// rate, i.e. health data; reset clears it explicitly, backup excludes it.
enum AppPreferenceKeys {
    static let workoutUngroupedCollapsedKey = "workoutUngroupedCollapsed"

    static let backedUp: [String] = [
        "didOnboard",
        "profileDisplayName",
        "weightUnitRaw",
        "distanceUnitRaw",
        "trainingFocusRaw",
        ShareCardStyle.preferenceKey,
        HomeQuickStartAction.preferenceKey,
        AppQuickActionStore.key,
        CyclePreferenceMigration.activeMesocycleKey,
        CyclePreferenceMigration.activeMicrocycleKey,
        ThemeManager.modeDefaultsKey,
        DefaultLaunchTab.key,
        "liveSyncEnabled",
        "healthWriteEnabled",
        WorkoutEffortPolicy.loggingEnabledKey,
        "effortScaleRaw",
        WorkoutEffortPolicy.failureTrainingKey,
        WarmupRampConfigStore.key,
        "reminderWeekdays",
        "reminderMinutes",
        "morningReadinessEnabled",
        "timerSoundEnabled",
        "loudRestAlarmEnabled",
        "paceAnnouncementsEnabled",
        "intervalSoundCues",
        "zoneVoiceCues",
        "paceVoiceCues",
        "yogaVoiceCues",
        YogaInstructor.preferenceKey,
        PlateInventoryStore.key(for: .lb),
        PlateInventoryStore.key(for: .kg),
    ] + StatisticsSectionPreference.allCases.map(\.defaultsKey)

    static let localOnly: [String] = [
        "initialTab",
        "insightsBuilderEnabled",
        WrappedReportService.lastAutomaticAttemptKey,
        ImportedExerciseBackfill.didRunKey,
        WeightModeBackfill.convertKey,
        BLEHeartRateService.rememberedIDKey,
        BLEHeartRateService.rememberedNameKey,
        "autoStartRoutine",
        "openSettings",
        LaunchSeedPolicy.defaultsKey,
        PlanMaintenancePolicy.defaultsKey,
        CyclePreferenceMigration.migrationKey,
        "lastActiveDate",
        "hasCompletedFirstLaunch",
        "welcomeBackPendingGapDays",
        "notificationPrimeShown",
        "morningReadinessScheduledFire",
        "morningReadinessLastFiredDay",
        "storeSplitMigration.v1.done",
        "backupLastSuccessAt",
        BackupScheduler.lastFailureMessageKey,
        BackupScheduler.lastFailureAtKey,
        HealthWorkoutImporter.lastAutomaticAttemptKey,
        ExperimentNotificationRoute.pendingURLDefaultsKey,
        ExperimentNotificationRoute.pendingExperimentIDDefaultsKey,
        SocialService.shareOutboxKey,
        SocialService.legacyPendingUnpublishKey,
        PlanImportService.importedPackagesDefaultsKey,
        workoutUngroupedCollapsedKey,
        SleepTargetPreference.key,
        SleepOverrideStore.defaultsKey,
        SleepOverrideStore.eagerDeleteRepairKey,
        RecoverySnapshotStore.defaultsKey,
        RecoverySnapshotStore.backfillKey,
        YogaGuidanceCatalog.recentGuidanceKey,
        YogaGuidanceCatalog.safetyAcknowledgementKey,
    ]

    /// Retired preferences kept only so Erase All Data also cleans installs
    /// that previously used the streak feature.
    static let deprecated = [
        "weeklyWorkoutGoal",
        "streakNudgeEnabled",
        "activeMacroFolderID",
        "activeMesoFolderID",
        "yogaVoiceID",
        "yogaVoiceRate",
    ]

    static var allResettable: [String] { backedUp + localOnly + deprecated }
}
