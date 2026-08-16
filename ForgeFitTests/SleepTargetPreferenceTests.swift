import Foundation
import Testing
@testable import ForgeFit

struct SleepTargetPreferenceTests {
    @Test func normalizesToSupportedQuarterHours() {
        #expect(SleepTargetPreference.normalized(100) == 300)
        #expect(SleepTargetPreference.normalized(493) == 495)
        #expect(SleepTargetPreference.normalized(900) == 720)
    }

    @Test func appliesOneExplicitTargetToEveryNight() {
        let metrics = [
            RecoveryEngine.DailyHealthMetric(date: .now, sleepTotalMinutes: 360),
            RecoveryEngine.DailyHealthMetric(date: .distantPast, sleepTotalMinutes: 600),
        ]

        let updated = SleepTargetPreference.applying(450, to: metrics)

        #expect(updated.map(\.sleepNeedMinutes) == [450, 450])
        #expect(updated.map(\.sleepTotalMinutes) == [360, 600])
    }
}
