import Foundation

// MARK: - Recipe vocabulary
//
// Everything here is the SHAPE of an insight — which metrics, how they are
// aligned, compared, and drawn. Never observations, never Health values.
// Shapes are Codable and versioned because they persist (and sync) far longer
// than any one build of the metric catalog.

/// The analysis the user is asking for. Drives which canvas controls exist,
/// which metric counts are legal, and which charts can express the result.
public enum InsightShape: String, Codable, Sendable, CaseIterable {
    case trend
    case relationship
    case groupComparison
    case periodComparison
    case distribution
}

/// Time bucketing an analysis aligns on. `session` exists because plenty of
/// training questions are per-workout, not per-calendar-day.
public enum InsightBucket: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case session
}

public enum InsightRange: String, Codable, Sendable, CaseIterable {
    case fourWeeks
    case twelveWeeks
    case sixMonths
    case oneYear
    case allHistory

    public var days: Int? {
        switch self {
        case .fourWeeks: 28
        case .twelveWeeks: 84
        case .sixMonths: 182
        case .oneYear: 365
        case .allHistory: nil
        }
    }
}

/// A semantic offset between an exposure and an outcome ("sleep vs NEXT-DAY
/// performance"). Only whitelisted ranges validate — the engine never mines
/// for the most flattering lag.
public struct InsightLag: Codable, Sendable, Equatable {
    public enum Unit: String, Codable, Sendable {
        case days
        case weeks
    }

    public var unit: Unit
    public var count: Int

    public init(unit: Unit, count: Int) {
        self.unit = unit
        self.count = count
    }

    public static let dayWhitelist = 0...7
    public static let weekWhitelist = 0...4
}

public enum InsightNormalization: String, Codable, Sendable {
    case none
    /// Index each series to 100 at its baseline window. Only valid for
    /// positive ratio-scale metrics with enough baseline data — indexing a
    /// score or a near-zero series manufactures fake swings.
    case baselineIndex
}

/// Which calendar buckets a relationship may pair when a training total can
/// be structurally zero. `automatic` keeps saved recipes metric-aware: dose
/// relationships use active buckets, while relationships without a
/// zero-capable operand simply use their recorded intersection.
public enum InsightRelationshipPopulation: String, Codable, Sendable, Equatable {
    case automatic
    case includeInactiveBuckets
    case activeBucketsOnly
}

/// Every chart the result surface can draw. The compatibility engine decides
/// which of these a given recipe may use; the UI never offers the rest.
public enum InsightChartKind: String, Codable, Sendable, CaseIterable {
    case lineTrend
    case barTrend
    case sharedUnitOverlay
    case smallMultiples
    case baselineIndexLines
    case scatterWithTrend
    case groupedBars
    case boxSummary
    case donutShare
    case periodComparisonCards
    case histogram
}

/// What a metric's numbers mean, for unit-compatibility decisions (shared
/// axes, baseline indexing, donut eligibility). Mass note: values are stored
/// in kilograms and rendered through `Fmt` in the exercise's effective unit —
/// the kind is about compatibility, not formatting.
public enum InsightValueKind: String, Codable, Sendable {
    case count
    case sessions
    case trainingDays
    case reps
    case durationSeconds
    case massKilograms
    case distanceMeters
    case pace
    case speed
    case heartRateBPM
    case heartRateVariabilityMS
    case percentage
    case energyKilocalories
    case power
    case cadence
    case elevationMeters
    case score
    case steps
    /// Respiratory rate — a physiological rate, NOT a tally. It must never
    /// share the count axis family with reps or steps.
    case breathsPerMinute
    /// Strength work divided by strength-only minutes.
    case massPerMinute
    /// Estimated strength divided by body weight; 1.0 means one body weight.
    case bodyweightMultiple
    case rpe
    case rir
    case readinessScore

    /// Kinds that may honestly share one y-axis. Raw tallies unify (sets,
    /// reps, and steps are all dimensionless counts); every other kind is
    /// its own axis — overlaying kilograms on hours misleads at a glance.
    public var axisFamily: String {
        switch self {
        case .count, .sessions, .trainingDays, .reps, .steps: "count"
        default: rawValue
        }
    }

    /// Ratio-scale positives can be baseline-indexed; interval-like scores
    /// and paces cannot (pace inverts meaning, scores have arbitrary zero).
    public var supportsBaselineIndex: Bool {
        switch self {
        case .count, .sessions, .trainingDays, .reps, .durationSeconds, .massKilograms, .distanceMeters,
             .energyKilocalories, .power, .elevationMeters, .steps, .speed:
            true
        case .pace, .heartRateBPM, .heartRateVariabilityMS, .percentage, .score, .cadence,
             .breathsPerMinute, .massPerMinute, .bodyweightMultiple, .rpe, .rir,
             .readinessScore:
            false
        }
    }
}

/// Whether a metric is a plausible cause-side or effect-side of a lagged
/// pairing. Recovery inputs (sleep, HRV) expose; training outputs respond;
/// plenty of metrics can sit on either side of a same-bucket comparison.
public enum InsightTimingRole: String, Codable, Sendable {
    case exposure
    case outcome
    case either
}

public enum InsightProvenance: String, Codable, Sendable {
    case measured
    case estimated
    case imported
    case mixed
}

/// Each metric owns exactly one aggregation per bucket collapse — volume
/// sums, e1RM takes the session best, pace re-weights by distance. Callers
/// never choose freely; the descriptor whitelists what is meaningful.
public enum InsightAggregation: String, Codable, Sendable {
    case sum
    case mean
    case max
    case min
    case bestSession
    case distanceWeightedMean
    case lastValue
}

/// Whether an absent observation can be represented as an exact zero. This is
/// independent of aggregation: a day's missing elevation sample and a day with
/// no workouts are both absent sums, but only the latter is known to be zero.
public enum InsightZeroFillPolicy: String, Sendable, Equatable {
    case never
    case zeroWhenAbsent
}

public enum InsightDimension: String, Codable, Sendable, CaseIterable {
    case exercise
    case routine
    case muscle
    case modality
    case weekday
    case source
    case checkinTag
}

/// Version-1 shared filter payload. The current canvas uses visible
/// per-operand scopes; only one valid legacy exercise UUID remains readable
/// long enough for Edit to migrate it.
public struct InsightFilter: Codable, Sendable, Equatable {
    public var dimension: InsightDimension
    public var values: [String]

    public init(dimension: InsightDimension, values: [String]) {
        self.dimension = dimension
        self.values = values
    }
}

// MARK: - Metric descriptor

/// Catalog metadata the validator reasons over. The app-side catalog supplies
/// these (wired to real data adapters); ForgeCore only needs the semantics.
public struct InsightMetricDescriptor: Sendable, Equatable {
    public var id: String
    public var title: String
    public var category: String
    public var valueKind: InsightValueKind
    public var timingRole: InsightTimingRole
    public var nativeBuckets: Set<InsightBucket>
    public var aggregation: InsightAggregation
    public var supportedShapes: Set<InsightShape>
    public var supportedDimensions: Set<InsightDimension>
    /// Metric requires Health read authorization (drives setup states, and
    /// range policy: Health-backed recipes cap at one year).
    public var requiresHealth: Bool
    /// Days of history below which analyses are refused rather than implied.
    public var minimumHistoryDays: Int
    /// Scope the operand must carry before this metric has one coherent
    /// meaning. For example, e1RM requires an exercise and pace/power require
    /// one cardio modality; combining running and cycling pace is not a
    /// meaningful unscoped value.
    public var requiredScope: InsightScopeKind?
    /// Source-compatible convenience for older app/catalog call sites.
    public var requiresExerciseScope: Bool { requiredScope == .exercise }
    /// Scope kinds that genuinely change this metric's calculation. The
    /// builder offers only these, and validation rejects the rest — a scope
    /// that filters nothing (or filters misleadingly) must not be pickable.
    public var supportedScopes: Set<InsightScopeKind>
    /// Controls grid completion for trends/distributions and explicit rest-day
    /// rows in grouped comparisons.
    public var zeroFillPolicy: InsightZeroFillPolicy
    /// Dimensions whose groups partition this metric's contributions exactly.
    /// Donut charts require membership here; contextual/overlapping groups may
    /// still use bars and ranges.
    public var exclusiveGroupingDimensions: Set<InsightDimension>

    public init(
        id: String,
        title: String,
        category: String,
        valueKind: InsightValueKind,
        timingRole: InsightTimingRole,
        nativeBuckets: Set<InsightBucket>,
        aggregation: InsightAggregation,
        supportedShapes: Set<InsightShape>,
        supportedDimensions: Set<InsightDimension> = [],
        requiresHealth: Bool = false,
        minimumHistoryDays: Int = 7,
        requiresExerciseScope: Bool = false,
        requiredScope: InsightScopeKind? = nil,
        supportedScopes: Set<InsightScopeKind> = [.exercise, .modality, .routine],
        zeroFillPolicy: InsightZeroFillPolicy? = nil,
        exclusiveGroupingDimensions: Set<InsightDimension> = [.weekday, .source, .routine]
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.valueKind = valueKind
        self.timingRole = timingRole
        self.nativeBuckets = nativeBuckets
        self.aggregation = aggregation
        self.supportedShapes = supportedShapes
        self.supportedDimensions = supportedDimensions
        self.requiresHealth = requiresHealth
        self.minimumHistoryDays = minimumHistoryDays
        self.requiredScope = requiredScope ?? (requiresExerciseScope ? .exercise : nil)
        self.supportedScopes = supportedScopes
        self.zeroFillPolicy = zeroFillPolicy ?? (aggregation == .sum ? .zeroWhenAbsent : .never)
        self.exclusiveGroupingDimensions = exclusiveGroupingDimensions
    }
}

// MARK: - Operands

/// One compared quantity: a metric plus ITS OWN scope. Two operands may share
/// a metric with different scopes — bench e1RM vs squat e1RM, running pace vs
/// cycling pace, routine A volume vs routine B volume. Recipe-level filters
/// still narrow every operand together; operand scope narrows just the one.
public struct InsightOperand: Codable, Sendable, Equatable, Hashable {
    public var metricID: String
    /// Compute this operand over one exercise's own sets/series.
    public var exerciseID: UUID?
    /// Restrict this operand to one cardio modality ("run", "cycle"…).
    public var modality: String?
    /// Restrict this operand to sessions of one routine.
    public var routineID: UUID?

    public init(metricID: String, exerciseID: UUID? = nil, modality: String? = nil, routineID: UUID? = nil) {
        self.metricID = metricID
        self.exerciseID = exerciseID
        self.modality = modality
        self.routineID = routineID
    }

    public var isScoped: Bool { exerciseID != nil || modality != nil || routineID != nil }

    public func hasScope(_ kind: InsightScopeKind) -> Bool {
        switch kind {
        case .exercise: exerciseID != nil
        case .modality: modality?.isEmpty == false
        case .routine: routineID != nil
        }
    }

    /// Stable identity for observation tables and series — metric plus
    /// scope, so scoped twins never collide.
    public var key: String {
        var parts = [metricID]
        if let exerciseID { parts.append("ex:\(exerciseID.uuidString)") }
        if let modality { parts.append("mod:\(modality)") }
        if let routineID { parts.append("rt:\(routineID.uuidString)") }
        return parts.joined(separator: "#")
    }

    public static func metricID(fromKey key: String) -> String {
        key.components(separatedBy: "#").first ?? key
    }
}

// MARK: - Recipe

/// The saved shape of an insight. Persisted as versioned JSON inside
/// `SavedInsightModel.recipeJSON` (CloudKit-synced by founder decision:
/// configuration, not data). Metric ids are plain strings so a recipe
/// outlives catalog evolution — unknown ids surface as editable warnings,
/// never decode failures.
public struct InsightRecipe: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var templateID: String?
    public var shape: InsightShape
    /// The compared quantities, each with its own optional scope. First
    /// operand = "Show me"; the rest = companions/exposure.
    /// Trend: up to three companions. Relationship: exactly one. Others: none.
    public var operands: [InsightOperand]
    /// Optional "broken down by" grouping dimension.
    public var dimension: InsightDimension?
    public var filters: [InsightFilter]
    public var range: InsightRange
    public var bucket: InsightBucket
    public var lag: InsightLag?
    public var relationshipPopulation: InsightRelationshipPopulation
    public var normalization: InsightNormalization
    /// nil = engine-recommended chart.
    public var chart: InsightChartKind?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        schemaVersion: Int = InsightRecipe.currentSchemaVersion,
        id: UUID = UUID(),
        name: String = "",
        templateID: String? = nil,
        shape: InsightShape,
        primaryMetricID: String,
        comparisonMetricIDs: [String] = [],
        dimension: InsightDimension? = nil,
        filters: [InsightFilter] = [],
        range: InsightRange = .twelveWeeks,
        bucket: InsightBucket = .daily,
        lag: InsightLag? = nil,
        relationshipPopulation: InsightRelationshipPopulation = .automatic,
        normalization: InsightNormalization = .none,
        chart: InsightChartKind? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.init(
            schemaVersion: schemaVersion, id: id, name: name, templateID: templateID,
            shape: shape,
            operands: ([primaryMetricID] + comparisonMetricIDs).map { InsightOperand(metricID: $0) },
            dimension: dimension, filters: filters, range: range, bucket: bucket,
            lag: lag, relationshipPopulation: relationshipPopulation,
            normalization: normalization, chart: chart,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    public init(
        schemaVersion: Int = InsightRecipe.currentSchemaVersion,
        id: UUID = UUID(),
        name: String = "",
        templateID: String? = nil,
        shape: InsightShape,
        operands: [InsightOperand],
        dimension: InsightDimension? = nil,
        filters: [InsightFilter] = [],
        range: InsightRange = .twelveWeeks,
        bucket: InsightBucket = .daily,
        lag: InsightLag? = nil,
        relationshipPopulation: InsightRelationshipPopulation = .automatic,
        normalization: InsightNormalization = .none,
        chart: InsightChartKind? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.templateID = templateID
        self.shape = shape
        self.operands = operands
        self.dimension = dimension
        self.filters = filters
        self.range = range
        self.bucket = bucket
        self.lag = lag
        self.relationshipPopulation = relationshipPopulation
        self.normalization = normalization
        self.chart = chart
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Compatibility accessors — most rules care about the metric, not the
    /// scope. The primary setter preserves the first operand's scope.
    public var primaryMetricID: String {
        get { operands.first?.metricID ?? "" }
        set {
            if operands.isEmpty {
                operands = [InsightOperand(metricID: newValue)]
            } else {
                operands[0].metricID = newValue
            }
        }
    }

    public var comparisonMetricIDs: [String] { Array(operands.dropFirst().map(\.metricID)) }

    public var allMetricIDs: [String] { operands.map(\.metricID) }

    /// Table/series identities — metric + scope.
    public var operandKeys: [String] { operands.map(\.key) }

    /// Stable signature over the analysis-relevant fields — the cache key
    /// component and the bootstrap seed source. Excludes name/timestamps so
    /// renaming a card never changes its statistics.
    public var analysisSignature: String {
        let filterPart = filters
            .map { "\($0.dimension.rawValue)=\($0.values.sorted().joined(separator: ","))" }
            .sorted()
            .joined(separator: "|")
        let lagPart = lag.map { "\($0.count)\($0.unit.rawValue)" } ?? "none"
        return [
            // Math-contract version: bump whenever engine calculations
            // change meaning, so cached results from the old math can never
            // satisfy a lookup for the new.
            "m7",
            "v\(schemaVersion)", shape.rawValue,
            operandKeys.joined(separator: ","),
            dimension?.rawValue ?? "none", filterPart,
            range.rawValue, bucket.rawValue, lagPart,
            relationshipPopulation.rawValue, normalization.rawValue,
        ].joined(separator: ";")
    }

    // MARK: Codable (v1 → v3 migration)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, templateID, shape, operands
        case primaryMetricID, comparisonMetricIDs
        case dimension, filters, range, bucket, lag, relationshipPopulation
        case normalization, chart
        case createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
        shape = try container.decode(InsightShape.self, forKey: .shape)
        if let decoded = try container.decodeIfPresent([InsightOperand].self, forKey: .operands), !decoded.isEmpty {
            operands = decoded
        } else {
            // Version-1 payload: flat metric ids. Its one supported exercise
            // filter remains readable as a migration fallback; every other
            // hidden filter is rejected until the builder removes it.
            let primary = try container.decodeIfPresent(String.self, forKey: .primaryMetricID) ?? ""
            let comparisons = try container.decodeIfPresent([String].self, forKey: .comparisonMetricIDs) ?? []
            operands = ([primary] + comparisons)
                .filter { !$0.isEmpty }
                .map { InsightOperand(metricID: $0) }
        }
        dimension = try container.decodeIfPresent(InsightDimension.self, forKey: .dimension)
        filters = try container.decodeIfPresent([InsightFilter].self, forKey: .filters) ?? []
        range = try container.decode(InsightRange.self, forKey: .range)
        bucket = try container.decode(InsightBucket.self, forKey: .bucket)
        lag = try container.decodeIfPresent(InsightLag.self, forKey: .lag)
        relationshipPopulation = try container.decodeIfPresent(
            InsightRelationshipPopulation.self,
            forKey: .relationshipPopulation
        ) ?? .automatic
        normalization = try container.decodeIfPresent(InsightNormalization.self, forKey: .normalization) ?? .none
        chart = try container.decodeIfPresent(InsightChartKind.self, forKey: .chart)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(templateID, forKey: .templateID)
        try container.encode(shape, forKey: .shape)
        try container.encode(operands, forKey: .operands)
        // Legacy mirror fields so an older build syncing this recipe still
        // decodes the flat shape (scopes degrade gracefully there).
        try container.encode(primaryMetricID, forKey: .primaryMetricID)
        try container.encode(comparisonMetricIDs, forKey: .comparisonMetricIDs)
        try container.encodeIfPresent(dimension, forKey: .dimension)
        try container.encode(filters, forKey: .filters)
        try container.encode(range, forKey: .range)
        try container.encode(bucket, forKey: .bucket)
        try container.encodeIfPresent(lag, forKey: .lag)
        try container.encode(relationshipPopulation, forKey: .relationshipPopulation)
        try container.encode(normalization, forKey: .normalization)
        try container.encodeIfPresent(chart, forKey: .chart)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        // Default (deferredToDate) keeps Date's full Double precision, so a
        // decoded recipe is Equatable-identical to the one that was saved —
        // ISO strings truncate sub-second precision and made "unchanged"
        // recipes compare as edited.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> InsightRecipe? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(InsightRecipe.self, from: data)
    }
}

// MARK: - Observations & results

/// One aligned data point handed to the engines: immutable and Sendable so
/// aggregation and statistics run off the main actor.
public struct InsightObservation: Sendable, Equatable {
    /// Bucket anchor (start of day/week, or session start).
    public var timestamp: Date
    public var value: Double
    public var provenance: InsightProvenance
    /// Group membership when a dimension is active (e.g. a check-in tag).
    public var category: String?
    /// Aggregation weight for `distanceWeightedMean` metrics (pace carries
    /// its distance here); 1 everywhere else.
    public var weight: Double

    public init(
        timestamp: Date,
        value: Double,
        provenance: InsightProvenance,
        category: String? = nil,
        weight: Double = 1
    ) {
        self.timestamp = timestamp
        self.value = value
        self.provenance = provenance
        self.category = category
        self.weight = weight
    }
}

/// How much of the requested window actually had data — shown on every card;
/// sparse coverage is a first-class result, not a footnote.
public struct InsightCoverage: Sendable, Equatable {
    public var expectedBuckets: Int
    public var populatedBuckets: Int
    public var pairedSamples: Int?
    /// Real (never zero-filled) bucket counts for each operand key. The summary
    /// count is the weakest configured operand, not the densest one.
    public var operandBuckets: [String: Int]
    /// A weekly point can exist from a single daily reading. For daily-native
    /// measurements rolled into weeks, preserve the finer recording-day
    /// denominator so "4/4 weeks" never hides "4/28 recorded nights."
    public var expectedSourceBuckets: Int?
    public var populatedSourceBuckets: Int?

    public init(
        expectedBuckets: Int,
        populatedBuckets: Int,
        pairedSamples: Int? = nil,
        operandBuckets: [String: Int] = [:],
        expectedSourceBuckets: Int? = nil,
        populatedSourceBuckets: Int? = nil
    ) {
        self.expectedBuckets = expectedBuckets
        self.populatedBuckets = populatedBuckets
        self.pairedSamples = pairedSamples
        self.operandBuckets = operandBuckets
        self.expectedSourceBuckets = expectedSourceBuckets
        self.populatedSourceBuckets = populatedSourceBuckets
    }

    public var fraction: Double {
        let bucketFraction = expectedBuckets > 0
            ? min(1, Double(populatedBuckets) / Double(expectedBuckets))
            : 0
        guard let expectedSourceBuckets, expectedSourceBuckets > 0,
              let populatedSourceBuckets else { return bucketFraction }
        let sourceFraction = min(1, Double(populatedSourceBuckets) / Double(expectedSourceBuckets))
        return min(bucketFraction, sourceFraction)
    }
}

// MARK: - Validation

public enum InsightValidationIssue: Equatable, Sendable {
    case unknownMetric(id: String)
    case shapeUnsupported(metricID: String)
    case metricCountInvalid(expected: String)
    case bucketUnsupported(metricID: String, bucket: InsightBucket)
    case dimensionUnsupported(metricID: String, dimension: InsightDimension)
    case lagOutsideWhitelist
    case lagDirectionInvalid
    case lagUnsupportedForShape
    case normalizationUnsupported(metricID: String)
    case chartIncompatible(chart: InsightChartKind)
    case rangeUnsupported(reason: String)
    case missingRequiredScope(metricID: String, scope: InsightScopeKind)
    case healthAuthorizationRequired(metricID: String)
    /// Two operands with identical metric AND scope — scope one of them.
    case duplicateMetric(id: String)
    /// The operand carries a scope kind this metric can't honestly use —
    /// "Pace · Bench Press" filters sessions without changing what pace
    /// means, and a routine filter on a globally derived e1RM is a no-op.
    case scopeUnsupported(metricID: String, scope: InsightScopeKind)
    /// The UI defines operand scope as one mutually-exclusive choice. A
    /// decoded payload carrying two or three scopes is ambiguous and must be
    /// repaired before evaluation.
    case multipleScopes(metricID: String)
    /// A grouping dimension is meaningful only for group-comparison recipes.
    case dimensionUnsupportedForShape(dimension: InsightDimension)
    /// Grouping by the exact field already used to scope an operand can only
    /// produce one circular group ("Bench grouped by exercise").
    case scopeDimensionConflict(metricID: String, dimension: InsightDimension)
    case invalidFilter(dimension: InsightDimension)
}

/// The scope kinds an operand can carry; descriptors declare which of them
/// actually change the metric's calculation.
public enum InsightScopeKind: String, Sendable, Equatable, CaseIterable {
    case exercise
    case modality
    case routine
}

public struct InsightValidation: Sendable, Equatable {
    public var issues: [InsightValidationIssue]
    /// Charts this recipe may legitimately use, recommended first. Empty when
    /// invalid.
    public var allowedCharts: [InsightChartKind]

    public var isValid: Bool { issues.isEmpty }

    public init(issues: [InsightValidationIssue], allowedCharts: [InsightChartKind]) {
        self.issues = issues
        self.allowedCharts = allowedCharts
    }
}
