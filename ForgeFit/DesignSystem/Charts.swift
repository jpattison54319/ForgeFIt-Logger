import Charts
import ForgeCore
import ForgeData
import SwiftUI

/// A single (date, value) sample for the trend charts.
struct MetricPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

enum TimeChartRange: String, CaseIterable, Identifiable {
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

    @Environment(\.theme) private var theme

    var body: some View {
        let lineColor = color ?? theme.accent
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))

                AreaMark(x: .value("Date", point.date), y: .value("Value", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [lineColor.opacity(0.25), lineColor.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("Value", last.value))
                    .foregroundStyle(lineColor)
                    .symbolSize(80)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 2)) { value in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .frame(height: 180)
    }
}

/// Daily HRV against a shaded ±1 SD "normal" band and a dashed baseline mean,
/// with today's reading called out — so a single noisy night reads as "within
/// my range" rather than an alarming isolated number.
struct HRVBaselineBandChart: View {
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
    }

    let points: [Point]
    let mean: Double
    let sd: Double

    @Environment(\.theme) private var theme

    var body: some View {
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Date", point.date),
                         yStart: .value("Low", mean - sd),
                         yEnd: .value("High", mean + sd))
                    .foregroundStyle(theme.success.opacity(0.12))
            }
            RuleMark(y: .value("Baseline", mean))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(theme.textTertiary)
            ForEach(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("HRV", point.value))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let last = points.last {
                PointMark(x: .value("Date", last.date), y: .value("HRV", last.value))
                    .foregroundStyle(theme.accent)
                    .symbolSize(90)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
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
    private var orderedLabels: [String] {
        let windows = Set(current.map(\.windowSeconds)).union(prior.map(\.windowSeconds))
        return windows.sorted().map(windowLabel)
    }

    var body: some View {
        Chart {
            ForEach(prior) { point in
                LineMark(x: .value("Window", windowLabel(point.windowSeconds)),
                         y: .value("Pace", unitPace(point.paceSecPerKm)),
                         series: .value("Period", "Previous"))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            ForEach(current) { point in
                LineMark(x: .value("Window", windowLabel(point.windowSeconds)),
                         y: .value("Pace", unitPace(point.paceSecPerKm)),
                         series: .value("Period", "Now"))
                    .foregroundStyle(theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                PointMark(x: .value("Window", windowLabel(point.windowSeconds)),
                          y: .value("Pace", unitPace(point.paceSecPerKm)))
                    .foregroundStyle(theme.accent)
                    .symbolSize(60)
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
        .frame(height: 180)
    }
}

/// Heart rate over the course of a single workout (per-sample HealthKit series).
/// Red line + area fill with a dashed average, bpm on the y-axis and clock time
/// on the x-axis. The caller only renders this when samples exist.
struct HeartRateTrendChart: View {
    let samples: [(date: Date, bpm: Int)]
    /// Time windows shaded behind the trace — the cardio efforts of a hybrid
    /// session, in the same time domain as `samples`.
    var bands: [(start: Date, end: Date)] = []

    @Environment(\.theme) private var theme

    private var avg: Int {
        guard !samples.isEmpty else { return 0 }
        return Int((Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)).rounded())
    }

    var body: some View {
        Chart {
            // Declared first so the bands sit behind the line and area marks.
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                RectangleMark(
                    xStart: .value("Start", band.start),
                    xEnd: .value("End", band.end)
                )
                .foregroundStyle(theme.secondaryAccent.opacity(0.14))
            }
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(theme.danger)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                AreaMark(x: .value("Time", sample.date), y: .value("BPM", sample.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.danger.opacity(0.22), theme.danger.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            if avg > 0 {
                RuleMark(y: .value("Average", avg))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .frame(height: 160)
    }
}

extension HeartRateTrendChart {
    /// Cardio-effort windows for a hybrid workout's session HR chart. Only
    /// live-tracked sessions carry trustworthy wall-clock windows — manually
    /// logged ones are skipped rather than shading the wrong span. Pure-cardio
    /// workouts return nothing: shading the entire chart says nothing.
    static func cardioBands(for workout: WorkoutModel) -> [(start: Date, end: Date)] {
        let cardioExerciseIDs = Set(workout.cardioSessions.compactMap(\.workoutExerciseID))
        let hasStrength = workout.exercises.contains { !cardioExerciseIDs.contains($0.id) }
        guard hasStrength else { return [] }
        return workout.cardioSessions
            .filter { $0.deletedAt == nil }
            .compactMap { session -> (start: Date, end: Date)? in
                guard let start = session.liveStartedAt else { return nil }
                let end = session.endedAt
                    ?? session.durationSeconds.map { start.addingTimeInterval(Double($0)) }
                guard let end, end > start else { return nil }
                return (start, end)
            }
            .sorted { $0.start < $1.start }
    }
}

/// Sage bar trend (weekly duration / volume on the profile screen).
struct BarTrendChart: View {
    let points: [MetricPoint]
    var color: Color? = nil

    @Environment(\.theme) private var theme

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
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
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
