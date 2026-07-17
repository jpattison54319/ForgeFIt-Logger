import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct HealthMetricSupportTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test func noReadingsDoesNotInventAHealthScore() {
        let assessment = HealthRangeAssessment.make(metrics: [], calendar: calendar)
        #expect(assessment.headline == "No readings")
        #expect(assessment.evaluatedCount == 0)
        #expect(assessment.outsideRangeCount == 0)
    }

    @Test func stableOvernightSignalsAreAllInPersonalRange() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(latestHRV: 61, latestHeartRate: 58),
            calendar: calendar
        )

        #expect(assessment.readings.count == 4)
        #expect(assessment.evaluatedCount == 4)
        #expect(assessment.outsideRangeCount == 0)
        #expect(assessment.headline == "All in range")
    }

    @Test func HealthTileCountsSignalsOutsidePersonalRange() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(latestHRV: 38, latestHeartRate: 72),
            calendar: calendar
        )

        #expect(assessment.outsideRangeCount == 2)
        #expect(assessment.headline == "2 outside range")
        #expect(assessment.readings.first { $0.id == "hrv" }?.status == .belowRange)
        #expect(assessment.readings.first { $0.id == "resting-heart-rate" }?.status == .aboveRange)
    }

    @Test func respiratoryRateAndBloodOxygenUsePersonalRanges() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(
                latestHRV: 61,
                latestHeartRate: 58,
                latestRespiratoryRate: 18,
                latestOxygenSaturation: 92
            ),
            calendar: calendar
        )

        #expect(assessment.outsideRangeCount == 2)
        #expect(assessment.readings.first { $0.id == "respiratory-rate" }?.status == .aboveRange)
        #expect(assessment.readings.first { $0.id == "blood-oxygen" }?.status == .belowRange)
    }

    @Test func fewerThanSevenNightsIsLabeledBuilding() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let metrics = (0..<5).map { offset in
            metric(date: calendar.date(byAdding: .day, value: offset, to: start)!, hrv: 60, heartRate: 58)
        }
        let assessment = HealthRangeAssessment.make(metrics: metrics, calendar: calendar)

        #expect(assessment.headline == "Building")
        #expect(assessment.evaluatedCount == 0)
    }

    @Test func partialNightFallsBackToMatchingAllDayBaselines() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics = (0..<10).map { offset in
            RecoveryEngine.DailyHealthMetric(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                hrvSDNN: 60 + Double(offset % 2),
                restingHR: 58 + offset % 2,
                sleepTotalMinutes: 480,
                nocturnalHRV: 90 + Double(offset % 2),
                sleepingHR: 48 + offset % 2
            )
        }
        var latest = RecoveryEngine.DailyHealthMetric(
            date: calendar.date(byAdding: .day, value: 10, to: start)!,
            hrvSDNN: 60,
            restingHR: 58,
            sleepTotalMinutes: 180,
            nocturnalHRV: 110,
            sleepingHR: 42
        )
        latest.integrityFlags.insert(SleepIntegrity.Flag.partialWear)
        metrics.append(latest)

        let assessment = HealthRangeAssessment.make(metrics: metrics, calendar: calendar)

        #expect(assessment.headline == "All in range")
        #expect(assessment.readings.first { $0.id == "hrv" }?.value == 60)
        #expect(assessment.readings.first { $0.id == "resting-heart-rate" }?.name == "Resting HR")
        #expect(assessment.readings.first { $0.id == "resting-heart-rate" }?.value == 58)
    }

    private func history(
        latestHRV: Double,
        latestHeartRate: Int,
        latestRespiratoryRate: Double = 14.6,
        latestOxygenSaturation: Double = 97
    ) -> [RecoveryEngine.DailyHealthMetric] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics: [RecoveryEngine.DailyHealthMetric] = []
        for offset in 0..<10 {
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let respiratoryRate = 14.4 + Double(offset % 2) * 0.2
            let oxygenSaturation = 97 + Double(offset % 2)
            metrics.append(metric(
                date: date,
                hrv: 60 + Double(offset % 3),
                heartRate: 58 + offset % 2,
                respiratoryRate: respiratoryRate,
                oxygenSaturation: oxygenSaturation
            ))
        }
        metrics.append(metric(
            date: calendar.date(byAdding: .day, value: 10, to: start)!,
            hrv: latestHRV,
            heartRate: latestHeartRate,
            respiratoryRate: latestRespiratoryRate,
            oxygenSaturation: latestOxygenSaturation
        ))
        return metrics
    }

    private func metric(
        date: Date,
        hrv: Double,
        heartRate: Int,
        respiratoryRate: Double = 14.5,
        oxygenSaturation: Double = 97
    ) -> RecoveryEngine.DailyHealthMetric {
        RecoveryEngine.DailyHealthMetric(
            date: date,
            hrvSDNN: hrv,
            restingHR: heartRate,
            respiratoryRate: respiratoryRate,
            oxygenSaturationPercent: oxygenSaturation,
            sleepTotalMinutes: 480,
            nocturnalHRV: hrv,
            sleepingHR: heartRate
        )
    }
}
