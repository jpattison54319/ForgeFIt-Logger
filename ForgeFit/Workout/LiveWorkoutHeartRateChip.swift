import ForgeCore
import SwiftUI

/// Compact live heart-rate presence for focused workout headers that cover the
/// logger's full stats bar. The chip keeps its place while acquiring so heart-
/// rate support does not appear and disappear as samples arrive.
struct LiveWorkoutHeartRateChip: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let heartRate = LiveMetricsHub.shared.liveMetrics?.freshHeartRate()

        Label {
            Text(heartRate.map(String.init) ?? "—")
                .monospacedDigit()
                .foregroundStyle(heartRate == nil ? theme.textTertiary : theme.danger)
                .contentTransition(.numericText())
        } icon: {
            Image(systemName: "heart.fill")
                .foregroundStyle(heartRate == nil ? theme.textTertiary : theme.danger)
        }
        .font(.bodyStrong)
        .padding(.horizontal, Space.md)
        .frame(minHeight: TouchTarget.minimum)
        .background(theme.surfaceElevated)
        .clipShape(.capsule)
        .animation(Motion.stateChange, value: heartRate)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live heart rate")
        .accessibilityValue(
            heartRate.map { "\($0) beats per minute" } ?? "Acquiring"
        )
        .accessibilityIdentifier("guided-myo-live-heart-rate")
    }
}
