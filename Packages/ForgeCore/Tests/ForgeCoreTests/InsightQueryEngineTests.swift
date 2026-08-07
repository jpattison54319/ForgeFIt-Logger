import Foundation
@testable import ForgeCore
import Testing

struct InsightQueryEngineTests {

    // MARK: - Fixtures

    /// New York calendar on purpose: it has DST transitions inside any
    /// multi-month window, which is exactly what daily bucketing must survive.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// 2026-06-30 12:00 New York.
    private var now: Date {
        DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 6, day: 30, hour: 12
        ).date!
    }

    private func day(_ offset: Int, hour: Int = 9) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(TimeInterval(hour) * 3_600)
    }

    private func metric(
        _ id: String,
        kind: InsightValueKind = .count,
        aggregation: InsightAggregation = .sum,
        role: InsightTimingRole = .either,
        buckets: Set<InsightBucket> = [.session, .daily],
        zeroFill: InsightZeroFillPolicy? = nil
    ) -> InsightMetricDescriptor {
        InsightMetricDescriptor(
            id: id, title: id, category: "test", valueKind: kind, timingRole: role,
            nativeBuckets: buckets, aggregation: aggregation,
            supportedShapes: Set(InsightShape.allCases),
            supportedDimensions: Set(InsightDimension.allCases),
            zeroFillPolicy: zeroFill
        )
    }

    private func observations(_ values: [(Int, Double)], provenance: InsightProvenance = .measured) -> [InsightObservation] {
        values.map { InsightObservation(timestamp: day($0.0), value: $0.1, provenance: provenance) }
    }

    // MARK: - Bucketing & aggregation

    @Test func dailyBucketsMergeSameDaySessions() {
        let engine = InsightQueryEngine.bucket(
            [
                InsightObservation(timestamp: day(1, hour: 7), value: 10, provenance: .measured),
                InsightObservation(timestamp: day(1, hour: 18), value: 5, provenance: .measured),
                InsightObservation(timestamp: day(2), value: 3, provenance: .measured),
            ],
            bucket: .daily, aggregation: .sum, calendar: calendar
        )
        #expect(engine.map(\.value) == [3, 15])
    }

    @Test func sessionBucketKeepsEverySessionSeparate() {
        let engine = InsightQueryEngine.bucket(
            [
                InsightObservation(timestamp: day(1, hour: 7), value: 10, provenance: .measured),
                InsightObservation(timestamp: day(1, hour: 18), value: 5, provenance: .measured),
            ],
            bucket: .session, aggregation: .sum, calendar: calendar
        )
        #expect(engine.count == 2)
    }

    @Test func weeklyAnchorsAreStableAcrossDST() {
        // 2026 DST spring-forward in New York: March 8. Days either side of
        // it must land in their correct week buckets, not drift.
        let beforeDST = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 7, hour: 9).date!
        let afterDST = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 9, hour: 9).date!
        let buckets = InsightQueryEngine.bucket(
            [
                InsightObservation(timestamp: beforeDST, value: 1, provenance: .measured),
                InsightObservation(timestamp: afterDST, value: 1, provenance: .measured),
            ],
            bucket: .weekly, aggregation: .sum, calendar: calendar
        )
        #expect(buckets.count == 2, "March 7 and March 9 2026 straddle a week boundary and DST.")
    }

    @Test func aggregationRulesMatchTheirDescriptors() {
        let sameDay = [
            InsightObservation(timestamp: day(1, hour: 7), value: 100, provenance: .measured, weight: 1_000),
            InsightObservation(timestamp: day(1, hour: 18), value: 200, provenance: .measured, weight: 3_000),
        ]
        #expect(InsightQueryEngine.aggregate(sameDay, rule: .sum) == 300)
        #expect(InsightQueryEngine.aggregate(sameDay, rule: .mean) == 150)
        #expect(InsightQueryEngine.aggregate(sameDay, rule: .bestSession) == 200)
        #expect(InsightQueryEngine.aggregate(sameDay, rule: .min) == 100)
        // Distance-weighted: (100·1000 + 200·3000) / 4000 = 175.
        #expect(InsightQueryEngine.aggregate(sameDay, rule: .distanceWeightedMean) == 175)
        #expect(InsightQueryEngine.aggregate(sameDay, rule: .lastValue) == 200)
    }

    // MARK: - Relationship pairing

    private func relationshipRecipe(lagDays: Int = 1) -> InsightRecipe {
        InsightRecipe(
            shape: .relationship,
            primaryMetricID: "outcome",
            comparisonMetricIDs: ["exposure"],
            range: .twelveWeeks,
            bucket: .daily,
            lag: InsightLag(unit: .days, count: lagDays)
        )
    }

    @Test func lagShiftsExposureOntoNextDayOutcome() throws {
        // Exposure on day d pairs with outcome on day d+1; 12 aligned pairs.
        var exposure: [InsightObservation] = []
        var outcome: [InsightObservation] = []
        for offset in stride(from: 24, through: 2, by: -2) {
            exposure.append(InsightObservation(timestamp: day(offset), value: Double(offset), provenance: .measured))
            outcome.append(InsightObservation(timestamp: day(offset - 1), value: Double(offset) * 2, provenance: .measured))
        }
        let result = InsightQueryEngine.evaluate(
            recipe: relationshipRecipe(),
            descriptors: [metric("outcome", role: .outcome), metric("exposure", role: .exposure)],
            observations: ["exposure": exposure, "outcome": outcome],
            now: now, calendar: calendar
        )
        let relationship = try #require(result.relationship)
        #expect(relationship.pairs.count == 12)
        #expect(abs((relationship.spearman ?? 0) - 1) < 1e-9)
        #expect(result.coverage.pairedSamples == 12)
    }

    @Test func multiSessionDaysStillYieldOnePairPerDay() throws {
        // Two outcome sessions on the same day collapse into ONE daily bucket
        // before pairing — an exposure never fans across sessions.
        var exposure: [InsightObservation] = []
        var outcome: [InsightObservation] = []
        for offset in stride(from: 24, through: 2, by: -2) {
            exposure.append(InsightObservation(timestamp: day(offset), value: Double(offset), provenance: .measured))
            outcome.append(InsightObservation(timestamp: day(offset - 1, hour: 7), value: 10, provenance: .measured))
            outcome.append(InsightObservation(timestamp: day(offset - 1, hour: 18), value: 20, provenance: .measured))
        }
        let result = InsightQueryEngine.evaluate(
            recipe: relationshipRecipe(),
            descriptors: [metric("outcome", role: .outcome), metric("exposure", role: .exposure)],
            observations: ["exposure": exposure, "outcome": outcome],
            now: now, calendar: calendar
        )
        let relationship = try #require(result.relationship)
        #expect(relationship.pairs.count == 12)
        #expect(relationship.pairs.allSatisfy { $0.y == 30 }, "Same-day sessions sum into the outcome bucket.")
    }

    @Test func sparsePairsRefuseStatisticsHonestly() throws {
        let exposure = observations([(3, 1), (2, 2), (1, 3)])
        let outcome = observations([(2, 1), (1, 2), (0, 3)])
        let result = InsightQueryEngine.evaluate(
            recipe: relationshipRecipe(),
            descriptors: [metric("outcome", role: .outcome), metric("exposure", role: .exposure)],
            observations: ["exposure": exposure, "outcome": outcome],
            now: now, calendar: calendar
        )
        let relationship = try #require(result.relationship)
        #expect(relationship.spearman == nil)
        #expect(result.warnings.contains(.insufficientPairs(found: 2, needed: 10)))
    }

    @Test func relationshipResultsAreDeterministic() {
        var exposure: [InsightObservation] = []
        var outcome: [InsightObservation] = []
        for offset in 1...40 {
            exposure.append(InsightObservation(timestamp: day(offset + 1), value: Double(offset % 9), provenance: .measured))
            outcome.append(InsightObservation(timestamp: day(offset), value: Double((offset % 9) * 3 + offset % 4), provenance: .measured))
        }
        let inputs: [String: [InsightObservation]] = ["exposure": exposure, "outcome": outcome]
        let descriptors = [metric("outcome", role: .outcome), metric("exposure", role: .exposure)]
        let a = InsightQueryEngine.evaluate(recipe: relationshipRecipe(), descriptors: descriptors, observations: inputs, now: now, calendar: calendar)
        let b = InsightQueryEngine.evaluate(recipe: relationshipRecipe(), descriptors: descriptors, observations: inputs, now: now, calendar: calendar)
        #expect(a == b)
    }

    /// Spring-forward 2026-03-08 in New York is a 23-hour day: a fixed
    /// 86,400-second lag offset misses the pair that crosses it; calendar
    /// arithmetic must not.
    @Test func lagPairingSurvivesDaylightSaving() throws {
        let base = DateComponents(
            calendar: calendar, timeZone: calendar.timeZone,
            year: 2026, month: 3, day: 1, hour: 9
        ).date!
        func dstDay(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: base)! }
        let exposure = (0..<14).map { InsightObservation(timestamp: dstDay($0), value: Double($0), provenance: .measured) }
        let outcome = (0..<14).map { InsightObservation(timestamp: dstDay($0), value: Double($0) * 2, provenance: .measured) }
        var recipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "outcome",
            comparisonMetricIDs: ["exposure"], range: .sixMonths, bucket: .daily
        )
        recipe.lag = InsightLag(unit: .days, count: 1)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [
                metric("outcome", aggregation: .mean, role: .outcome),
                metric("exposure", aggregation: .mean, role: .exposure),
            ],
            observations: ["outcome": outcome, "exposure": exposure],
            now: now, calendar: calendar
        )
        // 14 exposure days; the first 13 have a next-day outcome — including
        // the one whose next day is only 23 hours away.
        #expect(result.relationship?.pairs.count == 13)
    }

    /// A metric whose whole recorded history is shorter than its declared
    /// minimum is refused with a named warning, not silently implied.
    @Test func shortHistoryIsRefusedNotImplied() {
        let gated = InsightMetricDescriptor(
            id: "e1rm", title: "e1rm", category: "test",
            valueKind: .massKilograms, timingRole: .outcome,
            nativeBuckets: [.session, .daily], aggregation: .bestSession,
            supportedShapes: Set(InsightShape.allCases), minimumHistoryDays: 14
        )
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(shape: .trend, primaryMetricID: "e1rm", bucket: .daily),
            descriptors: [gated],
            observations: ["e1rm": observations([(5, 100), (2, 105), (1, 102)])],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains(.insufficientHistory(metricID: "e1rm", daysAvailable: 5, needed: 14)))
    }

    /// Period values aggregate RAW observations, so weighted means keep
    /// their weights: a long run moves "average pace" more than a short jog.
    /// Bucket-mean aggregation would weight each day equally.
    @Test func periodComparisonKeepsAggregationWeights() throws {
        let weighted = InsightMetricDescriptor(
            id: "pace", title: "pace", category: "test", valueKind: .pace, timingRole: .either,
            nativeBuckets: [.session, .daily], aggregation: .distanceWeightedMean,
            supportedShapes: Set(InsightShape.allCases)
        )
        let recipe = InsightRecipe(shape: .periodComparison, primaryMetricID: "pace", range: .fourWeeks, bucket: .daily)
        // Current period: 6 min/km over 10 km and 8 min/km over 2 km —
        // weighted 6.33, unweighted daily-bucket mean 7.0.
        let rows = [
            InsightObservation(timestamp: day(40), value: 7, provenance: .measured, weight: 5),
            InsightObservation(timestamp: day(5), value: 6, provenance: .measured, weight: 10),
            InsightObservation(timestamp: day(2), value: 8, provenance: .measured, weight: 2),
        ]
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [weighted],
            observations: ["pace": rows],
            now: now, calendar: calendar
        )
        let delta = try #require(result.periodDeltas?.first)
        let current = try #require(delta.current)
        let previous = try #require(delta.previous)
        #expect(abs(current - (6 * 10 + 8 * 2) / 12) < 1e-9)
        #expect(abs(previous - 7) < 1e-9)
    }

    /// Observations partition by their own timestamps, not by which weekly
    /// bucket they fell into — a week straddling the period boundary must
    /// not drag its late observations into the previous period.
    @Test func periodBoundarySplitsStraddlingWeeks() throws {
        let recipe = InsightRecipe(shape: .periodComparison, primaryMetricID: "volume", range: .fourWeeks, bucket: .weekly)
        // Boundary = 27 days ago. Days 29 and 26 usually share a calendar
        // week; each must still count for its own period.
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": observations([(29, 100), (26, 1_000), (5, 500)])],
            now: now, calendar: calendar
        )
        let delta = try #require(result.periodDeltas?.first)
        #expect(delta.previous == 100)
        #expect(delta.current == 1_500)
    }

    /// The split is half-open at the shared boundary: the oldest and newest
    /// instants are retained, and the boundary belongs to the current period
    /// exactly once. This pins two equal 28-day elapsed windows rather than
    /// two calendar-bucket approximations.
    @Test func periodComparisonUsesEqualWindowsAndOneBoundaryOwner() throws {
        let boundary = try #require(calendar.date(byAdding: .day, value: -28, to: now))
        let previousStart = try #require(calendar.date(byAdding: .day, value: -56, to: now))
        let rows = [
            InsightObservation(timestamp: previousStart, value: 1, provenance: .measured),
            InsightObservation(timestamp: boundary.addingTimeInterval(-1), value: 10, provenance: .measured),
            InsightObservation(timestamp: boundary, value: 100, provenance: .measured),
            InsightObservation(timestamp: now, value: 1_000, provenance: .measured),
        ]
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .periodComparison, primaryMetricID: "volume",
                range: .fourWeeks, bucket: .weekly
            ),
            descriptors: [metric("volume")], observations: ["volume": rows],
            now: now, calendar: calendar
        )
        let delta = try #require(result.periodDeltas?.first)
        #expect(delta.previous == 11)
        #expect(delta.current == 1_100)
        #expect(delta.previousSamples == 2)
        #expect(delta.currentSamples == 2)
    }

    /// Missing measurements are unknown; absent true-event tallies are zero.
    /// They must never collapse into the same period result just because both
    /// use sum-like displays elsewhere.
    @Test func periodComparisonDistinguishesMissingFromTrueZero() throws {
        let recipe = InsightRecipe(
            shape: .periodComparison, primaryMetricID: "metric",
            range: .fourWeeks, bucket: .daily
        )
        let currentOnly = [
            InsightObservation(timestamp: day(4), value: 12, provenance: .measured),
        ]

        let measurement = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("metric", aggregation: .sum, zeroFill: .never)],
            observations: ["metric": currentOnly], now: now, calendar: calendar
        )
        let missingDelta = try #require(measurement.periodDeltas?.first)
        #expect(missingDelta.current == 12)
        #expect(missingDelta.previous == nil)
        #expect(missingDelta.change == nil)

        let eventTally = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("metric", aggregation: .sum, zeroFill: .zeroWhenAbsent)],
            observations: ["metric": currentOnly], now: now, calendar: calendar
        )
        let zeroDelta = try #require(eventTally.periodDeltas?.first)
        #expect(zeroDelta.current == 12)
        #expect(zeroDelta.previous == 0)
        #expect(zeroDelta.change == 12)
        #expect(zeroDelta.percentChange == nil)
    }

    /// Mixed-unit period comparisons cannot share one bar axis — cards only.
    @Test func mixedUnitPeriodComparisonDropsBars() {
        let mass = metric("volume")
        let duration = InsightMetricDescriptor(
            id: "minutes", title: "minutes", category: "test", valueKind: .durationSeconds,
            timingRole: .either, nativeBuckets: [.session, .daily], aggregation: .sum,
            supportedShapes: Set(InsightShape.allCases), supportedDimensions: Set(InsightDimension.allCases)
        )
        let recipe = InsightRecipe(
            shape: .periodComparison, primaryMetricID: "volume",
            comparisonMetricIDs: ["minutes"], range: .fourWeeks, bucket: .daily
        )
        let charts = InsightCompatibilityEngine.allowedCharts(recipe, metrics: [mass, duration])
        #expect(charts == [.periodComparisonCards])
    }

    /// A configured metric with nothing in the window is named in a warning —
    /// the overlay legend only shows series that draw marks, so without this
    /// the metric would vanish without explanation.
    @Test func emptySeriesIsNamedNotHidden() {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "a", comparisonMetricIDs: ["b"],
            range: .fourWeeks, bucket: .daily
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("a"), metric("b")],
            observations: ["a": observations([(5, 100), (2, 80)]), "b": []],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains(.emptySeries(metricID: "b")))
        #expect(!result.warnings.contains(.emptySeries(metricID: "a")))
        #expect(!result.warnings.contains(.emptyResult))
    }

    /// When EVERY series is empty the full empty state owns the message —
    /// per-series warnings on top of it would be noise.
    @Test func allEmptySeriesCollapseToEmptyResult() {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "a", comparisonMetricIDs: ["b"],
            range: .fourWeeks, bucket: .daily
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("a"), metric("b")],
            observations: [:],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains(.emptyResult))
        #expect(!result.warnings.contains { if case .emptySeries = $0 { return true } else { return false } })
    }

    /// A six-month request against a log that began nineteen completed days
    /// ago trims to the data start. Today's partial day is not denominator
    /// padding.
    @Test func windowNeverPredatesTheData() {
        let recipe = InsightRecipe(shape: .trend, primaryMetricID: "sessions", range: .sixMonths, bucket: .daily)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("sessions")],
            observations: ["sessions": observations([(19, 1), (12, 1), (5, 1), (1, 1)])],
            now: now, calendar: calendar, dataStart: day(19)
        )
        #expect(result.coverage.expectedBuckets == 19)
        #expect(result.series.first?.points.count == 19)
    }

    @Test func fixedDailyRangesContainTheirAdvertisedCompletedDays() throws {
        let todayStart = calendar.startOfDay(for: now)
        let rows = (0...28).map { offset in
            InsightObservation(
                timestamp: calendar.date(byAdding: .day, value: -offset, to: todayStart)!
                    .addingTimeInterval(43_200),
                value: 1,
                provenance: .measured
            )
        }
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .trend, primaryMetricID: "measurement",
                range: .fourWeeks, bucket: .daily
            ),
            descriptors: [metric("measurement", aggregation: .mean)],
            observations: ["measurement": rows],
            now: now,
            calendar: calendar,
            dataStart: day(40)
        )

        let points = try #require(result.series.first?.points)
        #expect(points.count == 28)
        #expect(result.coverage.expectedBuckets == 28)
        #expect(result.coverage.populatedBuckets == 28)
        #expect(points.allSatisfy { $0.date < todayStart })
        #expect(points.first?.date == calendar.date(byAdding: .day, value: -28, to: todayStart))
        #expect(points.last?.date == calendar.date(byAdding: .day, value: -1, to: todayStart))
    }

    @Test func completedDailyRangeUsesCalendarMathAcrossDaylightSaving() throws {
        let springNow = try #require(DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 3,
            day: 9,
            hour: 12
        ).date)
        let todayStart = calendar.startOfDay(for: springNow)
        let rows = try (0...28).map { offset -> InsightObservation in
            let date = try #require(calendar.date(byAdding: .day, value: -offset, to: todayStart))
            return InsightObservation(
                timestamp: date.addingTimeInterval(43_200),
                value: Double(offset),
                provenance: .measured
            )
        }
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .trend, primaryMetricID: "measurement",
                range: .fourWeeks, bucket: .daily
            ),
            descriptors: [metric("measurement", aggregation: .mean)],
            observations: ["measurement": rows],
            now: springNow,
            calendar: calendar
        )

        let points = try #require(result.series.first?.points)
        let expectedStart = try #require(calendar.date(byAdding: .day, value: -28, to: todayStart))
        #expect(points.count == 28)
        #expect(points.first?.date == expectedStart)
        #expect(todayStart.timeIntervalSince(expectedStart) == 28 * 86_400 - 3_600)
    }

    @Test func everyNonPeriodDailyShapeExcludesToday() throws {
        let todayStart = calendar.startOfDay(for: now)
        let primary = [
            InsightObservation(timestamp: day(1), value: 10, provenance: .measured, category: "A"),
            InsightObservation(timestamp: day(0), value: 20, provenance: .measured, category: "B"),
        ]
        let comparison = [
            InsightObservation(timestamp: day(1), value: 100, provenance: .measured),
            InsightObservation(timestamp: day(0), value: 200, provenance: .measured),
        ]
        let recipes = [
            InsightRecipe(shape: .trend, primaryMetricID: "primary", range: .fourWeeks, bucket: .daily),
            InsightRecipe(
                shape: .relationship, primaryMetricID: "primary",
                comparisonMetricIDs: ["comparison"], range: .fourWeeks, bucket: .daily,
                lag: InsightLag(unit: .days, count: 0)
            ),
            InsightRecipe(
                shape: .groupComparison, primaryMetricID: "primary",
                dimension: .checkinTag, range: .fourWeeks, bucket: .daily
            ),
            InsightRecipe(shape: .distribution, primaryMetricID: "primary", range: .fourWeeks, bucket: .daily),
        ]

        for recipe in recipes {
            let result = InsightQueryEngine.evaluate(
                recipe: recipe,
                descriptors: [
                    metric("primary", aggregation: .mean, role: .outcome),
                    metric("comparison", aggregation: .mean, role: .exposure),
                ],
                observations: ["primary": primary, "comparison": comparison],
                now: now,
                calendar: calendar
            )
            #expect(result.series.allSatisfy { line in
                line.points.allSatisfy { $0.date < todayStart }
            }, "\(recipe.shape) included today's incomplete bucket")
            #expect(result.relationship?.pairs.allSatisfy { $0.date < todayStart } != false)
        }
    }

    @Test func sessionAnalysesRemainCurrent() throws {
        let currentSession = day(0)
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .trend, primaryMetricID: "sessions",
                range: .fourWeeks, bucket: .session
            ),
            descriptors: [metric("sessions")],
            observations: [
                "sessions": [InsightObservation(
                    timestamp: currentSession, value: 1, provenance: .measured
                )],
            ],
            now: now,
            calendar: calendar
        )

        let point = try #require(result.series.first?.points.first)
        #expect(point.date == currentSession)
        #expect(point.value == 1)
    }

    @Test func periodComparisonsRemainCurrentToNow() throws {
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .periodComparison, primaryMetricID: "volume",
                range: .fourWeeks, bucket: .daily
            ),
            descriptors: [metric("volume")],
            observations: [
                "volume": [InsightObservation(
                    timestamp: day(0), value: 25, provenance: .measured
                )],
            ],
            now: now,
            calendar: calendar
        )

        let delta = try #require(result.periodDeltas?.first)
        #expect(delta.current == 25)
        #expect(delta.currentSamples == 1)
    }

    @Test func allHistoryWithNoCompletedDayIsEmpty() {
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .trend, primaryMetricID: "sessions",
                range: .allHistory, bucket: .daily
            ),
            descriptors: [metric("sessions")],
            observations: ["sessions": observations([(0, 1)])],
            now: now,
            calendar: calendar,
            dataStart: day(0)
        )

        #expect(result.series.first?.points.isEmpty == true)
        #expect(result.coverage.expectedBuckets == 0)
        #expect(result.coverage.populatedBuckets == 0)
        #expect(result.warnings.contains(.emptyResult))
    }

    @Test func allHistoryEndsYesterdayWhenTodayAlsoHasData() throws {
        let result = InsightQueryEngine.evaluate(
            recipe: InsightRecipe(
                shape: .trend, primaryMetricID: "measurement",
                range: .allHistory, bucket: .daily
            ),
            descriptors: [metric("measurement", aggregation: .mean)],
            observations: ["measurement": observations([(1, 10), (0, 20)])],
            now: now,
            calendar: calendar,
            dataStart: day(1)
        )

        let points = try #require(result.series.first?.points)
        #expect(points.count == 1)
        #expect(points.first?.date == calendar.startOfDay(for: day(1)))
        #expect(result.coverage.expectedBuckets == 1)
        #expect(result.coverage.populatedBuckets == 1)
    }

    /// Every chart kind the validator allows must have its payload in the
    /// evaluated result — an "allowed" chart that renders empty is a lie.
    @Test func everyAllowedChartHasItsPayload() throws {
        func hasPayload(_ kind: InsightChartKind, _ result: InsightResult) -> Bool {
            switch kind {
            case .lineTrend, .barTrend, .sharedUnitOverlay, .smallMultiples, .baselineIndexLines:
                return result.series.contains { !$0.points.isEmpty }
            case .scatterWithTrend:
                return result.relationship != nil
            case .groupedBars:
                return result.groups?.isEmpty == false || result.periodDeltas?.isEmpty == false
            case .boxSummary:
                return result.groups?.isEmpty == false || result.distributionSummary != nil
            case .donutShare:
                return result.groups?.isEmpty == false
            case .periodComparisonCards:
                return result.periodDeltas?.isEmpty == false
            case .histogram:
                return result.histogram?.isEmpty == false
            }
        }

        let dense = observations((1...30).map { ($0, Double(50 + $0)) })
        let exposure = observations((1...30).map { ($0, Double(400 + $0)) })
        let grouped: [InsightObservation] = (1...6).flatMap { offset in
            ["fresh", "sore"].map { tag in
                InsightObservation(timestamp: day(offset), value: Double(100 + offset), provenance: .measured, category: tag)
            }
        }

        var pairRecipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "volume",
            comparisonMetricIDs: ["sleep"], bucket: .daily
        )
        pairRecipe.lag = InsightLag(unit: .days, count: 0)
        let cases: [(InsightRecipe, [String: [InsightObservation]])] = [
            (InsightRecipe(shape: .trend, primaryMetricID: "volume", bucket: .daily), ["volume": dense]),
            (pairRecipe, ["volume": dense, "sleep": exposure]),
            (InsightRecipe(shape: .groupComparison, primaryMetricID: "volume", dimension: .checkinTag, bucket: .daily), ["volume": grouped]),
            (InsightRecipe(shape: .periodComparison, primaryMetricID: "volume", range: .fourWeeks, bucket: .daily), ["volume": dense]),
            (InsightRecipe(shape: .distribution, primaryMetricID: "volume", bucket: .daily), ["volume": dense]),
        ]
        for (candidate, inputs) in cases {
            let descriptors = [metric("volume", role: .outcome), metric("sleep", aggregation: .mean, role: .exposure)]
            let validation = InsightCompatibilityEngine.validate(candidate, descriptors: descriptors)
            #expect(!validation.allowedCharts.isEmpty, "\(candidate.shape) allows no charts")
            let result = InsightQueryEngine.evaluate(
                recipe: candidate, descriptors: descriptors, observations: inputs,
                now: now, calendar: calendar
            )
            for kind in validation.allowedCharts {
                #expect(hasPayload(kind, result), "\(candidate.shape) allows \(kind) but the payload is missing")
            }
        }
    }

    // MARK: - Groups, periods, distribution

    @Test func groupsSplitByCategoryAndSortByMedian() throws {
        let recipe = InsightRecipe(shape: .groupComparison, primaryMetricID: "volume", dimension: .checkinTag, bucket: .daily)
        // Five buckets per group — the chart minimum.
        let observations: [InsightObservation] =
            (1...5).map { InsightObservation(timestamp: day($0), value: 300 + Double($0) * 10, provenance: .measured, category: "fresh") } +
            (6...10).map { InsightObservation(timestamp: day($0), value: 100 + Double($0), provenance: .measured, category: "sore") }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": observations], now: now, calendar: calendar
        )
        let groups = try #require(result.groups)
        #expect(groups.map(\.category) == ["fresh", "sore"])
        #expect(groups.first?.median == 330)
        let fresh = try #require(groups.first)
        #expect(fresh.q1 >= fresh.minimum && fresh.q1 <= fresh.median)
        #expect(fresh.q3 >= fresh.median && fresh.q3 <= fresh.maximum)
    }

    /// Groups thinner than five buckets are dropped with a warning — two
    /// lucky days versus three is noise, not a comparison.
    @Test func tinyGroupsAreDroppedNotCharted() {
        let recipe = InsightRecipe(shape: .groupComparison, primaryMetricID: "volume", dimension: .checkinTag, bucket: .daily)
        let observations: [InsightObservation] =
            (1...5).map { InsightObservation(timestamp: day($0), value: 300, provenance: .measured, category: "fresh") } +
            (6...7).map { InsightObservation(timestamp: day($0), value: 100, provenance: .measured, category: "sore") }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": observations], now: now, calendar: calendar
        )
        #expect(result.groups?.map(\.category) == ["fresh"])
        #expect(result.warnings.contains(.groupsBelowMinimum(dropped: 1, needed: 5)))
    }

    @Test func periodComparisonSplitsTheWindowAndGuardsDenominators() throws {
        // "4W" means the CURRENT 28 days against the PRECEDING 28 days —
        // previous 100, current 150 → +50%.
        let recipe = InsightRecipe(shape: .periodComparison, primaryMetricID: "volume", range: .fourWeeks, bucket: .daily)
        let points = observations([(44, 40), (32, 60), (8, 90), (4, 60)])
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": points], now: now, calendar: calendar
        )
        let delta = try #require(result.periodDeltas?.first)
        #expect(delta.previous == 100)
        #expect(delta.current == 150)
        #expect(delta.percentChange == 50)

        // Zero previous → nil percent, never a divide-into-noise.
        let emptyPreviousResult = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": observations([(8, 90), (4, 60)])], now: now, calendar: calendar
        )
        #expect(try #require(emptyPreviousResult.periodDeltas?.first).percentChange == nil)
    }

    @Test func distributionRefusesThinData() {
        let recipe = InsightRecipe(shape: .distribution, primaryMetricID: "volume", bucket: .daily)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume", aggregation: .mean)],
            observations: ["volume": observations([(3, 10), (2, 12), (1, 14)])],
            now: now, calendar: calendar
        )
        #expect(result.histogram == nil)
        #expect(result.warnings.contains(.insufficientDistribution(found: 3, needed: 15)))
    }

    @Test func distributionBinsCoverEveryValue() throws {
        let recipe = InsightRecipe(shape: .distribution, primaryMetricID: "volume", bucket: .daily)
        let values = (1...30).map { (offset: $0, value: Double($0 % 10) * 5 + 40) }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume", aggregation: .mean)],
            observations: ["volume": observations(values.map { ($0.offset, $0.value) })],
            now: now, calendar: calendar
        )
        let bins = try #require(result.histogram)
        #expect(bins.reduce(0) { $0 + $1.count } == 30)
    }

    @Test func constantDistributionReturnsASummaryWithoutFakeBins() throws {
        let recipe = InsightRecipe(shape: .distribution, primaryMetricID: "measurement", bucket: .daily)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("measurement", aggregation: .mean)],
            observations: ["measurement": observations((1...15).map { ($0, 42.0) })],
            now: now, calendar: calendar
        )
        #expect(result.histogram == nil)
        #expect(result.warnings.contains(.constantDistribution(value: 42)))
        let summary = try #require(result.distributionSummary)
        #expect(summary.count == 15)
        #expect(summary.minimum == 42)
        #expect(summary.q1 == 42)
        #expect(summary.median == 42)
        #expect(summary.q3 == 42)
        #expect(summary.maximum == 42)
    }

    // MARK: - Normalization, provenance, coverage

    @Test func baselineIndexAnchorsTo100() throws {
        var recipe = InsightRecipe(shape: .trend, primaryMetricID: "volume", bucket: .daily)
        recipe.normalization = .baselineIndex
        // The baseline is the WINDOW's first fifth by calendar — the series
        // must span the window, and early values anchor 100.
        let points = (0...83).map { (offset: 83 - $0, value: $0 < 20 ? 50.0 : 75.0) }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume", aggregation: .mean)],
            observations: ["volume": observations(points.map { ($0.0, $0.1) })],
            now: now, calendar: calendar
        )
        let series = try #require(result.series.first)
        #expect(abs((series.points.first?.value ?? 0) - 100) < 1e-9)
        #expect(abs((series.points.last?.value ?? 0) - 150) < 1e-9)
    }

    /// A range too short for an early-window anchor still renders ONE chart:
    /// every series falls back together to its whole-range average.
    @Test func shortRangesFallBackToMeanIndexing() throws {
        var recipe = InsightRecipe(shape: .trend, primaryMetricID: "volume", bucket: .daily)
        recipe.normalization = .baselineIndex
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume", aggregation: .mean)],
            observations: ["volume": observations([(3, 10), (2, 12), (1, 14)])],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains(.meanIndexedBaseline))
        #expect(!result.warnings.contains(.insufficientBaseline))
        let values = try #require(result.series.first).points.map(\.value)
        #expect(abs(values.reduce(0, +) / Double(values.count) - 100) < 1e-9)
    }

    @Test func baselineIndexRefusesSinglePoints() {
        var recipe = InsightRecipe(shape: .trend, primaryMetricID: "volume", bucket: .daily)
        recipe.normalization = .baselineIndex
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume", aggregation: .mean)],
            observations: ["volume": observations([(1, 14)])],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains(.insufficientBaseline))
    }

    /// A daily tally trained ~2×/week zero-fills into a rest-day-dominated
    /// grid; both anchors (early window AND whole-range mean) are mostly
    /// zeros, so a normal training day would index at 2,000%. Refuse with
    /// the named warning and return the series raw, in native units.
    @Test func zeroDominatedDailyTallyRefusesIndexing() throws {
        var recipe = InsightRecipe(shape: .trend, primaryMetricID: "volume", range: .twelveWeeks, bucket: .daily)
        recipe.normalization = .baselineIndex
        let trainingDays = stride(from: 2, through: 80, by: 7).map { ($0, 2_000.0) }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": observations(trainingDays)],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains(.zeroDominatedIndexAnchor))
        #expect(!result.warnings.contains(.meanIndexedBaseline))
        let values = try #require(result.series.first).points.map(\.value)
        #expect(values.max() == 2_000)
    }

    /// The same training regrouped by week has no empty buckets — indexing
    /// succeeds (mean-anchored: twelve weekly buckets are too few for an
    /// early-fifth baseline), which is why the warning points users at Week.
    @Test func weeklyGroupingIndexesWhatDailyRefused() throws {
        var recipe = InsightRecipe(shape: .trend, primaryMetricID: "volume", range: .twelveWeeks, bucket: .weekly)
        recipe.normalization = .baselineIndex
        let sessions = (0..<12).flatMap { week in [(week * 7 + 1, 1_000.0), (week * 7 + 4, 1_200.0)] }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume")],
            observations: ["volume": observations(sessions)],
            now: now, calendar: calendar
        )
        #expect(!result.warnings.contains(.zeroDominatedIndexAnchor))
        #expect(result.warnings.contains(.meanIndexedBaseline))
        let values = try #require(result.series.first).points.map(\.value)
        #expect(abs(values.reduce(0, +) / Double(values.count) - 100) < 1e-9)
    }

    @Test func provenanceRollsUpToMixed() {
        let mixed = InsightQueryEngine.rollupProvenance([.measured, .imported])
        #expect(mixed == .mixed)
        #expect(InsightQueryEngine.rollupProvenance([.estimated, .estimated]) == .estimated)
    }

    @Test func sparseMeasurementCoverageWarns() {
        let recipe = InsightRecipe(shape: .trend, primaryMetricID: "volume", range: .twelveWeeks, bucket: .daily)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("volume", aggregation: .mean)],
            observations: ["volume": observations([(3, 10), (2, 12)])],
            now: now, calendar: calendar
        )
        #expect(result.warnings.contains { if case .sparseCoverage = $0 { return true } else { return false } })
    }

    /// Weekly analyses use four complete weeks for a 4W range. Expected and
    /// populated coverage derive from those same anchors and never exceed
    /// 100%, even though the rolling 28-day interval touches edge weeks.
    @Test func weeklyCoverageNeverExceedsOneHundredPercent() {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "measurement",
            range: .fourWeeks, bucket: .weekly
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("measurement", aggregation: .mean)],
            observations: ["measurement": observations((0..<28).map { ($0, Double($0 + 1)) })],
            now: now, calendar: calendar, dataStart: day(40)
        )
        #expect(result.coverage.populatedBuckets <= result.coverage.expectedBuckets)
        #expect(result.coverage.fraction <= 1)
        #expect(result.coverage.expectedBuckets == 4)
        #expect(result.coverage.populatedBuckets == 4)
    }

    @Test func weeklyMeasurementCoverageRetainsRecordedDayDenominator() {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "sleep",
            range: .fourWeeks, bucket: .weekly
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric(
                "sleep", aggregation: .mean,
                buckets: [.daily], zeroFill: .never
            )],
            observations: ["sleep": observations([3, 10, 17, 24].map { ($0, 7.5) })],
            now: now,
            calendar: calendar,
            dataStart: day(40)
        )

        #expect(result.coverage.expectedBuckets == 4)
        #expect(result.coverage.populatedBuckets == 4)
        #expect(result.coverage.expectedSourceBuckets == 28)
        #expect(result.coverage.populatedSourceBuckets == 4)
        #expect(result.coverage.fraction < 0.15)
        #expect(result.warnings.contains { warning in
            if case .sparseCoverage = warning { return true }
            return false
        })
    }

    @Test func weeklyDailyTallyDoesNotMasqueradeAsSensorRecordingCoverage() {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "sessions",
            range: .fourWeeks, bucket: .weekly
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric(
                "sessions", buckets: [.daily], zeroFill: .zeroWhenAbsent
            )],
            observations: ["sessions": observations([3, 10, 17, 24].map { ($0, 1) })],
            now: now,
            calendar: calendar,
            dataStart: day(40)
        )

        #expect(result.coverage.expectedSourceBuckets == nil)
        #expect(result.coverage.populatedSourceBuckets == nil)
        #expect(result.coverage.fraction == 1)
        #expect(!result.warnings.contains { warning in
            if case .sparseCoverage = warning { return true }
            return false
        })
    }

    /// A tally's empty bucket is a true zero, not a gap: the series grid-
    /// completes across the window (no line bridging empty months at the
    /// last seen value), coverage still counts only real observations, and
    /// the gaps warning stays quiet — zeros are exact.
    @Test func tallyTrendsZeroFillEmptyBuckets() throws {
        let recipe = InsightRecipe(shape: .trend, primaryMetricID: "sessions", range: .fourWeeks, bucket: .daily)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("sessions")],
            observations: ["sessions": observations([(10, 2), (3, 1)])],
            now: now, calendar: calendar
        )
        let series = try #require(result.series.first)
        #expect(series.points.count == result.coverage.expectedBuckets)
        #expect(series.points.map(\.value).reduce(0, +) == 3)
        #expect(series.points.last?.value == 0)
        #expect(result.coverage.populatedBuckets == 2)
        #expect(!result.warnings.contains { if case .sparseCoverage = $0 { return true } else { return false } })
    }

    /// Measurement metrics keep true gaps — an unmeasured day has no value,
    /// and relationships never see fabricated zero pairs.
    @Test func measurementTrendsKeepTrueGaps() {
        let recipe = InsightRecipe(shape: .trend, primaryMetricID: "hrv", range: .fourWeeks, bucket: .daily)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe, descriptors: [metric("hrv", aggregation: .mean)],
            observations: ["hrv": observations([(10, 55), (3, 62)])],
            now: now, calendar: calendar
        )
        #expect(result.series.first?.points.count == 2)
    }

    /// Dose relationships default to days where the training total and the
    /// measurement were both recorded. Missing sleep is never fabricated, and
    /// inactive training days do not flatten the fitted dose relationship.
    @Test func mixedRelationshipDefaultsToActiveTrainingDays() throws {
        var recipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "sessions",
            comparisonMetricIDs: ["sleep"], range: .fourWeeks, bucket: .daily
        )
        recipe.lag = InsightLag(unit: .days, count: 0)
        let sleepDays = (1...20).map { (offset: $0, value: 400.0 + Double($0)) }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("sessions"), metric("sleep", aggregation: .mean, role: .exposure)],
            observations: [
                "sessions": observations([(10, 2), (3, 1)]),
                "sleep": observations(sleepDays.map { ($0.0, $0.1) }),
            ],
            now: now, calendar: calendar
        )
        let relationship = try #require(result.relationship)
        #expect(relationship.pairs.count == 2)
        #expect(relationship.pairs.allSatisfy { $0.y > 0 })
        #expect(relationship.pairs.allSatisfy { $0.x >= 401 })
        #expect(result.warnings.contains(.insufficientPairs(found: 2, needed: 10)))
        #expect(!result.warnings.contains { if case .sparseCoverage = $0 { return true } else { return false } })
    }

    /// The visible override restores the all-measured-days question: a
    /// recorded sleep day with no session receives a structural training zero.
    @Test func mixedRelationshipCanIncludeInactiveTrainingDays() throws {
        var recipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "sessions",
            comparisonMetricIDs: ["sleep"], range: .fourWeeks, bucket: .daily,
            relationshipPopulation: .includeInactiveBuckets
        )
        recipe.lag = InsightLag(unit: .days, count: 0)
        let sleepDays = (1...20).map { (offset: $0, value: 400.0 + Double($0)) }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("sessions"), metric("sleep", aggregation: .mean, role: .exposure)],
            observations: [
                "sessions": observations([(10, 2), (3, 1)]),
                "sleep": observations(sleepDays.map { ($0.0, $0.1) }),
            ],
            now: now, calendar: calendar
        )
        let relationship = try #require(result.relationship)
        #expect(relationship.pairs.count == 20)
        #expect(relationship.pairs.filter { $0.y == 0 }.count == 18)
        #expect(relationship.pairs.allSatisfy { $0.x >= 401 })
        #expect(!result.warnings.contains { if case .sparseCoverage = $0 { return true } else { return false } })
    }

    /// When BOTH operands are exact event tallies, the meaningful daily
    /// comparison is their union: a day with A but no B is (A, 0), not a
    /// dropped pair. Intersecting only active-on-both days is selection bias.
    @Test func tallyRelationshipsCompleteTheUnionWithTrueZeros() throws {
        var recipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "outcome",
            comparisonMetricIDs: ["exposure"], range: .fourWeeks, bucket: .daily,
            relationshipPopulation: .includeInactiveBuckets
        )
        recipe.lag = InsightLag(unit: .days, count: 0)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [
                metric("outcome", role: .outcome, zeroFill: .zeroWhenAbsent),
                metric("exposure", role: .exposure, zeroFill: .zeroWhenAbsent),
            ],
            observations: [
                "outcome": observations([(3, 30), (1, 10)]),
                "exposure": observations([(3, 300), (2, 200)]),
            ],
            now: now, calendar: calendar
        )
        let pairs = try #require(result.relationship).pairs
        #expect(pairs.count == 3)
        #expect(pairs.map(\.x) == [300, 200, 0])
        #expect(pairs.map(\.y) == [30, 0, 10])
    }

    /// `sum` does not by itself authorize zero completion: an optional sensor
    /// sum remains missing when the device did not record it.
    @Test func optionalSumRelationshipDoesNotInventZeros() throws {
        var recipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "energy",
            comparisonMetricIDs: ["steps"], range: .fourWeeks, bucket: .daily,
            relationshipPopulation: .includeInactiveBuckets
        )
        recipe.lag = InsightLag(unit: .days, count: 0)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [
                metric("energy", aggregation: .sum, role: .outcome, zeroFill: .never),
                metric("steps", aggregation: .sum, role: .exposure, zeroFill: .zeroWhenAbsent),
            ],
            observations: [
                "energy": observations([(3, 500), (1, 300)]),
                "steps": observations([(3, 8_000), (2, 6_000)]),
            ],
            now: now, calendar: calendar
        )
        let pairs = try #require(result.relationship).pairs
        #expect(pairs.count == 2)
        #expect(pairs.map(\.x) == [8_000, 0])
        #expect(pairs.map(\.y) == [500, 300])
    }

    @Test func emptyKnownTallyRendersAsZeroInsteadOfMissing() throws {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "sessions",
            range: .fourWeeks, bucket: .daily
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("sessions", zeroFill: .zeroWhenAbsent)],
            observations: ["sessions": []],
            now: now,
            calendar: calendar,
            dataStart: day(40)
        )
        let points = try #require(result.series.first?.points)
        #expect(points.count == 28)
        #expect(points.allSatisfy { $0.value == 0 })
        #expect(!result.warnings.contains(.emptyResult))
    }

    @Test func weeklyAnalysesUseOnlyCompletedCalendarWeeks() throws {
        let recipe = InsightRecipe(
            shape: .trend, primaryMetricID: "volume",
            range: .fourWeeks, bucket: .weekly
        )
        let rows = (0..<35).map {
            InsightObservation(timestamp: day($0), value: 1, provenance: .measured)
        }
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("volume", zeroFill: .zeroWhenAbsent)],
            observations: ["volume": rows],
            now: now,
            calendar: calendar,
            dataStart: day(40)
        )
        let points = try #require(result.series.first?.points)
        #expect(points.count == 4)
        #expect(points.allSatisfy { $0.value == 7 })
        #expect(points.allSatisfy { $0.date < InsightQueryEngine.anchor(for: now, bucket: .weekly, calendar: calendar) })
    }

    @Test func weekdayTallyGroupsIncludeEligibleRestDays() throws {
        let monday = calendar.weekdaySymbols[1]
        let recipe = InsightRecipe(
            shape: .groupComparison,
            primaryMetricID: "volume",
            dimension: .weekday,
            range: .twelveWeeks,
            bucket: .daily
        )
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [metric("volume", zeroFill: .zeroWhenAbsent)],
            observations: [
                "volume": [InsightObservation(
                    timestamp: day(1), value: 700, provenance: .measured,
                    category: monday
                )],
            ],
            now: now,
            calendar: calendar,
            dataStart: day(83)
        )
        let groups = try #require(result.groups)
        #expect(groups.count == 7)
        #expect(groups.allSatisfy { $0.bucketCount >= 11 })
        #expect(groups.first { $0.category == monday }?.total == 700)
        #expect(groups.first { $0.category == monday }?.median == 0)
    }

    @Test func constantRelationshipRefusesUndefinedCorrelation() throws {
        var recipe = InsightRecipe(
            shape: .relationship, primaryMetricID: "outcome",
            comparisonMetricIDs: ["exposure"], range: .fourWeeks, bucket: .daily
        )
        recipe.lag = InsightLag(unit: .days, count: 0)
        let result = InsightQueryEngine.evaluate(
            recipe: recipe,
            descriptors: [
                metric("outcome", aggregation: .mean, role: .outcome),
                metric("exposure", aggregation: .mean, role: .exposure),
            ],
            observations: [
                "outcome": observations((1...12).map { ($0, Double($0)) }),
                "exposure": observations((1...12).map { ($0, 7.0) }),
            ],
            now: now, calendar: calendar
        )
        let relationship = try #require(result.relationship)
        #expect(relationship.pairs.count == 12)
        #expect(relationship.spearman == nil)
        #expect(relationship.interval == nil)
        #expect(relationship.trend == nil)
        #expect(relationship.sensitivitySpearman == nil)
        #expect(result.warnings.contains(.constantRelationship(metricID: "exposure")))
    }
}
