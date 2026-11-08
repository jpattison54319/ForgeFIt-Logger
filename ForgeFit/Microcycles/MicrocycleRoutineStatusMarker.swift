import SwiftUI

struct MicrocycleRoutineStatusMarker: View {
    static let diameter: CGFloat = 28

    @Environment(\.theme) private var theme

    let marker: String
    let isCompleted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isCompleted ? theme.accent : .clear)
            Circle()
                .strokeBorder(
                    isCompleted ? theme.accent : theme.textTertiary,
                    lineWidth: 1.5
                )
            Text(marker)
                .font(.caption.bold())
                .foregroundStyle(isCompleted ? theme.background : theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(3)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }
}
