import Charts
import ForgeCore
import ForgeData
import SwiftUI

/// A single (date, value) sample for the trend charts.
nonisolated struct MetricPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let value: Double
}

nonisolated enum TimeChartRange: String, CaseIterable, Identifiable, Sendable {
    case fourWeeks
    case twelveWeeks
    case oneYear
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fourWeeks: "4W"
        case .twelveWeeks: "12W"
        case .oneYear: "1Y"
        case .all: "All"
        }
    }

    var weekCount: Int {
        switch self {
        case .fourWeeks: 4
        case .twelveWeeks: 12
        case .oneYear: 52
        case .all: 520
        }
    }

    func filtered(_ points: [MetricPoint], now: Date = Date(), calendar: Calendar = .current) -> [MetricPoint] {
        guard self != .all,
              let start = calendar.date(byAdding: .weekOfYear, value: -weekCount, to: now) else {
            return points
        }
        return points.filter { $0.date >= start }
    }
}

struct TimeChartRangePicker: View {
    @Binding var selection: TimeChartRange

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(TimeChartRange.allCases) { range in
                if selection == range {
                    Button {
                        selection = range
                    } label: {
                        Label(range.label, systemImage: "checkmark")
                    }
                } else {
                    Button(range.label) {
                        selection = range
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selection.label)
                    .font(.system(size: 13, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.surfaceElevated)
            .clipShape(Capsule())
            .minimumTouchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chart time range")
    }
}

/// Sage line trend with a filled end dot and a soft area fill.
struct LineTrendChart: View {
    let points: [MetricPoint]
    var color: Color? = nil
    var yLabel: String? = nil
    var valueFormatter: @MainActor (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(0...1)))
    }
    var axisValueFormatter: @MainActor (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(0...1)))
    }
    var yAxisUnitLabel: String? = nil
    var chartAccessibilityIdentifier: String = "line-trend-chart"

    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private var selectedPoint: MetricPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        let lineColor = color ?? theme.accent
        let yDomain = ChartYDomain.padded(values: points.map(\.value), lowerLimit: 0)
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .accessibilityHidden(true)

                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Visible baseline", yDomain.lowerBound),
                    yEnd: .value("Value", point.value)
                )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [lineColor.opacity(0.25), lineColor.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .accessibilityHidden(true)
                PointMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .foregroundStyle(lineColor)
                    .symbolSize(28)
                    .accessibilityHidden(true)
            }
            if let selectedPoint {
                RuleMark(x: .value("Selected date", selectedPoint.date))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: selectedPoint.date.formatted(date: .abbreviated, time: .omitted),
                            lines: [(yLabel ?? "Value", valueFormatter(selectedPoint.value))]
                        )
                    }
                PointMark(x: .value("Selected date", selectedPoint.date), y: .value("Value", selectedPoint.value))
                    .foregroundStyle(lineColor)
                    .symbolSize(90)
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel {
                    if let measurement = value.as(Double.self) {
                        Text(axisValueFormatter(measurement)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            if let label = yAxisUnitLabel ?? yLabel {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .pressHoldChartXSelection(value: $selectedDate)
        .frame(height: 180)
        // Swift Charts otherwise exposes its internal numeric plot values.
        // Those values are canonical storage units (for example seconds or
        // kilograms), which can disagree with the user-facing formatter.
        // Keep one trustworthy element and let VoiceOver step through the
        // same formatted measurements with adjustable actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(yLabel ?? "Value") trend chart")
        .accessibilityValue(lineChartAccessibilityValue(domain: yDomain))
        .accessibilityHint("Swipe up or down to inspect measurements")
        .accessibilityAdjustableAction(adjustAccessibilitySelection)
        .accessibilityIdentifier(chartAccessibilityIdentifier)
    }

    private func lineChartAccessibilityValue(domain: ClosedRange<Double>) -> String {
        let range = "Visible range \(axisValueFormatter(domain.lowerBound)) to \(axisValueFormatter(domain.upperBound))"
        if selectedDate != nil, let selectedPoint {
            return "\(selectedPoint.date.formatted(date: .abbreviated, time: .omitted)), "
                + "\(valueFormatter(selectedPoint.value)). \(range)"
        }
        guard let latest = points.last else { return range }
        return "Latest \(valueFormatter(latest.value)). \(range)"
    }

    private func adjustAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        guard !points.isEmpty else { return }
        let currentIndex = selectedPoint.flatMap { selected in
            points.firstIndex(where: { $0.id == selected.id })
        } ?? (points.count - 1)
        let nextIndex: Int
        switch direction {
        case .increment:
            nextIndex = min(points.count - 1, currentIndex + 1)
        case .decrement:
            nextIndex = max(0, currentIndex - 1)
        @unknown default:
            return
        }
        selectedDate = points[nextIndex].date
    }
}

/// Daily HRV against a shaded 10th–90th percentile usual observed band and a
/// dashed median. This is personal descriptive history, not a medical range.
struct HRVBaselineBandChart: View {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    let points: [Point]
    let median: Double
    let lowerBound: Double
    let upperBound: Double

    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private var selectedPoint: Point? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        let yDomain = ChartYDomain.padded(
            values: points.map(\.value) + [median, lowerBound, upperBound],
            lowerLimit: 0
        )
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Date", point.date),
                         yStart: .value("Low", lowerBound),
                         yEnd: .value("High", upperBound))
                    .foregroundStyle(theme.success.opacity(0.12))
            }
            RuleMark(y: .value("Baseline median", median))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(theme.textTertiary)
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("HRV", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(theme.accentForeground)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Date", point.date), y: .value("HRV", point.value))
                    .foregroundStyle(theme.accentForeground)
                    .symbolSize(24)
                    .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityValue("\(Int(point.value.rounded())) ms")
            }
            if let selectedPoint {
                RuleMark(x: .value("Selected date", selectedPoint.date))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: selectedPoint.date.formatted(date: .abbreviated, time: .omitted),
                            lines: [("HRV", "\(Int(selectedPoint.value.rounded())) ms")]
                        )
                    }
                PointMark(x: .value("Selected date", selectedPoint.date), y: .value("HRV", selectedPoint.value))
                    .foregroundStyle(theme.accentForeground)
                    .symbolSize(90)
                    .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            Text("HRV (ms)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .pressHoldChartXSelection(value: $selectedDate)
        .frame(height: 160)
    }
}

/// Mean-maximal pace curve: best sustained pace at each duration window, with an
/// optional prior-period overlay so fitness change is visible at a glance. Pace
/// shows in the user's unit and the y-axis is reversed so faster sits higher.
struct CriticalPaceCurveView: View {
    let current: [TrainingAnalytics.CriticalPacePoint]
    var prior: [TrainingAnalytics.CriticalPacePoint] = []

    @Environment(\.theme) private var theme
    @State private var selectedWindow: String?

    private func unitPace(_ secPerKm: Double) -> Double {
        secPerKm * (Fmt.distanceUnit.metersPerUnit / 1000)
    }
    private func windowLabel(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds)s"
    }
    private func paceLabel(_ secInUnit: Double) -> String {
        let s = Int(secInUnit.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    private var paceUnit: String { "min\(Fmt.distanceUnit.paceSuffix)" }
    private var orderedLabels: [String] {
        let windows = Set(current.map(\.windowSeconds)).union(prior.map(\.windowSeconds))
        return windows.sorted().map(windowLabel)
    }
    private var selectedLabel: String? {
        guard let selectedWindow else { return nil }
        return orderedLabels.min {
            abs((orderedLabels.firstIndex(of: $0) ?? 0) - (orderedLabels.firstIndex(of: selectedWindow) ?? 0))
                < abs((orderedLabels.firstIndex(of: $1) ?? 0) - (orderedLabels.firstIndex(of: selectedWindow) ?? 0))
        }
    }

    var body: some View {
        Chart {
            ForEach(prior) { point in
                LineMark(x: .value("Window", windowLabel(point.windowSeconds)),
                         y: .value("Pace", unitPace(point.paceSecPerKm)),
                         series: .value("Period", "Previous"))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                PointMark(x: .value("Window", windowLabel(point.windowSeconds)),
                          y: .value("Pace", unitPace(point.paceSecPerKm)))
                    .foregroundStyle(theme.textTertiary)
                    .symbolSize(30)
            }
            ForEach(current) { point in
                LineMark(x: .value("Window", windowLabel(point.windowSeconds)),
                         y: .value("Pace", unitPace(point.paceSecPerKm)),
                         series: .value("Period", "Now"))
                    .foregroundStyle(theme.accentForeground)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Window", windowLabel(point.windowSeconds)),
                          y: .value("Pace", unitPace(point.paceSecPerKm)))
                    .foregroundStyle(theme.accentForeground)
                    .symbolSize(60)
            }
            if let selectedLabel {
                let currentPoint = current.first { windowLabel($0.windowSeconds) == selectedLabel }
                let priorPoint = prior.first { windowLabel($0.windowSeconds) == selectedLabel }
                RuleMark(x: .value("Selected window", selectedLabel))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: selectedLabel,
                            lines: [
                                currentPoint.map { ("Current", "\(paceLabel(unitPace($0.paceSecPerKm))) \(paceUnit)") },
                                priorPoint.map { ("Previous", "\(paceLabel(unitPace($0.paceSecPerKm))) \(paceUnit)") },
                            ].compactMap { $0 }
                        )
                    }
            }
        }
        .chartXScale(domain: orderedLabels)
        .chartYScale(domain: .automatic(reversed: true))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                if let secs = value.as(Double.self) {
                    AxisValueLabel { Text(paceLabel(secs)).foregroundStyle(theme.textTertiary) }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            Text("Pace (\(paceUnit))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .pressHoldChartXSelection(value: $selectedWindow)
        .frame(height: 180)
    }
}

/// Heart rate over the course of a single workout (per-sample HealthKit series).
/// Red line + area fill with a dashed average, bpm on the y-axis and clock time
/// on the x-axis. The caller only renders this when samples exist.
struct HeartRateTrendChart: View {
    struct Band: Identifiable, Equatable {
        enum Kind: String, CaseIterable {
            case cardio = "Cardio"
            case conditioning = "Conditioning"
            case yoga = "Yoga"
        }

        let id: UUID
        let start: Date
        let end: Date
        let kind: Kind
    }

    let samples: [(date: Date, bpm: Int)]
    /// Typed timed-segment windows in the same time domain as `samples`.
    var bands: [Band] = []
    var height: CGFloat = 160

    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private var validSamples: [(date: Date, bpm: Int)] {
        samples.filter { $0.bpm > 0 }
    }

    private var legendKinds: [Band.Kind] {
        Band.Kind.allCases.filter { kind in bands.contains { $0.kind == kind } }
    }

    private func selectedSample(in samples: [(date: Date, bpm: Int)]) -> (date: Date, bpm: Int)? {
        guard let selectedDate else { return nil }
        return samples.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private func averageBPM(in samples: [(date: Date, bpm: Int)]) -> Int {
        guard !samples.isEmpty else { return 0 }
        return Int((Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)).rounded())
    }

    var body: some View {
        let plottedSamples = validSamples
        let average = averageBPM(in: plottedSamples)
        let selectedSample = selectedSample(in: plottedSamples)
        let yDomain = ChartYDomain.padded(
            values: plottedSamples.map { Double($0.bpm) },
            lowerLimit: 0
        )
        VStack(alignment: .leading, spacing: 6) {
            Chart {
            // Declared first so the bands sit behind the line and area marks.
            ForEach(bands) { band in
                RectangleMark(
                    xStart: .value("Start", band.start),
                    xEnd: .value("End", band.end)
                )
                .foregroundStyle(color(for: band.kind).opacity(0.16))
            }
            ForEach(Array(plottedSamples.enumerated()), id: \.offset) { _, sample in
                LineMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(theme.danger)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                AreaMark(
                    x: .value("Time", sample.date),
                    yStart: .value("Visible baseline", yDomain.lowerBound),
                    yEnd: .value("BPM", Double(sample.bpm))
                )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.danger.opacity(0.22), theme.danger.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                PointMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                    .foregroundStyle(theme.danger)
                    .symbolSize(plottedSamples.count > 80 ? 8 : 18)
                    .accessibilityLabel(sample.date.formatted(date: .omitted, time: .shortened))
                    .accessibilityValue("\(sample.bpm) bpm")
            }
            if average > 0 {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(theme.textTertiary)
            }
            if let selectedSample {
                RuleMark(x: .value("Selected time", selectedSample.date))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: selectedSample.date.formatted(date: .omitted, time: .shortened),
                            lines: [("Heart rate", "\(selectedSample.bpm) bpm")]
                        )
                    }
                PointMark(x: .value("Selected time", selectedSample.date), y: .value("BPM", selectedSample.bpm))
                    .foregroundStyle(theme.danger)
                    .symbolSize(90)
                    .accessibilityHidden(true)
            }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(theme.separator.opacity(0.35))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                    AxisValueLabel().foregroundStyle(theme.textTertiary)
                }
            }
            .chartYAxisLabel(position: .top, alignment: .leading) {
                Text("Heart rate (bpm)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .pressHoldChartXSelection(value: $selectedDate)
            .frame(height: bands.isEmpty ? height : max(64, height - 20))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Heart rate trend chart")
            .accessibilityValue(heartRateChartAccessibilityValue(
                samples: plottedSamples,
                average: average,
                domain: yDomain
            ))
            .accessibilityIdentifier("heart-rate-trend-chart")

            if !legendKinds.isEmpty {
                HStack(spacing: 12) {
                    ForEach(legendKinds, id: \.self) { kind in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: kind))
                                .frame(width: 10, height: 6)
                            Text(kind.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func heartRateChartAccessibilityValue(
        samples: [(date: Date, bpm: Int)],
        average: Int,
        domain: ClosedRange<Double>
    ) -> String {
        guard !samples.isEmpty else { return "No valid heart rate samples" }
        return "Average \(average) bpm. Visible range \(Int(domain.lowerBound.rounded())) to \(Int(domain.upperBound.rounded())) bpm. \(samples.count) samples."
    }

    private func color(for kind: Band.Kind) -> Color {
        switch kind {
        case .cardio: theme.secondaryAccent
        case .conditioning: theme.warmup
        case .yoga: theme.accent
        }
    }
}

extension HeartRateTrendChart {
    /// Trustworthy wall-clock windows for every timed modality. A block can
    /// own summary and movement sessions; those collapse to its longest
    /// window so one conditioning effort never paints itself twice.
    static func modalityBands(for workout: WorkoutModel) -> [Band] {
        let candidates = workout.cardioSessions
            .filter { $0.deletedAt == nil }
            .compactMap { session -> Band? in
                guard let start = session.liveStartedAt else { return nil }
                let end = session.endedAt
                    ?? session.durationSeconds.map { start.addingTimeInterval(Double($0)) }
                guard let end, end > start else { return nil }
                let kind: Band.Kind
                if session.isConditioningSession || session.workoutBlockID.flatMap({ id in
                    workout.blocks.first { $0.id == id }?.kind
                }) == .conditioning {
                    kind = .conditioning
                } else if session.isYogaSession {
                    kind = .yoga
                } else {
                    kind = .cardio
                }
                return Band(id: session.id, start: start, end: end, kind: kind)
            }

        var collapsed: [String: Band] = [:]
        for band in candidates {
            let session = workout.cardioSessions.first { $0.id == band.id }
            let key = session?.workoutBlockID.map { "block-\($0.uuidString)" }
                ?? "session-\(band.id.uuidString)"
            let existing = collapsed[key]
            if existing == nil || band.end.timeIntervalSince(band.start) > existing!.end.timeIntervalSince(existing!.start) {
                collapsed[key] = band
            }
        }
        return collapsed.values.sorted { $0.start < $1.start }
    }

    /// Source-compatible name retained for existing call sites.
    static func cardioBands(for workout: WorkoutModel) -> [Band] {
        modalityBands(for: workout)
    }
}

/// Sage bar trend (weekly duration / volume on the profile screen).
struct BarTrendChart: View {
    let points: [MetricPoint]
    var color: Color? = nil
    var valueFormatter: @MainActor (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(0...1)))
    }
    var axisValueFormatter: @MainActor (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(0...1)))
    }
    var yAxisLabel: String? = nil

    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private var selectedPoint: MetricPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        let barColor = color ?? theme.accent
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Date", point.date, unit: .weekOfYear),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(barColor)
                .cornerRadius(4)
                .accessibilityLabel(point.date.formatted(date: .abbreviated, time: .omitted))
                .accessibilityValue(valueFormatter(point.value))
            }
            if let selectedPoint {
                RuleMark(x: .value("Selected date", selectedPoint.date))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: selectedPoint.date.formatted(date: .abbreviated, time: .omitted),
                            lines: [("Value", valueFormatter(selectedPoint.value))]
                        )
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel {
                    if let measurement = value.as(Double.self) {
                        Text(axisValueFormatter(measurement)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            if let yAxisLabel {
                Text(yAxisLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .pressHoldChartXSelection(value: $selectedDate)
        .frame(height: 200)
    }
}

/// Horizontal muscle-volume bars (weekly sets per muscle group).
struct MuscleVolumeBars: View {
    struct Row: Identifiable {
        let id = UUID()
        let muscle: String
        let sets: Double
        let target: Double
    }
    let rows: [Row]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.md) {
            ForEach(rows) { row in
                VStack(spacing: 6) {
                    HStack {
                        Text(row.muscle.capitalized)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(row.sets.formatted(.number.precision(.fractionLength(0...1)))) / \(Int(row.target)) sets")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.surfaceHighlight)
                            Capsule()
                                .fill(barColor(row))
                                .frame(width: geo.size.width * min(1, row.sets / max(1, row.target)))
                        }
                    }
                    .frame(height: 8)
                }
            }
        }
    }

    private func barColor(_ row: Row) -> Color {
        let ratio = row.sets / max(1, row.target)
        if ratio < 0.6 { return theme.warmup }        // under-stimulated
        if ratio > 1.3 { return theme.danger }        // over-reaching
        return theme.accent
    }
}
