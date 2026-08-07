import ForgeCore
import SwiftUI

/// A single live heart-rate readout shared by every phone workout surface.
/// It always occupies its place so a session that is still acquiring a first
/// sample does not look as though heart-rate support is missing.
struct LiveWorkoutHeartRateStat: View {
    @Environment(\.theme) private var theme

    var body: some View {
        let heartRate = LiveMetricsHub.shared.liveMetrics?.freshHeartRate()
        StatColumn(
            label: "HR",
            value: heartRate.map(String.init) ?? "—",
            valueColor: heartRate == nil ? theme.textTertiary : theme.danger,
            animatesValue: true
        )
        .accessibilityLabel(
            heartRate.map { "Live heart rate, \($0) beats per minute" }
                ?? "Live heart rate, acquiring"
        )
    }
}
