import Charts
import SwiftUI

/// The shared chart gesture used throughout ForgeFit. Selection begins only
/// after a deliberate press, then follows the user's finger across the plot.
extension View {
    func pressHoldChartXSelection<P: Plottable>(value: Binding<P?>) -> some View {
        chartXSelection(value: value)
            .chartGesture { proxy in
                LongPressGesture(minimumDuration: 0.2, maximumDistance: 20)
                    .simultaneously(with: DragGesture(minimumDistance: 0))
                    .onChanged { gesture in
                        guard gesture.first == true, let drag = gesture.second else { return }
                        proxy.selectXValue(at: drag.location.x)
                    }
            }
    }

    func pressHoldChartAngleSelection<P: Plottable>(value: Binding<P?>) -> some View {
        chartAngleSelection(value: value)
            .chartGesture { proxy in
                LongPressGesture(minimumDuration: 0.2, maximumDistance: 20)
                    .simultaneously(with: DragGesture(minimumDistance: 0))
                    .onChanged { gesture in
                        guard gesture.first == true, let drag = gesture.second else { return }
                        proxy.selectAngleValue(at: proxy.angle(at: drag.location))
                    }
            }
    }
}

/// Compact exact-value callout shared by interactive charts.
struct ChartSelectionCallout: View {
    let title: String
    let lines: [(label: String, value: String)]

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 4) {
                    if !line.label.isEmpty {
                        Text(line.label)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Text(line.value)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
            }
        }
        .padding(6)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(lines.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        .accessibilityIdentifier("chart-selected-measurement")
    }
}
