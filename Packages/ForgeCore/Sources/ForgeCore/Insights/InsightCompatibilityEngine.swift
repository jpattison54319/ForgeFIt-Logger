import Foundation

/// Pure recipe validation: given a recipe and the catalog's descriptors,
/// report every reason it can't run and the charts it may legitimately use.
/// The builder UI renders these as inline explanations and disabled options —
/// the engine is the single authority on what's statistically defensible, so
/// no view ever re-derives (or forgets) a rule.
public enum InsightCompatibilityEngine {

    /// A population choice is meaningful only for calendar-bucket
    /// relationships containing a total whose absence is a factual zero.
    /// Recorded measurements never gain a zero option from this API.
    public static func allowedRelationshipPopulations(
        for recipe: InsightRecipe,
        descriptors descriptorList: [InsightMetricDescriptor]
    ) -> [InsightRelationshipPopulation] {
        guard recipe.shape == .relationship,
              recipe.bucket != .session,
              recipe.operands.count == 2 else { return [] }
        let byID = Dictionary(
            descriptorList.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let metrics = recipe.operands.compactMap { byID[$0.metricID] }
        guard metrics.count == 2,
              metrics.contains(where: { $0.zeroFillPolicy == .zeroWhenAbsent }) else {
            return []
        }
        return [.activeBucketsOnly, .includeInactiveBuckets]
    }

    /// `automatic` deliberately favors dose quality over calendar density:
    /// when zero-capable training totals are involved, fit only buckets where
    /// both operands were recorded. The visible override can opt back into
    /// structural zeros. Relationships without that choice also use their
    /// recorded intersection.
    public static func resolvedRelationshipPopulation(
        for recipe: InsightRecipe,
        descriptors: [InsightMetricDescriptor]
    ) -> InsightRelationshipPopulation {
        let allowed = allowedRelationshipPopulations(for: recipe, descriptors: descriptors)
        guard !allowed.isEmpty else { return .activeBucketsOnly }
        return allowed.contains(recipe.relationshipPopulation)
            ? recipe.relationshipPopulation
            : .activeBucketsOnly
    }

    public static func validate(
        _ recipe: InsightRecipe,
        descriptors descriptorList: [InsightMetricDescriptor]
    ) -> InsightValidation {
        var issues: [InsightValidationIssue] = []
        let byID = Dictionary(descriptorList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Unknown metrics end validation early: every other rule needs
        // descriptors, and the card-level "metric no longer available"
        // warning is built from exactly these issues.
        let resolved = recipe.allMetricIDs.map { (id: $0, descriptor: byID[$0]) }
        let unknown = resolved.filter { $0.descriptor == nil }
        guard unknown.isEmpty else {
            return InsightValidation(
                issues: unknown.map { .unknownMetric(id: $0.id) },
                allowedCharts: []
            )
        }
        let metrics = resolved.compactMap(\.descriptor)
        guard let primary = metrics.first else {
            return InsightValidation(issues: [.metricCountInvalid(expected: "at least one metric")], allowedCharts: [])
        }

        issues += metricCountIssues(recipe)
        let usableLegacyExerciseFilter = hasUsableLegacyExerciseFilter(recipe, metrics: metrics)
        // Filters are a version-1 storage artifact, not a current canvas
        // feature. Only its one historically supported meaning remains
        // executable: one valid exercise UUID when at least one operand can
        // genuinely use exercise scope. Every other hidden filter must be
        // repaired in the visible per-operand scope UI before evaluation.
        if !recipe.filters.isEmpty, !usableLegacyExerciseFilter {
            issues += InsightDimension.allCases.compactMap { dimension in
                recipe.filters.contains(where: { $0.dimension == dimension })
                    ? .invalidFilter(dimension: dimension)
                    : nil
            }
        }

        // Two identical operands (same metric AND same scope) say nothing —
        // scoped twins (bench vs squat e1RM) are exactly the point and pass.
        let duplicateKeys = Dictionary(grouping: recipe.operandKeys, by: { $0 })
            .filter { $1.count > 1 }.keys.sorted()
        issues += duplicateKeys.map { .duplicateMetric(id: $0) }

        for (index, metric) in metrics.enumerated() {
            let operand = recipe.operands.indices.contains(index) ? recipe.operands[index] : nil
            if !metric.supportedShapes.contains(recipe.shape) {
                issues.append(.shapeUnsupported(metricID: metric.id))
            }
            if !supports(metric, bucket: recipe.bucket) {
                issues.append(.bucketUnsupported(metricID: metric.id, bucket: recipe.bucket))
            }
            if let dimension = recipe.dimension, !metric.supportedDimensions.contains(dimension) {
                issues.append(.dimensionUnsupported(metricID: metric.id, dimension: dimension))
            }
            // Per-operand scope satisfies the requirement. A single valid
            // version-1 exercise filter remains a read-only fallback only for
            // metrics that require exercise scope.
            if let requiredScope = metric.requiredScope,
               operand?.hasScope(requiredScope) != true,
               !(requiredScope == .exercise && usableLegacyExerciseFilter) {
                issues.append(.missingRequiredScope(metricID: metric.id, scope: requiredScope))
            }
            if recipe.normalization == .baselineIndex && !metric.valueKind.supportsBaselineIndex {
                issues.append(.normalizationUnsupported(metricID: metric.id))
            }
            if let operand {
                let scopeCount = [operand.exerciseID != nil, operand.modality != nil, operand.routineID != nil]
                    .count(where: { $0 })
                if scopeCount > 1 {
                    issues.append(.multipleScopes(metricID: metric.id))
                }
                if operand.exerciseID != nil, !metric.supportedScopes.contains(.exercise) {
                    issues.append(.scopeUnsupported(metricID: metric.id, scope: .exercise))
                }
                if operand.modality != nil, !metric.supportedScopes.contains(.modality) {
                    issues.append(.scopeUnsupported(metricID: metric.id, scope: .modality))
                }
                if operand.routineID != nil, !metric.supportedScopes.contains(.routine) {
                    issues.append(.scopeUnsupported(metricID: metric.id, scope: .routine))
                }
                if let dimension = recipe.dimension,
                   (dimension == .exercise && operand.exerciseID != nil
                    || dimension == .modality && operand.modality != nil
                    || dimension == .routine && operand.routineID != nil) {
                    issues.append(.scopeDimensionConflict(metricID: metric.id, dimension: dimension))
                }
            }
        }

        if recipe.shape != .groupComparison, let dimension = recipe.dimension {
            issues.append(.dimensionUnsupportedForShape(dimension: dimension))
        }
        if recipe.shape == .groupComparison && recipe.dimension == nil {
            issues.append(.metricCountInvalid(expected: "a grouping dimension"))
        }
        if recipe.shape == .groupComparison,
           recipe.dimension == .checkinTag,
           recipe.bucket != .daily,
           !issues.contains(.bucketUnsupported(metricID: primary.id, bucket: recipe.bucket)) {
            // The check-in adapter owns a complete DAILY eligible-day grid.
            // Treating those rows as sessions invents zero-valued workouts;
            // summing tags into weeks confounds output with tag frequency.
            issues.append(.bucketUnsupported(metricID: primary.id, bucket: recipe.bucket))
        }
        if recipe.normalization == .baselineIndex && recipe.shape != .trend {
            issues.append(.normalizationUnsupported(metricID: primary.id))
        }
        issues += lagIssues(recipe, metrics: metrics)

        if recipe.range == .allHistory && metrics.contains(where: \.requiresHealth) {
            issues.append(.rangeUnsupported(reason: "Health-backed metrics support up to one year"))
        }
        if recipe.shape == .periodComparison, recipe.range == .allHistory {
            issues.append(.rangeUnsupported(reason: "Period comparisons need a fixed current window"))
        }
        if let reason = infeasibleSampleReason(recipe) {
            issues.append(.rangeUnsupported(reason: reason))
        }

        let allowed = issues.isEmpty ? allowedCharts(recipe, metrics: metrics) : []
        if let chart = recipe.chart, issues.isEmpty, !allowed.contains(chart) {
            issues.append(.chartIncompatible(chart: chart))
        }
        return InsightValidation(issues: issues, allowedCharts: issues.isEmpty ? allowed : [])
    }

    // MARK: - Rules

    private static func metricCountIssues(_ recipe: InsightRecipe) -> [InsightValidationIssue] {
        let total = recipe.allMetricIDs.count
        switch recipe.shape {
        case .relationship where total != 2:
            return [.metricCountInvalid(expected: "exactly two metrics")]
        case .trend where total > 4:
            return [.metricCountInvalid(expected: "at most four metrics")]
        case .groupComparison where total != 1,
             .distribution where total != 1:
            return [.metricCountInvalid(expected: "exactly one metric")]
        case .periodComparison where total > 4:
            return [.metricCountInvalid(expected: "at most four metrics")]
        default:
            return []
        }
    }

    /// A metric fits a bucket natively, or by rolling finer native data up
    /// (sessions collapse into days, days into weeks). Never the reverse —
    /// weekly data can't be invented into days.
    static func supports(_ metric: InsightMetricDescriptor, bucket: InsightBucket) -> Bool {
        if metric.nativeBuckets.contains(bucket) { return true }
        switch bucket {
        case .weekly:
            return metric.nativeBuckets.contains(.daily) || metric.nativeBuckets.contains(.session)
        case .daily:
            return metric.nativeBuckets.contains(.session)
        case .session:
            return false
        }
    }

    /// Buckets that can be selected without constructing an invalid recipe.
    /// Views consume this projection instead of offering every enum case and
    /// explaining the failure afterward.
    public static func allowedBuckets(
        for recipe: InsightRecipe,
        descriptors descriptorList: [InsightMetricDescriptor]
    ) -> [InsightBucket] {
        let byID = Dictionary(descriptorList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metrics = recipe.allMetricIDs.compactMap { byID[$0] }
        guard !metrics.isEmpty, metrics.count == recipe.allMetricIDs.count else { return [] }
        return InsightBucket.allCases.filter { bucket in
            guard metrics.allSatisfy({ supports($0, bucket: bucket) }),
                  !(recipe.shape == .groupComparison && recipe.dimension == .checkinTag && bucket != .daily) else {
                return false
            }
            var candidate = recipe
            candidate.bucket = bucket
            if candidate.lag != nil {
                candidate.lag = InsightLag(unit: bucket == .weekly ? .weeks : .days, count: 0)
            }
            return infeasibleSampleReason(candidate) == nil
        }
    }

    /// Grouping dimensions supported by every selected metric. Empty for
    /// shapes that do not group.
    public static func allowedDimensions(
        for recipe: InsightRecipe,
        descriptors descriptorList: [InsightMetricDescriptor]
    ) -> [InsightDimension] {
        guard recipe.shape == .groupComparison else { return [] }
        let byID = Dictionary(descriptorList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metrics = recipe.allMetricIDs.compactMap { byID[$0] }
        guard !metrics.isEmpty, metrics.count == recipe.allMetricIDs.count else { return [] }
        return InsightDimension.allCases.filter { dimension in
            guard metrics.allSatisfy({ $0.supportedDimensions.contains(dimension) }) else {
                return false
            }
            guard let scope = operandScopeKind(for: dimension) else { return true }
            return !recipe.operands.contains { $0.hasScope(scope) }
        }
    }

    private static func operandScopeKind(for dimension: InsightDimension) -> InsightScopeKind? {
        switch dimension {
        case .exercise: .exercise
        case .modality: .modality
        case .routine: .routine
        case .muscle, .weekday, .source, .checkinTag: nil
        }
    }

    /// Ranges that can satisfy both the data-domain cap and the analysis's
    /// structural minimum before any user history is considered.
    public static func allowedRanges(
        for recipe: InsightRecipe,
        descriptors descriptorList: [InsightMetricDescriptor]
    ) -> [InsightRange] {
        let byID = Dictionary(descriptorList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metrics = recipe.allMetricIDs.compactMap { byID[$0] }
        guard !metrics.isEmpty, metrics.count == recipe.allMetricIDs.count else { return [] }
        return InsightRange.allCases.filter { range in
            if range == .allHistory,
               (recipe.shape == .periodComparison || metrics.contains(where: \.requiresHealth)) {
                return false
            }
            var candidate = recipe
            candidate.range = range
            return infeasibleSampleReason(candidate) == nil
        }
    }

    public static func allowedLags(
        for recipe: InsightRecipe,
        descriptors descriptorList: [InsightMetricDescriptor]
    ) -> [InsightLag] {
        guard recipe.shape == .relationship else { return [] }
        let byID = Dictionary(descriptorList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metrics = recipe.allMetricIDs.compactMap { byID[$0] }
        guard metrics.count == 2, metrics.count == recipe.allMetricIDs.count else { return [] }
        let unit: InsightLag.Unit = recipe.bucket == .weekly ? .weeks : .days
        let counts: ClosedRange<Int> = recipe.bucket == .session
            ? 0...0
            : (unit == .weeks ? InsightLag.weekWhitelist : InsightLag.dayWhitelist)
        return counts.compactMap { count in
            var candidate = recipe
            let lag = InsightLag(unit: unit, count: count)
            candidate.lag = lag
            return lagIssues(candidate, metrics: metrics).isEmpty
                && infeasibleSampleReason(candidate) == nil
                ? lag
                : nil
        }
    }

    private static func hasUsableLegacyExerciseFilter(
        _ recipe: InsightRecipe,
        metrics: [InsightMetricDescriptor]
    ) -> Bool {
        guard recipe.filters.count == 1,
              let filter = recipe.filters.first,
              filter.dimension == .exercise,
              filter.values.count == 1,
              UUID(uuidString: filter.values[0]) != nil else {
            return false
        }
        return metrics.contains { $0.supportedScopes.contains(.exercise) }
    }

    private static func lagIssues(
        _ recipe: InsightRecipe,
        metrics: [InsightMetricDescriptor]
    ) -> [InsightValidationIssue] {
        guard let lag = recipe.lag else { return [] }
        guard recipe.shape == .relationship else { return [.lagUnsupportedForShape] }
        var issues: [InsightValidationIssue] = []
        switch lag.unit {
        case .days:
            if !InsightLag.dayWhitelist.contains(lag.count) { issues.append(.lagOutsideWhitelist) }
            if recipe.bucket == .weekly { issues.append(.lagOutsideWhitelist) }
        case .weeks:
            if !InsightLag.weekWhitelist.contains(lag.count) { issues.append(.lagOutsideWhitelist) }
            if recipe.bucket != .weekly { issues.append(.lagOutsideWhitelist) }
        }
        if recipe.bucket == .session, lag.count > 0 {
            // Session pairing is by workout occurrence. A calendar lag would
            // require another workout at an invented matching clock time.
            issues.append(.lagOutsideWhitelist)
        }
        // Direction convention: "Compare with" is the exposure that precedes
        // the "Show me" outcome. A positive lag with the roles backwards
        // (yesterday's workout vs tonight's earlier sleep) is nonsense the
        // builder must refuse, not chart.
        if lag.count > 0, metrics.count == 2 {
            let outcome = metrics[0]
            let exposure = metrics[1]
            let exposureOK = exposure.timingRole == .exposure || exposure.timingRole == .either
            let outcomeOK = outcome.timingRole == .outcome || outcome.timingRole == .either
            if !(exposureOK && outcomeOK) {
                issues.append(.lagDirectionInvalid)
            }
        }
        return issues
    }

    /// Reject questions whose selected calendar grid cannot possibly reach
    /// the method's minimum, even with perfectly complete data.
    private static func infeasibleSampleReason(_ recipe: InsightRecipe) -> String? {
        guard let days = recipe.range.days, recipe.bucket != .session else { return nil }
        let buckets: Int
        switch recipe.bucket {
        case .daily:
            buckets = days
        case .weekly:
            // Weekly analyses admit completed calendar weeks only; the
            // current partial week and a partial data-start week are excluded.
            buckets = days / 7
        case .session:
            return nil
        }
        let lag = recipe.lag?.count ?? 0
        let maximumPairs = max(0, buckets - lag)
        if recipe.shape == .relationship,
           maximumPairs < InsightQueryEngine.exploratoryPairMinimum {
            return "This range and grouping can produce at most \(maximumPairs) matched buckets; relationships need \(InsightQueryEngine.exploratoryPairMinimum)"
        }
        if recipe.shape == .distribution,
           buckets < InsightQueryEngine.distributionMinimum {
            return "This range and grouping can produce at most \(buckets) values; distributions need \(InsightQueryEngine.distributionMinimum)"
        }
        if recipe.shape == .groupComparison,
           recipe.dimension == .weekday {
            let occurrencesPerWeekday = Int(ceil(Double(days) / 7.0))
            if occurrencesPerWeekday < InsightQueryEngine.groupMinimumBuckets {
                return "This range can contain at most \(occurrencesPerWeekday) values per weekday; groups need \(InsightQueryEngine.groupMinimumBuckets)"
            }
        }
        return nil
    }

    /// Charts a valid recipe may use, recommended first. The UI offers these
    /// and nothing else — no dual axes, no donuts over non-exclusive parts,
    /// no shared axes across unlike units.
    static func allowedCharts(
        _ recipe: InsightRecipe,
        metrics: [InsightMetricDescriptor]
    ) -> [InsightChartKind] {
        switch recipe.shape {
        case .trend:
            if recipe.normalization == .baselineIndex {
                return [.baselineIndexLines]
            }
            if metrics.count == 1 {
                return metrics[0].zeroFillPolicy == .zeroWhenAbsent
                    ? [.barTrend, .lineTrend]
                    : [.lineTrend, .barTrend]
            }
            // One shared chart whenever the axes can honestly merge; synced
            // small multiples only for unit mixes that can't.
            let families = Set(metrics.map(\.valueKind.axisFamily))
            return families.count == 1
                ? [.sharedUnitOverlay, .smallMultiples]
                : [.smallMultiples]
        case .relationship:
            return [.scatterWithTrend]
        case .groupComparison:
            var charts: [InsightChartKind] = [.groupedBars, .boxSummary]
            if let metric = metrics.first, donutEligible(metric, dimension: recipe.dimension) {
                charts.append(.donutShare)
            }
            return charts
        case .periodComparison:
            // Paired bars put every metric on ONE y axis — only offer them
            // when the units can honestly share it. Cards carry any mix.
            return Set(metrics.map(\.valueKind.axisFamily)).count == 1
                ? [.periodComparisonCards, .groupedBars]
                : [.periodComparisonCards]
        case .distribution:
            return [.histogram, .boxSummary]
        }
    }

    /// Donut only for mutually exclusive parts of a meaningful whole: summed
    /// quantity metrics split by a partitioning dimension. Averages and
    /// point-in-time values have no "whole" to share.
    private static func donutEligible(
        _ metric: InsightMetricDescriptor,
        dimension: InsightDimension?
    ) -> Bool {
        guard metric.aggregation == .sum,
              let dimension,
              metric.exclusiveGroupingDimensions.contains(dimension) else { return false }
        switch metric.valueKind {
        case .count, .sessions, .trainingDays, .reps, .durationSeconds, .massKilograms, .distanceMeters,
             .energyKilocalories, .steps, .elevationMeters:
            return true
        case .pace, .speed, .heartRateBPM, .heartRateVariabilityMS,
             .percentage, .power, .cadence, .score, .breathsPerMinute,
             .massPerMinute, .bodyweightMultiple, .rpe, .rir, .readinessScore:
            return false
        }
    }
}
