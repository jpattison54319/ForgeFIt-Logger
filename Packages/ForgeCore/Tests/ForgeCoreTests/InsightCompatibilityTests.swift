import Foundation
@testable import ForgeCore
import Testing

struct InsightCompatibilityTests {

    // MARK: - Fixtures

    private func metric(
        _ id: String,
        kind: InsightValueKind = .massKilograms,
        role: InsightTimingRole = .either,
        buckets: Set<InsightBucket> = [.session, .daily],
        aggregation: InsightAggregation = .sum,
        shapes: Set<InsightShape> = Set(InsightShape.allCases),
        dimensions: Set<InsightDimension> = Set(InsightDimension.allCases),
        health: Bool = false,
        exerciseScope: Bool = false,
        requiredScope: InsightScopeKind? = nil,
        scopes: Set<InsightScopeKind> = [.exercise, .modality, .routine],
        zeroFill: InsightZeroFillPolicy? = nil,
        exclusiveDimensions: Set<InsightDimension> = [.weekday, .source, .routine]
    ) -> InsightMetricDescriptor {
        InsightMetricDescriptor(
            id: id, title: id, category: "test", valueKind: kind, timingRole: role,
            nativeBuckets: buckets, aggregation: aggregation, supportedShapes: shapes,
            supportedDimensions: dimensions, requiresHealth: health,
            requiresExerciseScope: exerciseScope, requiredScope: requiredScope,
            supportedScopes: scopes,
            zeroFillPolicy: zeroFill,
            exclusiveGroupingDimensions: exclusiveDimensions
        )
    }

    private var volume: InsightMetricDescriptor { metric("volume", role: .outcome) }
    private var sleep: InsightMetricDescriptor {
        metric("sleep", kind: .durationSeconds, role: .exposure, buckets: [.daily], aggregation: .sum, health: true)
    }

    private func recipe(
        shape: InsightShape,
        primary: String = "volume",
        comparisons: [String] = [],
        dimension: InsightDimension? = nil,
        filters: [InsightFilter] = [],
        range: InsightRange = .twelveWeeks,
        bucket: InsightBucket = .daily,
        lag: InsightLag? = nil,
        normalization: InsightNormalization = .none,
        chart: InsightChartKind? = nil
    ) -> InsightRecipe {
        InsightRecipe(
            shape: shape, primaryMetricID: primary, comparisonMetricIDs: comparisons,
            dimension: dimension, filters: filters, range: range, bucket: bucket,
            lag: lag, normalization: normalization, chart: chart
        )
    }

    /// A scope kind the metric doesn't support is rejected, not silently
    /// no-opped — "Pace · Bench Press" must be unbuildable and unsaveable.
    @Test func unsupportedOperandScopeIsRejected() {
        var pace = metric("pace", kind: .pace, aggregation: .distanceWeightedMean)
        pace.supportedScopes = [.modality, .routine]
        var recipe = recipe(shape: .trend, primary: "pace")
        recipe.operands[0].exerciseID = UUID()
        let validation = InsightCompatibilityEngine.validate(recipe, descriptors: [pace])
        #expect(validation.issues.contains(.scopeUnsupported(metricID: "pace", scope: .exercise)))

        recipe.operands[0].exerciseID = nil
        recipe.operands[0].modality = "run"
        let scoped = InsightCompatibilityEngine.validate(recipe, descriptors: [pace])
        #expect(!scoped.issues.contains { if case .scopeUnsupported = $0 { return true } else { return false } })
    }

    // MARK: - Structure rules

    @Test func unknownMetricReportsAndBlocksCharts() {
        let result = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, primary: "vanished"), descriptors: [volume]
        )
        #expect(result.issues == [.unknownMetric(id: "vanished")])
        #expect(result.allowedCharts.isEmpty)
    }

    @Test func relationshipDemandsExactlyTwoMetrics() {
        let one = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship), descriptors: [volume]
        )
        #expect(one.issues.contains(.metricCountInvalid(expected: "exactly two metrics")))

        let two = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship, comparisons: ["sleep"], lag: InsightLag(unit: .days, count: 1)),
            descriptors: [volume, sleep]
        )
        #expect(two.isValid)
        #expect(two.allowedCharts == [.scatterWithTrend])
    }

    @Test func groupComparisonRequiresADimension() {
        let missing = InsightCompatibilityEngine.validate(
            recipe(shape: .groupComparison), descriptors: [volume]
        )
        #expect(missing.issues.contains(.metricCountInvalid(expected: "a grouping dimension")))

        let grouped = InsightCompatibilityEngine.validate(
            recipe(shape: .groupComparison, dimension: .checkinTag), descriptors: [volume]
        )
        #expect(grouped.isValid)
    }

    @Test func operandScopeIsMutuallyExclusive() {
        let exerciseID = UUID()
        let routineID = UUID()
        let ambiguous = InsightRecipe(
            shape: .trend,
            operands: [
                InsightOperand(
                    metricID: "volume",
                    exerciseID: exerciseID,
                    modality: "run",
                    routineID: routineID
                ),
            ],
            bucket: .daily
        )
        let validation = InsightCompatibilityEngine.validate(ambiguous, descriptors: [volume])
        #expect(validation.issues.contains(.multipleScopes(metricID: "volume")))
        #expect(validation.allowedCharts.isEmpty)
    }

    @Test func groupingByAnOperandScopeIsCircular() {
        let scoped = InsightRecipe(
            shape: .groupComparison,
            operands: [InsightOperand(metricID: "volume", modality: "run")],
            dimension: .modality,
            bucket: .daily
        )
        let validation = InsightCompatibilityEngine.validate(scoped, descriptors: [volume])
        #expect(validation.issues.contains(.scopeDimensionConflict(metricID: "volume", dimension: .modality)))
        #expect(!InsightCompatibilityEngine.allowedDimensions(
            for: scoped, descriptors: [volume]
        ).contains(.modality))
        #expect(InsightCompatibilityEngine.allowedDimensions(
            for: scoped, descriptors: [volume]
        ).contains(.weekday))
    }

    // MARK: - Buckets

    @Test func finerNativeDataRollsUpNeverDown() {
        let sessionNative = metric("sessions", buckets: [.session])
        let dailyNative = metric("hrv", kind: .heartRateVariabilityMS, buckets: [.daily])

        #expect(InsightCompatibilityEngine.supports(sessionNative, bucket: .weekly))
        #expect(InsightCompatibilityEngine.supports(sessionNative, bucket: .daily))
        #expect(InsightCompatibilityEngine.supports(dailyNative, bucket: .weekly))
        #expect(!InsightCompatibilityEngine.supports(dailyNative, bucket: .session))
    }

    // MARK: - Lag rules

    @Test func lagOnlyBelongsToRelationships() {
        let result = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, lag: InsightLag(unit: .days, count: 1)),
            descriptors: [volume]
        )
        #expect(result.issues.contains(.lagUnsupportedForShape))
    }

    @Test func lagWhitelistsAreEnforced() {
        let tooLong = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship, comparisons: ["sleep"], lag: InsightLag(unit: .days, count: 9)),
            descriptors: [volume, sleep]
        )
        #expect(tooLong.issues.contains(.lagOutsideWhitelist))

        let weeklyLagDailyBucket = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship, comparisons: ["sleep"], bucket: .daily, lag: InsightLag(unit: .weeks, count: 1)),
            descriptors: [volume, sleep]
        )
        #expect(weeklyLagDailyBucket.issues.contains(.lagOutsideWhitelist))
    }

    @Test func sessionRelationshipsOnlyAllowSameSessionTiming() {
        let sessionLag = InsightCompatibilityEngine.validate(
            recipe(
                shape: .relationship,
                comparisons: ["sleep"],
                bucket: .session,
                lag: InsightLag(unit: .days, count: 1)
            ),
            descriptors: [volume, metric("sleep", kind: .durationSeconds, role: .exposure)]
        )
        #expect(sessionLag.issues.contains(.lagOutsideWhitelist))

        let sameSession = InsightCompatibilityEngine.validate(
            recipe(
                shape: .relationship,
                comparisons: ["sleep"],
                bucket: .session,
                lag: InsightLag(unit: .days, count: 0)
            ),
            descriptors: [volume, metric("sleep", kind: .durationSeconds, role: .exposure)]
        )
        #expect(sameSession.isValid, "\(sameSession.issues)")
    }

    /// "Compare with" is the exposure that precedes the "Show me" outcome —
    /// the reverse pairing with a positive lag must refuse to validate.
    @Test func lagDirectionFollowsTimingRoles() {
        let backwards = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship, primary: "sleep", comparisons: ["volume"], lag: InsightLag(unit: .days, count: 1)),
            descriptors: [
                metric("sleep", kind: .durationSeconds, role: .exposure, buckets: [.daily], health: true),
                metric("volume", role: .outcome),
            ]
        )
        #expect(backwards.issues.contains(.lagDirectionInvalid))
    }

    // MARK: - Range, normalization, scope

    @Test func allHistoryRefusesHealthMetrics() {
        let result = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship, comparisons: ["sleep"], range: .allHistory, lag: InsightLag(unit: .days, count: 1)),
            descriptors: [volume, sleep]
        )
        #expect(result.issues.contains(.rangeUnsupported(reason: "Health-backed metrics support up to one year")))
    }

    @Test func baselineIndexRejectsNonRatioKindsAndNonTrends() {
        let pace = metric("pace", kind: .pace, aggregation: .distanceWeightedMean)
        let onPace = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, primary: "pace", normalization: .baselineIndex),
            descriptors: [pace]
        )
        #expect(onPace.issues.contains(.normalizationUnsupported(metricID: "pace")))

        let onRelationship = InsightCompatibilityEngine.validate(
            recipe(shape: .relationship, comparisons: ["sleep"], lag: InsightLag(unit: .days, count: 0), normalization: .baselineIndex),
            descriptors: [volume, sleep]
        )
        #expect(!onRelationship.isValid)
    }

    @Test func perExerciseMetricsNeedExactlyOneExercise() {
        let e1rm = metric("e1rm", aggregation: .bestSession, exerciseScope: true)
        let bare = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, primary: "e1rm"), descriptors: [e1rm]
        )
        #expect(bare.issues.contains(.missingRequiredScope(metricID: "e1rm", scope: .exercise)))

        let scoped = InsightCompatibilityEngine.validate(
            recipe(
                shape: .trend, primary: "e1rm",
                filters: [InsightFilter(dimension: .exercise, values: [UUID().uuidString])]
            ),
            descriptors: [e1rm]
        )
        #expect(scoped.isValid)
    }

    @Test func malformedLegacyExerciseScopeDoesNotSatisfyRequiredScope() {
        let e1rm = metric("e1rm", aggregation: .bestSession, exerciseScope: true)
        for values in [["not-a-uuid"], [], [UUID().uuidString, UUID().uuidString]] {
            let candidate = recipe(
                shape: .trend,
                primary: "e1rm",
                filters: [InsightFilter(dimension: .exercise, values: values)]
            )
            let validation = InsightCompatibilityEngine.validate(candidate, descriptors: [e1rm])
            #expect(validation.issues.contains(.invalidFilter(dimension: .exercise)))
            #expect(validation.issues.contains(.missingRequiredScope(metricID: "e1rm", scope: .exercise)))
            #expect(validation.allowedCharts.isEmpty)
        }
    }

    @Test func genericRequiredScopeRejectsUnscopedCardioMetrics() {
        let pace = metric(
            "pace",
            kind: .pace,
            aggregation: .distanceWeightedMean,
            requiredScope: .modality,
            scopes: [.modality, .routine]
        )
        let bare = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, primary: "pace"), descriptors: [pace]
        )
        #expect(bare.issues.contains(.missingRequiredScope(metricID: "pace", scope: .modality)))

        var scopedRecipe = recipe(shape: .trend, primary: "pace")
        scopedRecipe.operands[0].modality = "run"
        #expect(InsightCompatibilityEngine.validate(scopedRecipe, descriptors: [pace]).isValid)

        var wrongScope = recipe(shape: .trend, primary: "pace")
        wrongScope.operands[0].routineID = UUID()
        let wrong = InsightCompatibilityEngine.validate(wrongScope, descriptors: [pace])
        #expect(wrong.issues.contains(.missingRequiredScope(metricID: "pace", scope: .modality)))
    }

    @Test func legacyFiltersAllowOnlyOneApplicableExerciseScope() {
        let id = UUID().uuidString
        let exerciseCapable = metric("volume", scopes: [.exercise])
        let healthOnly = metric("sleep", scopes: [])

        let validLegacy = recipe(
            shape: .trend,
            filters: [InsightFilter(dimension: .exercise, values: [id])]
        )
        #expect(InsightCompatibilityEngine.validate(
            validLegacy, descriptors: [exerciseCapable]
        ).isValid)

        let noApplicableOperand = InsightCompatibilityEngine.validate(
            recipe(
                shape: .trend,
                primary: "sleep",
                filters: [InsightFilter(dimension: .exercise, values: [id])]
            ),
            descriptors: [healthOnly]
        )
        #expect(noApplicableOperand.issues.contains(.invalidFilter(dimension: .exercise)))

        for dimension in InsightDimension.allCases where dimension != .exercise {
            let filtered = InsightCompatibilityEngine.validate(
                recipe(
                    shape: .trend,
                    filters: [InsightFilter(dimension: dimension, values: ["value"])]
                ),
                descriptors: [exerciseCapable]
            )
            #expect(filtered.issues.contains(.invalidFilter(dimension: dimension)))
        }

        let exercisePlusHiddenFilter = InsightCompatibilityEngine.validate(
            recipe(
                shape: .trend,
                filters: [
                    InsightFilter(dimension: .exercise, values: [id]),
                    InsightFilter(dimension: .modality, values: ["run"]),
                ]
            ),
            descriptors: [exerciseCapable]
        )
        #expect(exercisePlusHiddenFilter.issues.contains(.invalidFilter(dimension: .exercise)))
        #expect(exercisePlusHiddenFilter.issues.contains(.invalidFilter(dimension: .modality)))
    }

    @Test func rangeAndBucketProjectionsExcludeStructurallyImpossibleSamples() {
        let daily = metric("daily", buckets: [.daily], aggregation: .mean)

        let weeklyRelationship = recipe(
            shape: .relationship,
            primary: "daily",
            comparisons: ["daily2"],
            range: .fourWeeks,
            bucket: .weekly,
            lag: InsightLag(unit: .weeks, count: 0)
        )
        let relationshipDescriptors = [daily, metric("daily2", buckets: [.daily], aggregation: .mean)]
        let relationshipValidation = InsightCompatibilityEngine.validate(
            weeklyRelationship,
            descriptors: relationshipDescriptors
        )
        #expect(relationshipValidation.issues.contains {
            if case .rangeUnsupported(let reason) = $0 {
                return reason.contains("at most 4 matched buckets")
            }
            return false
        })
        #expect(!InsightCompatibilityEngine.allowedRanges(
            for: weeklyRelationship,
            descriptors: relationshipDescriptors
        ).contains(.fourWeeks))

        let shortWeeklyDistribution = recipe(
            shape: .distribution,
            primary: "daily",
            range: .twelveWeeks,
            bucket: .weekly
        )
        let distributionValidation = InsightCompatibilityEngine.validate(
            shortWeeklyDistribution,
            descriptors: [daily]
        )
        #expect(distributionValidation.issues.contains {
            if case .rangeUnsupported(let reason) = $0 {
                return reason.contains("at most 12 values")
            }
            return false
        })

        var fourWeekDistribution = shortWeeklyDistribution
        fourWeekDistribution.range = .fourWeeks
        let buckets = InsightCompatibilityEngine.allowedBuckets(
            for: fourWeekDistribution,
            descriptors: [daily]
        )
        #expect(buckets == [.daily])

        let periodAllHistory = InsightCompatibilityEngine.validate(
            recipe(shape: .periodComparison, range: .allHistory),
            descriptors: [volume]
        )
        #expect(periodAllHistory.issues.contains(
            .rangeUnsupported(reason: "Period comparisons need a fixed current window")
        ))

        let weekdayGroups = recipe(
            shape: .groupComparison,
            dimension: .weekday,
            range: .fourWeeks,
            bucket: .daily
        )
        let weekdayValidation = InsightCompatibilityEngine.validate(
            weekdayGroups, descriptors: [volume]
        )
        #expect(weekdayValidation.issues.contains {
            if case .rangeUnsupported(let reason) = $0 {
                return reason.contains("at most 4 values per weekday")
            }
            return false
        })
        let weekdayRanges = InsightCompatibilityEngine.allowedRanges(
            for: weekdayGroups, descriptors: [volume]
        )
        #expect(!weekdayRanges.contains(.fourWeeks))
        #expect(weekdayRanges.contains(.twelveWeeks))
    }

    // MARK: - Chart allowlists

    @Test func trendChartsFollowUnitCompatibility() {
        let single = InsightCompatibilityEngine.validate(recipe(shape: .trend), descriptors: [volume])
        #expect(single.allowedCharts == [.barTrend, .lineTrend])

        let sameKind = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, comparisons: ["volume2"]),
            descriptors: [volume, metric("volume2")]
        )
        #expect(sameKind.allowedCharts == [.sharedUnitOverlay, .smallMultiples])

        let mixedKind = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, comparisons: ["sleep"]),
            descriptors: [volume, metric("sleep", kind: .durationSeconds, buckets: [.daily])]
        )
        #expect(mixedKind.allowedCharts == [.smallMultiples])
    }

    /// Raw tallies (sets, reps, steps) live in one axis family — a sets-vs-
    /// reps trend overlays on one chart instead of splitting into multiples.
    @Test func countLikeKindsShareOneAxisFamily() {
        let setsVsReps = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, primary: "sets", comparisons: ["reps"]),
            descriptors: [metric("sets", kind: .count), metric("reps", kind: .reps)]
        )
        #expect(setsVsReps.allowedCharts == [.sharedUnitOverlay, .smallMultiples])
    }

    /// Mixed-unit trends still get ONE chart when every series can be
    /// baseline-indexed — the builder flips normalization for exactly this.
    @Test func baselineIndexedMixedTrendRecommendsOneChart() {
        let indexed = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, comparisons: ["sleep"], normalization: .baselineIndex),
            descriptors: [volume, metric("sleep", kind: .durationSeconds, buckets: [.daily])]
        )
        #expect(indexed.allowedCharts == [.baselineIndexLines])
    }

    @Test func donutOnlyForSummedQuantities() {
        let summedDuration = InsightCompatibilityEngine.validate(
            recipe(shape: .groupComparison, primary: "duration", dimension: .modality),
            descriptors: [metric(
                "duration",
                kind: .durationSeconds,
                aggregation: .sum,
                exclusiveDimensions: [.modality]
            )]
        )
        #expect(summedDuration.allowedCharts.contains(.donutShare))

        let overlappingDuration = InsightCompatibilityEngine.validate(
            recipe(shape: .groupComparison, primary: "duration", dimension: .modality),
            descriptors: [metric(
                "duration",
                kind: .durationSeconds,
                aggregation: .sum,
                exclusiveDimensions: [.weekday]
            )]
        )
        #expect(!overlappingDuration.allowedCharts.contains(.donutShare))

        let averagedHR = InsightCompatibilityEngine.validate(
            recipe(shape: .groupComparison, primary: "avgHR", dimension: .modality),
            descriptors: [metric("avgHR", kind: .heartRateBPM, aggregation: .mean)]
        )
        #expect(!averagedHR.allowedCharts.contains(.donutShare))
    }

    @Test func explicitChartMustBeAllowed() {
        let result = InsightCompatibilityEngine.validate(
            recipe(shape: .trend, chart: .donutShare), descriptors: [volume]
        )
        #expect(result.issues.contains(.chartIncompatible(chart: .donutShare)))
    }

    // MARK: - Recipe codec

    @Test func recipeRoundTripsThroughJSON() throws {
        let original = recipe(
            shape: .relationship, comparisons: ["sleep"],
            filters: [InsightFilter(dimension: .modality, values: ["run"])],
            lag: InsightLag(unit: .days, count: 2), chart: .scatterWithTrend
        )
        let decoded = try #require(InsightRecipe.decode(from: original.encodedJSON()))
        #expect(decoded == original)
    }

    @Test func signatureIgnoresNameAndTimestamps() {
        var a = recipe(shape: .trend)
        var b = a
        #expect(a.analysisSignature.hasPrefix("m6;"))
        b.name = "Renamed"
        b.updatedAt = Date(timeIntervalSinceNow: 999)
        #expect(a.analysisSignature == b.analysisSignature)
        a.range = .fourWeeks
        #expect(a.analysisSignature != b.analysisSignature)
    }
}
