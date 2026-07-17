import Foundation
@testable import ForgeCore
import Testing

/// The one-liners must stay honest: caveats win over strength labels, no
/// causal phrasing, and empty/sparse states say so plainly.
struct InsightExplanationTests {

    private func result(
        warnings: [InsightWarning] = [],
        relationship: InsightRelationship? = nil,
        deltas: [InsightPeriodDelta]? = nil,
        groups: [InsightGroup]? = nil
    ) -> InsightResult {
        InsightResult(
            signature: "test", series: [], relationship: relationship, groups: groups,
            periodDeltas: deltas, histogram: nil,
            coverage: InsightCoverage(expectedBuckets: 84, populatedBuckets: 60),
            provenance: .measured, warnings: warnings
        )
    }

    private func relationship(spearman: Double, pairs: Int = 30) -> InsightRelationship {
        InsightRelationship(
            pairs: (0..<pairs).map { InsightPair(date: Date(timeIntervalSinceReferenceDate: Double($0) * 86_400), x: 0, y: 0) },
            spearman: spearman, interval: 0.2...0.7, trend: nil, sensitivitySpearman: spearman
        )
    }

    @Test func neutralIntervalBeatsAnyStrengthLabel() {
        let summary = InsightExplanationBuilder.summary(
            for: result(warnings: [.neutralInterval], relationship: relationship(spearman: 0.55)),
            shape: .relationship, primaryTitle: "Working volume", comparisonTitle: "Sleep duration"
        )
        #expect(summary.contains("No consistent pattern"))
        #expect(!summary.lowercased().contains("tendency"))
    }

    @Test func sparsePairsExplainTheThreshold() {
        let summary = InsightExplanationBuilder.summary(
            for: result(
                warnings: [.insufficientPairs(found: 4, needed: 10)],
                relationship: InsightRelationship(pairs: [], spearman: nil, interval: nil, trend: nil, sensitivitySpearman: nil)
            ),
            shape: .relationship, primaryTitle: "Working volume", comparisonTitle: "Sleep duration"
        )
        #expect(summary.contains("4 matched days"))
        #expect(summary.contains("10"))
    }

    @Test func strongCleanSignalGetsALabelWithoutCausalLanguage() {
        let summary = InsightExplanationBuilder.summary(
            for: result(relationship: relationship(spearman: 0.65)),
            shape: .relationship, primaryTitle: "Working volume", comparisonTitle: "Sleep duration"
        )
        #expect(summary.contains("A clear tendency"))
        #expect(summary.contains("tended to move"))
        for banned in ["improved", "caused", "because", "boosts", "leads to"] {
            #expect(!summary.lowercased().contains(banned), "Causal phrasing leaked: \(banned)")
        }
    }

    @Test func outlierSensitiveHeadlinesGetTheCareCaveat() {
        let summary = InsightExplanationBuilder.summary(
            for: result(warnings: [.outlierSensitive], relationship: relationship(spearman: 0.6)),
            shape: .relationship, primaryTitle: "Working volume", comparisonTitle: "Sleep duration"
        )
        #expect(summary.contains("read with care"))
    }

    @Test func periodSummaryGuardsZeroDenominator() {
        let noPrevious = InsightExplanationBuilder.summary(
            for: result(deltas: [
                InsightPeriodDelta(metricID: "m", current: 120, previous: 0, change: 120, percentChange: nil),
            ]),
            shape: .periodComparison, primaryTitle: "Working volume"
        )
        #expect(noPrevious.contains("previous period was zero"))
        #expect(noPrevious.contains("undefined"))

        let normal = InsightExplanationBuilder.summary(
            for: result(deltas: [
                InsightPeriodDelta(metricID: "m", current: 150, previous: 100, change: 50, percentChange: 50),
            ]),
            shape: .periodComparison, primaryTitle: "Working volume"
        )
        #expect(normal.contains("up 50%"))
    }

    @Test func groupSummaryNamesTopAndBottom() {
        let summary = InsightExplanationBuilder.summary(
            for: result(groups: [
                InsightGroup(category: "fresh", bucketCount: 12, total: 900, median: 300, minimum: 250, maximum: 380),
                InsightGroup(category: "sore", bucketCount: 11, total: 500, median: 110, minimum: 80, maximum: 200),
            ]),
            shape: .groupComparison, primaryTitle: "Working volume"
        )
        #expect(summary.contains("fresh"))
        #expect(summary.contains("sore"))
    }

    @Test func multiSeriesTrendSummaryReadsBothLines() {
        func series(_ id: String, values: [Double]) -> InsightSeries {
            InsightSeries(
                metricID: id,
                points: values.enumerated().map {
                    InsightSeriesPoint(date: Date(timeIntervalSinceReferenceDate: Double($0.offset) * 604_800), value: $0.element)
                },
                provenance: .measured
            )
        }
        var result = result()
        result.series = [
            series("a", values: [3, 3, 3, 3.1, 3, 3]),
            series("b", values: [2, 2.4, 2.8, 3.0, 3.2, 3.6]),
        ]
        let summary = InsightExplanationBuilder.summary(
            for: result, shape: .trend,
            primaryTitle: "Chest sets", comparisonTitle: "Back sets"
        )
        #expect(summary.contains("Chest sets had no measurable change"))
        // Theil–Sen over timestamps, expressed as fitted end versus fitted
        // start — robust to noisy endpoints without using a hidden mean
        // denominator for the percentage.
        #expect(summary.contains("Back sets showed a robust trend ending 71.4% higher than it began"))
    }

    @Test func tallySummariesCompareHalvesNotEndpoints() {
        func series(_ id: String, values: [Double]) -> InsightSeries {
            InsightSeries(
                metricID: id,
                points: values.enumerated().map {
                    InsightSeriesPoint(date: Date(timeIntervalSinceReferenceDate: Double($0.offset) * 86_400), value: $0.element)
                },
                provenance: .measured
            )
        }
        var zeroStart = result()
        zeroStart.series = [series("cardio.sessions", values: [0, 0, 0, 0, 0, 1, 0, 1, 1, 1])]
        let recentHalf = InsightExplanationBuilder.summary(
            for: zeroStart, shape: .trend,
            primaryTitle: "Cardio sessions", tallyMetricIDs: ["cardio.sessions"]
        )
        #expect(recentHalf.contains("landed in the recent half"))

        var steady = result()
        steady.series = [series("cardio.sessions", values: [1, 0, 1, 1, 0, 1, 1, 0, 1, 0])]
        let steadySummary = InsightExplanationBuilder.summary(
            for: steady, shape: .trend,
            primaryTitle: "Cardio sessions", tallyMetricIDs: ["cardio.sessions"]
        )
        #expect(steadySummary.contains("same average per bucket"))
    }

    /// Odd-length windows compare equal-duration halves and leave the single
    /// middle bucket neutral. Including it in either side would manufacture a
    /// 16.7% change from thirteen identical daily counts.
    @Test func oddTallyWindowsDoNotGiveTheMiddleBucketToEitherHalf() {
        let points = (0..<13).map {
            InsightSeriesPoint(
                date: Date(timeIntervalSinceReferenceDate: Double($0) * 86_400),
                value: 1
            )
        }
        var odd = result()
        odd.series = [InsightSeries(metricID: "sessions", points: points, provenance: .measured)]
        let summary = InsightExplanationBuilder.summary(
            for: odd, shape: .trend,
            primaryTitle: "Training days", tallyMetricIDs: ["sessions"]
        )
        #expect(summary.contains("same average per bucket"))
        #expect(!summary.contains("16.7%"))
    }

    @Test func trendNoiseBandIsSymmetricAndKeepsExactDirection() {
        func summary(_ later: Double) -> String {
            var trend = result()
            trend.series = [InsightSeries(
                metricID: "volume",
                points: [100, 100, later, later].enumerated().map {
                    InsightSeriesPoint(
                        date: Date(timeIntervalSinceReferenceDate: Double($0.offset) * 86_400),
                        value: $0.element
                    )
                },
                provenance: .measured
            )]
            return InsightExplanationBuilder.summary(
                for: trend,
                shape: .trend,
                primaryTitle: "Volume",
                tallyMetricIDs: ["volume"]
            )
        }

        let below = summary(102.99)
        #expect(below.contains("roughly steady"))
        #expect(below.contains("higher"))

        let above = summary(103.01)
        #expect(!above.contains("roughly steady"))
        #expect(above.contains("higher"))

        let negative = summary(96.99)
        #expect(!negative.contains("roughly steady"))
        #expect(negative.contains("lower"))
    }

    @Test func constantRelationshipExplainsWhyCorrelationIsUndefined() {
        var constant = result(
            warnings: [.constantRelationship(metricID: "sleep")],
            relationship: InsightRelationship(
                pairs: (0..<12).map {
                    InsightPair(date: Date(timeIntervalSinceReferenceDate: Double($0) * 86_400), x: 7, y: Double($0))
                },
                spearman: nil, interval: nil, trend: nil, sensitivitySpearman: nil
            )
        )
        constant.series = [
            InsightSeries(metricID: "volume", points: [], provenance: .measured),
            InsightSeries(metricID: "sleep", points: [], provenance: .measured),
        ]
        let summary = InsightExplanationBuilder.summary(
            for: constant, shape: .relationship,
            primaryTitle: "Working volume", comparisonTitle: "Sleep"
        )
        #expect(summary.contains("Sleep did not vary"))
        #expect(summary.contains("cannot be calculated"))
    }

    @Test func constantDistributionStatesTheValueInsteadOfCallingItThin() {
        var constant = result(warnings: [.constantDistribution(value: 42)])
        constant.series = [
            InsightSeries(
                metricID: "measurement",
                points: (0..<15).map {
                    InsightSeriesPoint(
                        date: Date(timeIntervalSinceReferenceDate: Double($0) * 86_400),
                        value: 42
                    )
                },
                provenance: .measured
            ),
        ]
        let summary = InsightExplanationBuilder.summary(
            for: constant, shape: .distribution, primaryTitle: "Measurement"
        )
        #expect(summary == "All 15 recorded values were 42 in this range.")
    }

    @Test func strengthLabelScaleIsConservative() {
        #expect(InsightExplanationBuilder.strengthLabel(0.65) == "A clear tendency")
        #expect(InsightExplanationBuilder.strengthLabel(0.45) == "A moderate tendency")
        #expect(InsightExplanationBuilder.strengthLabel(0.25) == "A weak tendency")
        #expect(InsightExplanationBuilder.strengthLabel(0.1) == "Little to no tendency")
    }
}
