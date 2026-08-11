import Foundation
import Testing
@testable import ForgeFit

struct LiveWorkoutLifecyclePolicyTests {
    @Test func foregroundMaintenanceNeverRunsOverALiveWorkout() {
        #expect(!LiveWorkoutLifecyclePolicy.shouldRunForegroundMaintenance(hasActiveWorkout: true))
        #expect(LiveWorkoutLifecyclePolicy.shouldRunForegroundMaintenance(hasActiveWorkout: false))
    }

    @Test func backupProjectionRequiresDirtyIdleForegroundState() {
        #expect(BackupExportPolicy.canStart(
            hasPendingChanges: true,
            isLiveWorkoutActive: false,
            isBackgrounded: false,
            hasExportInFlight: false
        ))
        #expect(!BackupExportPolicy.canStart(
            hasPendingChanges: true,
            isLiveWorkoutActive: true,
            isBackgrounded: false,
            hasExportInFlight: false
        ))
        #expect(!BackupExportPolicy.canStart(
            hasPendingChanges: true,
            isLiveWorkoutActive: false,
            isBackgrounded: true,
            hasExportInFlight: false
        ))
        #expect(!BackupExportPolicy.canStart(
            hasPendingChanges: false,
            isLiveWorkoutActive: false,
            isBackgrounded: false,
            hasExportInFlight: false
        ))
    }

    @Test func automaticWorkoutHistoryBackupIsEnabledForThisRelease() {
        #expect(BackupAutomationPolicy.isEnabledInThisRelease)
    }

    @Test func eachRestAlertGetsAUniquePrefixMatchedIdentifier() {
        let first = NotificationScheduler.NotificationID.restTimerAlert(UUID())
        let second = NotificationScheduler.NotificationID.restTimerAlert(UUID())

        #expect(first != second)
        #expect(NotificationScheduler.NotificationID.isRestTimer(first))
        #expect(NotificationScheduler.NotificationID.isRestTimer(second))
        #expect(!NotificationScheduler.NotificationID.isRestTimer("forgefit.reminder.2"))
    }

    @Test func inAppFallbackCoversAShortForegroundDelay() {
        let endsAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let shortlyAfter = endsAt.addingTimeInterval(5)

        #expect(RestAlertDeliveryPolicy.shouldPlayInApp(
            soundEnabled: true,
            applicationIsActive: true,
            endsAt: endsAt,
            now: shortlyAfter
        ))
    }

    @Test func inAppFallbackDoesNotPlayInBackgroundOrLongAfterExpiry() {
        let endsAt = Date(timeIntervalSinceReferenceDate: 20_000)

        #expect(!RestAlertDeliveryPolicy.shouldPlayInApp(
            soundEnabled: true,
            applicationIsActive: false,
            endsAt: endsAt,
            now: endsAt.addingTimeInterval(2)
        ))
        #expect(!RestAlertDeliveryPolicy.shouldPlayInApp(
            soundEnabled: true,
            applicationIsActive: true,
            endsAt: endsAt,
            now: endsAt.addingTimeInterval(
                RestAlertDeliveryPolicy.maximumForegroundFallbackLateness
            )
        ))
    }

    @Test func foregroundRestSoundCanBeClaimedByOnlyOneDeliveryPath() async {
        let coordinator = RestAlertDeliveryCoordinator()
        let identifier = NotificationScheduler.NotificationID.restTimerAlert(UUID())

        #expect(await coordinator.claim(identifier, owner: .inApp))
        #expect(!(await coordinator.claim(identifier, owner: .system)))
    }

    @Test func primaryRestAlertNeverFallsBackToForegroundNotificationAudio() {
        let primary = NotificationScheduler.NotificationID.restTimerAlert(UUID())
        let followUp = NotificationScheduler.NotificationID.loudRestFollowUp(0)

        #expect(NotificationScheduler.foregroundDelivery(for: primary) == .inAppRestChime)
        #expect(NotificationScheduler.foregroundDelivery(for: followUp) == .systemSound)
        #expect(
            NotificationScheduler.foregroundDelivery(for: "forgefit.reminder.2")
                == .bannerAndSystemSound
        )
    }
}
