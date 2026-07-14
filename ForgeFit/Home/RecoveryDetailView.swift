import Charts
import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Full recovery breakdown focused on action first: what to do today, why the
/// app thinks that, and only then the supporting details. Leads with three
/// evidence-based scores — systemic, per-muscle, and cardio — each of which
/// admits when it doesn't have enough data yet.
struct RecoveryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    var exercises: [ExerciseLibraryModel] = []

    @State private var selectedInfo: RecoveryInfoTopic?
    @State private var selectedTab: Tab = .today
    @State private var reportMemo = Memo<String, RecoveryEngine.Report>()
    @Query private var checkins: [DailyCheckinModel]

    private var todayCheckin: DailyCheckinModel? {
        checkins
            .filter { $0.deletedAt == nil && Calendar.current.isDate($0.date, inSameDayAs: Date()) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private var report: RecoveryEngine.Report {
        reportMemo("\(AnalyticsFingerprint.withHealth(workouts))|\(todayCheckin?.tagsRaw ?? "")") {
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
        let model: DailyCheckinModel
        if let existing = todayCheckin {
            model = existing
        } else {
            model = DailyCheckinModel(userID: ForgeFitDemo.userID, date: Calendar.current.startOfDay(for: Date()))
            modelContext.insert(model)
        }
        var tags = model.tags
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        model.tags = tags
        model.updatedAt = Date()
        try? modelContext.save()
    }

    /// Daily HRV over the last ~45 days with its mean/SD baseline band — the
    /// substrate for the honest "trend, not one night" display. nil until there
    /// are enough readings to form a baseline.
    private var hrvTrend: HRVTrendData? {
        let metrics = HealthMetricsStore.shared.metrics.sorted { $0.date < $1.date }.suffix(45)
        guard let channel = HealthMetricChannelSeries.hrv(metrics: Array(metrics)) else { return nil }
        let usedRMSSD = metrics.contains { $0.hrvRMSSD != nil || $0.nocturnalHRV != nil }
        let values = channel.values.map { ($0.date, $0.value) }
        guard values.count >= 7, let today = values.last?.1 else { return nil }
        let all = channel.baselineValues.isEmpty ? values.map(\.1) : channel.baselineValues
        let mean = all.reduce(0, +) / Double(all.count)
        let variance = all.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(all.count)
        return HRVTrendData(
            points: values.map { .init(date: $0.0, value: $0.1) },
            mean: mean,
            sd: variance.squareRoot(),
            today: today,
            usedRMSSD: usedRMSSD
        )
    }

    /// CTL/ATL/TSB over the last 90 days from the same session loads the
    /// readiness engine uses. The (now, 0) sentinel extends the decay walk
    /// through today so a week off shows honestly falling fitness.
    private var fitnessFatigue: [FitnessFatigue.Point] {
        let engine = RecoveryEngine(workouts: workouts, exercises: exercises)
        let loads = engine.completed.map { ($0.startedAt, engine.sessionLoad($0)) } + [(Date(), 0.0)]
        return Array(FitnessFatigue.series(dailyLoads: loads).suffix(90))
    }

    var body: some View {
        let report = self.report
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                Picker("View", selection: $selectedTab) {
                    Text("Today").tag(Tab.today)
                    Text("Trends").tag(Tab.trends)
                }
                .pickerStyle(.segmented)

                switch selectedTab {
                case .today:
                    RecoverySummaryCard(report: report) { selectedInfo = $0 }

                    ReadinessReasonList(report: report)

                    MorningCheckinCard(
                        selectedTags: Set(todayCheckin?.tags ?? []),
                        onToggle: toggleCheckinTag
                    )

                    AdvancedLoadDisclosure(report: report) { selectedInfo = $0 }

                case .trends:
                    if HealthMetricsStore.shared.hrvGapDetected {
                        GarminHRVGapCard()
                    }

                    SystemicScoreCard(systemic: report.recovery.systemic) { selectedInfo = $0 }

                    if let trend = hrvTrend {
                        HRVTrendCard(trend: trend, readiness: report.displayScore)
                    }

                    MuscleRecoveryCard(muscles: report.recovery.muscles) { selectedInfo = $0 }

                    CardioRecoveryCard(cardio: report.recovery.cardio) { selectedInfo = $0 }

                    // The chart needs ~2 weeks of history before the curves mean
                    // anything; below that it reads as noise with an axis.
                    if fitnessFatigue.count >= 14 {
                        SectionHeader("Fitness vs fatigue")
                        FitnessFatigueCard(points: fitnessFatigue)
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        // Pull down to re-query Apple Health and recompute readiness.
        .refreshable { await AppRefresh.run(in: modelContext) }
        .sheet(item: $selectedInfo) { topic in
            MetricInfoSheet(topic: topic)
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            VStack(spacing: 0) {
                Text("Recovery").font(.rowValue).foregroundStyle(theme.textPrimary)
                Text(Date.now, format: .dateTime.month(.abbreviated).day().weekday(.abbreviated))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            // Match the leading button's 44 pt so the title centers optically.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, Space.sm)
    }
}

private enum Tab: Hashable {
    case today, trends
}

/// The classic training-load chart: fitness (CTL, 42-day) builds slowly,
/// fatigue (ATL, 7-day) swings fast, and form (TSB = fitness − fatigue)
/// says whether you're fresh or buried. Same session loads as readiness —
/// one load model everywhere, never two stories.
private struct FitnessFatigueCard: View {
    @Environment(\.theme) private var theme
    let points: [FitnessFatigue.Point]

    private var latest: FitnessFatigue.Point? { points.last }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                if let latest {
                    HStack(spacing: Space.lg) {
                        legendValue("Fitness", value: latest.ctl, color: theme.accent)
                        legendValue("Fatigue", value: latest.atl, color: theme.secondaryAccent)
                        legendValue("Form", value: latest.tsb, color: latest.tsb >= 0 ? theme.success : theme.recoveryMid, signed: true)
                    }
                }
                Chart(points, id: \.date) { point in
                    LineMark(x: .value("Day", point.date), y: .value("Fitness", point.ctl), series: .value("Metric", "Fitness"))
                        .foregroundStyle(theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    LineMark(x: .value("Day", point.date), y: .value("Fatigue", point.atl), series: .value("Metric", "Fatigue"))
                        .foregroundStyle(theme.secondaryAccent)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                        AxisValueLabel().foregroundStyle(theme.textTertiary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .frame(height: 150)
                Text(formLine)
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var formLine: String {
        guard let latest else { return "" }
        if latest.tsb >= 5 {
            return "Form is positive — fitness is banked and fatigue has cleared. Good window for a hard session or a test."
        }
        if latest.tsb <= -15 {
            return "Deep in fatigue — you're building, but plan the recovery that lets it turn into fitness."
        }
        return "Fitness and fatigue are balanced — productive training territory."
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
/// Garmin Connect doesn't sync HRV, so readiness re-weights to sleeping HR +
/// sleep. Explains the gap honestly rather than showing an empty HRV row.
private struct GarminHRVGapCard: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Garmin detected — HRV isn't synced", systemImage: "info.circle.fill")
                    .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Text("Garmin doesn't share HRV with Apple Health, so readiness re-weights to sleeping heart rate and sleep — still a solid signal. A bridge app like HealthFit or Health Sync can copy HRV across.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Summary

private struct HRVTrendData {
    var points: [HRVBaselineBandChart.Point]
    var mean: Double
    var sd: Double
    var today: Double
    var usedRMSSD: Bool
    /// How many standard deviations today sits from the baseline mean.
    var z: Double { sd > 0 ? (today - mean) / sd : 0 }
}

/// Shows the HRV baseline band as evidence behind the one global daily verdict.
/// It reports the signal's state without issuing a competing training command.
private struct HRVTrendCard: View {
    @Environment(\.theme) private var theme
    let trend: HRVTrendData
    let readiness: Double   // 0...1

    private var call: (icon: String, title: String, detail: String, tint: Color) {
        let z = trend.z
        if z <= -1 {
            return ("waveform.path.ecg", "HRV below your baseline",
                    "Today's HRV is \(abs(z).formatted(.number.precision(.fractionLength(1)))) SD below your baseline. This is one input to today’s verdict, alongside sleep and overnight heart rate.",
                    theme.danger)
        } else if z >= 1 && readiness >= 0.7 {
            return ("waveform.path.ecg", "HRV above your baseline",
                    "HRV is above your normal range this morning and supports the day’s readiness picture.",
                    theme.success)
        } else {
            return ("waveform.path.ecg", "HRV within your normal range",
                    "HRV is within your usual range and is not adding a recovery concern today.",
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
                HRVBaselineBandChart(points: trend.points, mean: trend.mean, sd: trend.sd)
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
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .center, spacing: Space.lg) {
                    ZStack {
                        ProgressRing(progress: report.displayScore, lineWidth: 14, color: theme.readinessColor(report.displayScore))
                            .frame(width: 132, height: 132)
                        Text("\(Int(report.displayScore * 100))")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .accessibilityLabel("Readiness score \(Int(report.displayScore * 100))")

                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            Text("Today")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.textSecondary)
                                .textCase(.uppercase)
                            InfoButton { onInfo(.dailyScore) }
                        }
                        HStack(spacing: Space.sm) {
                            Image(systemName: report.action.systemImage)
                                .font(.system(size: 15, weight: .bold))
                            Text(report.action.title)
                                .font(.cardTitle)
                        }
                        .foregroundStyle(report.action.tint(in: theme))

                        Text(report.preWorkoutAdjustment)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
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

                Text(report.recommendation)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                    Text("Confidence \(Int(report.confidence * 100))%")
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

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Per muscle", systemImage: "figure.strengthtraining.traditional")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.muscleScore) }
                    Spacer()
                }

                if muscles.allSatisfy({ $0.state.value == nil }) {
                    Text("Log strength workouts and each muscle gets its own recovery estimate here.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    VStack(spacing: Space.md) {
                        ForEach(muscles) { muscle in
                            MuscleRecoveryRow(muscle: muscle)
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
                Text(muscle.muscle.capitalized)
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
                    Text("\(Int(score * 100))%")
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
    }

    private var subtitle: String {
        guard let days = muscle.lastTrainedDaysAgo else { return "Not trained" }
        if days == 0 { return "Trained today" }
        if days == 1 { return "Trained yesterday" }
        return "Trained \(days)d ago"
    }

    private func trailingLabel(score: Double) -> String {
        if score >= 0.9 { return "Ready" }
        if let hours = muscle.readyInHours {
            return hours >= 24 ? "~\((Double(hours) / 24).formatted(.number.precision(.fractionLength(0...1))))d" : "~\(hours)h"
        }
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
                    Label("Cardiovascular", systemImage: "heart.circle.fill")
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
                    Text("Last session: \(lastSessionText)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }

                Text(guidanceText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var guidanceText: String {
        if case .building(let needed) = cardio.state { return needed }
        return cardio.guidance
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

// MARK: - Reasons

private struct ReadinessReasonList: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Why this recommendation")

            HStack(spacing: Space.sm) {
                ForEach(report.reasonChips.prefix(3)) { chip in
                    Tag(text: chip.text, color: chip.tone.foreground(in: theme), background: chip.tone.background(in: theme))
                }
            }

            if !report.insights.isEmpty {
                Card(padding: Space.md, fill: theme.surfaceElevated) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(report.insights.prefix(2)), id: \.self) { insight in
                            HStack(alignment: .top, spacing: Space.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                                    .padding(.top, 2)
                                Text(insight)
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
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
            if chips.contains("HRV low trend") { return "HRV has been low for multiple readings" }
            if chips.contains("HRV low today") { return "HRV is below your baseline today" }
            if chips.contains("HRV normal") { return "HRV is near your baseline" }
            return "HRV baseline is building"
        case "Resting HR":
            if chips.contains("RHR elevated") { return "Resting heart rate is elevated" }
            if chips.contains("RHR normal") { return "Resting heart rate is near baseline" }
            return "Resting heart rate baseline is building"
        case "Sleep":
            if chips.contains("Sleep excluded by you") { return "Sleep excluded by you" }
            if chips.contains("Sleep debt") { return "Sleep debt is high enough to matter" }
            if chips.contains("Sleep slightly short") { return "Sleep is a little short" }
            if chips.contains("Sleep okay") { return "Sleep is supporting normal training" }
            return "Sleep history is building"
        default:
            return "\(signal.name) is available"
        }
    }
}

// MARK: - Advanced load

private struct AdvancedLoadDisclosure: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report
    let onInfo: (RecoveryInfoTopic) -> Void
    @State private var expanded = false

    private var baselineValue: String {
        report.trainingLoad.state == .building
            ? "—"
            : Int(report.chronicLoad.rounded()).formatted()
    }

    private var comparisonValue: String {
        switch report.trainingLoad.state {
        case .building:
            return "\(report.trainingLoad.baselineDaysAvailable)/28d"
        case .noRecentLoad:
            return "No baseline"
        case .sparseBaseline:
            return "Too light"
        case .ready:
            guard let ratio = report.loadRatio else { return "—" }
            let percent = Int((abs(ratio - 1) * 100).rounded())
            if percent <= 5 { return "Near" }
            return "\(percent)% \(ratio > 1 ? "above" : "below")"
        }
    }

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Descriptive context only. This comparison does not change readiness or predict injury.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        StatColumn(label: "Last 7d", value: Int(report.acuteLoad.rounded()).formatted())
                        StatColumn(label: "Prior 4w avg", value: baselineValue)
                        StatColumn(label: "Comparison", value: comparisonValue)
                    }

                    HStack {
                        StatColumn(label: "Strength", value: Int(report.strengthLoad).formatted())
                        StatColumn(label: "Cardio", value: Int(report.cardioLoad).formatted())
                        StatColumn(label: "Monotony", value: report.monotony.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "-")
                    }

                    if report.trainingLoad.state == .building {
                        Text("ForgeFit needs \(report.trainingLoad.baselineDaysRemaining) more prior day\(report.trainingLoad.baselineDaysRemaining == 1 ? "" : "s") before showing a comparison.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if report.trainingLoad.state == .sparseBaseline {
                        Text("The prior 4 weeks carry too little logged load to compare against — a percentage of almost nothing would read as a spike no matter what you did this week.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if report.trainingLoad.estimatedEffortSessionCount > 0 {
                        Text("Effort was estimated for \(report.trainingLoad.estimatedEffortSessionCount) session\(report.trainingLoad.estimatedEffortSessionCount == 1 ? "" : "s") with no directly logged effort.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !report.missingInputs.isEmpty {
                        Text("Missing: \(report.missingInputs.joined(separator: ", "))")
                            .font(.label)
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Space.md)
            } label: {
                HStack(spacing: Space.sm) {
                    Text("Advanced load details")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.trainingLoad) }
                    Spacer()
                }
            }
            .tint(theme.textSecondary)
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

                if let evidence = topic.evidence {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Grounded in")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                            .textCase(.uppercase)
                        ForEach(evidence, id: \.self) { line in
                            HStack(alignment: .top, spacing: Space.sm) {
                                Image(systemName: "book.closed.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.top, 2)
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
    case trainingLoad
    case confidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dailyScore: "Today's readiness"
        case .systemicScore: "Recovery trend"
        case .muscleScore: "Muscle recovery"
        case .cardioScore: "Cardio recovery"
        case .trainingLoad: "Training load"
        case .confidence: "Confidence"
        }
    }

    var explanation: String {
        switch self {
        case .dailyScore:
            return "Compares last night's HRV, sleeping heart rate, and sleep against your own baseline. It's deliberately reactive — one rough night will move it."
        case .systemicScore:
            return "The slow-moving picture: 7-day HRV, sleep, and resting heart rate against your baseline. It answers \"how has recovery been trending\" rather than \"how am I today\"."
        case .muscleScore:
            return "Each muscle recovers on its own clock — a session deposits fatigue based on your sets and how close to failure they were, clearing over roughly 24–72 hours. Bigger muscles recover more slowly."
        case .cardioScore:
            return "Cardio stress depends on intensity, not just minutes. Easy Zone 2 clears in about a day; hard intervals can take two to three."
        case .trainingLoad:
            return "Strength load counts every completed working set — sets closer to failure and technique sets like myo-reps or drop sets count for more, and with failure training on, an unlogged effort counts as failure. Cardio load is minutes weighted by time in heart-rate zones, or by your logged effort when you rated the session. The last 7 days compare against the preceding 28 non-overlapping days only once that full history exists."
        case .confidence:
            return "Reflects how complete the health signals behind the recommendation are. Consistent HRV, resting heart rate, and sleep data make it more reliable."
        }
    }

    var takeaway: String? {
        switch self {
        case .dailyScore:
            return "Use the action first — Push, Train as planned, Reduce volume, or Deload. A low morning after good weeks usually means: train, but leave PRs for another day; a low morning during a low trend means back off."
        case .systemicScore:
            return "One rough night or one low HRV morning rarely matters here — sustained trends against your own baseline are the real signal."
        case .muscleScore:
            return "A fatigued muscle doesn't mean skipping the gym. Rotate to a muscle that shows Ready, or train the fatigued one lighter."
        case .cardioScore:
            return "You can layer easy Zone 2 on most days. It's back-to-back hard interval days that this score will warn you about."
        case .trainingLoad:
            return "Use this to understand how recent training differs from your own history, not as an injury warning or an automatic reason to change today's workout."
        case .confidence:
            return "Low confidence does not mean the recommendation is useless; it means the app is being appropriately humble."
        }
    }

    var evidence: [String]? {
        switch self {
        case .dailyScore:
            return [
                "Plews et al. 2013 (Sports Med) — HRV is log-normal; baselines and smallest-worthwhile-change belong in ln space.",
                "Buchheit 2014 (Front Physiol) — judge HRV and heart rate against your own baseline variability, ideally measured overnight.",
                "Fullagar et al. 2015 (Sports Med) — sleep loss measurably impairs strength, sprint, and endurance performance.",
            ]
        case .systemicScore:
            return [
                "Plews et al. 2013 (Sports Med) — 7-day rolling HRV averages track training status better than single readings.",
                "Buchheit 2014 (Front Physiol) — interpret HRV and resting HR against your own baseline variability.",
                "Fullagar et al. 2015 (Sports Med) — sleep loss measurably impairs strength, sprint, and endurance performance.",
            ]
        case .muscleScore:
            return [
                "McLester et al. 2003 (JSCR) — force recovery commonly needs 48–72 h after a full resistance bout.",
                "Morán-Navarro et al. 2017 (Eur J Appl Physiol) — training to failure lengthens recovery by 24–48 h versus stopping short.",
                "Schoenfeld et al. 2016 (Sports Med) — training each muscle ~2×/week implies roughly 48–72 h between hard sessions.",
            ]
        case .cardioScore:
            return [
                "Stanley, Peake & Buchheit 2013 (Sports Med) — parasympathetic recovery: ≈24 h after easy sessions, 24–48 h after threshold, 48 h+ after high-intensity work.",
                "Seiler 2010 (IJSPP) — most endurance volume belongs at low intensity precisely because it recovers quickly.",
            ]
        case .trainingLoad:
            return [
                "Foster et al. 2001 (JSCR) — session RPE: duration × perceived effort as the common currency of internal load.",
                "Edwards' summated heart-rate-zone method — minutes in higher zones count for more load than the same minutes lower down.",
                "Pareja-Blanco et al. 2017 (Scand J Med Sci Sports) — sets taken closer to failure produce disproportionately more fatigue and slower recovery.",
                "Refalo et al. 2023 (Sports Med) — proximity-to-failure meta-analysis behind weighting each set by how hard it was.",
                "Sødal et al. 2023; Prestes et al. 2019 — drop-set and rest-pause equivalences behind the effective-set weights.",
                "Impellizzeri et al. 2020 (IJSPP); Coyne et al. 2019 — workload ratios have real conceptual limits, so this comparison stays descriptive.",
            ]
        case .confidence:
            return nil
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
                .frame(width: 24, height: 24)
                // Hit-slop to the HIG 44 pt minimum without moving layout:
                // the glyph stays 24 pt, the tappable area extends outward.
                .contentShape(Rectangle().inset(by: -10))
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
