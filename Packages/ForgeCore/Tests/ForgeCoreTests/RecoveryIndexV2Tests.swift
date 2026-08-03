import Foundation
import Testing
@testable import ForgeCore

struct RecoveryIndexV2Tests {
    @Test func channelIdentitySeparatesStatisticContextAndSource() {
        let sdnn = AnalyticsChannelKey(
            metric: "hrv",
            statistic: "SDNN",
            context: "main-sleep",
            sourceBundleID: "com.apple.health",
            deviceModel: "Watch9",
            sourceAlgorithmVersion: "watchOS26",
            protocolVersion: "overnight-sdnn-v2",
            unit: "ms"
        )
        let rmssd = AnalyticsChannelKey(
            metric: "hrv",
            statistic: "RMSSD",
            context: "standardized-morning",
            sourceBundleID: "external",
            protocolVersion: "morning-rmssd-v1",
            unit: "ms"
        )

        #expect(sdnn != rmssd)
    }

    @Test(arguments: [
        (0.0, 100.0),
        (0.5, 85.0),
        (1.0, 70.0),
        (2.0, 40.0),
        (3.0, 10.0),
        (4.0, 0.0),
    ])
    func adverseTransformMatchesGoldenVectors(adverse: Double, expected: Double) {
        #expect(RecoveryIndexV2.componentScore(adverseUnits: adverse) == expected)
    }

    @Test func oneSignalNeverCreatesAHeadlineScore() {
        let result = RecoveryIndexV2.combine([
            RecoveryComponentInput(domain: .heartRate, adverseUnits: 0, quality: 1),
        ])

        #expect(result == nil)
    }

    @Test func sleepWithoutAnAutonomicDomainNeverCreatesAHeadlineScore() {
        let result = RecoveryIndexV2.combine([
            RecoveryComponentInput(domain: .sleep, adverseUnits: 0, quality: 1),
        ])

        #expect(result == nil)
    }

    @Test func twoPerfectDomainsShrinkTowardFifty() throws {
        let result = try #require(RecoveryIndexV2.combine([
            RecoveryComponentInput(domain: .hrv, adverseUnits: 0, quality: 1),
            RecoveryComponentInput(domain: .sleep, adverseUnits: 0, quality: 1),
        ]))

        #expect(result.coverage == 2.0 / 3.0)
        #expect(abs(result.rawScore - 100) < 1e-12)
        #expect(abs(result.score - 77.21655269759087) < 1e-12)
    }

    @Test func qualityBelowHalfWithholdsTheScore() {
        let result = RecoveryIndexV2.combine([
            RecoveryComponentInput(domain: .hrv, adverseUnits: 0, quality: 0.7),
            RecoveryComponentInput(domain: .sleep, adverseUnits: 0, quality: 0.7),
        ])

        #expect(result == nil)
    }

    @Test func favorableDeviationsDoNotAddBonuses() {
        #expect(RecoveryIndexV2.componentScore(adverseUnits: -5) == 100)
    }

    @Test func historyQualityRequiresBothCountAndSpan() {
        #expect(RecoveryIndexV2.historyQuality(count: 28, spanDays: 42) == 1)
        #expect(RecoveryIndexV2.historyQuality(count: 14, spanDays: 42) == 0.5)
        #expect(RecoveryIndexV2.historyQuality(count: 28, spanDays: 21) == 0.5)
    }
}
