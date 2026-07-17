import Charts
import SwiftUI

enum MetricDetailTab: Hashable {
    case today
    case trends
}

/// Shared shell for focused metric pages. The four Home tiles all use the same
/// Today/Trends interaction so switching metrics never means relearning the UI.
struct MetricDetailScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    @Binding var selectedTab: MetricDetailTab
    @ViewBuilder let content: () -> Content

    var body: some View {
        DashboardScaffold(title: title, dismiss: dismiss) {
            Picker("View", selection: $selectedTab) {
                Text("Today").tag(MetricDetailTab.today)
                Text("Trends").tag(MetricDetailTab.trends)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("\(title.lowercased())-detail-tabs")

            content()
        }
        .accessibilityIdentifier("\(title.lowercased())-detail")
    }
}

/// Generic personal-baseline chart used by Sleep and Health. The shaded band
/// is this user's mean +/- one standard deviation, not a population cutoff.
struct MetricBaselineBandChart: View {
    let trend: MetricTrendSeries
    let metricName: String
    let tint: Color

    @Environment(\.theme) private var theme

    var body: some View {
        Chart {
            ForEach(trend.points) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Low", trend.mean - trend.standardDeviation),
                    yEnd: .value("High", trend.mean + trend.standardDeviation)
                )
                .foregroundStyle(tint.opacity(0.12))
            }
            RuleMark(y: .value("Baseline", trend.mean))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(theme.textTertiary)
            ForEach(trend.points) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value(metricName, point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if let latest = trend.latest {
                PointMark(
                    x: .value("Date", latest.date),
                    y: .value(metricName, latest.value)
                )
                .foregroundStyle(tint)
                .symbolSize(80)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
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
        .frame(height: 170)
        .accessibilityLabel("\(metricName) trend against your personal baseline")
    }
}

struct MetricReadingRow: View {
    @Environment(\.theme) private var theme

    let title: String
    let value: String
    let systemImage: String
    var detail: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint ?? theme.accent)
                .frame(width: 38, height: 38)
                .background((tint ?? theme.accent).opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.sm)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MetricEmptyCard: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        EmptyStateCard(title: title, message: message, systemImage: systemImage)
    }
}
