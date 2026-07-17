import Charts
import ForgeCore
import SwiftUI

/// One renderer per chart kind the compatibility engine can allow. Every
/// variant is theme-aware, differentiates without color (dash + point marks
/// alongside hue), formats axes in the metric's display units, and never
/// draws a representation the engine didn't allow — the kind arrives
/// validated, this view just draws it.
struct InsightChartView: View {
    private struct SegmentedSeriesPoint: Identifiable {
        let point: InsightSeriesPoint
        let segment: Int

        var id: String {
            "\(segment)-\(point.date.timeIntervalSinceReferenceDate)"
        }
    }

    @Environment(\.theme) private var theme

    let kind: InsightChartKind
    let result: InsightResult
    /// Display metadata per metric id (title + value formatting), supplied by
    /// the result screen so per-exercise weight units resolve correctly.
    let titleFor: (String) -> String
    /// nil = plain numbers (baseline-indexed series pass nil — an index of
    /// 112 must not be dressed up as kilograms).
    var valueKindFor: (String) -> InsightValueKind? = { _ in nil }
    var weightUnitFor: (String) -> WeightUnit? = { _ in nil }
    /// Pace denominators depend on the operand's selected activity: rowers
    /// use /500 m and swimmers /100 m rather than the global km/mi unit.
    var modalityFor: (String) -> String? = { _ in nil }
    /// Saved cards render small and non-interactive; detail screens get the
    /// full treatment.
    var compact = false
    /// Spoken description for the whole chart — the deterministic takeaway.
    var accessibilitySummary: String?
    var height: CGFloat = 220
    /// Required to distinguish a missing daily/weekly measurement from an
    /// ordinary gap between irregular workout sessions.
    var bucket: InsightBucket = .daily
    /// What one histogram observation IS ("Days", "Weeks", "Sessions") — a
    /// count axis is meaningless without it. Supplied from the recipe bucket.
    var distributionCountNoun = "Values"

    @State private var selectedDate: Date?
    @State private var selectedX: Double?

    /// Series colors must be tellable apart at a glance — accent green, then
    /// amber, teal, and slate (secondaryAccent is a near-twin of accent, so
    /// it never pairs with it on one chart).
    private var seriesPalette: [Color] {
        [theme.accent, theme.warmup, theme.zone2, theme.zone1]
    }

    private var primaryKind: InsightValueKind? {
        let kinds = result.series.compactMap { valueKindFor($0.metricID) }
        if kinds.count > 1, kinds.allSatisfy({ $0.axisFamily == "count" }) {
            // The marks/callouts keep their nouns; the shared axis is a plain
            // numeric count so steps are never labelled as sessions or reps.
            return .count
        }
        return kinds.first
    }

    private var primaryKey: String { result.series.first?.metricID ?? "" }

    private func formattedValue(_ value: Double, key: String) -> String {
        InsightValueFormat.string(
            value,
            kind: valueKindFor(key),
            weightUnit: weightUnitFor(key),
            modality: modalityFor(key)
        )
    }

    private func spokenPointLabel(key: String, date: Date) -> String {
        let title = titleFor(key)
        let renderedDate = date.formatted(date: .abbreviated, time: .omitted)
        return "\(title), \(renderedDate)"
    }

    private var showsPaceNote: Bool {
        result.series.contains { valueKindFor($0.metricID) == .pace }
    }

    private var supportsValueInspection: Bool {
        switch kind {
        case .lineTrend, .sharedUnitOverlay, .baselineIndexLines, .scatterWithTrend:
            true
        default:
            false
        }
    }

    /// Every small-multiple panel must cover the same dates. Letting each chart
    /// auto-scale makes a late-starting series look as though it began beside
    /// the others, even when their calendars do not overlap.
    private var sharedTimeDomain: ClosedRange<Date> {
        let dates = result.series.flatMap { $0.points.map(\.date) }
        let calendar = Calendar.current
        guard let first = dates.min(), let last = dates.max() else {
            let end = Date()
            return (calendar.date(byAdding: .day, value: -1, to: end) ?? end)...end
        }
        guard first == last else { return first...last }
        let lower = calendar.date(byAdding: .day, value: -1, to: first) ?? first
        let upper = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        return lower...upper
    }

    private var seriesSymbols: [any ChartSymbolShape] {
        [
            BasicChartSymbolShape.circle,
            BasicChartSymbolShape.square,
            BasicChartSymbolShape.triangle,
            BasicChartSymbolShape.diamond,
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch kind {
                case .lineTrend, .sharedUnitOverlay:
                    annotatedTimeChart
                case .baselineIndexLines:
                    VStack(alignment: .leading, spacing: 4) {
                        annotatedTimeChart
                        Text(result.warnings.contains(.meanIndexedBaseline)
                            ? "Different units share one scale: 100 = each line's average across this range."
                            : "Different units share one scale by indexing: each line starts at 100, its own early-window average.")
                            .font(.tag)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .barTrend:
                    barChart
                case .smallMultiples:
                    smallMultiples
                case .scatterWithTrend:
                    scatterChart
                case .groupedBars:
                    // Period comparisons carry deltas, group comparisons carry
                    // groups — each payload gets its own honest renderer.
                    if result.periodDeltas != nil {
                        periodBars
                    } else {
                        groupChart(showRange: false)
                    }
                case .boxSummary:
                    if let summary = result.distributionSummary {
                        distributionBox(summary)
                    } else {
                        groupChart(showRange: true)
                    }
                case .donutShare:
                    donutChart
                case .periodComparisonCards:
                    periodCards
                case .histogram:
                    histogramChart
                }
            }

            if showsPaceNote, !compact {
                Text("Lower pace = faster.")
                    .font(.tag)
                    .foregroundStyle(theme.textTertiary)
            }
            if supportsValueInspection, !compact {
                Label("Drag across the chart to inspect values", systemImage: "hand.draw")
                    .font(.tag)
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: height)
        // Preserve every mark for VoiceOver. The prior `.ignore` collapsed a
        // rich chart to one sentence and made individual values unreachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Insight chart. \(accessibilitySummary ?? "")")
    }

    // MARK: - Trend

    @ViewBuilder
    private var annotatedTimeChart: some View {
        if compact {
            lineChart
        } else {
            lineChart
                .chartXSelection(value: $selectedDate)
        }
    }

    private var lineChart: some View {
        let callout = selectedDate.flatMap { calloutLines(at: $0) }
        return Chart {
            ForEach(Array(result.series.enumerated()), id: \.element.metricID) { index, series in
                ForEach(segmentedPoints(for: series)) { item in
                    let point = item.point
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(titleFor(series.metricID), point.value),
                        series: .value("Continuous segment", "\(series.metricID)-\(item.segment)")
                    )
                    .foregroundStyle(by: .value("Metric", titleFor(series.metricID)))
                    .lineStyle(lineStyle(for: index))
                    .interpolationMethod(interpolationMethod(for: series.metricID))
                    .symbol(by: .value("Metric", titleFor(series.metricID)))
                    .symbolSize(compact ? 16 : 28)
                    .accessibilityLabel(spokenPointLabel(key: series.metricID, date: point.date))
                    .accessibilityValue(
                        formattedValue(point.value, key: series.metricID)
                    )
                }
            }
            if let callout {
                selectionMark(date: callout.date, lines: callout.lines)
            }
        }
        .chartForegroundStyleScale(range: seriesPalette)
        .chartSymbolScale(range: seriesSymbols)
        .chartLegend(result.series.count > 1 ? .visible : .hidden)
        .chartYAxis { formattedYAxis(primaryKind) }
        .chartXAxis { dateXAxis }
        .chartYAxisLabel(alignment: .leading) { timeChartYTitle }
    }

    /// An indexed y axis must say it's an index ON the axis — bare "2,000"
    /// otherwise reads as raw values. Non-indexed single-series charts get
    /// the metric name; multi-series legends already name every line.
    @ViewBuilder
    private var timeChartYTitle: some View {
        if kind == .baselineIndexLines {
            axisTitle(result.warnings.contains(.meanIndexedBaseline)
                ? "% of own average" : "% of own baseline")
        } else {
            singleSeriesYTitle
        }
    }

    @ChartContentBuilder
    private func selectionMark(date: Date, lines: [(String, String)]) -> some ChartContent {
        RuleMark(x: .value("Selected", date))
            .foregroundStyle(theme.separator)
            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                selectionBox(title: date.formatted(date: .abbreviated, time: .omitted), lines: lines)
            }
    }

    /// Nearest bucket to the touched date, one formatted line per series.
    private func calloutLines(at date: Date) -> (date: Date, lines: [(String, String)])? {
        guard let first = result.series.first, !first.points.isEmpty else { return nil }
        let nearest = first.points.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
        guard let anchor = nearest?.date else { return nil }
        let lines: [(String, String)] = result.series.compactMap { series in
            guard let point = series.points.first(where: { $0.date == anchor }) else { return nil }
            return (titleFor(series.metricID), formattedValue(point.value, key: series.metricID))
        }
        return lines.isEmpty ? nil : (anchor, lines)
    }

    private func selectionBox(title: String, lines: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(theme.textSecondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    Text(line.0).font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                    Text(line.1).font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textPrimary)
                }
            }
        }
        .padding(6)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var barChart: some View {
        Chart {
            if let series = result.series.first {
                ForEach(series.points, id: \.date) { point in
                    BarMark(
                        x: .value("Date", point.date),
                        y: .value(titleFor(series.metricID), point.value)
                    )
                    .foregroundStyle(theme.accent)
                    .cornerRadius(3)
                    .accessibilityLabel(spokenPointLabel(key: series.metricID, date: point.date))
                    .accessibilityValue(
                        formattedValue(point.value, key: series.metricID)
                    )
                }
            }
        }
        .chartYAxis { formattedYAxis(primaryKind) }
        .chartXAxis { dateXAxis }
        .chartYAxisLabel(alignment: .leading) { singleSeriesYTitle }
    }

    private var smallMultiples: some View {
        VStack(spacing: Space.md) {
            ForEach(Array(result.series.enumerated()), id: \.element.metricID) { index, series in
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleFor(series.metricID))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                    Chart {
                        ForEach(segmentedPoints(for: series)) { item in
                            let point = item.point
                            LineMark(
                                x: .value("Date", point.date),
                                y: .value("Value", point.value),
                                series: .value("Continuous segment", "\(series.metricID)-\(item.segment)")
                            )
                                .foregroundStyle(seriesPalette[index % seriesPalette.count])
                                .lineStyle(lineStyle(for: index))
                                .interpolationMethod(interpolationMethod(for: series.metricID))
                                .symbol(by: .value("Metric", titleFor(series.metricID)))
                                .symbolSize(compact ? 14 : 24)
                                .accessibilityLabel(spokenPointLabel(key: series.metricID, date: point.date))
                                .accessibilityValue(
                                    formattedValue(point.value, key: series.metricID)
                                )
                        }
                    }
                    .chartXScale(domain: sharedTimeDomain)
                    .chartXAxis { dateXAxis }
                    .chartYAxis { formattedYAxis(valueKindFor(series.metricID), key: series.metricID) }
                    .chartLegend(.hidden)
                    .frame(height: max(64, (height - 40) / CGFloat(max(result.series.count, 1))))
                }
            }
        }
    }

    // MARK: - Relationship

    private var scatterChart: some View {
        // Pairs are (x: exposure = series[1], y: outcome = series[0]).
        let outcomeID = result.series.first?.metricID ?? ""
        let exposureID = result.series.dropFirst().first?.metricID ?? ""
        return Chart {
            if let relationship = result.relationship {
                ForEach(Array(relationship.pairs.enumerated()), id: \.offset) { _, pair in
                    PointMark(x: .value("x", pair.x), y: .value("y", pair.y))
                        .symbol(pair.isOutlierFlagged ? .cross : .circle)
                        .foregroundStyle(pair.isOutlierFlagged ? theme.warmup : theme.accent)
                        .opacity(0.8)
                        .accessibilityLabel(pair.date.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(
                            "\(titleFor(exposureID)) \(formattedValue(pair.x, key: exposureID)); "
                                + "\(titleFor(outcomeID)) \(formattedValue(pair.y, key: outcomeID))"
                                + (pair.isOutlierFlagged ? "; unusual point" : "")
                        )
                }
                if let trend = relationship.trend,
                   let minX = relationship.pairs.map(\.x).min(),
                   let maxX = relationship.pairs.map(\.x).max(), maxX > minX {
                    LineMark(x: .value("x", minX), y: .value("y", trend.intercept + trend.slope * minX))
                        .accessibilityHidden(true)
                    LineMark(x: .value("x", maxX), y: .value("y", trend.intercept + trend.slope * maxX))
                        .accessibilityHidden(true)
                }
                if let selectedX, let pair = nearestPair(to: selectedX) {
                    RuleMark(x: .value("Selected", pair.x))
                        .foregroundStyle(theme.separator)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            selectionBox(
                                title: pair.date.formatted(date: .abbreviated, time: .omitted),
                                lines: [
                                    (titleFor(exposureID), formattedValue(pair.x, key: exposureID)),
                                    (titleFor(outcomeID), formattedValue(pair.y, key: outcomeID)),
                                ]
                            )
                        }
                }
            }
        }
        .chartLegend(.hidden)
        .chartXSelection(value: $selectedX)
        .chartXAxisLabel(titleFor(exposureID))
        .chartYAxisLabel(titleFor(outcomeID))
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(formattedValue(doubleValue, key: exposureID))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis { formattedYAxis(valueKindFor(outcomeID), key: outcomeID) }
    }

    private func nearestPair(to x: Double) -> InsightPair? {
        result.relationship?.pairs.min { abs($0.x - x) < abs($1.x - x) }
    }

    // MARK: - Groups

    private func groupChart(showRange: Bool) -> some View {
        Chart {
            ForEach(result.groups ?? [], id: \.category) { group in
                if showRange {
                    // Whiskers = full min–max span; box = middle half
                    // (q1–q3); rule = median. A real range summary, not a
                    // min/max rectangle pretending to be one.
                    RuleMark(
                        x: .value("Group", group.category),
                        yStart: .value("Min", group.minimum),
                        yEnd: .value("Max", group.maximum)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
                    RectangleMark(
                        x: .value("Group", group.category),
                        yStart: .value("Q1", group.q1),
                        yEnd: .value("Q3", group.q3),
                        width: .ratio(0.55)
                    )
                    .foregroundStyle(theme.accent.opacity(0.3))
                    .accessibilityHidden(true)
                    groupMedianMark(group)
                } else {
                    BarMark(
                        x: .value("Group", group.category),
                        y: .value("Median", group.median),
                        width: .ratio(0.6)
                    )
                    .foregroundStyle(theme.accent)
                    .cornerRadius(4)
                    .accessibilityLabel(group.category)
                    .accessibilityValue(
                        "Median \(formattedValue(group.median, key: primaryKey)) across \(group.bucketCount) values"
                    )
                }
            }
        }
        .chartYAxis { formattedYAxis(primaryKind) }
        .chartYAxisLabel(alignment: .leading) { singleSeriesYTitle }
    }

    private var donutChart: some View {
        let total = (result.groups ?? []).reduce(0) { $0 + $1.total }
        return Chart {
            ForEach(result.groups ?? [], id: \.category) { group in
                SectorMark(
                    angle: .value("Total", group.total),
                    innerRadius: .ratio(0.62),
                    angularInset: 2
                )
                .foregroundStyle(by: .value("Group", group.category))
                .cornerRadius(3)
                .accessibilityLabel(group.category)
                .accessibilityValue(
                    total > 0
                        ? "\(formattedValue(group.total, key: primaryKey)), "
                            + "\((group.total / total * 100).formatted(.number.precision(.fractionLength(0...1)))) percent"
                        : formattedValue(group.total, key: primaryKey)
                )
            }
        }
        .chartForegroundStyleScale(range: seriesPalette + [theme.danger, theme.textTertiary])
    }

    @ChartContentBuilder
    private func groupMedianMark(_ group: InsightGroup) -> some ChartContent {
        PointMark(
            x: .value("Group", group.category),
            y: .value("Median", group.median)
        )
        .symbol {
            Capsule()
                .fill(theme.accent)
                .frame(width: 30, height: 3)
        }
        .accessibilityLabel("\(group.category) range")
        .accessibilityValue(groupRangeAccessibilityValue(group))
    }

    private func groupRangeAccessibilityValue(_ group: InsightGroup) -> String {
        let median = formattedValue(group.median, key: primaryKey)
        let q1 = formattedValue(group.q1, key: primaryKey)
        let q3 = formattedValue(group.q3, key: primaryKey)
        let minimum = formattedValue(group.minimum, key: primaryKey)
        let maximum = formattedValue(group.maximum, key: primaryKey)
        return "Median \(median); middle half \(q1) to \(q3); full range \(minimum) to \(maximum)"
    }

    // MARK: - Periods

    private var periodCards: some View {
        VStack(spacing: Space.sm) {
            ForEach(result.periodDeltas ?? [], id: \.metricID) { delta in
                HStack(spacing: Space.md) {
                    Text(titleFor(delta.metricID))
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(delta.current.map { formattedValue($0, key: delta.metricID) } ?? "No data")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(delta.current == nil ? theme.textSecondary : theme.textPrimary)
                        HStack(spacing: 4) {
                            if delta.current == nil {
                                Text("no current-period data")
                                    .font(.system(size: 12, weight: .semibold))
                            } else if let percent = delta.percentChange,
                                      let previous = delta.previous {
                                Image(systemName: percent >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.system(size: 10, weight: .bold))
                                Text("\(abs(percent).formatted(.number.precision(.fractionLength(0...1))))% vs previous \(formattedValue(previous, key: delta.metricID))")
                                    .font(.system(size: 12, weight: .semibold))
                            } else if delta.previous == nil {
                                Text("no previous-period data")
                                    .font(.system(size: 12, weight: .semibold))
                            } else {
                                Text("previous period was zero; % change unavailable")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .foregroundStyle(deltaColor(delta))
                        Text("\(delta.currentSamples) current / \(delta.previousSamples) previous records")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(Space.md)
                .background(theme.surfaceElevated.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }

    /// Current vs preceding period as paired bars — the "Bars" option for a
    /// period question draws deltas, never the (absent) group payload.
    private var periodBars: some View {
        Chart {
            ForEach(result.periodDeltas ?? [], id: \.metricID) { delta in
                if let previous = delta.previous {
                    BarMark(
                        x: .value("Metric", titleFor(delta.metricID)),
                        y: .value("Value", previous)
                    )
                    .position(by: .value("Period", "Previous"))
                    .foregroundStyle(by: .value("Period", "Previous"))
                    .cornerRadius(3)
                    .accessibilityLabel("Previous \(titleFor(delta.metricID))")
                    .accessibilityValue(formattedValue(previous, key: delta.metricID))
                }
                if let current = delta.current {
                    BarMark(
                        x: .value("Metric", titleFor(delta.metricID)),
                        y: .value("Value", current)
                    )
                    .position(by: .value("Period", "Current"))
                    .foregroundStyle(by: .value("Period", "Current"))
                    .cornerRadius(3)
                    .accessibilityLabel("Current \(titleFor(delta.metricID))")
                    .accessibilityValue(formattedValue(current, key: delta.metricID))
                }
            }
        }
        .chartForegroundStyleScale(["Previous": theme.zone1.opacity(0.7), "Current": theme.accent])
        .chartLegend(.visible)
        .chartYAxis { formattedYAxis(primaryKind) }
    }

    /// Five-number summary for a distribution's "Ranges" chart: min–max
    /// whiskers, q1–q3 box, median rule.
    private func distributionBox(_ summary: InsightDistributionSummary) -> some View {
        let title = result.series.first.map { titleFor($0.metricID) } ?? "Values"
        return Chart {
            RuleMark(
                x: .value("Metric", title),
                yStart: .value("Min", summary.minimum),
                yEnd: .value("Max", summary.maximum)
            )
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(theme.textTertiary)
            .accessibilityHidden(true)
            RectangleMark(
                x: .value("Metric", title),
                yStart: .value("Q1", summary.q1),
                yEnd: .value("Q3", summary.q3),
                width: .ratio(0.45)
            )
            .foregroundStyle(theme.accent.opacity(0.3))
            .accessibilityHidden(true)
            PointMark(
                x: .value("Metric", title),
                y: .value("Median", summary.median)
            )
            .symbol {
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 36, height: 3)
            }
            .accessibilityLabel("\(title) distribution")
            .accessibilityValue(
                "Median \(formattedValue(summary.median, key: primaryKey)); "
                    + "middle half \(formattedValue(summary.q1, key: primaryKey)) to "
                    + "\(formattedValue(summary.q3, key: primaryKey)); "
                    + "full range \(formattedValue(summary.minimum, key: primaryKey)) to "
                    + "\(formattedValue(summary.maximum, key: primaryKey))"
            )
        }
        .chartYAxis { formattedYAxis(primaryKind) }
    }

    private func deltaColor(_ delta: InsightPeriodDelta) -> Color {
        guard delta.percentChange != nil else { return theme.textSecondary }
        // Neutral coloring on purpose: more isn't automatically better
        // (more resting HR isn't a win), so direction gets an arrow, not a
        // value judgment.
        return theme.textPrimary
    }

    // MARK: - Distribution

    private var histogramChart: some View {
        Chart {
            ForEach(result.histogram ?? [], id: \.lowerBound) { bin in
                BarMark(
                    x: .value("Range", (bin.lowerBound + bin.upperBound) / 2),
                    y: .value("Count", bin.count),
                    width: .automatic
                )
                .foregroundStyle(theme.accent)
                .cornerRadius(2)
                .accessibilityLabel(
                    "\(formattedValue(bin.lowerBound, key: primaryKey)) to "
                        + "\(formattedValue(bin.upperBound, key: primaryKey))"
                )
                .accessibilityValue("\(bin.count) \(distributionCountNoun.lowercased())")
            }
        }
        .chartYAxisLabel(alignment: .leading) { axisTitle(distributionCountNoun) }
        .chartXAxisLabel(alignment: .center) {
            if let first = result.series.first { axisTitle(titleFor(first.metricID)) }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(formattedValue(doubleValue, key: primaryKey))
                            .font(.system(size: 9))
                    }
                }
            }
        }
    }

    // MARK: - Axis helpers

    /// Four deliberately different patterns match the four-series recipe cap.
    /// Symbols carry the same identity in the legend, so color is never the
    /// only way to follow a line.
    private func lineStyle(for index: Int) -> StrokeStyle {
        let dash: [CGFloat] = switch index % 4 {
        case 0: []
        case 1: [7, 3]
        case 2: [2, 3]
        default: [8, 3, 2, 3]
        }
        return StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dash)
    }

    /// Counts are bucket totals, not a continuously measured curve. Stepping
    /// preserves the held bucket value; physiological and other measurements
    /// keep the product's monotone visual language without inventing extrema.
    private func interpolationMethod(for key: String) -> InterpolationMethod {
        let kind = valueKindFor(key)
            ?? InsightMetricCatalog.definition(for: InsightOperand.metricID(fromKey: key))?.valueKind
        switch kind {
        case .count, .sessions, .trainingDays, .reps, .steps:
            return .stepEnd
        default:
            return .monotone
        }
    }

    /// Measurement lines stop at a missing calendar bucket instead of
    /// visually asserting continuity across an unrecorded day/week. Exact
    /// event tallies are grid-completed upstream, and session points are an
    /// intentionally irregular sequence, so neither is split here.
    private func segmentedPoints(
        for series: InsightSeries
    ) -> [SegmentedSeriesPoint] {
        guard bucket != .session else {
            return series.points.map { SegmentedSeriesPoint(point: $0, segment: 0) }
        }
        let descriptor = InsightMetricCatalog.definition(
            for: InsightOperand.metricID(fromKey: series.metricID)
        )
        guard descriptor?.zeroFillPolicy == .never else {
            return series.points.map { SegmentedSeriesPoint(point: $0, segment: 0) }
        }
        let points = series.points.sorted { $0.date < $1.date }
        let component: Calendar.Component = bucket == .weekly ? .weekOfYear : .day
        let calendar = Calendar.current
        var segment = 0
        var prior: Date?
        return points.map { point in
            if let prior,
               let expected = calendar.date(byAdding: component, value: 1, to: prior),
               anchorForChart(expected) != anchorForChart(point.date) {
                segment += 1
            }
            prior = point.date
            return SegmentedSeriesPoint(point: point, segment: segment)
        }
    }

    private func anchorForChart(_ date: Date) -> Date {
        let calendar = Calendar.current
        if bucket == .weekly {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
        return calendar.startOfDay(for: date)
    }

    /// Time charts never drop their date scale — a trend with no x labels is
    /// shape without time. Compact cards get three sparse marks; spans past
    /// ~6 months label by month + year instead of month + day.
    private var dateXAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: compact ? 3 : 5)) { value in
            AxisGridLine()
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    Text(date, format: xDateFormat)
                        .font(.system(size: 9))
                }
            }
        }
    }

    private var xDateFormat: Date.FormatStyle {
        let dates = result.series.flatMap { $0.points.map(\.date) }
        guard let first = dates.min(), let last = dates.max(),
              last.timeIntervalSince(first) > 200 * 86_400 else {
            return .dateTime.month(.abbreviated).day()
        }
        return .dateTime.month(.abbreviated).year(.twoDigits)
    }

    /// Names the y axis when nothing else on the chart does — multi-series
    /// charts already name every line in the legend.
    @ViewBuilder
    private var singleSeriesYTitle: some View {
        if result.series.count == 1, let first = result.series.first {
            axisTitle(titleFor(first.metricID))
        }
    }

    private func axisTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
    }

    private func formattedYAxis(
        _ kind: InsightValueKind?,
        key: String? = nil
    ) -> some AxisContent {
        AxisMarks(position: .trailing) { value in
            AxisGridLine()
            AxisValueLabel {
                if let doubleValue = value.as(Double.self) {
                    Text(InsightValueFormat.string(
                        doubleValue,
                        kind: kind,
                        weightUnit: weightUnitFor(key ?? primaryKey),
                        modality: modalityFor(key ?? primaryKey)
                    ))
                        .font(.system(size: 9))
                }
            }
        }
    }
}

extension Double {
    var insightFormatted: String {
        if abs(self) >= 10_000 {
            return (self / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "k"
        }
        return formatted(.number.precision(.fractionLength(0...1)))
    }
}
