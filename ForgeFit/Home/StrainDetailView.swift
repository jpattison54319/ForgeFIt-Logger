import Charts
import SwiftData
import SwiftUI

struct StrainDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let report: DailyStrainEngine.Report
    @State private var selectedTab: MetricDetailTab = .today
    @State private var showingInfo = false
    @State private var snapshots = RecoverySnapshotStore.shared

    private struct TrendPoint: Identifiable {
        var id: Date { date }
        let date: Date
        let score: Double
        let target: ClosedRange<Double>?
    }

    private var trendPoints: [TrendPoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return snapshots.snapshots
            .compactMap { date, snapshot -> TrendPoint? in
                guard date >= cutoff, let score = snapshot.strain else { return nil }
                return TrendPoint(date: date, score: score, target: snapshot.strainTargetRange)
            }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        MetricDetailScaffold(title: "Strain", selectedTab: $selectedTab) {
            switch selectedTab {
            case .today:
                todayContent
            case .trends:
                trendsContent
            }
        }
        .refreshable { await AppRefresh.run(in: modelContext) }
        .sheet(isPresented: $showingInfo) {
            DailyStrainInfoSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var todayContent: some View {
        if let score = report.score {
            strainSummary(score)
            activityInputs
            sourceBreakdown
        } else {
            MetricEmptyCard(
                title: "Strain baseline is building",
                message: "Seven days of movement data unlocks a personal score and a recovery-adjusted daily target.",
                systemImage: "chart.line.uptrend.xyaxis"
            )
        }

        Button {
            showingInfo = true
        } label: {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(theme.secondaryAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How strain works")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Recovery sets today's target; activity and training build the score.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("daily-strain-info")
    }

    @ViewBuilder
    private var trendsContent: some View {
        if trendPoints.count >= 2 {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Strain and target")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Last 30 days")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text("Avg \(averageStrain.formatted(.number.precision(.fractionLength(1))))")
                            .font(.tag)
                            .foregroundStyle(theme.textSecondary)
                    }
                    strainTrendChart
                    HStack(spacing: Space.lg) {
                        Label("Daily strain", systemImage: "line.diagonal")
                            .foregroundStyle(theme.secondaryAccent)
                        Label("Target range", systemImage: "rectangle.fill")
                            .foregroundStyle(theme.accent.opacity(0.55))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    Text("Targets move modestly with that morning's recovery. They guide the day; they are not an injury-risk threshold.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                HStack {
                    trendStat("Tracked days", "\(trendPoints.count)")
                    trendStat("In target", "\(daysInTarget)")
                    trendStat("Average", averageStrain.formatted(.number.precision(.fractionLength(1))))
                }
            }
        } else {
            MetricEmptyCard(
                title: "Strain trend is building",
                message: "Keep Apple Health connected and log workouts to see strain against each day's target.",
                systemImage: "chart.xyaxis.line"
            )
        }
    }

    private func strainSummary(_ score: Double) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .lastTextBaseline, spacing: Space.sm) {
                    Text(score.formatted(.number.precision(.fractionLength(1))))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(strainTint)
                    Text("/ 10")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        if let target = report.targetRange {
                            Text("Target \(formatted(target.lowerBound))-\(formatted(target.upperBound))")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                        } else {
                            Text("Target building")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Text(statusText(score))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(statusTint)
                    }
                }
                StrainTargetBar(score: score, target: report.targetRange, color: strainTint)
            }
        }
        .accessibilityIdentifier("strain-today-summary")
    }

    private var activityInputs: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Today's activity")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                if let steps = report.steps {
                    MetricReadingRow(title: "Steps", value: steps.formatted(), systemImage: "shoeprints.fill", tint: theme.secondaryAccent)
                }
                if report.steps != nil, report.exerciseMinutes != nil { Divider().overlay(theme.separator) }
                if let minutes = report.exerciseMinutes {
                    MetricReadingRow(title: "Active minutes", value: "\(minutes) min", systemImage: "figure.walk", tint: theme.zone2)
                }
                if (report.steps != nil || report.exerciseMinutes != nil), report.activeEnergyKcal != nil { Divider().overlay(theme.separator) }
                if let energy = report.activeEnergyKcal {
                    MetricReadingRow(title: "Active energy", value: "\(energy) kcal", systemImage: "bolt.fill", tint: theme.warmup)
                }
                if report.workoutMinutes > 0 {
                    Divider().overlay(theme.separator)
                    MetricReadingRow(title: "Logged training", value: "\(report.workoutMinutes) min", systemImage: "dumbbell.fill", tint: theme.accent)
                }
            }
        }
    }

    private var sourceBreakdown: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Against your norm")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                if let ratio = report.movementRatio {
                    ratioRow("Movement", ratio: ratio, systemImage: "figure.walk", tint: theme.zone2)
                }
                if report.movementRatio != nil, report.workoutRatio != nil { Divider().overlay(theme.separator) }
                if let ratio = report.workoutRatio {
                    ratioRow("Training", ratio: ratio, systemImage: "dumbbell.fill", tint: theme.accent)
                }
                if report.movementRatio == nil, report.workoutRatio == nil {
                    Text("More activity history is needed before ForgeFit can compare today with your norm.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func ratioRow(_ title: String, ratio: Double, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(ratio.formatted(.number.precision(.fractionLength(1))))x")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceElevated)
                    Capsule().fill(tint).frame(width: max(5, proxy.size.width * min(2, ratio) / 2))
                    Rectangle().fill(theme.textTertiary).frame(width: 1, height: 8)
                        .position(x: proxy.size.width / 2, y: 4)
                }
            }
            .frame(height: 6)
        }
    }

    private var strainTrendChart: some View {
        Chart(trendPoints) { point in
            if let target = point.target {
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Target low", target.lowerBound),
                    yEnd: .value("Target high", target.upperBound)
                )
                .foregroundStyle(theme.accent.opacity(0.13))
            }
            LineMark(x: .value("Date", point.date), y: .value("Strain", point.score))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(theme.secondaryAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(x: .value("Date", point.date), y: .value("Strain", point.score))
                .foregroundStyle(theme.secondaryAccent)
                .symbolSize(20)
        }
        .chartYScale(domain: 0...10)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 5, 10]) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .frame(height: 190)
    }

    private func trendStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.statValue)
                .foregroundStyle(theme.textPrimary)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var averageStrain: Double {
        guard !trendPoints.isEmpty else { return 0 }
        return trendPoints.map(\.score).reduce(0, +) / Double(trendPoints.count)
    }

    private var daysInTarget: Int {
        trendPoints.count { point in
            point.target?.contains(point.score) == true
        }
    }

    private var strainTint: Color {
        report.status == .aboveTarget ? theme.warmup : theme.secondaryAccent
    }

    private var statusTint: Color {
        switch report.status {
        case .inTarget: theme.success
        case .aboveTarget: theme.warmup
        default: theme.textSecondary
        }
    }

    private func statusText(_ score: Double) -> String {
        switch report.status {
        case .building: "Building baseline"
        case .targetBuilding: "Recovery target building"
        case .belowTarget:
            report.targetRange.map { "\(formatted(max(0, $0.lowerBound - score))) to target" } ?? "Below target"
        case .inTarget: "Target reached"
        case .aboveTarget: "Above today's range"
        }
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
