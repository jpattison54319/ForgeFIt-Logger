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
    static let backedUp: [String] = [
        "didOnboard",
        "profileDisplayName",
        "weightUnitRaw",
        "distanceUnitRaw",
        "trainingFocusRaw",
        "homeQuickStartActions.v1",
        AppQuickActionStore.key,
        "activeMacroFolderID",
        "activeMesoFolderID",
        ThemeManager.modeDefaultsKey,
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
        "yogaVoiceCues",
        "yogaVoiceID",
        "yogaVoiceRate",
        YogaInstructor.preferenceKey,
        PlateInventoryStore.key(for: .lb),
        PlateInventoryStore.key(for: .kg),
    ]

    static let localOnly: [String] = [
        "initialTab",
        "autoStartRoutine",
        "openSettings",
        LaunchSeedPolicy.defaultsKey,
        "lastActiveDate",
        "hasCompletedFirstLaunch",
        "welcomeBackPendingGapDays",
        "notificationPrimeShown",
        "morningReadinessScheduledFire",
        "morningReadinessLastFiredDay",
        "storeSplitMigration.v1.done",
        "backupLastSuccessAt",
    ]

    /// Retired preferences kept only so Erase All Data also cleans installs
    /// that previously used the streak feature.
    static let deprecated = ["weeklyWorkoutGoal", "streakNudgeEnabled"]

    static var allResettable: [String] { backedUp + localOnly + deprecated }
}
