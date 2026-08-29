import SwiftUI

struct MicrocycleCompactPrimaryActionLabel: View {
    @Environment(\.theme) private var theme

    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .allowsTightening(true)
            .frame(minWidth: 32)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .foregroundStyle(theme.onAccent)
            .glassEffect(.regular.tint(theme.accent).interactive(), in: Capsule())
            .frame(minHeight: TouchTarget.minimum)
            .contentShape(Rectangle())
    }
}
