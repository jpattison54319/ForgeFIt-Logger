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
            .frame(minHeight: TouchTarget.minimum)
            .accessibilityIdentifier("\(title.lowercased())-detail-tabs")

            content()
        }
        .accessibilityIdentifier("\(title.lowercased())-detail")
    }
}

/// Generic personal-baseline chart used by Sleep and Health. The shaded band
/// is this user's 10th-to-90th percentile usual observed band, not a
/// population cutoff or a medical normal range.
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
                    yStart: .value("Low", trend.lowerBound),
                    yEnd: .value("High", trend.upperBound)
                )
                .foregroundStyle(tint.opacity(0.12))
            }
            RuleMark(y: .value("Baseline median", trend.median))
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
        .accessibilityLabel("\(metricName) trend against your usual observed band")
        .accessibilityValue(chartAccessibilityValue)
    }

    private var chartAccessibilityValue: String {
        let latest = trend.latest?.value.formatted(.number.precision(.fractionLength(1))) ?? "unavailable"
        let lower = trend.lowerBound.formatted(.number.precision(.fractionLength(1)))
        let upper = trend.upperBound.formatted(.number.precision(.fractionLength(1)))
        return "Latest \(latest). Usual range \(lower) to \(upper). \(trend.points.count) observations."
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

/// A visible, familiar route to optional explanation. The summary remains
/// scannable while interpretation details stay one tap away.
struct MetricInfoLink: View {
    @Environment(\.theme) private var theme

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(theme.secondaryAccent)
                    Text(title)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens an explanation")
    }
}

struct MetricExplanationItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String

    init(_ title: String, detail: String, systemImage: String) {
        id = title
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

struct MetricExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let title: String
    let summary: String
    let items: [MetricExplanationItem]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text(title)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                }

                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: Space.lg) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: Space.md) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.secondaryAccent)
                                .frame(width: 28, height: 28)
                                .background(theme.secondaryAccent.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text(item.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(Space.lg)
        }
        .background(theme.background)
    }
}
