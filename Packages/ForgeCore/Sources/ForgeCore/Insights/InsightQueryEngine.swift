import Foundation

// MARK: - Results

public struct InsightSeriesPoint: Sendable, Equatable {
    public var date: Date
    public var value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct InsightSeries: Sendable, Equatable {
    public var metricID: String
    public var points: [InsightSeriesPoint]
    public var provenance: InsightProvenance

    public init(metricID: String, points: [InsightSeriesPoint], provenance: InsightProvenance) {
        self.metricID = metricID
        self.points = points
        self.provenance = provenance
    }
}

public struct InsightPair: Sendable, Equatable {
    public var date: Date
    public var x: Double
    public var y: Double
    public var isOutlierFlagged: Bool

    public init(date: Date, x: Double, y: Double, isOutlierFlagged: Bool = false) {
        self.date = date
        self.x = x
        self.y = y
        self.isOutlierFlagged = isOutlierFlagged
    }
}

public struct InsightRelationship: Sendable, Equatable {
    public var pairs: [InsightPair]
    public var spearman: Double?
    /// Deterministic 95% moving-block bootstrap interval; nil below the
    /// exploratory threshold or when resampling degenerates.
    public var interval: ClosedRange<Double>?
    public var trend: InsightStatistics.TrendLine?
    /// Spearman with flagged pairs excluded — shown as a sensitivity
    /// comparison, never as the headline number.
    public var sensitivitySpearman: Double?
}

public struct InsightGroup: Sendable, Equatable {
    public var category: String
    public var bucketCount: Int
    public var total: Double
    public var median: Double
    public var minimum: Double
    public var maximum: Double
    /// 25th/75th percentiles of the group's bucket values — the honest box
    /// for the range chart; min/max alone overstate spread.
    public var q1: Double = 0
    public var q3: Double = 0
}

public struct InsightPeriodDelta: Sendable, Equatable {
    public var metricID: String
    /// Missing measurements stay missing. Only metrics whose descriptor says
    /// an absent bucket is an exact zero may synthesize zero for an empty
    /// period.
    public var current: Double?
    public var previous: Double?
    public var change: Double?
    /// nil when either period is missing or the observed previous value is
    /// zero — a percent over a zero denominator is undefined.
    public var percentChange: Double?
    public var currentSamples: Int = 0
    public var previousSamples: Int = 0
}

public struct InsightHistogramBin: Sendable, Equatable {
    public var lowerBound: Double
    public var upperBound: Double
    public var count: Int
}

public enum InsightWarning: Equatable, Sendable {
    case insufficientPairs(found: Int, needed: Int)
    case belowLabelThreshold(found: Int, needed: Int)
    case sparseCoverage(fraction: Double)
    case mostlyEstimated
    case neutralInterval
    case outlierSensitive
    case insufficientBaseline
    /// Indexing was refused because an anchor window is mostly zero-filled
    /// buckets — an average dominated by rest days manufactures huge fake
    /// swings (a normal training day reads as 2,000% of baseline). The
    /// series come back raw in their native units.
    case zeroDominatedIndexAnchor
    /// Informational: the range was too short for an early-window baseline,
    /// so every series is indexed to its own whole-range average instead —
    /// still one shared chart, differently anchored.
    case meanIndexedBaseline
    case insufficientDistribution(found: Int, needed: Int)
    case insufficientTrendSamples(metricID: String, found: Int, needed: Int)
    /// Enough samples exist, but every bucket has the same value. A histogram
    /// has no width; the truthful result is a constant-value statement.
    case constantDistribution(value: Double)
    /// A relationship has enough aligned buckets, but one axis never varies;
    /// correlation is mathematically undefined rather than "zero".
    case constantRelationship(metricID: String)
    /// The metric's total recorded history is shorter than the minimum its
    /// descriptor declares trustworthy — refuse rather than imply.
    case insufficientHistory(metricID: String, daysAvailable: Int, needed: Int)
    /// Groups with fewer buckets than the chart minimum were dropped.
    case groupsBelowMinimum(dropped: Int, needed: Int)
    /// One configured metric has no observations in the window while others
    /// do — it draws nothing, so the result must say so instead of hiding it.
    /// Carries the operand KEY (metric + scope), same as `insufficientHistory`.
    case emptySeries(metricID: String)
    /// Defense in depth: a caller attempted to evaluate a recipe that the
    /// compatibility engine rejects. No observations were read or analyzed.
    case invalidRecipe
    case emptyResult
}

/// Five-number summary of a distribution — the payload behind the "Ranges"
/// chart for distribution questions.
public struct InsightDistributionSummary: Sendable, Equatable {
    public var count: Int
    public var minimum: Double
    public var q1: Double
    public var median: Double
    public var q3: Double
    public var maximum: Double
}

public struct InsightResult: Sendable, Equatable {
    public var signature: String
    public var series: [InsightSeries]
    public var relationship: InsightRelationship?
    public var groups: [InsightGroup]?
    public var periodDeltas: [InsightPeriodDelta]?
    public var histogram: [InsightHistogramBin]?
    public var distributionSummary: InsightDistributionSummary?
    public var coverage: InsightCoverage
    public var provenance: InsightProvenance
    public var warnings: [InsightWarning]

    public init(
        signature: String,
        series: [InsightSeries],
        relationship: InsightRelationship? = nil,
        groups: [InsightGroup]? = nil,
        periodDeltas: [InsightPeriodDelta]? = nil,
        histogram: [InsightHistogramBin]? = nil,
        distributionSummary: InsightDistributionSummary? = nil,
        coverage: InsightCoverage,
        provenance: InsightProvenance,
        warnings: [InsightWarning]
    ) {
        self.signature = signature
        self.series = series
        self.relationship = relationship
        self.groups = groups
        self.periodDeltas = periodDeltas
        self.histogram = histogram
        self.distributionSummary = distributionSummary
        self.coverage = coverage
        self.provenance = provenance
        self.warnings = warnings
    }
}

// MARK: - Engine

/// Pure evaluation of a valid recipe over pre-produced observations. Runs
/// anywhere (callers put it off the main actor), takes a calendar so
/// timezone/DST behavior is testable, and derives every stochastic seed from
/// the recipe signature.
public enum InsightQueryEngine {

    public static let exploratoryPairMinimum = 10
    public static let labelPairMinimum = 20
    public static let distributionMinimum = 15
    public static let sparseCoverageThreshold = 0.35
    /// Groups need at least this many buckets to chart at all…
    public static let groupMinimumBuckets = 5
    /// …and this many before a highest/lowest conclusion is written.
    public static let groupConclusionMinimum = 10
    /// |ρ − ρ_sensitivity| beyond this flags the headline as outlier-driven.
    public static let outlierSensitivityDelta = 0.2

    public static func evaluate(
        recipe: InsightRecipe,
        descriptors: [InsightMetricDescriptor],
        observations: [String: [InsightObservation]],
        now: Date = Date(),
        calendar: Calendar = .current,
        dataStart: Date? = nil,
        shouldCancel: @Sendable () -> Bool = { false }
    ) -> InsightResult {
        let byID = Dictionary(descriptors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Period comparisons read "range" as the CURRENT period and compare
        // against the equal window immediately before it — the analysis span
        // is twice the selected range.
        var window = window(
            for: recipe.range, now: now, calendar: calendar, observations: observations,
            dataStart: dataStart,
            doubled: recipe.shape == .periodComparison && recipe.range.days != nil
        )
        var hasEligibleWindow = true
        // A calendar-day result is not complete until the day closes. Mixing
        // today's accumulating value with prior full days manufactures a
        // predictable end-of-chart dip and can bias relationships, groups,
        // and distributions by the time the user opens the app. Non-period
        // daily analyses therefore end immediately before today's local
        // midnight. Session analyses remain current, while period comparisons
        // intentionally keep their exact elapsed windows ending at `now`.
        if recipe.bucket == .daily, recipe.shape != .periodComparison {
            if let completed = completedDailyWindow(
                range: recipe.range, baseWindow: window, dataStart: dataStart,
                now: now, calendar: calendar
            ) {
                window = completed
            } else {
                hasEligibleWindow = false
                let anchor = anchor(for: now, bucket: .daily, calendar: calendar)
                window = anchor...anchor
            }
        }
        // Weekly totals must compare like with like. A rolling range almost
        // always begins and ends inside calendar weeks; treating those edge
        // fragments as full observations manufactures a drop at both ends.
        // Non-period weekly analyses therefore use the most recent COMPLETE
        // calendar weeks. Period comparisons aggregate raw rows into their
        // own equal elapsed windows and are intentionally unaffected.
        if recipe.bucket == .weekly, recipe.shape != .periodComparison {
            let knownDataStart = dataStart
                ?? observations.values.lazy.flatMap { $0 }.map(\.timestamp).min()
            if let completed = completedWeeklyWindow(
                range: recipe.range, baseWindow: window, dataStart: knownDataStart,
                now: now, calendar: calendar
            ) {
                window = completed
            } else {
                hasEligibleWindow = false
                let anchor = anchor(for: now, bucket: .weekly, calendar: calendar)
                window = anchor...anchor
            }
        }
        var warnings: [InsightWarning] = []

        // Observation tables and series are keyed by OPERAND (metric +
        // scope) so scoped twins — bench e1RM vs squat e1RM — never collide.
        // v1 recipes have unscoped operands whose key IS the metric id, so
        // old tables keep working.
        func rows(for operand: InsightOperand) -> [InsightObservation] {
            observations[operand.key] ?? observations[operand.metricID] ?? []
        }

        // A metric whose entire recorded history is shorter than its declared
        // minimum gets refused up front, not implied.
        for operand in recipe.operands {
            guard let descriptor = byID[operand.metricID], descriptor.minimumHistoryDays > 0 else { continue }
            let stamps = rows(for: operand).map(\.timestamp)
            guard let first = stamps.min(), let last = stamps.max() else { continue }
            let span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
            if span < descriptor.minimumHistoryDays {
                warnings.append(.insufficientHistory(
                    metricID: operand.key, daysAvailable: span, needed: descriptor.minimumHistoryDays
                ))
            }
        }

        // Bucket + aggregate each operand under its metric's rule. The raw
        // windowed rows are kept per operand — period comparisons must
        // aggregate from THEM, not from bucketed values (bucket means would
        // drop weights, and a week straddling the boundary would land whole
        // on one side).
        var series: [InsightSeries] = []
        var windowedRows: [String: [InsightObservation]] = [:]
        for operand in recipe.operands {
            guard let descriptor = byID[operand.metricID] else { continue }
            var raw = hasEligibleWindow
                ? rows(for: operand).filter { window.contains($0.timestamp) }
                : []
            if recipe.shape == .groupComparison,
               recipe.dimension == .weekday,
               recipe.bucket == .daily,
               hasEligibleWindow,
               descriptor.zeroFillPolicy == .zeroWhenAbsent {
                raw = weekdayGridCompleted(
                    raw,
                    window: window,
                    calendar: calendar,
                    canCompleteFullWindow: dataStart != nil
                )
            }
            windowedRows[operand.key] = raw
            let bucketed = bucket(
                raw,
                bucket: recipe.bucket,
                aggregation: descriptor.aggregation,
                calendar: calendar
            )
            series.append(
                InsightSeries(
                    metricID: operand.key,
                    points: bucketed.map { InsightSeriesPoint(date: $0.date, value: $0.value) },
                    provenance: rollupProvenance(raw.map(\.provenance))
                )
            )
        }

        // Coverage counts real observations — the tally zero-fill below must
        // not inflate it.
        let coverage = coverage(
            for: series,
            recipe: recipe,
            window: window,
            calendar: calendar,
            descriptors: byID,
            windowedRows: windowedRows,
            hasEligibleWindow: hasEligibleWindow
        )

        if recipe.shape == .trend {
            for line in series {
                let metricID = InsightOperand.metricID(fromKey: line.metricID)
                guard byID[metricID]?.zeroFillPolicy == .never,
                      !line.points.isEmpty,
                      line.points.count < 3 else { continue }
                warnings.append(.insufficientTrendSamples(
                    metricID: line.metricID, found: line.points.count, needed: 3
                ))
            }
        }

        // Tally metrics (sum-aggregated) mean ZERO on a gridded bucket with
        // no observations: no cardio that day is a fact, not missing data.
        // Without the fill, a trend line bridges empty months at the last
        // seen value and reads as a false baseline. Measurement metrics
        // (means, bests) keep true gaps — their empty buckets are unknown.
        var allSeriesAreZeroFilledTallies = false
        if (recipe.shape == .trend || recipe.shape == .distribution), recipe.bucket != .session {
            var filled = 0
            series = series.map { line in
                guard byID[InsightOperand.metricID(fromKey: line.metricID)]?.zeroFillPolicy == .zeroWhenAbsent,
                      hasEligibleWindow,
                      (!line.points.isEmpty || dataStart != nil) else { return line }
                filled += 1
                return zeroFilled(line, bucket: recipe.bucket, window: window, calendar: calendar)
            }
            allSeriesAreZeroFilledTallies = recipe.shape == .trend && !series.isEmpty && filled == series.count
        }

        if recipe.normalization == .baselineIndex {
            // All-or-nothing on BOTH the decision and the anchor: mixing
            // indexed and raw — or early-anchored and mean-anchored — series
            // would put two meanings on one axis. Every series anchors on the
            // SAME calendar window (its first fifth); when the range is too
            // short for that, every series falls back TOGETHER to its own
            // whole-range average, so a comparison stays ONE chart on any
            // range. Raw + split multiples only when a series is genuinely
            // too thin to scale at all.
            var earlyWarnings: [InsightWarning] = []
            let early = series.map { baselineIndexed($0, window: window, warnings: &earlyWarnings) }
            if earlyWarnings.isEmpty {
                series = early
            } else {
                var meanWarnings: [InsightWarning] = []
                let meanScaled = series.map { meanIndexed($0, warnings: &meanWarnings) }
                if meanWarnings.isEmpty {
                    series = meanScaled
                    warnings.append(.meanIndexedBaseline)
                } else {
                    // Name the actual blocker: zero-dominated anchors get
                    // their own warning (weekly grouping usually fixes them);
                    // genuinely thin series keep the generic one.
                    warnings.append(meanWarnings.contains(.zeroDominatedIndexAnchor)
                        ? .zeroDominatedIndexAnchor : .insufficientBaseline)
                }
            }
        }

        // Zero-filled tallies have no "gaps" — every bucket is exact.
        if recipe.shape != .relationship,
           !allSeriesAreZeroFilledTallies,
           coverage.expectedBuckets > 0, coverage.fraction < sparseCoverageThreshold {
            warnings.append(.sparseCoverage(fraction: coverage.fraction))
        }

        var relationship: InsightRelationship?
        var groups: [InsightGroup]?
        var periodDeltas: [InsightPeriodDelta]?
        var histogram: [InsightHistogramBin]?
        var distributionSummary: InsightDistributionSummary?
        var pairedCount: Int?

        switch recipe.shape {
        case .trend:
            break
        case .relationship:
            relationship = relationshipResult(
                recipe: recipe, series: series, byID: byID, window: window,
                calendar: calendar,
                warnings: &warnings, shouldCancel: shouldCancel
            )
            pairedCount = relationship?.pairs.count
        case .groupComparison:
            groups = groupResult(
                recipe: recipe, byID: byID, observations: windowedRows,
                window: window, calendar: calendar,
                warnings: &warnings
            )
        case .periodComparison:
            periodDeltas = periodResult(
                recipe: recipe, byID: byID, windowedRows: windowedRows,
                window: window, now: now, calendar: calendar
            )
        case .distribution:
            histogram = distributionResult(series: series, warnings: &warnings)
            if let values = series.first?.points.map(\.value), values.count >= distributionMinimum {
                let sorted = values.sorted()
                distributionSummary = InsightDistributionSummary(
                    count: sorted.count,
                    minimum: sorted.first ?? 0,
                    q1: InsightStatistics.percentile(sorted: sorted, 0.25),
                    median: InsightStatistics.median(sorted) ?? 0,
                    q3: InsightStatistics.percentile(sorted: sorted, 0.75),
                    maximum: sorted.last ?? 0
                )
            }
        }

        let overall = rollupProvenance(series.map(\.provenance))
        if overall == .estimated { warnings.append(.mostlyEstimated) }
        if series.allSatisfy(\.points.isEmpty) {
            warnings.append(.emptyResult)
        } else {
            // A configured metric that contributed nothing must be named, not
            // silently absent — the chart legend only shows series with marks.
            for line in series where line.points.isEmpty {
                warnings.append(.emptySeries(metricID: line.metricID))
            }
        }

        return InsightResult(
            signature: recipe.analysisSignature,
            series: series,
            relationship: relationship,
            groups: groups,
            periodDeltas: periodDeltas,
            histogram: histogram,
            distributionSummary: distributionSummary,
            coverage: InsightCoverage(
                expectedBuckets: coverage.expectedBuckets,
                populatedBuckets: coverage.populatedBuckets,
                pairedSamples: pairedCount,
                operandBuckets: coverage.operandBuckets,
                expectedSourceBuckets: coverage.expectedSourceBuckets,
                populatedSourceBuckets: coverage.populatedSourceBuckets
            ),
            provenance: overall,
            warnings: warnings
        )
    }

    // MARK: - Windowing & bucketing

    static func window(
        for range: InsightRange,
        now: Date,
        calendar: Calendar,
        observations: [String: [InsightObservation]],
        dataStart: Date? = nil,
        doubled: Bool = false
    ) -> ClosedRange<Date> {
        let end = now
        if let days = range.days {
            let span = doubled ? days * 2 : days
            // A period comparison uses two equal elapsed calendar windows,
            // both ending at the same local time of day. Starting the doubled
            // span at midnight made the current accumulating period shorter
            // whenever `now` was after midnight.
            var start = doubled
                ? (calendar.date(byAdding: .day, value: -span, to: now) ?? now)
                : (calendar.date(byAdding: .day, value: -(span - 1), to: calendar.startOfDay(for: now)) ?? now)
            // Never demand history from before the user HAD any data — a
            // three-week-old log is 100% of what exists, not 10% of six
            // months. (Callers pass the domain's earliest record.)
            if let dataStart, dataStart > start {
                start = doubled ? dataStart : calendar.startOfDay(for: dataStart)
            }
            return start...max(start, end)
        }
        let earliest = observations.values.flatMap { $0 }.map(\.timestamp).min() ?? end
        return min(earliest, end)...end
    }

    /// Returns only whole calendar weeks. Fixed ranges use exactly their
    /// advertised number of completed weeks (4W = four completed weeks),
    /// then clamp to the first complete week after the common data-domain
    /// start. All-history follows the same lower-bound rule. `nil` means the
    /// user has not accumulated one complete eligible week yet.
    static func completedWeeklyWindow(
        range: InsightRange,
        baseWindow: ClosedRange<Date>,
        dataStart: Date? = nil,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        let currentWeekStart = anchor(for: now, bucket: .weekly, calendar: calendar)
        guard let lastInstant = calendar.date(byAdding: .second, value: -1, to: currentWeekStart) else {
            return nil
        }

        let desiredStart: Date
        if let days = range.days {
            let weeks = max(days / 7, 1)
            desiredStart = calendar.date(byAdding: .weekOfYear, value: -weeks, to: currentWeekStart)
                ?? currentWeekStart
        } else {
            desiredStart = baseWindow.lowerBound
        }

        // A fixed rolling-day base window begins inside the first desired
        // completed week. It is not a data-domain boundary. Clamp only to an
        // actual/inferred first record; all-history still uses its own base.
        let firstKnownTimestamp = dataStart
            ?? (range.days == nil ? baseWindow.lowerBound : desiredStart)
        let baseAnchor = anchor(for: firstKnownTimestamp, bucket: .weekly, calendar: calendar)
        let firstCompleteFromData: Date
        if firstKnownTimestamp > baseAnchor {
            firstCompleteFromData = calendar.date(byAdding: .weekOfYear, value: 1, to: baseAnchor)
                ?? currentWeekStart
        } else {
            firstCompleteFromData = baseAnchor
        }
        let start = max(desiredStart, firstCompleteFromData)
        guard start <= lastInstant else { return nil }
        return start...lastInstant
    }

    /// Returns only completed local calendar days. Fixed ranges preserve the
    /// advertised number of days (4W = 28 completed days) before clamping to
    /// an explicit data-domain start. All-history begins on the first known
    /// calendar day. `nil` means no day has completed inside the domain yet.
    static func completedDailyWindow(
        range: InsightRange,
        baseWindow: ClosedRange<Date>,
        dataStart: Date? = nil,
        now: Date,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        let todayStart = calendar.startOfDay(for: now)
        let end = Date(
            timeIntervalSinceReferenceDate: todayStart.timeIntervalSinceReferenceDate.nextDown
        )

        let desiredStart: Date
        if let days = range.days {
            desiredStart = calendar.date(byAdding: .day, value: -days, to: todayStart)
                ?? todayStart
        } else {
            desiredStart = calendar.startOfDay(for: baseWindow.lowerBound)
        }

        let firstKnownTimestamp = dataStart
            ?? (range.days == nil ? baseWindow.lowerBound : desiredStart)
        let firstKnownDay = calendar.startOfDay(for: firstKnownTimestamp)
        let start = max(desiredStart, firstKnownDay)
        guard start <= end else { return nil }
        return start...end
    }

    struct BucketedValue {
        var date: Date
        var value: Double
    }

    static func bucket(
        _ observations: [InsightObservation],
        bucket: InsightBucket,
        aggregation: InsightAggregation,
        calendar: Calendar
    ) -> [BucketedValue] {
        guard !observations.isEmpty else { return [] }
        var grouped: [Date: [InsightObservation]] = [:]
        for observation in observations {
            let anchor = anchor(for: observation.timestamp, bucket: bucket, calendar: calendar)
            grouped[anchor, default: []].append(observation)
        }
        return grouped
            .map { BucketedValue(date: $0.key, value: aggregate($0.value, rule: aggregation)) }
            .sorted { $0.date < $1.date }
    }

    /// Grid-completes a tally series: every daily/weekly bucket in the
    /// window gets a point, absent buckets at exactly 0. Only sound for sum
    /// aggregation — an empty bucket's sum IS zero, while an empty bucket's
    /// mean or best is genuinely unknown. Empty series stay empty so the
    /// no-data state still shows instead of a flat zero line.
    private static func zeroFilled(
        _ series: InsightSeries,
        bucket: InsightBucket,
        window: ClosedRange<Date>,
        calendar: Calendar
    ) -> InsightSeries {
        let byDate = Dictionary(series.points.map { ($0.date, $0.value) }, uniquingKeysWith: { first, _ in first })
        var points: [InsightSeriesPoint] = []
        var cursor = anchor(for: window.lowerBound, bucket: bucket, calendar: calendar)
        let step: Calendar.Component = bucket == .weekly ? .weekOfYear : .day
        while cursor <= window.upperBound {
            points.append(InsightSeriesPoint(date: cursor, value: byDate[cursor] ?? 0))
            guard let next = calendar.date(byAdding: step, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return InsightSeries(metricID: series.metricID, points: points, provenance: series.provenance)
    }

    static func anchor(for date: Date, bucket: InsightBucket, calendar: Calendar) -> Date {
        switch bucket {
        case .session:
            return date
        case .daily:
            return calendar.startOfDay(for: date)
        case .weekly:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    static func aggregate(_ observations: [InsightObservation], rule: InsightAggregation) -> Double {
        let values = observations.map(\.value)
        switch rule {
        case .sum:
            return values.reduce(0, +)
        case .mean:
            return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        case .max, .bestSession:
            return values.max() ?? 0
        case .min:
            return values.min() ?? 0
        case .distanceWeightedMean:
            let totalWeight = observations.reduce(0) { $0 + $1.weight }
            guard totalWeight > 0 else { return 0 }
            return observations.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
        case .lastValue:
            return observations.max(by: { $0.timestamp < $1.timestamp })?.value ?? 0
        }
    }

    // MARK: - Relationship

    private static func relationshipResult(
        recipe: InsightRecipe,
        series: [InsightSeries],
        byID: [String: InsightMetricDescriptor],
        window: ClosedRange<Date>,
        calendar: Calendar,
        warnings: inout [InsightWarning],
        shouldCancel: @Sendable () -> Bool
    ) -> InsightRelationship? {
        guard series.count == 2 else { return nil }
        let outcome = series[0]
        let exposure = series[1]

        // ONE pair per exposure bucket: the exposure at date d pairs with the
        // outcome bucket at d + lag. Bucket aggregation upstream already
        // collapsed multi-session days, so an exposure can never fan out
        // across several outcome rows and inflate n. The lag walks CALENDAR
        // days/weeks — a fixed 86,400s offset silently drops every pair that
        // straddles a daylight-saving transition.
        let outcomeByDate = Dictionary(
            outcome.points.map { ($0.date, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let exposureByDate = Dictionary(
            exposure.points.map { ($0.date, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        func laggedDate(_ date: Date) -> Date? {
            guard let lag = recipe.lag, lag.count != 0 else { return date }
            let component: Calendar.Component = lag.unit == .weeks ? .weekOfYear : .day
            return calendar.date(byAdding: component, value: lag.count, to: date)
        }
        let outcomeDescriptor = byID[InsightOperand.metricID(fromKey: outcome.metricID)]
        let exposureDescriptor = byID[InsightOperand.metricID(fromKey: exposure.metricID)]
        // Missing measurements are always excluded. Zero-capable training
        // totals may either stay on their recorded active buckets (the
        // metric-aware default) or contribute structural zeros on dates made
        // eligible by the other operand (the visible recipe override).
        let population = InsightCompatibilityEngine.resolvedRelationshipPopulation(
            for: recipe,
            descriptors: Array(byID.values)
        )
        let includesInactiveBuckets = population == .includeInactiveBuckets
        let outcomeMayBeZero = includesInactiveBuckets
            && outcomeDescriptor?.zeroFillPolicy == .zeroWhenAbsent
        let exposureMayBeZero = includesInactiveBuckets
            && exposureDescriptor?.zeroFillPolicy == .zeroWhenAbsent
        let reverseComponent: Calendar.Component = recipe.lag?.unit == .weeks ? .weekOfYear : .day
        let reverseCount = -(recipe.lag?.count ?? 0)
        let shiftedOutcomeDates = Set(outcome.points.compactMap {
            calendar.date(byAdding: reverseComponent, value: reverseCount, to: $0.date)
        })
        let exposureDates = Set(exposure.points.map(\.date))

        let candidateSet: Set<Date>
        switch (exposureMayBeZero, outcomeMayBeZero) {
        case (false, false): candidateSet = exposureDates.intersection(shiftedOutcomeDates)
        case (true, false): candidateSet = shiftedOutcomeDates
        case (false, true): candidateSet = exposureDates
        case (true, true): candidateSet = exposureDates.union(shiftedOutcomeDates)
        }
        let candidateExposureDates = candidateSet.sorted()

        // Calendar buckets are anchored to midnight/week-start. An all-
        // history window begins at the first raw timestamp, so comparing an
        // anchor against that exact time would incorrectly discard the first
        // partial day or week.
        let eligibleLower = recipe.bucket == .session
            ? window.lowerBound
            : anchor(for: window.lowerBound, bucket: recipe.bucket, calendar: calendar)
        let eligibleUpper = recipe.bucket == .session
            ? window.upperBound
            : anchor(for: window.upperBound, bucket: recipe.bucket, calendar: calendar)

        var pairs: [InsightPair] = candidateExposureDates.compactMap { exposureDate in
            guard (eligibleLower...eligibleUpper).contains(exposureDate),
                  let outcomeDate = laggedDate(exposureDate),
                  (eligibleLower...eligibleUpper).contains(outcomeDate) else { return nil }
            let exposureValue = exposureByDate[exposureDate] ?? (exposureMayBeZero ? 0 : .nan)
            let outcomeValue = outcomeByDate[outcomeDate] ?? (outcomeMayBeZero ? 0 : .nan)
            guard exposureValue.isFinite, outcomeValue.isFinite else { return nil }
            return InsightPair(date: exposureDate, x: exposureValue, y: outcomeValue)
        }

        guard pairs.count >= exploratoryPairMinimum else {
            warnings.append(.insufficientPairs(found: pairs.count, needed: exploratoryPairMinimum))
            return InsightRelationship(pairs: pairs, spearman: nil, interval: nil, trend: nil, sensitivitySpearman: nil)
        }
        if pairs.count < labelPairMinimum {
            warnings.append(.belowLabelThreshold(found: pairs.count, needed: labelPairMinimum))
        }

        let x = pairs.map(\.x)
        let y = pairs.map(\.y)
        if Set(x).count < 2 || Set(y).count < 2 {
            warnings.append(.constantRelationship(
                metricID: Set(x).count < 2 ? exposure.metricID : outcome.metricID
            ))
            return InsightRelationship(
                pairs: pairs, spearman: nil, interval: nil, trend: nil,
                sensitivitySpearman: nil
            )
        }
        let flagsX = InsightStatistics.madOutlierFlags(x)
        let flagsY = InsightStatistics.madOutlierFlags(y)
        for index in pairs.indices {
            pairs[index].isOutlierFlagged = flagsX[index] || flagsY[index]
        }

        let seed = InsightStatistics.seed(fromSignature: recipe.analysisSignature)
        let spearman = InsightStatistics.spearman(x, y)
        let interval = InsightStatistics.blockBootstrapSpearmanInterval(
            x: x, y: y, seed: seed, shouldCancel: shouldCancel
        )
        let trend = InsightStatistics.theilSen(x: x, y: y, seed: seed)

        let kept = pairs.filter { !$0.isOutlierFlagged }
        let sensitivity = kept.count >= 3
            ? InsightStatistics.spearman(kept.map(\.x), kept.map(\.y))
            : nil

        if let interval, interval.contains(0) { warnings.append(.neutralInterval) }
        if let spearman, let sensitivity, abs(spearman - sensitivity) > outlierSensitivityDelta {
            warnings.append(.outlierSensitive)
        }

        return InsightRelationship(
            pairs: pairs,
            spearman: spearman,
            interval: interval,
            trend: trend,
            sensitivitySpearman: sensitivity
        )
    }

    static func lagOffsetSeconds(_ lag: InsightLag?) -> TimeInterval {
        guard let lag else { return 0 }
        switch lag.unit {
        case .days: return TimeInterval(lag.count) * 86_400
        case .weeks: return TimeInterval(lag.count) * 7 * 86_400
        }
    }

    // MARK: - Groups

    private static func groupResult(
        recipe: InsightRecipe,
        byID: [String: InsightMetricDescriptor],
        observations: [String: [InsightObservation]],
        window: ClosedRange<Date>,
        calendar: Calendar,
        warnings: inout [InsightWarning]
    ) -> [InsightGroup] {
        guard let primary = recipe.operands.first,
              let descriptor = byID[primary.metricID] else { return [] }
        let raw = (observations[primary.key] ?? observations[primary.metricID] ?? [])
            .filter { window.contains($0.timestamp) }

        var byCategory: [String: [InsightObservation]] = [:]
        for observation in raw {
            guard let category = observation.category else { continue }
            byCategory[category, default: []].append(observation)
        }
        let all = byCategory
            .map { category, members -> InsightGroup in
                let buckets = bucket(members, bucket: recipe.bucket, aggregation: descriptor.aggregation, calendar: calendar)
                let values = buckets.map(\.value).sorted()
                return InsightGroup(
                    category: category,
                    bucketCount: buckets.count,
                    total: values.reduce(0, +),
                    median: InsightStatistics.median(values) ?? 0,
                    minimum: values.first ?? 0,
                    maximum: values.last ?? 0,
                    q1: values.isEmpty ? 0 : InsightStatistics.percentile(sorted: values, 0.25),
                    q3: values.isEmpty ? 0 : InsightStatistics.percentile(sorted: values, 0.75)
                )
            }
            .sorted {
                if $0.median == $1.median { return $0.category < $1.category }
                return $0.median > $1.median
            }
        // Tiny groups are noise, not comparison material.
        let kept = all.filter { $0.bucketCount >= groupMinimumBuckets }
        if kept.count < all.count {
            warnings.append(.groupsBelowMinimum(dropped: all.count - kept.count, needed: groupMinimumBuckets))
        }
        return kept
    }

    /// For a zero-capable daily tally, "volume by weekday" means average
    /// across ALL eligible Mondays/Tuesdays/etc., including rest days.
    /// Conditioning only on days with a workout makes rare large days look
    /// systematically better. Completing before coverage is calculated also
    /// keeps the UI from labelling these factual zeros as missing data.
    private static func weekdayGridCompleted(
        _ rows: [InsightObservation],
        window: ClosedRange<Date>,
        calendar: Calendar,
        canCompleteFullWindow: Bool
    ) -> [InsightObservation] {
        guard canCompleteFullWindow || !rows.isEmpty else { return rows }
        var completed = rows
        let covered = Set(rows.map { calendar.startOfDay(for: $0.timestamp) })
        let firstKnown = canCompleteFullWindow
            ? calendar.startOfDay(for: window.lowerBound)
            : rows.map { calendar.startOfDay(for: $0.timestamp) }.min()
        guard var cursor = firstKnown else { return rows }
        let end = calendar.startOfDay(for: window.upperBound)
        while cursor <= end {
            if !covered.contains(cursor) {
                let weekday = calendar.component(.weekday, from: cursor)
                let symbols = calendar.weekdaySymbols
                let index = weekday - 1
                let category = symbols.indices.contains(index) ? symbols[index] : "Day \(weekday)"
                completed.append(InsightObservation(
                    // Noon stays inside the intended date across DST.
                    timestamp: cursor.addingTimeInterval(43_200),
                    value: 0,
                    provenance: .measured,
                    category: category
                ))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                  next > cursor else { break }
            cursor = next
        }
        return completed
    }

    // MARK: - Periods

    private static func periodResult(
        recipe: InsightRecipe,
        byID: [String: InsightMetricDescriptor],
        windowedRows: [String: [InsightObservation]],
        window: ClosedRange<Date>,
        now: Date,
        calendar: Calendar
    ) -> [InsightPeriodDelta] {
        // Fixed ranges: the selected range IS the current period, compared
        // against the equal calendar window immediately before it (the
        // evaluate window already spans both). All-history: equal halves.
        let boundary: Date
        if let days = recipe.range.days,
           let explicit = calendar.date(byAdding: .day, value: -days, to: now) {
            boundary = explicit
        } else {
            boundary = window.lowerBound.addingTimeInterval(
                window.upperBound.timeIntervalSince(window.lowerBound) / 2
            )
        }
        let fullPreviousStart = recipe.range.days.flatMap {
            calendar.date(byAdding: .day, value: -($0 * 2), to: now)
        } ?? window.lowerBound
        let previousWindowIsComplete = window.lowerBound <= fullPreviousStart
        let currentWindowIsComplete = window.lowerBound <= boundary
        // Partition RAW observations by the boundary, then aggregate each
        // side under the metric's own rule. Aggregating bucketed values
        // instead would average away distance/time weights (a 2 km jog would
        // count as much as a 20 km run in "average pace"), and a weekly
        // bucket straddling the boundary would land whole on one side.
        return recipe.operands.map { operand in
            let descriptor = byID[operand.metricID]
            let aggregation = descriptor?.aggregation ?? .sum
            let rows = windowedRows[operand.key] ?? []
            let previous = rows.filter { $0.timestamp < boundary }
            let current = rows.filter { $0.timestamp >= boundary }
            func periodValue(
                _ rows: [InsightObservation],
                completeWindow: Bool
            ) -> Double? {
                guard completeWindow else { return nil }
                if rows.isEmpty {
                    return descriptor?.zeroFillPolicy == .zeroWhenAbsent && completeWindow
                        ? 0
                        : nil
                }
                return aggregate(rows, rule: aggregation)
            }
            let previousValue = periodValue(
                previous, completeWindow: previousWindowIsComplete
            )
            let currentValue = periodValue(
                current, completeWindow: currentWindowIsComplete
            )
            let change = currentValue.flatMap { currentValue in
                previousValue.map { currentValue - $0 }
            }
            let percent = currentValue.flatMap { currentValue in
                previousValue.flatMap { previousValue in
                    previousValue == 0 ? nil : (currentValue - previousValue) / previousValue * 100
                }
            }
            return InsightPeriodDelta(
                metricID: operand.key,
                current: currentValue,
                previous: previousValue,
                change: change,
                percentChange: percent,
                currentSamples: current.count,
                previousSamples: previous.count
            )
        }
    }

    // MARK: - Distribution

    private static func distributionResult(
        series: [InsightSeries],
        warnings: inout [InsightWarning]
    ) -> [InsightHistogramBin]? {
        guard let values = series.first?.points.map(\.value), !values.isEmpty else { return nil }
        guard values.count >= distributionMinimum else {
            warnings.append(.insufficientDistribution(found: values.count, needed: distributionMinimum))
            return nil
        }
        guard let minimum = values.min(), let maximum = values.max() else { return nil }
        guard maximum > minimum else {
            warnings.append(.constantDistribution(value: minimum))
            return nil
        }
        let binCount = min(12, max(5, values.count / 5))
        let width = (maximum - minimum) / Double(binCount)
        var bins = (0..<binCount).map { index in
            InsightHistogramBin(
                lowerBound: minimum + Double(index) * width,
                upperBound: minimum + Double(index + 1) * width,
                count: 0
            )
        }
        for value in values {
            let index = min(binCount - 1, Int((value - minimum) / width))
            bins[index].count += 1
        }
        return bins
    }

    // MARK: - Normalization & coverage

    private static func baselineIndexed(
        _ series: InsightSeries,
        window: ClosedRange<Date>,
        warnings: inout [InsightWarning]
    ) -> InsightSeries {
        // Baseline = the WINDOW's first fifth by calendar, at least 5 buckets
        // inside it. Anchoring on point counts would let two series index
        // against different time periods; fewer than 5 anchors 100 to noise.
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let baselineEnd = window.lowerBound.addingTimeInterval(span / 5)
        let baseline = series.points.filter { $0.date <= baselineEnd }.map(\.value)
        let baselineCount = baseline.count
        guard baselineCount >= 5, series.points.count >= baselineCount + 3 else {
            warnings.append(.insufficientBaseline)
            return series
        }
        // Zero-filled tallies sneak past the count guard with an anchor made
        // of rest days; 100 must mean a typical bucket, not a near-empty one.
        let nonzero = baseline.count(where: { $0 > 0 })
        guard nonzero >= 5, nonzero * 2 >= baselineCount else {
            warnings.append(.zeroDominatedIndexAnchor)
            return series
        }
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        guard mean > 0 else {
            warnings.append(.insufficientBaseline)
            return series
        }
        var indexed = series
        indexed.points = series.points.map {
            InsightSeriesPoint(date: $0.date, value: $0.value / mean * 100)
        }
        return indexed
    }

    /// Fallback scale for short ranges: 100 = the series' own average over
    /// the whole window. Any positive series with two points can scale.
    private static func meanIndexed(
        _ series: InsightSeries,
        warnings: inout [InsightWarning]
    ) -> InsightSeries {
        let values = series.points.map(\.value)
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        guard values.count >= 2, mean > 0 else {
            warnings.append(.insufficientBaseline)
            return series
        }
        // Same zero-domination rule as the early anchor — a whole-range mean
        // that is mostly rest days inflates every training day identically.
        guard values.count(where: { $0 > 0 }) * 2 >= values.count else {
            warnings.append(.zeroDominatedIndexAnchor)
            return series
        }
        var indexed = series
        indexed.points = series.points.map {
            InsightSeriesPoint(date: $0.date, value: $0.value / mean * 100)
        }
        return indexed
    }

    private static func coverage(
        for series: [InsightSeries],
        recipe: InsightRecipe,
        window: ClosedRange<Date>,
        calendar: Calendar,
        descriptors: [String: InsightMetricDescriptor],
        windowedRows: [String: [InsightObservation]],
        hasEligibleWindow: Bool
    ) -> InsightCoverage {
        let operandBuckets = Dictionary(
            series.map { ($0.metricID, $0.points.count) },
            uniquingKeysWith: { first, _ in first }
        )
        guard hasEligibleWindow else {
            return InsightCoverage(
                expectedBuckets: 0,
                populatedBuckets: 0,
                operandBuckets: operandBuckets
            )
        }
        let counts = Array(operandBuckets.values)
        let populated = counts.min() ?? 0
        let densest = counts.max() ?? 0
        let expected: Int
        switch recipe.bucket {
        case .session:
            // Sessions have no external calendar grid; the densest configured
            // operand is the available session universe and the weakest is the
            // honest headline coverage.
            expected = densest
        case .daily:
            expected = expectedBucketAnchors(in: window, bucket: .daily, calendar: calendar).count
        case .weekly:
            expected = expectedBucketAnchors(in: window, bucket: .weekly, calendar: calendar).count
        }

        var expectedSourceBuckets: Int?
        var populatedSourceBuckets: Int?
        if recipe.bucket == .weekly {
            let expectedDays = expectedBucketAnchors(
                in: window, bucket: .daily, calendar: calendar
            ).count
            let dailyNativeCounts = recipe.operands.compactMap { operand -> Int? in
                guard let descriptor = descriptors[operand.metricID],
                      descriptor.nativeBuckets.contains(.daily),
                      !descriptor.nativeBuckets.contains(.session),
                      descriptor.zeroFillPolicy == .never else { return nil }
                let rows = windowedRows[operand.key] ?? []
                return Set(rows.map { anchor(for: $0.timestamp, bucket: .daily, calendar: calendar) }).count
            }
            if !dailyNativeCounts.isEmpty {
                expectedSourceBuckets = expectedDays
                populatedSourceBuckets = dailyNativeCounts.min()
            }
        }
        return InsightCoverage(
            expectedBuckets: expected,
            populatedBuckets: populated,
            operandBuckets: operandBuckets,
            expectedSourceBuckets: expectedSourceBuckets,
            populatedSourceBuckets: populatedSourceBuckets
        )
    }

    private static func expectedBucketAnchors(
        in window: ClosedRange<Date>,
        bucket: InsightBucket,
        calendar: Calendar
    ) -> [Date] {
        guard bucket != .session else { return [] }
        let component: Calendar.Component = bucket == .weekly ? .weekOfYear : .day
        var anchors: [Date] = []
        var cursor = anchor(for: window.lowerBound, bucket: bucket, calendar: calendar)
        while cursor <= window.upperBound {
            anchors.append(cursor)
            guard let next = calendar.date(byAdding: component, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return anchors
    }

    static func rollupProvenance(_ provenances: [InsightProvenance]) -> InsightProvenance {
        let distinct = Set(provenances)
        if distinct.isEmpty { return .measured }
        if distinct.count == 1 { return distinct.first ?? .measured }
        return .mixed
    }
}
