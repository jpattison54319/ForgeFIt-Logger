import Foundation

/// Deterministic exact-window comparison for experiment outcomes. Data
/// adapters own observation production; this engine owns membership,
/// aggregation, normalization, coverage, and deltas.
public enum ExperimentComparisonEngine {
    private static let durationEqualityTolerance: TimeInterval = 0.001

    /// Resolves an immediately preceding reference with exactly the same
    /// elapsed duration as the current interval.
    public static func previousEqualWindow(
        for currentWindow: ExperimentWindow
    ) throws -> ExperimentWindow {
        try validate(version: currentWindow.version)
        let duration = currentWindow.duration
        return try ExperimentWindow(
            start: currentWindow.start.addingTimeInterval(-duration),
            end: currentWindow.start,
            timeZoneIdentifier: currentWindow.timeZoneIdentifier
        )
    }

    /// Builds the honest live comparison: only elapsed experiment time is
    /// compared, capped at the planned end, against an equal elapsed period.
    public static func activeElapsedRequest(
        for plannedWindow: ExperimentWindow,
        now: Date
    ) throws -> ExperimentComparisonRequest {
        try validate(version: plannedWindow.version)
        guard now > plannedWindow.start else {
            throw ExperimentComparisonError.noElapsedExperimentTime
        }
        let elapsedEnd = min(now, plannedWindow.end)
        let elapsedWindow = try ExperimentWindow(
            start: plannedWindow.start,
            end: elapsedEnd,
            timeZoneIdentifier: plannedWindow.timeZoneIdentifier
        )
        return ExperimentComparisonRequest(
            currentWindow: elapsedWindow,
            reference: .previousEqualPeriod
        )
    }

    public static func resolvedReferenceWindow(
        for request: ExperimentComparisonRequest
    ) throws -> ExperimentWindow {
        try validate(version: request.version)
        try validate(version: request.currentWindow.version)

        let referenceWindow: ExperimentWindow
        switch request.reference {
        case .previousEqualPeriod:
            referenceWindow = try previousEqualWindow(for: request.currentWindow)
        case let .experiment(_, window), let .custom(window):
            try validate(version: window.version)
            referenceWindow = window
        }

        guard !overlaps(request.currentWindow, referenceWindow) else {
            throw ExperimentComparisonError.overlappingWindows
        }
        return referenceWindow
    }

    public static func evaluate(
        request: ExperimentComparisonRequest,
        selections: [ExperimentMetricSelection],
        observations: [ExperimentMetricObservation]
    ) throws -> ExperimentResult {
        let referenceWindow = try resolvedReferenceWindow(for: request)
        try validate(selections: selections)
        for observation in observations {
            try validate(version: observation.version)
        }

        let metrics = selections.map { selection in
            let matching = observations.filter { $0.metric == selection.key }
            let current = periodAggregate(
                matching,
                selection: selection,
                window: request.currentWindow
            )
            let reference = periodAggregate(
                matching,
                selection: selection,
                window: referenceWindow
            )

            let rawAbsolute = absoluteChange(
                current: current.value,
                reference: reference.value
            )
            let rawPercent = percentChange(
                current: current.value,
                reference: reference.value
            )
            let perDayAbsolute = absoluteChange(
                current: current.perDayValue,
                reference: reference.perDayValue
            )
            let perDayPercent = percentChange(
                current: current.perDayValue,
                reference: reference.perDayValue
            )
            let basis = comparisonBasis(
                selection: selection,
                currentWindow: request.currentWindow,
                referenceWindow: referenceWindow
            )

            return ExperimentMetricDelta(
                selection: selection,
                current: current,
                reference: reference,
                rawAbsoluteChange: rawAbsolute,
                rawPercentChange: rawPercent,
                perDayAbsoluteChange: perDayAbsolute,
                perDayPercentChange: perDayPercent,
                comparisonBasis: basis,
                comparisonAbsoluteChange: basis == .perDay ? perDayAbsolute : rawAbsolute,
                comparisonPercentChange: basis == .perDay ? perDayPercent : rawPercent
            )
        }

        return ExperimentResult(
            currentWindow: request.currentWindow,
            referenceWindow: referenceWindow,
            reference: request.reference,
            metrics: metrics
        )
    }

    // MARK: - Validation

    private static func validate(version: Int) throws {
        guard version == ExperimentAnalysisContract.currentVersion else {
            throw ExperimentComparisonError.invalidVersion(version)
        }
    }

    private static func validate(
        selections: [ExperimentMetricSelection]
    ) throws {
        var keys = Set<ExperimentMetricKey>()
        for selection in selections {
            try validate(version: selection.version)
            guard !selection.metricID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExperimentComparisonError.emptyMetricID
            }
            guard keys.insert(selection.key).inserted else {
                throw ExperimentComparisonError.duplicateMetric(selection.key)
            }
            if selection.normalization == .perDay,
               !selection.aggregation.supportsPerDayNormalization {
                throw ExperimentComparisonError.unsupportedPerDayNormalization(selection.key)
            }
            if selection.missingValuePolicy == .zeroWhenAbsent,
               selection.aggregation != .sum {
                throw ExperimentComparisonError.unsupportedZeroWhenAbsent(selection.key)
            }
        }
    }

    private static func overlaps(
        _ lhs: ExperimentWindow,
        _ rhs: ExperimentWindow
    ) -> Bool {
        lhs.start < rhs.end && rhs.start < lhs.end
    }

    // MARK: - Period aggregation

    private struct ValidObservation {
        let timestamp: Date
        let value: Double
        let provenance: InsightProvenance
        let group: String?
        let weight: Double
    }

    private static func periodAggregate(
        _ observations: [ExperimentMetricObservation],
        selection: ExperimentMetricSelection,
        window: ExperimentWindow
    ) -> ExperimentPeriodAggregate {
        let windowed = observations.filter { window.contains($0.timestamp) }
        let valid = windowed.compactMap {
            validObservation($0, aggregation: selection.aggregation)
        }
        let aggregateValue: Double?
        if valid.isEmpty {
            // Zero is factual only when no event occurred. If an event row
            // exists but its measurement is nil/non-finite, the value is
            // unknown and must not be silently converted to zero.
            aggregateValue = selection.missingValuePolicy == .zeroWhenAbsent
                && windowed.isEmpty ? 0 : nil
        } else {
            aggregateValue = aggregate(valid, using: selection.aggregation)
        }
        let perDayValue = selection.aggregation.supportsPerDayNormalization
            ? aggregateValue.map { $0 / window.elapsedDays }
            : nil
        let summary = numericSummary(valid.map(\.value))
        let provenance = rollupProvenance(valid.map(\.provenance))

        var byGroup: [String: [ValidObservation]] = [:]
        for observation in valid {
            guard let group = observation.group,
                  !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            byGroup[group, default: []].append(observation)
        }
        let groups = byGroup.keys.sorted().compactMap { group -> ExperimentGroupSummary? in
            guard let rows = byGroup[group],
                  let summary = numericSummary(rows.map(\.value)),
                  let aggregateValue = aggregate(rows, using: selection.aggregation),
                  let provenance = rollupProvenance(rows.map(\.provenance)) else {
                return nil
            }
            return ExperimentGroupSummary(
                group: group,
                aggregateValue: aggregateValue,
                summary: summary,
                provenance: provenance
            )
        }

        return ExperimentPeriodAggregate(
            value: aggregateValue,
            perDayValue: perDayValue,
            sampleCount: valid.count,
            coverage: coverage(windowed: windowed, valid: valid, window: window),
            summary: summary,
            groups: groups,
            provenance: provenance
        )
    }

    private static func validObservation(
        _ observation: ExperimentMetricObservation,
        aggregation: ExperimentMetricAggregation
    ) -> ValidObservation? {
        guard let value = observation.value, value.isFinite else { return nil }
        if aggregation == .weightedMean {
            guard observation.weight.isFinite, observation.weight > 0 else { return nil }
        }
        return ValidObservation(
            timestamp: observation.timestamp,
            value: value,
            provenance: observation.provenance,
            group: observation.group,
            weight: observation.weight
        )
    }

    private static func aggregate(
        _ observations: [ValidObservation],
        using aggregation: ExperimentMetricAggregation
    ) -> Double? {
        guard !observations.isEmpty else { return nil }
        // A producer is not required to return rows in a stable order. Use a
        // total semantic order so floating-point reductions remain identical
        // for the same observation set.
        let ordered = observations.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            if lhs.weight != rhs.weight { return lhs.weight < rhs.weight }
            if lhs.group != rhs.group { return (lhs.group ?? "") < (rhs.group ?? "") }
            return lhs.provenance.rawValue < rhs.provenance.rawValue
        }
        switch aggregation {
        case .sum:
            return ordered.reduce(0) { $0 + $1.value }
        case .mean:
            return ordered.reduce(0) { $0 + $1.value }
                / Double(ordered.count)
        case .maximum:
            return ordered.map(\.value).max()
        case .minimum:
            return ordered.map(\.value).min()
        case .weightedMean:
            let totalWeight = ordered.reduce(0) { $0 + $1.weight }
            guard totalWeight > 0 else { return nil }
            return ordered.reduce(0) { $0 + $1.value * $1.weight }
                / totalWeight
        case .latest:
            return ordered.max { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    // Stable tie policy makes reordered inputs deterministic.
                    return lhs.value < rhs.value
                }
                return lhs.timestamp < rhs.timestamp
            }?.value
        }
    }

    // MARK: - Coverage

    private static func coverage(
        windowed: [ExperimentMetricObservation],
        valid: [ValidObservation],
        window: ExperimentWindow
    ) -> ExperimentMetricCoverage {
        let calendar = window.calendar
        let populatedDays = Set(valid.map {
            calendar.startOfDay(for: $0.timestamp)
        })
        let completeDays = Set(completeCalendarDayStarts(in: window))

        return ExperimentMetricCoverage(
            observationCount: windowed.count,
            validValueCount: valid.count,
            missingValueCount: windowed.count - valid.count,
            populatedCalendarDays: populatedDays.count,
            expectedCompleteCalendarDays: completeDays.count,
            populatedCompleteCalendarDays: populatedDays.intersection(completeDays).count
        )
    }

    private static func completeCalendarDayStarts(
        in window: ExperimentWindow
    ) -> [Date] {
        let calendar = window.calendar
        var cursor = calendar.startOfDay(for: window.start)
        if cursor < window.start {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                return []
            }
            cursor = next
        }

        var result: [Date] = []
        while cursor < window.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor),
                  next > cursor else {
                break
            }
            guard next <= window.end else { break }
            result.append(cursor)
            cursor = next
        }
        return result
    }

    // MARK: - Summaries and deltas

    private static func numericSummary(
        _ values: [Double]
    ) -> ExperimentNumericSummary? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let sum = sorted.reduce(0, +)
        return ExperimentNumericSummary(
            count: sorted.count,
            sum: sum,
            mean: sum / Double(sorted.count),
            minimum: sorted[0],
            q1: percentile(sorted, probability: 0.25),
            median: percentile(sorted, probability: 0.5),
            q3: percentile(sorted, probability: 0.75),
            maximum: sorted[sorted.count - 1]
        )
    }

    private static func percentile(
        _ sortedValues: [Double],
        probability: Double
    ) -> Double {
        let clamped = min(max(probability, 0), 1)
        let position = clamped * Double(sortedValues.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        guard lower != upper else { return sortedValues[lower] }
        let fraction = position - Double(lower)
        return sortedValues[lower] * (1 - fraction)
            + sortedValues[upper] * fraction
    }

    private static func rollupProvenance(
        _ values: [InsightProvenance]
    ) -> InsightProvenance? {
        guard let first = values.first else { return nil }
        if first == .mixed || values.dropFirst().contains(where: { $0 != first }) {
            return .mixed
        }
        return first
    }

    private static func absoluteChange(
        current: Double?,
        reference: Double?
    ) -> Double? {
        guard let current, let reference else { return nil }
        return current - reference
    }

    private static func percentChange(
        current: Double?,
        reference: Double?
    ) -> Double? {
        guard let current, let reference, reference != 0 else { return nil }
        return (current - reference) / abs(reference) * 100
    }

    private static func comparisonBasis(
        selection: ExperimentMetricSelection,
        currentWindow: ExperimentWindow,
        referenceWindow: ExperimentWindow
    ) -> ExperimentComparisonBasis {
        switch selection.normalization {
        case .raw:
            return .raw
        case .perDay:
            return .perDay
        case .automatic:
            let durationsDiffer = abs(currentWindow.duration - referenceWindow.duration)
                > durationEqualityTolerance
            return selection.aggregation.supportsPerDayNormalization && durationsDiffer
                ? .perDay
                : .raw
        }
    }
}
