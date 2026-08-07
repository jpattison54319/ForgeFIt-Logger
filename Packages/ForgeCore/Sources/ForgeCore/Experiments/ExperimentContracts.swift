import Foundation

/// Version shared by the local experiment analysis payloads. Persisted app
/// models may evolve independently; this version describes only the pure
/// ForgeCore request/result contract.
public enum ExperimentAnalysisContract {
    public static let currentVersion = 1
}

public enum ExperimentComparisonError: LocalizedError, Equatable, Sendable {
    case invalidVersion(Int)
    case invalidWindowBounds
    case unknownTimeZone(String)
    case noElapsedExperimentTime
    case overlappingWindows
    case emptyMetricID
    case duplicateMetric(ExperimentMetricKey)
    case unsupportedPerDayNormalization(ExperimentMetricKey)
    case unsupportedZeroWhenAbsent(ExperimentMetricKey)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion:
            "This comparison uses an unsupported analysis version."
        case .invalidWindowBounds:
            "The comparison end must be after its start."
        case .unknownTimeZone:
            "The saved time zone for this comparison is unavailable."
        case .noElapsedExperimentTime:
            "Let the experiment run before comparing its progress."
        case .overlappingWindows:
            "Choose a comparison period that does not overlap this experiment."
        case .emptyMetricID, .duplicateMetric,
             .unsupportedPerDayNormalization, .unsupportedZeroWhenAbsent:
            "A saved outcome is not compatible with this analysis version."
        }
    }
}

/// An exact experiment interval. Membership is always start-inclusive and
/// end-exclusive; the stored time zone is for calendar-day coverage, never
/// for changing the interval's absolute instants.
public struct ExperimentWindow: Codable, Sendable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case version
        case start
        case end
        case timeZoneIdentifier
    }

    public let version: Int
    public let start: Date
    public let end: Date
    public let timeZoneIdentifier: String

    public init(
        version: Int = ExperimentAnalysisContract.currentVersion,
        start: Date,
        end: Date,
        timeZoneIdentifier: String
    ) throws {
        guard version > 0 else {
            throw ExperimentComparisonError.invalidVersion(version)
        }
        guard end > start else {
            throw ExperimentComparisonError.invalidWindowBounds
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw ExperimentComparisonError.unknownTimeZone(timeZoneIdentifier)
        }
        self.version = version
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? ExperimentAnalysisContract.currentVersion
        let start = try container.decode(Date.self, forKey: .start)
        let end = try container.decode(Date.self, forKey: .end)
        let timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        try self.init(
            version: version,
            start: start,
            end: end,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
    }

    public var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    /// Exact elapsed 24-hour equivalents. This deliberately does not round
    /// across daylight-saving transitions.
    public var elapsedDays: Double {
        duration / 86_400
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // The initializer validates this identifier.
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar
    }

    public func contains(_ timestamp: Date) -> Bool {
        timestamp >= start && timestamp < end
    }
}

public enum ExperimentMetricScopeKind: String, Codable, Sendable, Equatable, Hashable {
    case exercise
    case modality
    case routine
    case tracker
}

public struct ExperimentMetricScope: Codable, Sendable, Equatable, Hashable {
    public let kind: ExperimentMetricScopeKind
    public let id: String

    public init(kind: ExperimentMetricScopeKind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// The stable identity shared by a selection and its observations. Keeping
/// scope structured avoids delimiter-based string keys and lets two scoped
/// instances of the same catalog metric coexist.
public struct ExperimentMetricKey: Codable, Sendable, Equatable, Hashable {
    public let metricID: String
    public let scope: ExperimentMetricScope?

    public init(metricID: String, scope: ExperimentMetricScope? = nil) {
        self.metricID = metricID
        self.scope = scope
    }
}

public enum ExperimentMetricAggregation: String, Codable, Sendable, Equatable {
    case sum
    case mean
    case maximum
    case minimum
    case weightedMean
    case latest

    /// Only additive totals have a meaningful "per elapsed day" value.
    public var supportsPerDayNormalization: Bool {
        self == .sum
    }
}

public enum ExperimentMissingValuePolicy: String, Codable, Sendable, Equatable {
    /// No recorded value means the period value is unknown.
    case missing
    /// No event means an exact zero, appropriate for additive event tallies.
    case zeroWhenAbsent
}

public enum ExperimentComparisonNormalization: String, Codable, Sendable, Equatable {
    /// Prefer per-day totals when duration differs; otherwise compare raw
    /// values. Non-additive metrics always remain raw.
    case automatic
    case raw
    case perDay
}

/// A catalog metric and optional scope selected as an experiment outcome.
public struct ExperimentMetricSelection: Codable, Sendable, Equatable {
    public let version: Int
    public let metricID: String
    public let scope: ExperimentMetricScope?
    public let valueKind: InsightValueKind
    public let aggregation: ExperimentMetricAggregation
    public let missingValuePolicy: ExperimentMissingValuePolicy
    public let normalization: ExperimentComparisonNormalization

    public init(
        version: Int = ExperimentAnalysisContract.currentVersion,
        metricID: String,
        scope: ExperimentMetricScope? = nil,
        valueKind: InsightValueKind = .count,
        aggregation: ExperimentMetricAggregation,
        missingValuePolicy: ExperimentMissingValuePolicy = .missing,
        normalization: ExperimentComparisonNormalization = .automatic
    ) {
        self.version = version
        self.metricID = metricID
        self.scope = scope
        self.valueKind = valueKind
        self.aggregation = aggregation
        self.missingValuePolicy = missingValuePolicy
        self.normalization = normalization
    }

    public var key: ExperimentMetricKey {
        ExperimentMetricKey(metricID: metricID, scope: scope)
    }
}

/// One immutable numeric observation. A nil value records an attempted or
/// expected observation whose measurement was missing; non-finite values and
/// invalid weighted-mean weights are also excluded and disclosed in coverage.
public struct ExperimentMetricObservation: Codable, Sendable, Equatable {
    public let version: Int
    public let metric: ExperimentMetricKey
    public let timestamp: Date
    public let value: Double?
    public let provenance: InsightProvenance
    public let group: String?
    public let weight: Double

    public init(
        version: Int = ExperimentAnalysisContract.currentVersion,
        metric: ExperimentMetricKey,
        timestamp: Date,
        value: Double?,
        provenance: InsightProvenance = .measured,
        group: String? = nil,
        weight: Double = 1
    ) {
        self.version = version
        self.metric = metric
        self.timestamp = timestamp
        self.value = value
        self.provenance = provenance
        self.group = group
        self.weight = weight
    }
}

/// How the comparison window should be resolved. An experiment reference
/// retains its source ID; a custom range and another experiment retain their
/// own time-zone semantics.
public enum ExperimentComparisonReference: Codable, Sendable, Equatable {
    case previousEqualPeriod
    case experiment(id: UUID, window: ExperimentWindow)
    case custom(window: ExperimentWindow)
}

public struct ExperimentComparisonRequest: Codable, Sendable, Equatable {
    public let version: Int
    public let currentWindow: ExperimentWindow
    public let reference: ExperimentComparisonReference

    public init(
        version: Int = ExperimentAnalysisContract.currentVersion,
        currentWindow: ExperimentWindow,
        reference: ExperimentComparisonReference = .previousEqualPeriod
    ) {
        self.version = version
        self.currentWindow = currentWindow
        self.reference = reference
    }
}

public enum ExperimentComparisonBasis: String, Codable, Sendable, Equatable {
    case raw
    case perDay
}

/// Coverage is intentionally explicit about complete calendar days. Boundary
/// fragments still contribute observations to exact-window aggregates, but
/// they do not masquerade as complete Health days.
public struct ExperimentMetricCoverage: Codable, Sendable, Equatable {
    public let observationCount: Int
    public let validValueCount: Int
    public let missingValueCount: Int
    public let populatedCalendarDays: Int
    public let expectedCompleteCalendarDays: Int
    public let populatedCompleteCalendarDays: Int

    public init(
        observationCount: Int,
        validValueCount: Int,
        missingValueCount: Int,
        populatedCalendarDays: Int,
        expectedCompleteCalendarDays: Int,
        populatedCompleteCalendarDays: Int
    ) {
        self.observationCount = observationCount
        self.validValueCount = validValueCount
        self.missingValueCount = missingValueCount
        self.populatedCalendarDays = populatedCalendarDays
        self.expectedCompleteCalendarDays = expectedCompleteCalendarDays
        self.populatedCompleteCalendarDays = populatedCompleteCalendarDays
    }

    public var completeDayFraction: Double? {
        guard expectedCompleteCalendarDays > 0 else { return nil }
        return min(
            1,
            Double(populatedCompleteCalendarDays) / Double(expectedCompleteCalendarDays)
        )
    }
}

public struct ExperimentNumericSummary: Codable, Sendable, Equatable {
    public let count: Int
    public let sum: Double
    public let mean: Double
    public let minimum: Double
    public let q1: Double
    public let median: Double
    public let q3: Double
    public let maximum: Double

    public init(
        count: Int,
        sum: Double,
        mean: Double,
        minimum: Double,
        q1: Double,
        median: Double,
        q3: Double,
        maximum: Double
    ) {
        self.count = count
        self.sum = sum
        self.mean = mean
        self.minimum = minimum
        self.q1 = q1
        self.median = median
        self.q3 = q3
        self.maximum = maximum
    }
}

public struct ExperimentGroupSummary: Codable, Sendable, Equatable {
    public let group: String
    public let aggregateValue: Double
    public let summary: ExperimentNumericSummary
    public let provenance: InsightProvenance

    public init(
        group: String,
        aggregateValue: Double,
        summary: ExperimentNumericSummary,
        provenance: InsightProvenance
    ) {
        self.group = group
        self.aggregateValue = aggregateValue
        self.summary = summary
        self.provenance = provenance
    }
}

public struct ExperimentPeriodAggregate: Codable, Sendable, Equatable {
    public let value: Double?
    public let perDayValue: Double?
    public let sampleCount: Int
    public let coverage: ExperimentMetricCoverage
    public let summary: ExperimentNumericSummary?
    public let groups: [ExperimentGroupSummary]
    public let provenance: InsightProvenance?

    public init(
        value: Double?,
        perDayValue: Double?,
        sampleCount: Int,
        coverage: ExperimentMetricCoverage,
        summary: ExperimentNumericSummary?,
        groups: [ExperimentGroupSummary],
        provenance: InsightProvenance?
    ) {
        self.value = value
        self.perDayValue = perDayValue
        self.sampleCount = sampleCount
        self.coverage = coverage
        self.summary = summary
        self.groups = groups
        self.provenance = provenance
    }
}

public struct ExperimentMetricDelta: Codable, Sendable, Equatable {
    public let selection: ExperimentMetricSelection
    public let current: ExperimentPeriodAggregate
    public let reference: ExperimentPeriodAggregate
    public let rawAbsoluteChange: Double?
    public let rawPercentChange: Double?
    public let perDayAbsoluteChange: Double?
    public let perDayPercentChange: Double?
    public let comparisonBasis: ExperimentComparisonBasis
    public let comparisonAbsoluteChange: Double?
    public let comparisonPercentChange: Double?

    public init(
        selection: ExperimentMetricSelection,
        current: ExperimentPeriodAggregate,
        reference: ExperimentPeriodAggregate,
        rawAbsoluteChange: Double?,
        rawPercentChange: Double?,
        perDayAbsoluteChange: Double?,
        perDayPercentChange: Double?,
        comparisonBasis: ExperimentComparisonBasis,
        comparisonAbsoluteChange: Double?,
        comparisonPercentChange: Double?
    ) {
        self.selection = selection
        self.current = current
        self.reference = reference
        self.rawAbsoluteChange = rawAbsoluteChange
        self.rawPercentChange = rawPercentChange
        self.perDayAbsoluteChange = perDayAbsoluteChange
        self.perDayPercentChange = perDayPercentChange
        self.comparisonBasis = comparisonBasis
        self.comparisonAbsoluteChange = comparisonAbsoluteChange
        self.comparisonPercentChange = comparisonPercentChange
    }
}

public struct ExperimentResult: Codable, Sendable, Equatable {
    public let version: Int
    public let currentWindow: ExperimentWindow
    public let referenceWindow: ExperimentWindow
    public let reference: ExperimentComparisonReference
    public let metrics: [ExperimentMetricDelta]

    public init(
        version: Int = ExperimentAnalysisContract.currentVersion,
        currentWindow: ExperimentWindow,
        referenceWindow: ExperimentWindow,
        reference: ExperimentComparisonReference,
        metrics: [ExperimentMetricDelta]
    ) {
        self.version = version
        self.currentWindow = currentWindow
        self.referenceWindow = referenceWindow
        self.reference = reference
        self.metrics = metrics
    }
}
