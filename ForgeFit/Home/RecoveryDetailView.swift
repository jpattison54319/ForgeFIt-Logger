import Charts
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Full recovery breakdown focused on action first: what to do today, why the
/// app thinks that, and only then the supporting details. Leads with three
/// versioned personal indices — recovery signals, per-muscle exposure, and
/// cardio exposure — each of which admits when it lacks comparable data.
struct RecoveryDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let workouts: [WorkoutModel]
    var exercises: [ExerciseLibraryModel] = []

    @State private var selectedInfo: RecoveryInfoTopic?
    @State private var selectedTab: MetricDetailTab = .today
    @State private var reportMemo = Memo<String, RecoveryEngine.Report>()
    @Query private var checkins: [DailyCheckinModel]

    private var todayCheckin: DailyCheckinModel? {
        checkins
            .filter { $0.deletedAt == nil && Calendar.current.isDate($0.date, inSameDayAs: Date()) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var report: RecoveryEngine.Report {
        reportMemo("\(AnalyticsFingerprint.withHealth(workouts))|\(HealthMetricsStore.shared.metricsRevision)|\(todayCheckin?.tagsRaw ?? "")") {
            RecoveryEngine(
                workouts: workouts,
                exercises: exercises,
                healthMetrics: HealthMetricsStore.shared.metrics,
                supplementalSignals: HealthMetricsStore.shared.extraSignals,
                todayCheckinTags: todayCheckin?.tags ?? []
            ).report()
        }
    }

    private func toggleCheckinTag(_ tag: String) {
        var tags = todayCheckin?.tags ?? []
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        let attempt = DailyCheckinCommitAttempt(
            id: todayCheckin?.id ?? UUID(),
            userID: ForgeFitDemo.userID,
            day: Date(),
            tags: tags
        )
        PersistentChangeSaveCenter.shared.perform {
            _ = try attempt.commit(in: modelContext)
        }
    }

    /// Daily HRV over the last ~45 days with a source-pure 10th–90th
    /// percentile band. Nil until 28 readings span at least 42 days.
    private var hrvTrend: HRVTrendData? {
        let metrics = HealthMetricsStore.shared.metrics.sorted { $0.date < $1.date }.suffix(45)
        guard let channel = HealthMetricChannelSeries.hrv(metrics: Array(metrics)) else { return nil }
        let usedRMSSD = channel.name.localizedCaseInsensitiveContains("RMSSD")
        let values = channel.values.map { ($0.date, $0.value) }
        let baseline = channel.baselineValues
        guard baseline.count >= 28,
              let first = channel.baselineDates.min(), let last = channel.baselineDates.max(),
              (Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0) >= 42,
              let today = values.last?.1 else { return nil }
        func quantile(_ probability: Double) -> Double {
            let sorted = baseline.sorted()
            let position = probability * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Int(position.rounded(.up))
            guard lower != upper else { return sorted[lower] }
            let fraction = position - Double(lower)
            return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
        }
        return HRVTrendData(
            points: values.map { .init(date: $0.0, value: $0.1) },
            median: quantile(0.5),
            lowerBound: quantile(0.10),
            upperBound: quantile(0.90),
            today: today,
            usedRMSSD: usedRMSSD
        )
    }

    /// Startup-normalized short- and long-term EWMAs of same-method session-RPE load.
    private var fitnessFatigue: [FitnessFatigue.Point] {
        let engine = RecoveryEngine(workouts: workouts, exercises: exercises)
        let loads = engine.completed.compactMap { workout -> (Date, Double)? in
            let load = engine.sessionLoad(workout)
            return load > 0 ? (workout.startedAt, load) : nil
        } + [(Date(), 0.0)]
        return Array(FitnessFatigue.series(dailyLoads: loads).suffix(90))
    }

    var body: some View {
        let report = self.report
        MetricDetailScaffold(title: "Recovery", selectedTab: $selectedTab) {
            switch selectedTab {
            case .today:
                RecoverySummaryCard(report: report) { selectedInfo = $0 }

                MorningCheckinCard(
                    selectedTags: Set(todayCheckin?.tags ?? []),
                    onToggle: toggleCheckinTag
                )

            case .trends:
                if HealthMetricsStore.shared.hrvGapDetected {
                    GarminHRVGapCard()
                }

                SystemicScoreCard(systemic: report.recovery.systemic) { selectedInfo = $0 }

                if let trend = hrvTrend {
                    HRVTrendCard(trend: trend)
                }

                MuscleRecoveryCard(muscles: report.recovery.muscles) { selectedInfo = $0 }

                CardioRecoveryCard(cardio: report.recovery.cardio) { selectedInfo = $0 }

                if fitnessFatigue.count >= 42 {
                    SectionHeader("Training load balance")
                    FitnessFatigueCard(points: fitnessFatigue)
                }
            }
        }
        .refreshable { await AppRefresh.run(in: modelContext) }
        .sheet(item: $selectedInfo) { topic in
            MetricInfoSheet(topic: topic)
                .presentationDetents([.medium, .large])
        }
    }

}

/// Descriptive load smoothing. These curves are not physiological fitness,
/// fatigue, or form and do not carry universal training thresholds.
private struct FitnessFatigueCard: View {
    @Environment(\.theme) private var theme
    let points: [FitnessFatigue.Point]
    @State private var selectedDate: Date?

    private var latest: FitnessFatigue.Point? { points.last }
    private var selectedPoint: FitnessFatigue.Point? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                if let latest {
                    HStack(spacing: Space.lg) {
                        legendValue("Long-term", value: latest.ctl, color: theme.accent)
                        legendValue("Short-term", value: latest.atl, color: theme.secondaryAccent)
                        legendValue("Balance", value: latest.tsb, color: theme.textSecondary, signed: true)
                    }
                }
                Chart {
                    ForEach(points, id: \.date) { point in
                        LineMark(x: .value("Day", point.date), y: .value("Long-term load", point.ctl), series: .value("Metric", "Long-term"))
                            .foregroundStyle(theme.accentForeground)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("Day", point.date), y: .value("Short-term load", point.atl), series: .value("Metric", "Short-term"))
                            .foregroundStyle(theme.secondaryAccentForeground)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        PointMark(x: .value("Day", point.date), y: .value("Long-term load", point.ctl))
                            .foregroundStyle(theme.accentForeground)
                            .symbolSize(20)
                        PointMark(x: .value("Day", point.date), y: .value("Short-term load", point.atl))
                            .foregroundStyle(theme.secondaryAccentForeground)
                            .symbolSize(20)
                    }
                    if let selectedPoint {
                        RuleMark(x: .value("Selected day", selectedPoint.date))
                            .foregroundStyle(theme.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartSelectionCallout(
                                    title: selectedPoint.date.formatted(date: .abbreviated, time: .omitted),
                                    lines: [
                                        ("Long-term", "\(Int(selectedPoint.ctl.rounded())) AU"),
                                        ("Short-term", "\(Int(selectedPoint.atl.rounded())) AU"),
                                        ("Balance", "\(Int(selectedPoint.tsb.rounded())) AU"),
                                    ]
                                )
                            }
                    }
                }
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
                    Text("Load (AU)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .pressHoldChartXSelection(value: $selectedDate)
                .frame(height: 150)
                Text(balanceLine)
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var balanceLine: String {
        guard let latest else { return "" }
        let direction = latest.tsb >= 0 ? "above" : "below"
        return "Long-term load is \(abs(Int(latest.tsb.rounded()))) AU \(direction) short-term load. This is training history, not a readiness prescription."
    }

    private func legendValue(_ label: String, value: Double, color: Color, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
            }
            Text(signed && value > 0 ? "+\(Int(value.rounded()))" : "\(Int(value.rounded()))")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
        }
    }
}

/// One-tap subjective context for today: the tags appear as reason chips
/// beside the readiness score (context, deliberately not scored) and build
/// the history Insights will correlate once there's enough of it.
private struct MorningCheckinCard: View {
    @Environment(\.theme) private var theme
    let selectedTags: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Morning check-in").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Text("How do you feel? Tags sit beside today's score — the sensors don't know everything.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(CheckinTags.all, id: \.id) { tag in
                        let on = selectedTags.contains(tag.id)
                        Button {
                            onToggle(tag.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tag.icon).font(.system(size: 11, weight: .semibold))
                                Text(tag.label).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(on ? .white : theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().fill(on ? theme.accent : theme.surfaceElevated)
                            )
                            .minimumTouchTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }
}

/// Shown when Garmin sleep is flowing into Apple Health but HRV isn't:
/// Garmin Connect may not sync HRV. The index can still appear when sleeping
/// heart rate and complete sleep meet the two-domain coverage gate.
private struct GarminHRVGapCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Garmin detected — HRV isn't synced", systemImage: "info.circle.fill")
                    .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Text("Garmin may not share HRV with Apple Health. ForgeFit will show that channel as unavailable; sleeping heart rate plus complete sleep can still support a coverage-limited index. A bridge app may provide a separate HRV source, which will build its own baseline.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Summary

private struct HRVTrendData {
    var points: [HRVBaselineBandChart.Point]
    var median: Double
    var lowerBound: Double
    var upperBound: Double
    var today: Double
    var usedRMSSD: Bool
}

/// Shows the HRV baseline band as evidence behind the one global daily verdict.
/// It reports the signal's state without issuing a competing training command.
private struct HRVTrendCard: View {
    @Environment(\.theme) private var theme
    let trend: HRVTrendData

    private var call: (icon: String, title: String, detail: String, tint: Color) {
        if trend.today < trend.lowerBound {
            return ("waveform.path.ecg", "HRV below your baseline",
                    "Today's HRV is below your recent source-consistent observed band. This is one input to today’s index, alongside sleep and heart rate.",
                    theme.danger)
        } else if trend.today > trend.upperBound {
            return ("waveform.path.ecg", "HRV above your baseline",
                    "HRV is above your usual observed range. Higher is not automatically better; interpret it with symptoms and the other signals.",
                    theme.secondaryAccent)
        } else {
            return ("waveform.path.ecg", "HRV within your usual observed range",
                    "HRV is within your recent comparable range and is not adding a recovery concern today.",
                    theme.secondaryAccent)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text("HRV vs baseline").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text("\(Int(trend.today.rounded())) ms · \(trend.usedRMSSD ? "RMSSD" : "SDNN")")
                        .font(.tag).foregroundStyle(theme.textSecondary)
                }
                HRVBaselineBandChart(
                    points: trend.points,
                    median: trend.median,
                    lowerBound: trend.lowerBound,
                    upperBound: trend.upperBound
                )
                HStack(alignment: .top, spacing: Space.sm) {
                    Image(systemName: call.icon).foregroundStyle(call.tint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(call.title).font(.system(size: 14, weight: .bold)).foregroundStyle(call.tint)
                        Text(call.detail).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .background(call.tint.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Text("A single night's HRV is noisy — it's the trend against your baseline band that's actionable, not any one reading.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RecoverySummaryCard: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        let daily = report.recovery.daily
        let isDailyScore = daily.state.value != nil
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .center, spacing: Space.lg) {
                    if let score = report.displayScore {
                        // Readiness green is a statement about today. When the
                        // ring is falling back to the seven-day trend there is
                        // no acute read to be green about, so the number goes
                        // neutral — it stays informative without the colour
                        // vouching for a morning it has no data on.
                        let tint = isDailyScore ? theme.readinessColor(score) : theme.textSecondary
                        ZStack {
                            Circle()
                                .fill(tint.opacity(0.14))
                            Circle()
                                .stroke(tint.opacity(0.45), lineWidth: 2)
                                .frame(width: 132, height: 132)
                            Text("\(Int((score * 100).rounded()))")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(tint)
                        }
                        .frame(width: 132, height: 132)
                        .accessibilityLabel(isDailyScore
                            ? "Recovery-signal index \(Int((score * 100).rounded()))"
                            : "Seven-day recovery trend \(Int((score * 100).rounded())); today's index is still building")
                    } else {
                        ZStack {
                            Circle().fill(theme.surfaceElevated)
                            Circle().stroke(theme.surfaceHighlight, lineWidth: 2)
                                .frame(width: 132, height: 132)
                            Text("—")
                                .font(.system(size: 48, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .frame(width: 132, height: 132)
                        .accessibilityLabel("Recovery-signal index is building")
                    }

                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            Text(isDailyScore ? "Today" : "7-day trend")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.textSecondary)
                                .textCase(.uppercase)
                            InfoButton {
                                onInfo(isDailyScore ? .dailyScore : .systemicScore)
                            }
                        }
                        HStack(spacing: Space.sm) {
                            Image(systemName: report.action.systemImage)
                                .font(.system(size: 15, weight: .bold))
                            Text(report.action.title)
                                .font(.cardTitle)
                        }
                        .foregroundStyle(report.action.tint(in: theme))

                        if FeatureFlags.recoveryActionDetail {
                            Text(report.preWorkoutAdjustment)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("recovery-action-detail")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // The exact conditions that moved the score — number and copy
                // share one source of truth.
                if !daily.flags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(daily.flags, id: \.self) { flag in
                            Text(flag)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.warmup)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(theme.warmup.opacity(0.14), in: Capsule())
                        }
                    }
                } else if case .building(let needed) = daily.state {
                    // Daily score still forming: the ring is falling back to the
                    // trend/composite, so say what unlocks the acute read.
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                        Text(needed)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Last night's signals — the evidence behind the ring.
                Divider().overlay(theme.separator)
                VStack(spacing: Space.md) {
                    ForEach(daily.parts) { part in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            if part.sleepOverrideStatus == .notTracked {
                                Image(systemName: "minus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 8)
                            } else if let value = part.state.value {
                                Circle().fill(theme.readinessColor(value)).frame(width: 8, height: 8)
                            } else {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 8)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(part.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    if let status = part.sleepOverrideStatus {
                                        SleepOverrideStatusBadge(status: status)
                                    }
                                }
                                Text(detailText(for: part))
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(part.valueText)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(part.state.value == nil ? theme.textTertiary : theme.textPrimary)
                        }
                    }
                }

                HStack(spacing: Space.sm) {
                    Text("Data coverage \(Int((report.dataCoverage * 100).rounded()))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    InfoButton { onInfo(.confidence) }
                    Spacer()
                    if let trend = report.trendScore {
                        HStack(spacing: 4) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 11, weight: .bold))
                            Text("7-day trend \(Int(trend * 100))")
                                .font(.tag)
                        }
                        .foregroundStyle(theme.readinessColor(trend))
                    }
                }
            }
        }
        .accessibilityIdentifier("recovery-today-summary")
    }

    private func detailText(for part: RecoveryEngine.ScorePart) -> String {
        if case .building(let needed) = part.state { return needed }
        return part.detailText
    }
}

// MARK: - Systemic score

private struct SystemicScoreCard: View {
    @Environment(\.theme) private var theme
    let systemic: RecoveryEngine.SystemicRecovery
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Whole body", systemImage: "figure.mind.and.body")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.systemicScore) }
                    Spacer()
                    ScoreBadge(state: systemic.state)
                }

                if let score = systemic.state.value {
                    ScoreBar(progress: score)
                }

                Text(guidanceText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(theme.separator)

                VStack(spacing: Space.md) {
                    ForEach(systemic.parts) { part in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            if part.sleepOverrideStatus == .notTracked {
                                Image(systemName: "minus")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 8)
                            } else if let value = part.state.value {
                                Circle().fill(theme.readinessColor(value)).frame(width: 8, height: 8)
                            } else {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 8)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(part.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    if let status = part.sleepOverrideStatus {
                                        SleepOverrideStatusBadge(status: status)
                                    }
                                }
                                Text(detailText(for: part))
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(part.valueText)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(part.state.value == nil ? theme.textTertiary : theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private var guidanceText: String {
        if case .building(let needed) = systemic.state { return needed }
        return systemic.guidance
    }

    private func detailText(for part: RecoveryEngine.ScorePart) -> String {
        if case .building(let needed) = part.state { return needed }
        return part.detailText
    }
}

// MARK: - Muscle scores

private struct MuscleRecoveryCard: View {
    @Environment(\.theme) private var theme
    let muscles: [RecoveryEngine.MuscleRecoveryScore]
    let onInfo: (RecoveryInfoTopic) -> Void
    @State private var expandedGroups: Set<String> = []

    private var musclesByName: [String: RecoveryEngine.MuscleRecoveryScore] {
        Dictionary(muscles.map { ($0.muscle, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func toggle(_ group: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedGroups.contains(group) {
                expandedGroups.remove(group)
            } else {
                expandedGroups.insert(group)
            }
        }
    }

    private func accessibilityValue(
        for muscle: RecoveryEngine.MuscleRecoveryScore,
        expanded: Bool
    ) -> String {
        var parts = [expanded ? "Expanded" : "Collapsed"]
        if let score = muscle.state.value {
            parts.append("\(Int((score * 100).rounded())), \(muscle.statusLabel)")
        } else {
            parts.append("No sets yet")
        }
        if let days = muscle.lastTrainedDaysAgo {
            parts.append(days == 0 ? "Trained today" : (days == 1 ? "Trained yesterday" : "Trained \(days) days ago"))
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Muscle freshness", systemImage: "figure.strengthtraining.traditional")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.muscleScore) }
                    Spacer()
                }

                VStack(spacing: Space.md) {
                    ForEach(MuscleTaxonomy.freshnessGroups) { group in
                        if let muscle = musclesByName[group.name] {
                            if group.children.isEmpty {
                                MuscleRecoveryRow(muscle: muscle)
                            } else {
                                let expanded = expandedGroups.contains(group.name)
                                Button {
                                    toggle(group.name)
                                } label: {
                                    HStack(spacing: Space.sm) {
                                        MuscleRecoveryRow(muscle: muscle)
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(theme.textTertiary)
                                            .rotationEffect(.degrees(expanded ? 90 : 0))
                                            .frame(width: 18, height: 44)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(MuscleTaxonomy.freshnessDisplayName(group.name)) freshness")
                                .accessibilityValue(accessibilityValue(for: muscle, expanded: expanded))
                                .accessibilityHint(expanded
                                    ? "Collapses muscle details"
                                    : "Shows \(group.children.map(MuscleTaxonomy.freshnessDisplayName).joined(separator: ", "))")
                                .accessibilityInputLabels([MuscleTaxonomy.freshnessDisplayName(group.name)])
                                .accessibilityIdentifier("muscle-freshness-toggle-\(group.name)")

                                if expanded {
                                    VStack(spacing: Space.md) {
                                        ForEach(group.children, id: \.self) { childName in
                                            if let child = musclesByName[childName] {
                                                MuscleRecoveryRow(muscle: child)
                                            }
                                        }
                                    }
                                    .padding(.leading, Space.md)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MuscleRecoveryRow: View {
    @Environment(\.theme) private var theme
    let muscle: RecoveryEngine.MuscleRecoveryScore

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MuscleTaxonomy.freshnessDisplayName(muscle.muscle))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(width: 104, alignment: .leading)

            if let score = muscle.state.value {
                ScoreBar(progress: score)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(score * 100))")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.readinessColor(score))
                    Text(trailingLabel(score: score))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(width: 62, alignment: .trailing)
            } else {
                Spacer()
                Text("No sets yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        guard let days = muscle.lastTrainedDaysAgo else { return "Not trained" }
        if days == 0 { return "Trained today" }
        if days == 1 { return "Trained yesterday" }
        return "Trained \(days)d ago"
    }

    private func trailingLabel(score: Double) -> String {
        return muscle.statusLabel
    }
}

// MARK: - Cardio score

private struct CardioRecoveryCard: View {
    @Environment(\.theme) private var theme
    let cardio: RecoveryEngine.CardioRecovery
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Cardio freshness", systemImage: "heart.circle.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.cardioScore) }
                    Spacer()
                    ScoreBadge(state: cardio.state)
                }

                if let score = cardio.state.value {
                    ScoreBar(progress: score)
                }

                if let lastSessionText = cardio.lastSessionText {
                    Text("Last load: \(lastSessionText)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }

                if case .building(let needed) = cardio.state {
                    Text(needed)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Shared score chrome

private struct ScoreBadge: View {
    @Environment(\.theme) private var theme
    let state: RecoveryEngine.ScoreState

    var body: some View {
        if let value = state.value {
            Text("\(Int(value * 100))")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.readinessColor(value))
        } else {
            Tag(text: "Needs data", color: theme.textSecondary, background: theme.surfaceHighlight)
        }
    }
}

private struct ScoreBar: View {
    @Environment(\.theme) private var theme
    let progress: Double

    var body: some View {
        ProgressBar(progress: progress, color: theme.readinessColor(progress))
            .frame(height: 6)
    }
}

// MARK: - Health signals

private struct HealthSignalRows: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report

    private var healthSignals: [RecoveryEngine.Signal] {
        report.signals
    }

    var body: some View {
        VStack(spacing: Space.md) {
            ForEach(healthSignals) { signal in
                Card(padding: Space.md) {
                    HStack(spacing: Space.md) {
                        Image(systemName: signal.systemImage)
                            .font(.bodyStrong)
                            .foregroundStyle(signal.connected ? theme.accent : theme.textTertiary)
                            .frame(width: 38, height: 38)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(signalHeadline(signal))
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(signal.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: Space.sm)

                        Text(signal.value)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(signal.connected ? theme.textPrimary : theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    private func signalHeadline(_ signal: RecoveryEngine.Signal) -> String {
        guard signal.connected else { return "Connect Apple Health for \(signal.name.lowercased())" }
        let chips = Set(report.reasonChips.map(\.text))
        switch signal.name {
        case "HRV":
            if chips.contains("HRV low today") { return "HRV is below your baseline today" }
            return "HRV is available"
        case "Resting HR":
            if chips.contains("Resting HR elevated") || chips.contains("Sleeping HR elevated") { return "Heart rate is elevated versus its comparable baseline" }
            return "Heart rate is available"
        case "Sleep":
            if chips.contains("Sleep excluded by you") { return "Sleep excluded by you" }
            if chips.contains("Short sleep") { return "Sleep was below your target" }
            return "Sleep duration is available"
        default:
            return "\(signal.name) is available"
        }
    }
}

// MARK: - Info sheets

private struct MetricInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let topic: RecoveryInfoTopic

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text(topic.title)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                }

                Text(topic.explanation)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let takeaway = topic.takeaway {
                    Card(padding: Space.md, fill: theme.surfaceElevated) {
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(theme.warmup)
                            Text(takeaway)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

            }
            .padding(Space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }
}

private enum RecoveryInfoTopic: String, Identifiable {
    case dailyScore
    case systemicScore
    case muscleScore
    case cardioScore
    case confidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dailyScore: "Recovery-signal index"
        case .systemicScore: "Seven-day recovery trend"
        case .muscleScore: "Muscle freshness"
        case .cardioScore: "Cardio freshness"
        case .confidence: "Data coverage"
        }
    }

    var explanation: String {
        switch self {
        case .dailyScore:
            return "A versioned personal index built from available comparable HRV, heart-rate, and sleep data. It is not percent recovered, biological readiness, or a guarantee of performance."
        case .systemicScore:
            return "A seven-day view of available HRV, heart-rate, and sleep trends. It uses source-consistent personal baselines and appears only when enough recent observations are available."
        case .muscleScore:
            return "A recency-weighted estimate of completed working sets, normalized to your typical dose for each muscle or body region. Set type, primary or secondary role, and logged RPE or RIR shape the estimate; it is not a biological recovery clock."
        case .cardioScore:
            return "A recency-weighted cardiovascular-load estimate normalized to your typical session. Measured heart-rate zones can contribute from any workout, including strength circuits; cardio and conditioning effort is used only when measured zones are unavailable."
        case .confidence:
            return "Shows comparable data availability and baseline maturity. It is not a statistical confidence interval. Missing data shrinks the score toward 50 and can withhold it entirely."
        }
    }

    var takeaway: String? {
        switch self {
        case .dailyScore:
            return "Use symptoms, your warm-up, planned RPE, and performance to decide. A high index never authorizes an automatic load increase."
        case .systemicScore:
            return "Treat this as a compressed trend view, then open the components to see what moved."
        case .muscleScore:
            return "Lower freshness means more recent modeled exposure, not incomplete biological recovery."
        case .cardioScore:
            return "A score of 50 means one typical session's modeled exposure remains; it does not mean 50% recovered."
        case .confidence:
            return "Low coverage means the score should be interpreted less strongly or withheld."
        }
    }

}

private struct InfoButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
    }
}

private struct ProgressBar: View {
    @Environment(\.theme) private var theme
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceHighlight)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * max(0.04, min(1, progress)))
            }
        }
        .frame(height: 6)
    }
}

// Theme-injected, NOT hardcoded to `AppTheme.sage`: these feed the app's
// most-viewed surfaces (Home hero, "Up next", recovery chips), and drawing
// dark-tuned signal colors on light-mode's white cards dropped contrast to
// ~1.8:1. `sageLight` deepens every signal hue for exactly this — pass the
// active theme through.
extension RecoveryEngine.Action {
    func tint(in theme: AppTheme) -> Color {
        switch self {
        case .insufficientData: return theme.textTertiary
        case .push: return theme.recoveryHigh
        case .trainAsPlanned: return theme.accent
        case .reduceVolume: return theme.warmup
        case .deloadRecover: return theme.recoveryLow
        }
    }
}

extension RecoveryEngine.ReasonTone {
    func foreground(in theme: AppTheme) -> Color {
        switch self {
        case .positive: return theme.recoveryHigh
        case .caution: return theme.warmup
        case .neutral: return theme.textSecondary
        }
    }

    func background(in theme: AppTheme) -> Color {
        switch self {
        case .positive: return theme.recoveryHigh.opacity(0.16)
        case .caution: return theme.warmup.opacity(0.16)
        case .neutral: return theme.surfaceHighlight
        }
    }
}
