import SwiftData
import SwiftUI

struct SleepDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let metrics: [RecoveryEngine.DailyHealthMetric]
    @State private var selectedTab: MetricDetailTab = .today

    private var latest: RecoveryEngine.DailyHealthMetric? {
        metrics.max { $0.date < $1.date }
    }

    private var trend: MetricTrendSeries? {
        let recent = metrics.sorted { $0.date < $1.date }.suffix(45)
        let usable = recent.filter { $0.sleepIsTrustworthy && $0.sleepOverrideStatus != .notTracked }
        let values = usable.compactMap { metric -> (date: Date, value: Double)? in
            metric.sleepTotalMinutes.map { (metric.date, Double($0) / 60) }
        }
        let baseline = usable
            .dropLast()
            .filter { !$0.sleepUserCorrected }
            .compactMap { $0.sleepTotalMinutes.map { Double($0) / 60 } }
        return MetricTrendSeries.make(values: values, baselineValues: baseline)
    }

    var body: some View {
        MetricDetailScaffold(title: "Sleep", selectedTab: $selectedTab) {
            switch selectedTab {
            case .today:
                todayContent
            case .trends:
                trendsContent
            }
        }
        .refreshable { await AppRefresh.run(in: modelContext) }
    }

    @ViewBuilder
    private var todayContent: some View {
        if let latest {
            sleepSummary(latest)

            if let deep = latest.sleepDeepMinutes,
               let rem = latest.sleepREMMinutes,
               let total = latest.sleepTotalMinutes,
               deep + rem > 0 {
                sleepStages(total: total, deep: deep, rem: rem, awake: latest.sleepAwakeMinutes)
            }

            if latest.sleepStart != nil || latest.sleepEnd != nil {
                sleepTiming(latest)
            }

            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("How ForgeFit uses sleep", systemImage: "checkmark.shield.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Duration is compared with your sleep need and your own recent nights. A partial or excluded night is not treated as zero sleep, and manually corrected nights do not reshape your baseline.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            MetricEmptyCard(
                title: "No sleep recorded",
                message: "Connect Apple Health to see last night's duration and your personal trend.",
                systemImage: "moon.zzz"
            )
        }
    }

    @ViewBuilder
    private var trendsContent: some View {
        if let trend {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sleep duration")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Last \(trend.points.count) tracked nights")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text(SleepMetricPresentation.duration(Int((trend.mean * 60).rounded())))
                            .font(.tag)
                            .foregroundStyle(theme.textSecondary)
                    }
                    MetricBaselineBandChart(trend: trend, metricName: "Sleep hours", tint: theme.zone2)
                    Text("The shaded band is your personal normal range. Corrected nights can appear in the history, but they do not move that range.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            recentNights
        } else {
            MetricEmptyCard(
                title: "Sleep trend is building",
                message: "Seven consistent nights unlock your personal range and trend chart.",
                systemImage: "chart.line.uptrend.xyaxis"
            )
        }
    }

    private func sleepSummary(_ metric: RecoveryEngine.DailyHealthMetric) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last night")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .textCase(.uppercase)
                        Text(SleepMetricPresentation.value(for: metric))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(metric.sleepLikelyPartial && !metric.sleepUserCorrected ? theme.warmup : theme.zone2)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: Space.md)
                    if let status = metric.sleepOverrideStatus {
                        SleepOverrideStatusBadge(status: status)
                    }
                }

                if metric.sleepOverrideStatus != .notTracked, let minutes = metric.sleepTotalMinutes {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Sleep need")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text(SleepMetricPresentation.duration(metric.sleepNeedMinutes))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                        }
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.surfaceElevated)
                                Capsule()
                                    .fill(theme.zone2)
                                    .frame(width: max(6, proxy.size.width * min(1, Double(minutes) / Double(max(1, metric.sleepNeedMinutes)))))
                            }
                        }
                        .frame(height: 8)
                    }
                }

                HStack(alignment: .top, spacing: Space.sm) {
                    Image(systemName: summaryIcon(metric))
                        .foregroundStyle(summaryTint(metric))
                    Text(SleepMetricPresentation.caption(for: metric))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(summaryTint(metric))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("sleep-today-summary")
    }

    private func sleepStages(total: Int, deep: Int, rem: Int, awake: Int?) -> some View {
        let core = max(0, total - deep - rem)
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Sleep stages")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                MetricReadingRow(title: "Deep", value: SleepMetricPresentation.duration(deep), systemImage: "bed.double.fill", tint: theme.zone2)
                Divider().overlay(theme.separator)
                MetricReadingRow(title: "REM", value: SleepMetricPresentation.duration(rem), systemImage: "brain.head.profile", tint: theme.secondaryAccent)
                Divider().overlay(theme.separator)
                MetricReadingRow(title: "Core", value: SleepMetricPresentation.duration(core), systemImage: "moon.fill", tint: theme.accent)
                if let awake {
                    Divider().overlay(theme.separator)
                    MetricReadingRow(title: "Awake", value: SleepMetricPresentation.duration(awake), systemImage: "sun.max.fill", tint: theme.warmup)
                }
            }
        }
    }

    private func sleepTiming(_ metric: RecoveryEngine.DailyHealthMetric) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Timing")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                if let start = metric.sleepStart {
                    MetricReadingRow(title: "Fell asleep", value: start.formatted(date: .omitted, time: .shortened), systemImage: "moon.fill", tint: theme.zone2)
                }
                if metric.sleepStart != nil, metric.sleepEnd != nil {
                    Divider().overlay(theme.separator)
                }
                if let end = metric.sleepEnd {
                    MetricReadingRow(title: "Woke up", value: end.formatted(date: .omitted, time: .shortened), systemImage: "sunrise.fill", tint: theme.warmup)
                }
            }
        }
    }

    private var recentNights: some View {
        let nights = metrics
            .filter { $0.sleepTotalMinutes != nil && $0.sleepOverrideStatus != .notTracked }
            .sorted { $0.date > $1.date }
            .prefix(7)
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Recent nights")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                ForEach(Array(nights.enumerated()), id: \.offset) { index, metric in
                    if index > 0 { Divider().overlay(theme.separator) }
                    MetricReadingRow(
                        title: metric.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                        value: metric.sleepTotalMinutes.map { SleepMetricPresentation.duration($0) } ?? "-",
                        systemImage: metric.sleepUserCorrected ? "pencil" : "moon.fill",
                        detail: metric.sleepOverrideStatus?.detailPrefix,
                        tint: metric.sleepLikelyPartial && !metric.sleepUserCorrected ? theme.warmup : theme.zone2
                    )
                }
            }
        }
    }

    private func summaryIcon(_ metric: RecoveryEngine.DailyHealthMetric) -> String {
        if metric.sleepOverrideStatus == .notTracked { return "eye.slash.fill" }
        if metric.sleepLikelyPartial && !metric.sleepUserCorrected { return "exclamationmark.triangle.fill" }
        guard let minutes = metric.sleepTotalMinutes else { return "minus.circle.fill" }
        return minutes >= metric.sleepNeedMinutes ? "checkmark.circle.fill" : "clock.fill"
    }

    private func summaryTint(_ metric: RecoveryEngine.DailyHealthMetric) -> Color {
        if metric.sleepLikelyPartial && !metric.sleepUserCorrected { return theme.warmup }
        if metric.sleepOverrideStatus == .notTracked { return theme.textSecondary }
        guard let minutes = metric.sleepTotalMinutes else { return theme.textSecondary }
        return minutes >= metric.sleepNeedMinutes ? theme.success : theme.textSecondary
    }
}
