import Foundation

/// Stable identity for one measurement stream. Baselines may only compare
/// values whose channel keys match exactly; a source or protocol change is
/// data provenance, not a physiological event.
public struct AnalyticsChannelKey: Hashable, Codable, Sendable {
    public let metric: String
    public let statistic: String
    public let context: String
    public let sourceBundleID: String
    public let deviceModel: String?
    public let sourceAlgorithmVersion: String?
    public let protocolVersion: String
    public let unit: String

    public init(
        metric: String,
        statistic: String,
        context: String,
        sourceBundleID: String,
        deviceModel: String? = nil,
        sourceAlgorithmVersion: String? = nil,
        protocolVersion: String,
        unit: String
    ) {
        self.metric = metric
        self.statistic = statistic
        self.context = context
        self.sourceBundleID = sourceBundleID
        self.deviceModel = deviceModel
        self.sourceAlgorithmVersion = sourceAlgorithmVersion
        self.protocolVersion = protocolVersion
        self.unit = unit
    }
}

public enum AnalyticsMeasurementClass: String, Codable, Sendable {
    case sourceMeasured
    case sourceDerived
    case userEntered
    case conventionalEstimate
    case productHeuristic
}

/// Audit record carried by every consumer-facing analytic. The formula hash
/// is a stable identifier supplied by the implementation, not a security hash.
public struct AnalyticsProvenance: Hashable, Codable, Sendable {
    public let analyticsID: String
    public let analyticsVersion: String
    public let formulaHash: String
    public let channel: AnalyticsChannelKey?
    public let baselineStart: Date?
    public let baselineEnd: Date?
    public let baselineCount: Int
    public let coverage: Double
    public let measurementClass: AnalyticsMeasurementClass
    public let generatedAt: Date

    public init(
        analyticsID: String,
        analyticsVersion: String,
        formulaHash: String,
        channel: AnalyticsChannelKey? = nil,
        baselineStart: Date? = nil,
        baselineEnd: Date? = nil,
        baselineCount: Int = 0,
        coverage: Double,
        measurementClass: AnalyticsMeasurementClass,
        generatedAt: Date
    ) {
        self.analyticsID = analyticsID
        self.analyticsVersion = analyticsVersion
        self.formulaHash = formulaHash
        self.channel = channel
        self.baselineStart = baselineStart
        self.baselineEnd = baselineEnd
        self.baselineCount = baselineCount
        self.coverage = min(1, max(0, coverage))
        self.measurementClass = measurementClass
        self.generatedAt = generatedAt
    }
}
