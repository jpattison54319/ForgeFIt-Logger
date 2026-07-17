import Foundation

/// Deterministic, honest one-liners for insight cards. No causal language,
/// no p-values, no health advice — descriptions of what the user's available
/// history shows, with the caveat winning whenever the evidence is thin.
/// Wording rules follow the house copy voice: consequences and caveats stay;
/// reassurance and false authority don't ship.
public enum InsightExplanationBuilder {

    /// A descriptive noise band, not a significance test. We still show the
    /// exact direction and percentage; below 3% the headline says "roughly
    /// steady" instead of turning rounding-level movement into a trend call.
    static let roughlySteadyPercent = 3.0

    /// The single observation line a saved card shows.
    public static func summary(
        for result: InsightResult,
        shape: InsightShape,
        primaryTitle: String,
        comparisonTitle: String? = nil,
        tallyMetricIDs: Set<String> = [],
        seriesTitles: [String: String] = [:],
        bucketNoun: String = "days",
        valueFormatter: ((String, Double) -> String)? = nil
    ) -> String {
        if result.warnings.contains(.invalidRecipe) {
            return "This saved insight needs attention before it can run."
        }
        if result.warnings.contains(.emptyResult) {
            return "No data in this range yet."
        }
        for warning in result.warnings {
            if case .insufficientHistory(_, let daysAvailable, let needed) = warning {
                return "Needs about \(needed) days of history before this is trustworthy — \(daysAvailable) so far."
            }
            if case .insufficientTrendSamples(_, let found, let needed) = warning {
                return "Needs \(needed) recorded values before calling this a trend — \(found) so far."
            }
        }
        switch shape {
        case .relationship:
            return relationshipSummary(
                result, primaryTitle: primaryTitle,
                comparisonTitle: comparisonTitle, bucketNoun: bucketNoun
            )
        case .trend:
            return trendSummary(
                result, primaryTitle: primaryTitle, comparisonTitle: comparisonTitle,
                tallyMetricIDs: tallyMetricIDs, seriesTitles: seriesTitles
            )
        case .groupComparison:
            return groupSummary(result, primaryTitle: primaryTitle, bucketNoun: bucketNoun)
        case .periodComparison:
            return periodSummary(
                result, primaryTitle: primaryTitle, valueFormatter: valueFormatter
            )
        case .distribution:
            return distributionSummary(
                result, primaryTitle: primaryTitle, valueFormatter: valueFormatter
            )
        }
    }

    // MARK: - Relationship

    private static func relationshipSummary(
        _ result: InsightResult,
        primaryTitle: String,
        comparisonTitle: String?,
        bucketNoun: String
    ) -> String {
        guard let relationship = result.relationship else {
            return "Not enough overlapping history to compare these yet."
        }
        for warning in result.warnings {
            if case .insufficientPairs(let found, let needed) = warning {
                let noun = found == 1 ? singular(bucketNoun) : bucketNoun
                return "Only \(found) matched \(noun) so far — \(needed) are needed before any pattern is worth reading."
            }
        }
        guard let spearman = relationship.spearman else {
            if let warning = result.warnings.first(where: {
                if case .constantRelationship = $0 { return true }
                return false
            }), case .constantRelationship(let key) = warning {
                let title = key == result.series.first?.metricID
                    ? primaryTitle
                    : (comparisonTitle ?? "The comparison")
                return "\(title) did not vary in the matched history, so a relationship cannot be calculated."
            }
            return "These values don't overlap enough to compare yet."
        }
        if result.warnings.contains(.neutralInterval) {
            return "No consistent pattern between these in your available history."
        }
        if result.warnings.contains(.outlierSensitive) {
            return "A pattern shows up, but a few unusual \(primaryTitle.lowercased()) days drive most of it — read with care."
        }

        let direction = spearman > 0 ? "higher" : "lower"
        let pairNoun = comparisonTitle.map { $0.lowercased() } ?? "the comparison"
        if result.warnings.contains(where: {
            if case .belowLabelThreshold = $0 { return true } else { return false }
        }) {
            return "Early signs that \(direction) \(pairNoun) tended to come with \(spearman > 0 ? "higher" : "lower") \(primaryTitle.lowercased()) — more history will firm this up."
        }
        let strength = strengthLabel(abs(spearman))
        return "\(strength): \(direction) \(pairNoun) tended to move with \(spearman > 0 ? "higher" : "lower") \(primaryTitle.lowercased()) in your available history."
    }

    /// Plain-language association strength — only used at ≥20 pairs, and the
    /// scale is deliberately conservative.
    static func strengthLabel(_ magnitude: Double) -> String {
        switch magnitude {
        case 0.6...: "A clear tendency"
        case 0.4..<0.6: "A moderate tendency"
        case 0.2..<0.4: "A weak tendency"
        default: "Little to no tendency"
        }
    }

    // MARK: - Other shapes

    private static func trendSummary(
        _ result: InsightResult,
        primaryTitle: String,
        comparisonTitle: String? = nil,
        tallyMetricIDs: Set<String> = [],
        seriesTitles: [String: String] = [:]
    ) -> String {
        guard let points = result.series.first?.points, points.count >= 2,
              points.first?.value != nil else {
            return "Not enough history for a trend yet."
        }
        if result.warnings.contains(.sparseCoverage(fraction: result.coverage.fraction)) {
            return "\(primaryTitle) has too many gaps in this range to read a trend confidently."
        }
        func line(_ series: InsightSeries, title: String) -> String {
            tallyMetricIDs.contains(series.metricID)
                ? tallyTrendLine(series, title: title)
                : seriesTrendLine(series, title: title)
        }
        // Every plotted line gets a sentence — a chart with four series and a
        // one-series summary reads as if three of them don't matter.
        var lines: [String] = []
        for (index, series) in result.series.enumerated() where series.points.count >= 2 {
            let title = seriesTitles[series.metricID]
                ?? (index == 0 ? primaryTitle : (index == 1 ? (comparisonTitle ?? series.metricID) : series.metricID))
            lines.append(line(series, title: title))
        }
        return lines.isEmpty ? "Not enough history for a trend yet." : lines.joined(separator: " ")
    }

    /// Zero-filled tallies are spiky and often end on a rest-day zero, so
    /// first-vs-last is meaningless — compare the two halves of the window
    /// instead.
    private static func tallyTrendLine(_ series: InsightSeries, title: String) -> String {
        let values = series.points.map(\.value)
        let half = values.count / 2
        guard half > 0 else { return "\(title) across \(values.count) points in this range." }
        // Compare equal-duration rates. For an odd number of buckets, the
        // middle bucket is neutral instead of making the recent half longer.
        let earlier = values.prefix(half).reduce(0, +) / Double(half)
        let later = values.suffix(half).reduce(0, +) / Double(half)
        guard earlier + later > 0 else { return "No \(title.lowercased()) recorded in this range." }
        let equalityScale = max(max(abs(earlier), abs(later)), 1)
        if abs(later - earlier) <= equalityScale * 0.000_000_001 {
            return "\(title) had the same average per bucket in both halves of this range."
        }
        if earlier == 0 { return "All of this range's \(title.lowercased()) landed in the recent half." }
        if later == 0 { return "All of this range's \(title.lowercased()) landed in the earlier half." }
        let change = (later - earlier) / earlier * 100
        if abs(change) < roughlySteadyPercent {
            return "\(title) was roughly steady between halves (\(formattedPercent(abs(change))) \(change > 0 ? "higher" : "lower") in the recent half)."
        }
        return "\(title) averaged \(formattedPercent(abs(change))) \(change > 0 ? "higher" : "lower") per bucket in the recent half of this range."
    }

    /// Measurement trends read the Theil–Sen slope over actual timestamps —
    /// first-vs-last hands the whole verdict to two arbitrary (often noisy)
    /// readings; the median slope is robust to both.
    private static func seriesTrendLine(_ series: InsightSeries, title: String) -> String {
        guard series.points.count >= 2,
              let firstDate = series.points.first?.date,
              let lastDate = series.points.last?.date, lastDate > firstDate else {
            return series.points.isEmpty
                ? "\(title) has no history in this range yet."
                : "\(title) across \(series.points.count) \(series.points.count == 1 ? "point" : "points") in this range."
        }
        let x = series.points.map { $0.date.timeIntervalSince(firstDate) / 86_400 }
        let y = series.points.map(\.value)
        let mean = y.reduce(0, +) / Double(y.count)
        guard mean != 0, let trend = InsightStatistics.theilSen(x: x, y: y) else {
            return "\(title) across \(series.points.count) points in this range."
        }
        let spanDays = lastDate.timeIntervalSince(firstDate) / 86_400
        let fittedStart = trend.intercept
        let fittedEnd = trend.intercept + trend.slope * spanDays
        let fittedChange = fittedEnd - fittedStart
        if abs(fittedChange) <= max(abs(mean), 1) * 0.000_000_001 {
            return "\(title) had no measurable change across this range."
        }
        // A percentage means end relative to start. Dividing the fitted
        // change by the whole-series mean produced a mathematically defined
        // but nonstandard number that users naturally misread as ordinary
        // percent change. If the robust fitted start is not positive, avoid
        // inventing a percentage at all.
        guard fittedStart > 0, fittedStart.isFinite, fittedEnd.isFinite else {
            return "\(title) trended \(fittedChange > 0 ? "higher" : "lower") across this range."
        }
        let change = fittedChange / fittedStart * 100
        if abs(change) < roughlySteadyPercent {
            return "\(title) was roughly steady across this range (the robust trend ended \(formattedPercent(abs(change))) \(change > 0 ? "higher" : "lower") than it began)."
        }
        return "\(title) showed a robust trend ending \(formattedPercent(abs(change))) \(change > 0 ? "higher" : "lower") than it began across this range."
    }

    private static func groupSummary(
        _ result: InsightResult,
        primaryTitle: String,
        bucketNoun: String
    ) -> String {
        guard let groups = result.groups, groups.count >= 2,
              let top = groups.first, let bottom = groups.last else {
            return "Not enough groups with data to compare yet."
        }
        // No highest/lowest call until every group carries a real sample.
        let smallest = groups.map(\.bucketCount).min() ?? 0
        if smallest < InsightQueryEngine.groupConclusionMinimum {
            let noun = smallest == 1 ? singular(bucketNoun) : bucketNoun
            return "Groups are still small — the thinnest has \(smallest) \(noun), and a ranking needs \(InsightQueryEngine.groupConclusionMinimum). The medians will firm up as more values accumulate."
        }
        let scale = max(max(abs(top.median), abs(bottom.median)), 1)
        if abs(top.median - bottom.median) <= scale * 0.000_001 {
            return "The compared groups had the same median \(primaryTitle.lowercased()) in your available history."
        }
        return "\(primaryTitle) ran highest for \(top.category) and lowest for \(bottom.category) in your available history."
    }

    private static func singular(_ noun: String) -> String {
        switch noun.lowercased() {
        case "days": "day"
        case "weeks": "week"
        case "sessions": "session"
        default: noun
        }
    }

    private static func periodSummary(
        _ result: InsightResult,
        primaryTitle: String,
        valueFormatter: ((String, Double) -> String)?
    ) -> String {
        guard let delta = result.periodDeltas?.first else {
            return "Not enough history to compare periods yet."
        }
        switch (delta.current, delta.previous) {
        case (nil, nil):
            return "Neither period has recorded \(primaryTitle.lowercased()) data."
        case (nil, .some):
            return "No \(primaryTitle.lowercased()) reading was recorded in the current period."
        case (.some, nil):
            return "\(primaryTitle) has current-period data, but no previous-period reading to compare with."
        case (.some(let current), .some(let previous)) where previous == 0:
            if current == 0 {
                return "\(primaryTitle) was zero in both periods."
            }
            let rendered = valueFormatter?(delta.metricID, current) ?? current.cleanFormatted
            return "\(primaryTitle) is \(rendered) this period; the previous period was zero, so a percentage change is undefined."
        case (.some, .some):
            break
        }
        guard let percent = delta.percentChange else {
            return "Both periods have \(primaryTitle.lowercased()) data, but a percentage change is unavailable."
        }
        return "\(primaryTitle) \(percent >= 0 ? "up" : "down") \(formattedPercent(abs(percent))) versus the previous period."
    }

    private static func distributionSummary(
        _ result: InsightResult,
        primaryTitle: String,
        valueFormatter: ((String, Double) -> String)?
    ) -> String {
        guard let series = result.series.first else {
            return "Not enough history to show a distribution yet."
        }
        let values = series.points.map(\.value)
        if case .some(.constantDistribution(let value)) = result.warnings.first(where: {
            if case .constantDistribution = $0 { return true }
            return false
        }) {
            let rendered = valueFormatter?(series.metricID, value) ?? value.cleanFormatted
            return "All \(values.count) recorded \(values.count == 1 ? "value was" : "values were") \(rendered) in this range."
        }
        guard result.histogram != nil,
              let median = InsightStatistics.median(values) else {
            return "Not enough history to show a distribution yet."
        }
        let rendered = valueFormatter?(series.metricID, median) ?? median.cleanFormatted
        return "Your typical \(primaryTitle.lowercased()) centers around \(rendered) in this range."
    }

    private static func formattedPercent(_ value: Double) -> String {
        if value < 0.05 { return "less than 0.1%" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}

private extension Double {
    var cleanFormatted: String {
        formatted(.number.precision(.fractionLength(0...1)))
    }
}
