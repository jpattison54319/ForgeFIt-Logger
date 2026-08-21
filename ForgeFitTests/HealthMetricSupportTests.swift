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

    @Test func usualBandOwnsMostOfTheVitalPlot() {
        #expect(VitalBandScale.outerFraction == 0.20)
        #expect(VitalBandScale.usualFraction == 0.60)
        #expect(VitalBandScale.usualUpperBound == 0.80)
    }

    @Test func noReadingsDoesNotInventAHealthScore() {
        let assessment = HealthRangeAssessment.make(metrics: [], calendar: calendar)
        #expect(assessment.headline == "No readings")
        #expect(assessment.evaluatedCount == 0)
        #expect(assessment.outsideRangeCount == 0)
        #expect(assessment.favorableCount == 0)
        #expect(assessment.adverseCount == 0)
        #expect(VitalsTilePresentation.make(assessment: assessment).indicators.allSatisfy {
            $0.interpretation == .unavailable
        })
    }

    @Test func stableOvernightSignalsAreAllInPersonalRange() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(latestHRV: 61, latestHeartRate: 58),
            calendar: calendar
        )

        #expect(assessment.readings.count == 4)
        #expect(assessment.evaluatedCount == 4)
        #expect(assessment.outsideRangeCount == 0)
        #expect(assessment.readings.map(\.kind) == VitalMetricKind.allCases)
        #expect(assessment.headline == "Within usual bands")
        #expect(VitalsTilePresentation.make(assessment: assessment).indicators.allSatisfy {
            $0.interpretation == .typical
                && (VitalBandScale.usualLowerBound...VitalBandScale.usualUpperBound).contains($0.position)
        })
    }

    @Test func adverseDirectionsAreReportedWithoutPrescriptiveLanguage() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(latestHRV: 38, latestHeartRate: 72),
            calendar: calendar
        )

        #expect(assessment.outsideRangeCount == 2)
        #expect(assessment.adverseCount == 2)
        #expect(assessment.favorableCount == 0)
        #expect(assessment.headline == "Outside usual bands")
        #expect(assessment.readings.first { $0.kind == .hrv }?.status == .belowRange)
        #expect(assessment.readings.first { $0.kind == .heartRate }?.status == .aboveRange)
        let accessibilityValue = VitalsTilePresentation.make(assessment: assessment).accessibilityValue
        #expect(!accessibilityValue.contains("needs attention"))
    }

    @Test func reportedFavorableDirectionsMoveIntoTheGreenZone() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(
                latestHRV: 75,
                latestHeartRate: 54,
                latestOxygenSaturation: 100
            ),
            calendar: calendar
        )
        let presentation = VitalsTilePresentation.make(assessment: assessment)
        let favorable = presentation.indicators.filter { $0.interpretation == .favorable }

        #expect(assessment.outsideRangeCount == 3)
        #expect(assessment.adverseCount == 0)
        #expect(assessment.favorableCount == 3)
        #expect(assessment.headline == "3 favorable shifts")
        #expect(favorable.map(\.kind) == [.heartRate, .bloodOxygen, .hrv])
        #expect(favorable.allSatisfy { $0.position > VitalBandScale.usualUpperBound })
        #expect(presentation.accessibilityValue.contains("Sleeping HR, 54 bpm, below usual, favorable"))
        #expect(presentation.accessibilityValue.contains("HRV, 75 ms, above usual, favorable"))
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
        #expect(assessment.adverseCount == 2)
        #expect(assessment.readings.first { $0.kind == .respiratoryRate }?.status == .aboveRange)
        #expect(assessment.readings.first { $0.kind == .bloodOxygen }?.status == .belowRange)
        #expect(VitalsTilePresentation.make(assessment: assessment).indicators
            .filter { $0.interpretation == .adverse }
            .allSatisfy { $0.position < VitalBandScale.usualLowerBound })
    }

    @Test func rangeStatusUsesTheSamePrecisionAsDisplayedValues() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics = (0..<43).map { offset in
            metric(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                hrv: 60,
                heartRate: 58,
                oxygenSaturation: offset.isMultiple(of: 2) ? 97.04 : 98.04
            )
        }
        metrics.append(metric(
            date: calendar.date(byAdding: .day, value: 43, to: start)!,
            hrv: 60,
            heartRate: 58,
            oxygenSaturation: 96.96
        ))

        let oxygen = HealthRangeAssessment.make(metrics: metrics, calendar: calendar)
            .readings.first { $0.kind == .bloodOxygen }

        #expect(oxygen?.formattedVitalValue == "97%")
        #expect(oxygen?.lowerBound.map { Int($0.rounded()) } == 97)
        #expect(oxygen?.status == .typical)
        #expect(oxygen?.vitalRelationText == "within usual band")
    }

    @Test func lowerRespiratoryRateAndHigherOxygenAreFavorable() {
        let assessment = HealthRangeAssessment.make(
            metrics: history(
                latestHRV: 61,
                latestHeartRate: 58,
                latestRespiratoryRate: 12,
                latestOxygenSaturation: 100
            ),
            calendar: calendar
        )
        let presentation = VitalsTilePresentation.make(assessment: assessment)
        let respiratory = presentation.indicators.first { $0.kind == .respiratoryRate }
        let oxygen = presentation.indicators.first { $0.kind == .bloodOxygen }

        #expect(respiratory?.interpretation == .favorable)
        #expect(oxygen?.interpretation == .favorable)
        #expect(respiratory.map { $0.position > VitalBandScale.usualUpperBound } == true)
        #expect(oxygen.map { $0.position > VitalBandScale.usualUpperBound } == true)
    }

    @Test func fewerThanTwentyEightReadingsIsLabeledBuilding() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let metrics = (0..<5).map { offset in
            metric(date: calendar.date(byAdding: .day, value: offset, to: start)!, hrv: 60, heartRate: 58)
        }
        let assessment = HealthRangeAssessment.make(metrics: metrics, calendar: calendar)

        #expect(assessment.headline == "Building")
        #expect(assessment.evaluatedCount == 0)
        #expect(VitalsTilePresentation.make(assessment: assessment).indicators.allSatisfy {
            $0.position == 0.5 && $0.interpretation == .building
        })
    }

    @Test func partialNightDoesNotSilentlySubstituteAllDayChannels() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics = (0..<43).map { offset in
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
            date: calendar.date(byAdding: .day, value: 43, to: start)!,
            hrvSDNN: 60,
            restingHR: 58,
            sleepTotalMinutes: 180,
            nocturnalHRV: 110,
            sleepingHR: 42
        )
        latest.integrityFlags.insert(SleepIntegrity.Flag.partialWear)
        metrics.append(latest)

        let assessment = HealthRangeAssessment.make(metrics: metrics, calendar: calendar)

        #expect(assessment.headline == "No readings")
        #expect(assessment.readings.isEmpty)
    }

    private func history(
        latestHRV: Double,
        latestHeartRate: Int,
        latestRespiratoryRate: Double = 14.6,
        latestOxygenSaturation: Double = 97
    ) -> [RecoveryEngine.DailyHealthMetric] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var metrics: [RecoveryEngine.DailyHealthMetric] = []
        for offset in 0..<43 {
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
            date: calendar.date(byAdding: .day, value: 43, to: start)!,
            hrv: latestHRV,
            heartRate: latestHeartRate,
            respiratoryRate: latestRespiratoryRate,
            oxygenSaturation: latestOxygenSaturation
        ))
        return metrics
    }

    @Test func sourceChangeStartsANewUsualBand() {
        var metrics = history(latestHRV: 60, latestHeartRate: 58)
        metrics[metrics.count - 1].hrvSourceBundleID = "new-device"

        let assessment = HealthRangeAssessment.make(metrics: metrics, calendar: calendar)

        #expect(assessment.readings.first { $0.kind == .hrv }?.status == .building)
    }

    @Test func normalizedPositionsClampExtremeValues() {
        let highHRV = PersonalRangeReading(
            kind: .hrv,
            name: "HRV",
            systemImage: VitalMetricKind.hrv.systemImage,
            value: 100,
            unit: "ms",
            mean: 55,
            lowerBound: 50,
            upperBound: 60,
            status: .aboveRange
        )
        let highHeartRate = PersonalRangeReading(
            kind: .heartRate,
            name: "Sleeping HR",
            systemImage: VitalMetricKind.heartRate.systemImage,
            value: 100,
            unit: "bpm",
            mean: 55,
            lowerBound: 50,
            upperBound: 60,
            status: .aboveRange
        )

        #expect(highHRV.normalizedVitalPosition == 1)
        #expect(highHeartRate.normalizedVitalPosition == 0)
    }

    @Test func dedicatedSleepingHeartRateIsNotRepeatedUnderOtherReadings() {
        let signals = [
            RecoveryEngine.Signal(
                name: "Sleeping HR",
                systemImage: "heart.fill",
                value: "52 bpm",
                detail: "Last night",
                connected: true
            ),
            RecoveryEngine.Signal(
                name: "HRV",
                systemImage: "waveform.path.ecg",
                value: "61 ms",
                detail: "Last night",
                connected: true
            ),
            RecoveryEngine.Signal(
                name: "Post-workout HR drop",
                systemImage: "arrow.down.heart.fill",
                value: "31 bpm",
                detail: "Average first-minute decrease after exercise · 30 days",
                connected: true
            ),
        ]

        let supplemental = HealthDetailSignalFilter.supplemental(from: signals)

        #expect(supplemental.map(\.name) == ["Post-workout HR drop"])
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
