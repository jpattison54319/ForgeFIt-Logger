import Foundation
@testable import ForgeCore
import Testing

struct ExperimentComparisonEngineTests {
    private let timeZoneIdentifier = "America/New_York"

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ).date!
    }

    private func window(
        _ start: Date,
        _ end: Date,
        timeZoneIdentifier: String? = nil
    ) throws -> ExperimentWindow {
        try ExperimentWindow(
            start: start,
            end: end,
            timeZoneIdentifier: timeZoneIdentifier ?? self.timeZoneIdentifier
        )
    }

    private func selection(
        _ metricID: String,
        aggregation: ExperimentMetricAggregation = .sum,
        missing: ExperimentMissingValuePolicy = .missing,
        normalization: ExperimentComparisonNormalization = .automatic,
        scope: ExperimentMetricScope? = nil
    ) -> ExperimentMetricSelection {
        ExperimentMetricSelection(
            metricID: metricID,
            scope: scope,
            aggregation: aggregation,
            missingValuePolicy: missing,
            normalization: normalization
        )
    }

    private func observation(
        _ selection: ExperimentMetricSelection,
        _ timestamp: Date,
        _ value: Double?,
        provenance: InsightProvenance = .measured,
        group: String? = nil,
        weight: Double = 1
    ) -> ExperimentMetricObservation {
        ExperimentMetricObservation(
            metric: selection.key,
            timestamp: timestamp,
            value: value,
            provenance: provenance,
            group: group,
            weight: weight
        )
    }

    private func result(
        current: ExperimentWindow,
        reference: ExperimentWindow,
        selections: [ExperimentMetricSelection],
        observations: [ExperimentMetricObservation]
    ) throws -> ExperimentResult {
        try ExperimentComparisonEngine.evaluate(
            request: ExperimentComparisonRequest(
                currentWindow: current,
                reference: .custom(window: reference)
            ),
            selections: selections,
            observations: observations
        )
    }

    // MARK: - Exact windows

    @Test func negativeReferenceKeepsPercentDirectionAlignedWithAbsoluteChange() throws {
        let current = try window(date(2026, 1, 2), date(2026, 1, 3))
        let reference = try window(date(2026, 1, 1), date(2026, 1, 2))
        let metric = selection("temperature", aggregation: .mean)
        let delta = try #require(result(
            current: current,
            reference: reference,
            selections: [metric],
            observations: [
                observation(metric, reference.start, -10),
                observation(metric, current.start, -5),
            ]
        ).metrics.first)

        #expect(delta.comparisonAbsoluteChange == 5)
        #expect(delta.comparisonPercentChange == 50)
    }

    @Test func membershipIsStartInclusiveAndEndExclusive() throws {
        let current = try window(
            date(2026, 3, 8),
            date(2026, 3, 9)
        )
        let reference = try window(
            date(2026, 3, 7),
            date(2026, 3, 8)
        )
        let metric = selection("volume", normalization: .raw)
        let observations = [
            observation(metric, reference.start, 1),
            observation(metric, current.start, 10),
            observation(metric, current.end.addingTimeInterval(-0.001), 20),
            observation(metric, current.end, 100),
        ]

        let delta = try #require(
            result(
                current: current,
                reference: reference,
                selections: [metric],
                observations: observations
            ).metrics.first
        )

        #expect(current.contains(current.start))
        #expect(!current.contains(current.end))
        #expect(delta.current.value == 30)
        #expect(delta.reference.value == 1)
        #expect(delta.current.sampleCount == 2)
        #expect(delta.reference.sampleCount == 1)
    }

    @Test func previousEqualPeriodKeepsExactDurationAcrossDST() throws {
        // New York spring-forward day is 23 elapsed hours but one complete
        // local calendar day.
        let current = try window(
            date(2026, 3, 8),
            date(2026, 3, 9)
        )
        let previous = try ExperimentComparisonEngine.previousEqualWindow(for: current)
        let metric = selection("sleep", aggregation: .mean)
        let output = try ExperimentComparisonEngine.evaluate(
            request: ExperimentComparisonRequest(currentWindow: current),
            selections: [metric],
            observations: [observation(metric, date(2026, 3, 8, 12), 7.5)]
        )
        let coverage = try #require(output.metrics.first?.current.coverage)

        #expect(current.duration == 23 * 3_600)
        #expect(previous.duration == current.duration)
        #expect(previous.end == current.start)
        #expect(previous.timeZoneIdentifier == timeZoneIdentifier)
        #expect(
            calendar.dateComponents([.hour], from: date(2026, 3, 7), to: previous.start).hour == 1
        )
        #expect(coverage.expectedCompleteCalendarDays == 1)
        #expect(coverage.populatedCompleteCalendarDays == 1)
        #expect(coverage.completeDayFraction == 1)
    }

    @Test func activeComparisonUsesOnlyElapsedTimeAndCapsAtPlannedEnd() throws {
        let planned = try window(
            date(2026, 6, 1, 9),
            date(2026, 6, 9, 9)
        )
        let now = date(2026, 6, 4, 12)
        let active = try ExperimentComparisonEngine.activeElapsedRequest(
            for: planned,
            now: now
        )
        let activeReference = try ExperimentComparisonEngine.resolvedReferenceWindow(for: active)

        #expect(active.currentWindow.start == planned.start)
        #expect(active.currentWindow.end == now)
        #expect(activeReference.end == planned.start)
        #expect(activeReference.duration == active.currentWindow.duration)

        let completed = try ExperimentComparisonEngine.activeElapsedRequest(
            for: planned,
            now: date(2026, 6, 12)
        )
        #expect(completed.currentWindow == planned)

        #expect(throws: ExperimentComparisonError.noElapsedExperimentTime) {
            try ExperimentComparisonEngine.activeElapsedRequest(
                for: planned,
                now: planned.start
            )
        }
    }

    // MARK: - Aggregation and normalization

    @Test func unequalAdditiveWindowsPreferPerDayComparison() throws {
        let reference = try window(
            date(2026, 1, 1),
            date(2026, 1, 5)
        )
        let current = try window(
            date(2026, 1, 5),
            date(2026, 1, 7)
        )
        let metric = selection("sets")
        let observations = [
            observation(metric, date(2026, 1, 1, 12), 5),
            observation(metric, date(2026, 1, 2, 12), 5),
            observation(metric, date(2026, 1, 3, 12), 5),
            observation(metric, date(2026, 1, 4, 12), 5),
            observation(metric, date(2026, 1, 5, 12), 10),
            observation(metric, date(2026, 1, 6, 12), 10),
        ]

        let delta = try #require(
            result(
                current: current,
                reference: reference,
                selections: [metric],
                observations: observations
            ).metrics.first
        )

        #expect(delta.current.value == 20)
        #expect(delta.reference.value == 20)
        #expect(delta.rawAbsoluteChange == 0)
        #expect(delta.rawPercentChange == 0)
        #expect(delta.current.perDayValue == 10)
        #expect(delta.reference.perDayValue == 5)
        #expect(delta.perDayAbsoluteChange == 5)
        #expect(delta.perDayPercentChange == 100)
        #expect(delta.comparisonBasis == .perDay)
        #expect(delta.comparisonAbsoluteChange == 5)
        #expect(delta.comparisonPercentChange == 100)
    }

    @Test func nonAdditiveMetricsStayRawAcrossUnequalWindows() throws {
        let reference = try window(
            date(2026, 1, 1),
            date(2026, 1, 5)
        )
        let current = try window(
            date(2026, 1, 5),
            date(2026, 1, 7)
        )
        let metric = selection("resting-heart-rate", aggregation: .mean)
        let output = try result(
            current: current,
            reference: reference,
            selections: [metric],
            observations: [
                observation(metric, date(2026, 1, 2, 12), 60),
                observation(metric, date(2026, 1, 6, 12), 57),
            ]
        )
        let delta = try #require(output.metrics.first)

        #expect(delta.comparisonBasis == .raw)
        #expect(delta.current.perDayValue == nil)
        #expect(delta.reference.perDayValue == nil)
        #expect(delta.comparisonAbsoluteChange == -3)
        #expect(delta.comparisonPercentChange == -5)
    }

    @Test func everyAggregationHasPinnedSemanticsAndLatestTieBreaksDeterministically() throws {
        let reference = try window(date(2026, 1, 1), date(2026, 1, 3))
        let current = try window(date(2026, 1, 3), date(2026, 1, 5))
        let sum = selection("sum", aggregation: .sum)
        let mean = selection("mean", aggregation: .mean)
        let maximum = selection("maximum", aggregation: .maximum)
        let minimum = selection("minimum", aggregation: .minimum)
        let weighted = selection("weighted", aggregation: .weightedMean)
        let latest = selection("latest", aggregation: .latest)
        let selections = [sum, mean, maximum, minimum, weighted, latest]
        let early = date(2026, 1, 3, 8)
        let late = date(2026, 1, 4, 8)
        let observations = [
            observation(sum, early, 1), observation(sum, late, 3),
            observation(mean, early, 1), observation(mean, late, 3),
            observation(maximum, early, 1), observation(maximum, late, 3),
            observation(minimum, early, 1), observation(minimum, late, 3),
            observation(weighted, early, 100, weight: 1),
            observation(weighted, late, 200, weight: 3),
            observation(weighted, late, 999, weight: 0),
            observation(latest, early, 100),
            observation(latest, late, 7),
            observation(latest, late, 9),
        ]

        let forward = try result(
            current: current,
            reference: reference,
            selections: selections,
            observations: observations
        )
        let reversed = try result(
            current: current,
            reference: reference,
            selections: selections,
            observations: observations.reversed()
        )
        let values = Dictionary(
            uniqueKeysWithValues: forward.metrics.map {
                ($0.selection.metricID, $0.current.value)
            }
        )

        #expect(values["sum"] == 4)
        #expect(values["mean"] == 2)
        #expect(values["maximum"] == 3)
        #expect(values["minimum"] == 1)
        #expect(values["weighted"] == 175)
        #expect(values["latest"] == 9)
        #expect(
            forward.metrics.first { $0.selection.metricID == "weighted" }?
                .current.coverage.missingValueCount == 1
        )
        #expect(forward == reversed)
    }

    // MARK: - Missing data, coverage, and groups

    @Test func missingMeasurementStaysMissingWhileAbsentEventCanBeZero() throws {
        let reference = try window(date(2026, 1, 1), date(2026, 1, 3))
        let current = try window(date(2026, 1, 3), date(2026, 1, 5))
        let measurement = selection("hrv", missing: .missing)
        let tally = selection("sessions", missing: .zeroWhenAbsent)
        let output = try result(
            current: current,
            reference: reference,
            selections: [measurement, tally],
            observations: [
                observation(measurement, date(2026, 1, 3, 8), 12),
                observation(measurement, date(2026, 1, 4, 8), nil),
                observation(measurement, date(2026, 1, 4, 9), .infinity),
                observation(tally, date(2026, 1, 3, 10), 2),
            ]
        )
        let measurementDelta = try #require(
            output.metrics.first { $0.selection.metricID == "hrv" }
        )
        let tallyDelta = try #require(
            output.metrics.first { $0.selection.metricID == "sessions" }
        )

        #expect(measurementDelta.current.value == 12)
        #expect(measurementDelta.reference.value == nil)
        #expect(measurementDelta.rawAbsoluteChange == nil)
        #expect(measurementDelta.current.coverage.observationCount == 3)
        #expect(measurementDelta.current.coverage.validValueCount == 1)
        #expect(measurementDelta.current.coverage.missingValueCount == 2)

        #expect(tallyDelta.current.value == 2)
        #expect(tallyDelta.reference.value == 0)
        #expect(tallyDelta.rawAbsoluteChange == 2)
        #expect(tallyDelta.rawPercentChange == nil)
    }

    @Test func observedEventWithMissingAdditiveValueDoesNotBecomeZero() throws {
        let reference = try window(date(2026, 1, 1), date(2026, 1, 3))
        let current = try window(date(2026, 1, 3), date(2026, 1, 5))
        let distance = selection("distance", missing: .zeroWhenAbsent)
        let output = try result(
            current: current,
            reference: reference,
            selections: [distance],
            observations: [
                observation(distance, date(2026, 1, 3, 12), nil),
            ]
        )
        let delta = try #require(output.metrics.first)

        #expect(delta.current.value == nil)
        #expect(delta.current.coverage.observationCount == 1)
        #expect(delta.current.coverage.missingValueCount == 1)
        #expect(delta.reference.value == 0)
        #expect(delta.rawAbsoluteChange == nil)
    }

    @Test func completeDayCoverageUsesLocalCalendarAcrossDSTAndExcludesFragments() throws {
        let current = try window(
            date(2026, 3, 7, 12),
            date(2026, 3, 10, 12)
        )
        let metric = selection("sleep", aggregation: .mean)
        let output = try ExperimentComparisonEngine.evaluate(
            request: ExperimentComparisonRequest(currentWindow: current),
            selections: [metric],
            observations: [
                observation(metric, date(2026, 3, 7, 13), 7),
                observation(metric, date(2026, 3, 8, 13), 8),
                observation(metric, date(2026, 3, 9, 13), 7.5),
                observation(metric, date(2026, 3, 10, 11), 6),
            ]
        )
        let coverage = try #require(output.metrics.first?.current.coverage)

        #expect(current.duration == 71 * 3_600)
        #expect(coverage.populatedCalendarDays == 4)
        #expect(coverage.expectedCompleteCalendarDays == 2)
        #expect(coverage.populatedCompleteCalendarDays == 2)
        #expect(coverage.completeDayFraction == 1)
    }

    @Test func numericAndGroupSummariesAreStableAndKeepProvenance() throws {
        let reference = try window(date(2026, 1, 1), date(2026, 1, 3))
        let current = try window(date(2026, 1, 3), date(2026, 1, 5))
        let metric = selection("custom-rating", aggregation: .mean)
        let observations = [
            observation(metric, date(2026, 1, 3, 8), 1, group: "Fresh"),
            observation(metric, date(2026, 1, 3, 12), 3, group: "Fresh"),
            observation(metric, date(2026, 1, 4, 8), 10, group: "Sore"),
            observation(
                metric,
                date(2026, 1, 4, 12),
                14,
                provenance: .imported,
                group: "Sore"
            ),
            observation(metric, date(2026, 1, 4, 16), 100),
        ]
        let forward = try result(
            current: current,
            reference: reference,
            selections: [metric],
            observations: observations
        )
        let reversed = try result(
            current: current,
            reference: reference,
            selections: [metric],
            observations: observations.reversed()
        )
        let aggregate = try #require(forward.metrics.first?.current)
        let summary = try #require(aggregate.summary)
        let fresh = try #require(aggregate.groups.first)
        let sore = try #require(aggregate.groups.last)

        #expect(forward == reversed)
        #expect(summary.count == 5)
        #expect(summary.median == 10)
        #expect(summary.q1 == 3)
        #expect(summary.q3 == 14)
        #expect(aggregate.groups.map(\.group) == ["Fresh", "Sore"])
        #expect(fresh.aggregateValue == 2)
        #expect(fresh.summary.median == 2)
        #expect(fresh.provenance == .measured)
        #expect(sore.aggregateValue == 12)
        #expect(sore.provenance == .mixed)
        #expect(aggregate.provenance == .mixed)
    }

    // MARK: - Invalid requests and versioning

    @Test func invalidComparisonShapesAreRejectedRatherThanCoerced() throws {
        let current = try window(date(2026, 1, 3), date(2026, 1, 6))
        let overlapping = try window(date(2026, 1, 2), date(2026, 1, 4))
        let meanPerDay = selection(
            "mean",
            aggregation: .mean,
            normalization: .perDay
        )
        let zeroMean = selection(
            "zero-mean",
            aggregation: .mean,
            missing: .zeroWhenAbsent
        )
        let duplicate = selection("duplicate")
        let future = ExperimentMetricSelection(
            version: ExperimentAnalysisContract.currentVersion + 1,
            metricID: "future",
            aggregation: .sum
        )

        #expect(throws: ExperimentComparisonError.overlappingWindows) {
            try ExperimentComparisonEngine.evaluate(
                request: ExperimentComparisonRequest(
                    currentWindow: current,
                    reference: .custom(window: overlapping)
                ),
                selections: [],
                observations: []
            )
        }
        #expect(
            throws: ExperimentComparisonError.unsupportedPerDayNormalization(meanPerDay.key)
        ) {
            try ExperimentComparisonEngine.evaluate(
                request: ExperimentComparisonRequest(currentWindow: current),
                selections: [meanPerDay],
                observations: []
            )
        }
        #expect(
            throws: ExperimentComparisonError.unsupportedZeroWhenAbsent(zeroMean.key)
        ) {
            try ExperimentComparisonEngine.evaluate(
                request: ExperimentComparisonRequest(currentWindow: current),
                selections: [zeroMean],
                observations: []
            )
        }
        #expect(throws: ExperimentComparisonError.duplicateMetric(duplicate.key)) {
            try ExperimentComparisonEngine.evaluate(
                request: ExperimentComparisonRequest(currentWindow: current),
                selections: [duplicate, duplicate],
                observations: []
            )
        }
        #expect(
            throws: ExperimentComparisonError.invalidVersion(
                ExperimentAnalysisContract.currentVersion + 1
            )
        ) {
            try ExperimentComparisonEngine.evaluate(
                request: ExperimentComparisonRequest(currentWindow: current),
                selections: [future],
                observations: []
            )
        }
    }

    @Test func requestAndResultContractsRoundTripWithVersionAndScope() throws {
        let current = try window(date(2026, 1, 3), date(2026, 1, 5))
        let reference = try window(
            date(2025, 12, 30),
            date(2026, 1, 3),
            timeZoneIdentifier: "Europe/London"
        )
        let metric = selection(
            "estimated-one-rep-max",
            aggregation: .maximum,
            scope: ExperimentMetricScope(kind: .exercise, id: "bench-press")
        )
        let request = ExperimentComparisonRequest(
            currentWindow: current,
            reference: .experiment(id: UUID(), window: reference)
        )
        let output = try ExperimentComparisonEngine.evaluate(
            request: request,
            selections: [metric],
            observations: [observation(metric, date(2026, 1, 4, 12), 100)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let decodedRequest = try decoder.decode(
            ExperimentComparisonRequest.self,
            from: encoder.encode(request)
        )
        let decodedResult = try decoder.decode(
            ExperimentResult.self,
            from: encoder.encode(output)
        )

        #expect(decodedRequest == request)
        #expect(decodedResult == output)
        #expect(decodedResult.version == ExperimentAnalysisContract.currentVersion)
        #expect(decodedResult.metrics.first?.selection.key == metric.key)
        #expect(decodedResult.referenceWindow.timeZoneIdentifier == "Europe/London")
    }
}
