import SwiftUI

/// Three-column status hero shown at the top of the settings list. Gives an
/// at-a-glance summary of Apple Health, Apple Watch, and Bluetooth HR monitor
/// connection state. Values are passed in from the parent so this remains a
/// pure view with no service dependencies.
struct ConnectionStatusHero: View {
    @Environment(\.theme) private var theme

    let healthConnected: Bool
    let watchPaired: Bool
    let hrmConnected: Bool

    var body: some View {
        HStack(spacing: 0) {
            column(
                icon: "heart.fill",
                label: "Health",
                connected: healthConnected,
                tint: theme.danger
            )
            divider
            column(
                icon: "applewatch",
                label: "Watch",
                connected: watchPaired,
                tint: theme.accent
            )
            divider
            column(
                icon: "sensor.tag.radiowaves.forward.fill",
                label: "HRM",
                connected: hrmConnected,
                tint: theme.danger
            )
        }
        .padding(.vertical, Space.md)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(width: 1)
            .padding(.vertical, Space.sm)
    }

    private func column(icon: String, label: String, connected: Bool, tint: Color) -> some View {
        VStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            HStack(spacing: 3) {
                Circle()
                    .fill(connected ? theme.success : theme.textTertiary)
                    .frame(width: 7, height: 7)
                Text(connected ? "On" : "Off")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(connected ? theme.success : theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(connected ? "connected" : "not connected")")
    }
}
