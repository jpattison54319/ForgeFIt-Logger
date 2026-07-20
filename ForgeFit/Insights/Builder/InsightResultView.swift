import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Full result surface for one recipe: recommended (or chosen) chart, the
/// deterministic observation line, coverage + provenance badges, warnings
/// rendered as first-class states, and the Advanced panel with the raw
/// statistics. Works for saved cards and live builder previews alike.
struct InsightResultView: View {
    @Environment(\.theme) private var theme

    let recipe: InsightRecipe
    let result: InsightResult
    /// Resolves display titles (exercise names for scoped metrics).
    let titleFor: (String) -> String
    /// Exercise-scoped strength metrics may override the global mass unit.
    var weightUnitFor: (String) -> WeightUnit? = { _ in nil }
    var showsAdvanced = true

    @State private var advancedExpanded = false
    @State private var dataExpanded = false

    private var chartKind: InsightChartKind? {
        let kind = recipe.chart
            ?? InsightCompatibilityEngine.validate(recipe, descriptors: InsightMetricCatalog.descriptors(covering: recipe)).allowedCharts.first
        // When the baseline is too thin (or too zero-dominated) to index, the
        // engine returns the RAW series with a warning — mixed units must not
        // share one axis then.
        if kind == .baselineIndexLines, indexingFellBackToRaw {
            return .smallMultiples
        }
        // Shared semantic units do not guarantee a readable shared scale.
        // If one series is under one tenth of another's robust magnitude, a
        // shared axis would visually erase it.
        if kind == .sharedUnitOverlay, hasSevereScaleImbalance {
            return .smallMultiples
        }
        if kind == .groupedBars,
           recipe.shape == .periodComparison,
           hasSeverePeriodScaleImbalance {
            return .periodComparisonCards
        }
        if hasMixedMassDisplayUnits {
            if kind == .sharedUnitOverlay { return .smallMultiples }
            if kind == .groupedBars, recipe.shape == .periodComparison {
                return .periodComparisonCards
            }
        }
        // Pace is stored in the coherent base unit seconds/metre, but users
        // do not read every activity with the same denominator. A rower is
        // /500 m and a swimmer /100 m. One visual axis cannot truthfully wear
        // both labels even though the raw values are convertible.
        if InsightDisplayUnitPolicy.hasMixedPaceDenominators(recipe) {
            if kind == .sharedUnitOverlay { return .smallMultiples }
            if kind == .groupedBars, recipe.shape == .periodComparison {
                return .periodComparisonCards
            }
        }
        return kind
    }

    private var hasMixedMassDisplayUnits: Bool {
        let units = recipe.operandKeys.compactMap { key -> String? in
            let valueKind = valueKindFor(key)
            guard valueKind == .massKilograms || valueKind == .massPerMinute else {
                return nil
            }
            return (weightUnitFor(key) ?? Fmt.unit).rawValue
        }
        return Set(units).count > 1
    }

    private var hasSevereScaleImbalance: Bool {
        let magnitudes = result.series.compactMap { series -> Double? in
            let values = series.points.map { abs($0.value) }.filter { $0 > 0 }.sorted()
            guard !values.isEmpty else { return nil }
            let index = min(values.count - 1, Int((Double(values.count - 1) * 0.9).rounded()))
            return values[index]
        }
        guard let smallest = magnitudes.min(), let largest = magnitudes.max(), smallest > 0 else {
            return false
        }
        return largest / smallest > 10
    }

    private var hasSeverePeriodScaleImbalance: Bool {
        let magnitudes = (result.periodDeltas ?? []).compactMap { delta -> Double? in
            [delta.current, delta.previous]
                .compactMap { $0 }
                .map(abs)
                .filter { $0 > 0 }
                .max()
        }
        guard let smallest = magnitudes.min(), let largest = magnitudes.max(), smallest > 0 else {
            return false
        }
        return largest / smallest > 10
    }

    private var presentationState: InsightPresentationState {
        InsightPresentationState.resolve(
            recipe: recipe, result: result, chartKind: chartKind
        )
    }

    /// The recipe asked for indexed lines but the engine refused and returned
    /// native-unit series — everything downstream must treat them as raw.
    private var indexingFellBackToRaw: Bool {
        result.warnings.contains(.insufficientBaseline)
            || result.warnings.contains(.zeroDominatedIndexAnchor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            switch presentationState {
            case .invalidRecipe:
                EmptyStateCard(
                    title: "Insight needs attention",
                    message: "Its saved configuration is no longer a valid analysis. Edit it to choose supported metrics, grouping, and chart options.",
                    systemImage: "exclamationmark.triangle"
                )
            case .empty:
                EmptyStateCard(
                    title: "No data in this range",
                    message: "Log training (or connect the Health metrics involved) and this insight fills in.",
                    systemImage: "chart.xyaxis.line"
                )
            case .insufficientHistory:
                EmptyStateCard(
                    title: "More history needed",
                    message: nil,
                    systemImage: "calendar.badge.clock"
                )
            case .insufficientTrend:
                EmptyStateCard(
                    title: "More values needed",
                    message: nil,
                    systemImage: "chart.line.uptrend.xyaxis"
                )
            case .insufficientPairs:
                EmptyStateCard(
                    title: "Not enough overlap yet",
                    message: nil,
                    systemImage: "hourglass"
                )
            case .constantRelationship(let key):
                EmptyStateCard(
                    title: "No variation to compare",
                    message: "\(titleFor(key)) had one repeated value across the matched \(bucketNoun.lowercased()), so correlation is undefined.",
                    systemImage: "equal.circle"
                )
            case .insufficientDistribution:
                EmptyStateCard(
                    title: "More values needed",
                    message: nil,
                    systemImage: "chart.bar.xaxis"
                )
            case .constantDistribution(let value, let count):
                EmptyStateCard(
                    title: "Every value was the same",
                    message: "All \(count) values were \(formatted(value, key: recipe.operandKeys.first ?? "")).",
                    systemImage: "equal.circle"
                )
            case .insufficientGroups:
                EmptyStateCard(
                    title: "Not enough comparable groups",
                    message: "At least two groups need enough \(bucketNoun.lowercased()) before a comparison is shown.",
                    systemImage: "square.grid.2x2"
                )
            case .chart(let kind):
                InsightChartView(
                    kind: kind,
                    result: result,
                    titleFor: titleFor,
                    valueKindFor: valueKindFor,
                    weightUnitFor: weightUnitFor,
                    modalityFor: modalityFor,
                    compact: !showsAdvanced,
                    accessibilitySummary: summary,
                    height: showsAdvanced ? 220 : 130,
                    bucket: recipe.bucket,
                    distributionCountNoun: bucketNoun
                )
            }

            if presentationState.showsSummary {
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = presentationState.progressText(bucketNoun: bucketNoun.lowercased()) {
                badge(icon: "hourglass", text: progress, tint: theme.textSecondary)
            } else if presentationState.showsSummary {
                badges
            }

            if showsAdvanced, presentationState.hasInspectableData {
                dataDisclosure
            }

            if !visibleWarningLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(visibleWarningLines, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.warmup)
                                .padding(.top, 2)
                            Text(line)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if showsAdvanced, result.relationship?.spearman != nil {
                advancedPanel
            }
        }
    }

    private var bucketNoun: String {
        switch recipe.bucket {
        case .session: return "Sessions"
        case .daily: return "Days"
        case .weekly: return "Weeks"
        }
    }

    private var summary: String {
        InsightExplanationBuilder.summary(
            for: result,
            shape: recipe.shape,
            primaryTitle: titleFor(recipe.operandKeys.first ?? ""),
            comparisonTitle: recipe.operandKeys.dropFirst().first.map(titleFor),
            tallyMetricIDs: Set(recipe.operands.filter {
                InsightMetricCatalog.definition(for: $0.metricID)?.zeroFillPolicy == .zeroWhenAbsent
            }.map(\.key)),
            seriesTitles: Dictionary(
                recipe.operandKeys.map { ($0, titleFor($0)) },
                uniquingKeysWith: { first, _ in first }
            ),
            bucketNoun: bucketNoun.lowercased(),
            valueFormatter: { key, value in
                formatted(value, key: key)
            }
        )
    }

    /// Baseline-indexed series are dimensionless (percent of own baseline) —
    /// never dress an index of 112 up as kilograms. But when indexing fell
    /// back to raw, the values ARE kilograms again and must say so. Accepts
    /// operand keys.
    private func valueKindFor(_ key: String) -> InsightValueKind? {
        if recipe.normalization == .baselineIndex, !indexingFellBackToRaw { return nil }
        return InsightMetricCatalog.definition(for: InsightOperand.metricID(fromKey: key))?.valueKind
    }

    private func formatted(_ value: Double, key: String) -> String {
        InsightValueFormat.string(
            value,
            kind: valueKindFor(key),
            weightUnit: weightUnitFor(key),
            modality: modalityFor(key)
        )
    }

    private func modalityFor(_ key: String) -> String? {
        recipe.operands.first(where: { $0.key == key })?.modality
    }

    // MARK: - Badges

    private var badges: some View {
        HStack(spacing: Space.sm) {
            if recipe.shape != .relationship {
                badge(
                    icon: "square.grid.2x2",
                    text: coverageText,
                    tint: result.coverage.fraction < InsightQueryEngine.sparseCoverageThreshold ? theme.warmup : theme.textSecondary
                )
            }
            badge(icon: provenanceIcon, text: provenanceText, tint: theme.textSecondary)
            if let pairs = result.coverage.pairedSamples {
                badge(
                    icon: "link",
                    text: "\(pairs) matched \(bucketNoun.lowercased())",
                    tint: theme.textSecondary
                )
            }
        }
    }

    private var coverageText: String {
        if let expected = result.coverage.expectedSourceBuckets,
           let populated = result.coverage.populatedSourceBuckets {
            return "\(populated)/\(expected) recorded days"
        }
        return recipe.bucket == .session
            ? "\(result.coverage.populatedBuckets) sessions"
            : "\(result.coverage.populatedBuckets)/\(result.coverage.expectedBuckets) \(recipe.bucket == .daily ? "days" : "weeks")"
    }

    private var provenanceIcon: String {
        switch result.provenance {
        case .measured: "checkmark.seal"
        case .estimated: "wand.and.stars"
        case .imported: "square.and.arrow.down"
        case .mixed: "circle.grid.2x1"
        }
    }

    private var provenanceText: String {
        switch result.provenance {
        case .measured: "Measured"
        case .estimated: "Estimated"
        case .imported: "Imported"
        case .mixed: "Mixed sources"
        }
    }

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceElevated)
        .clipShape(Capsule())
    }

    private var warningLines: [String] {
        result.warnings.compactMap { warning in
            switch warning {
            case .belowLabelThreshold(let found, let needed):
                return "\(found) pairs — exploratory only until \(needed)."
            case .sparseCoverage(let fraction):
                return "Data covers \(Int(fraction * 100))% of this range; gaps weaken the picture."
            case .mostlyEstimated:
                return "Built mostly from estimated values."
            case .neutralInterval:
                return "The uncertainty range includes \"no relationship\" — treat any pattern as unconfirmed."
            case .outlierSensitive:
                return "A few unusual points drive most of this pattern (crosses on the chart)."
            case .insufficientBaseline:
                return "Not enough early data to index against a baseline — showing raw values."
            case .zeroDominatedIndexAnchor:
                let base = "Mostly-empty \(recipe.bucket == .weekly ? "weeks" : "days") can't anchor one shared scale — each metric keeps its own units."
                return recipe.bucket == .daily ? base + " Week grouping usually can." : base
            case .insufficientDistribution(let found, let needed):
                return "\(found) values so far; \(needed) needed for a distribution."
            case .insufficientTrendSamples:
                return nil
            case .constantDistribution:
                return nil
            case .constantRelationship:
                return nil
            case .groupsBelowMinimum(let dropped, let needed):
                return "\(dropped) \(dropped == 1 ? "group has" : "groups have") fewer than \(needed) \(bucketNoun.lowercased()) and \(dropped == 1 ? "isn't" : "aren't") shown."
            case .meanIndexedBaseline:
                return nil   // the chart caption explains the scale
            case .insufficientHistory:
                return nil   // the summary line carries the refusal
            case .emptySeries(let key):
                return "No \(titleFor(key)) data in this range — it isn't on the chart."
            case .invalidRecipe, .insufficientPairs, .emptyResult:
                return nil   // rendered as full states above
            }
        }
    }

    /// Compact cards already carry the takeaway and evidence badges. Keep only
    /// warnings that change what the chart is displaying; fuller interpretation
    /// remains available on the detail surface.
    private var visibleWarningLines: [String] {
        guard !showsAdvanced else { return warningLines }
        guard presentationState.showsSummary else { return [] }
        return result.warnings.compactMap { warning in
            switch warning {
            case .insufficientBaseline:
                return "Not enough early data to index against a baseline — showing raw values."
            case .zeroDominatedIndexAnchor:
                let base = "Mostly-empty \(recipe.bucket == .weekly ? "weeks" : "days") can't anchor one shared scale — each metric keeps its own units."
                return recipe.bucket == .daily ? base + " Week grouping usually can." : base
            case .groupsBelowMinimum(let dropped, let needed):
                return "\(dropped) \(dropped == 1 ? "group has" : "groups have") fewer than \(needed) \(bucketNoun.lowercased()) and \(dropped == 1 ? "isn't" : "aren't") shown."
            case .emptySeries(let key):
                return "No \(titleFor(key)) data in this range — it isn't on the chart."
            default:
                return nil
            }
        }
    }

    // MARK: - Advanced

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { advancedExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Advanced")
                        .font(.system(size: 13, weight: .bold))
                    Image(systemName: advancedExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityIdentifier("insight-advanced-toggle")

            if advancedExpanded, let relationship = result.relationship {
                VStack(alignment: .leading, spacing: 6) {
                    if let spearman = relationship.spearman {
                        advancedRow("Rank correlation (Spearman)", spearman.formatted(.number.precision(.fractionLength(2))))
                    }
                    if let interval = relationship.interval {
                        advancedRow(
                            "95% interval (block bootstrap)",
                            "\(interval.lowerBound.formatted(.number.precision(.fractionLength(2)))) to \(interval.upperBound.formatted(.number.precision(.fractionLength(2))))"
                        )
                    }
                    if let trend = relationship.trend {
                        advancedRow("Robust slope (Theil–Sen)", trend.slope.formatted(.number.precision(.significantDigits(3))))
                    }
                    if let sensitivity = relationship.sensitivitySpearman {
                        advancedRow("Excluding flagged points", sensitivity.formatted(.number.precision(.fractionLength(2))))
                    }
                    if let lag = recipe.lag, lag.count > 0 {
                        advancedRow("Lag", "\(lag.count) \(lag.unit == .days ? "day" : "week")\(lag.count == 1 ? "" : "s")")
                    }
                    Text(relationshipPopulationText)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                    Text("Exploratory description of your own history — not a causal claim, and not health advice.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, 2)
                }
            }
        }
        .padding(Space.md)
        .background(theme.surfaceElevated.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func advancedRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(theme.textPrimary)
        }
    }

    private var relationshipPopulationText: String {
        InsightRelationshipPopulationCopy.text(
            recipe: recipe,
            bucketNoun: bucketNoun.lowercased(),
            titleFor: titleFor
        )
    }

    private var dataDisclosure: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { dataExpanded.toggle() }
            } label: {
                HStack {
                    Label("View data", systemImage: "tablecells")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Image(systemName: dataExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(theme.textSecondary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(dataExpanded ? "Expanded" : "Collapsed")

            if dataExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(dataRows.prefix(80)) { row in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Text(row.label)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                            Spacer(minLength: Space.md)
                            Text(row.value)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.textPrimary)
                                .multilineTextAlignment(.trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if dataRows.count > 80 {
                        Text("Showing the first 80 of \(dataRows.count) rows.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .padding(Space.md)
                .background(theme.surfaceElevated.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }

    private struct DataRow: Identifiable {
        let id: String
        let label: String
        let value: String
    }

    private var dataRows: [DataRow] {
        switch recipe.shape {
        case .trend, .distribution:
            return result.series.flatMap { series in
                series.points.map { point in
                    DataRow(
                        id: "\(series.metricID)-\(point.date.timeIntervalSinceReferenceDate)",
                        label: "\(titleFor(series.metricID)) · \(point.date.formatted(date: .abbreviated, time: .omitted))",
                        value: formatted(point.value, key: series.metricID)
                    )
                }
            }
        case .relationship:
            let outcome = result.series.first?.metricID ?? ""
            let exposure = result.series.dropFirst().first?.metricID ?? ""
            return (result.relationship?.pairs ?? []).map { pair in
                DataRow(
                    id: "pair-\(pair.date.timeIntervalSinceReferenceDate)",
                    label: pair.date.formatted(date: .abbreviated, time: .omitted),
                    value: "\(titleFor(exposure)): \(formatted(pair.x, key: exposure)); \(titleFor(outcome)): \(formatted(pair.y, key: outcome))"
                )
            }
        case .groupComparison:
            return (result.groups ?? []).map { group in
                DataRow(
                    id: "group-\(group.category)",
                    label: group.category,
                    value: "Median \(formatted(group.median, key: recipe.operandKeys.first ?? "")), n=\(group.bucketCount)"
                )
            }
        case .periodComparison:
            return (result.periodDeltas ?? []).map { delta in
                let current = delta.current.map { formatted($0, key: delta.metricID) } ?? "No data"
                let previous = delta.previous.map { formatted($0, key: delta.metricID) } ?? "No data"
                return DataRow(
                    id: "period-\(delta.metricID)",
                    label: titleFor(delta.metricID),
                    value: "Current \(current); previous \(previous)"
                )
            }
        }
    }
}

/// Explains the exact population the relationship engine paired. This copy is
/// a math contract: measurements always require recorded values; zero-capable
/// training totals use their active intersection by default and include
/// structural zeros only when the recipe explicitly asks for them.
enum InsightRelationshipPopulationCopy {
    static func text(
        recipe: InsightRecipe,
        bucketNoun: String,
        titleFor: (String) -> String
    ) -> String {
        let descriptors = InsightMetricCatalog.descriptors(covering: recipe)
        let policies = recipe.operands.map { operand in
            descriptors.first(where: { $0.id == operand.metricID })?.zeroFillPolicy ?? .never
        }
        guard recipe.bucket != .session, policies.count == 2 else {
            return bothRecorded(bucketNoun)
        }

        let populations = InsightCompatibilityEngine.allowedRelationshipPopulations(
            for: recipe,
            descriptors: descriptors
        )
        let population = InsightCompatibilityEngine.resolvedRelationshipPopulation(
            for: recipe,
            descriptors: descriptors
        )
        if !populations.isEmpty, population == .activeBucketsOnly {
            let tallyTitles = policies.indices.compactMap { index in
                policies[index] == .zeroWhenAbsent
                    ? titleFor(recipe.operands[index].key).lowercased()
                    : nil
            }
            let subject = tallyTitles.count == 1
                ? (tallyTitles.first ?? "training")
                : "both logged totals"
            return "Population: matched \(bucketNoun) with recorded values for both metrics; \(bucketNoun) without \(subject) were excluded."
        }

        let tallyIndices = policies.indices.filter { policies[$0] == .zeroWhenAbsent }
        switch tallyIndices.count {
        case 2:
            return "Population: \(bucketNoun) where either logged total existed; the other absent logged total counted as zero."
        case 1:
            let tallyIndex = tallyIndices[0]
            let measurementIndex = tallyIndex == 0 ? 1 : 0
            let tallyTitle = titleFor(recipe.operands[tallyIndex].key)
            let measurementTitle = titleFor(recipe.operands[measurementIndex].key)
            return "Population: matched \(bucketNoun) where \(measurementTitle) had a recorded value; an absent \(tallyTitle.lowercased()) total counted as zero."
        default:
            return bothRecorded(bucketNoun)
        }
    }

    private static func bothRecorded(_ bucketNoun: String) -> String {
        "Population: matched \(bucketNoun) where both metrics had a recorded value. Missing readings were not treated as zero."
    }
}

enum InsightDisplayUnitPolicy {
    static func hasMixedPaceDenominators(_ recipe: InsightRecipe) -> Bool {
        let families = recipe.operands.compactMap { operand -> String? in
            guard InsightMetricCatalog.definition(for: operand.metricID)?.valueKind == .pace else {
                return nil
            }
            switch operand.modality.map({ CardioKind.from(modality: $0) }) {
            case .row: return "500m"
            case .swim: return "100m"
            default: return "distancePreference"
            }
        }
        return Set(families).count > 1
    }
}

enum InsightPresentationState: Equatable {
    case invalidRecipe
    case empty
    case insufficientHistory(found: Int, needed: Int)
    case insufficientTrend(found: Int, needed: Int)
    case insufficientPairs(found: Int, needed: Int)
    case constantRelationship(metricID: String)
    case insufficientDistribution(found: Int, needed: Int)
    case constantDistribution(value: Double, count: Int)
    case insufficientGroups
    case chart(InsightChartKind)

    static func resolve(
        recipe: InsightRecipe,
        result: InsightResult,
        chartKind: InsightChartKind?
    ) -> InsightPresentationState {
        if result.warnings.contains(.invalidRecipe) { return .invalidRecipe }
        if result.warnings.contains(.emptyResult) { return .empty }
        if let warning = result.warnings.first(where: {
            if case .insufficientHistory = $0 { return true }
            return false
        }), case .insufficientHistory(_, let found, let needed) = warning {
            return .insufficientHistory(found: found, needed: needed)
        }
        if let warning = result.warnings.first(where: {
            if case .insufficientTrendSamples = $0 { return true }
            return false
        }), case .insufficientTrendSamples(_, let found, let needed) = warning {
            return .insufficientTrend(found: found, needed: needed)
        }
        if recipe.shape == .trend,
           (result.series.map(\.points.count).max() ?? 0) < 2 {
            return .insufficientTrend(
                found: result.series.map(\.points.count).max() ?? 0,
                needed: 2
            )
        }
        if let warning = result.warnings.first(where: {
            if case .insufficientPairs = $0 { return true }
            return false
        }), case .insufficientPairs(let found, let needed) = warning {
            return .insufficientPairs(found: found, needed: needed)
        }
        if let warning = result.warnings.first(where: {
            if case .constantRelationship = $0 { return true }
            return false
        }), case .constantRelationship(let key) = warning {
            return .constantRelationship(metricID: key)
        }
        if let warning = result.warnings.first(where: {
            if case .insufficientDistribution = $0 { return true }
            return false
        }), case .insufficientDistribution(let found, let needed) = warning {
            return .insufficientDistribution(found: found, needed: needed)
        }
        if let warning = result.warnings.first(where: {
            if case .constantDistribution = $0 { return true }
            return false
        }), case .constantDistribution(let value) = warning {
            return .constantDistribution(
                value: value, count: result.series.first?.points.count ?? 0
            )
        }
        if recipe.shape == .groupComparison, (result.groups?.count ?? 0) < 2 {
            return .insufficientGroups
        }
        guard let chartKind else { return .invalidRecipe }
        let hasPayload: Bool
        switch chartKind {
        case .lineTrend, .barTrend, .sharedUnitOverlay, .smallMultiples, .baselineIndexLines:
            hasPayload = result.series.contains { !$0.points.isEmpty }
        case .scatterWithTrend:
            hasPayload = !(result.relationship?.pairs.isEmpty ?? true)
        case .groupedBars:
            hasPayload = !(result.periodDeltas?.isEmpty ?? true)
                || !(result.groups?.isEmpty ?? true)
        case .boxSummary:
            hasPayload = result.distributionSummary != nil
                || !(result.groups?.isEmpty ?? true)
        case .donutShare:
            hasPayload = !(result.groups?.isEmpty ?? true)
        case .periodComparisonCards:
            hasPayload = !(result.periodDeltas?.isEmpty ?? true)
        case .histogram:
            hasPayload = !(result.histogram?.isEmpty ?? true)
        }
        return hasPayload ? .chart(chartKind) : .empty
    }

    var hasInspectableData: Bool {
        if case .invalidRecipe = self { return false }
        if case .empty = self { return false }
        return true
    }

    var showsSummary: Bool {
        if case .chart = self { return true }
        return false
    }

    func progressText(bucketNoun: String) -> String? {
        switch self {
        case .insufficientHistory(let found, let needed):
            return "\(found)/\(needed) days to create insight"
        case .insufficientTrend(let found, let needed),
             .insufficientDistribution(let found, let needed):
            return "\(found)/\(needed) values to create insight"
        case .insufficientPairs(let found, let needed):
            return "\(found)/\(needed) matched \(bucketNoun) to create insight"
        default:
            return nil
        }
    }
}
