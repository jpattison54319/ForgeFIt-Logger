import SwiftUI

struct TrophyShelfItem: View {
    @Environment(\.theme) private var theme
    let trophy: Trophy

    var body: some View {
        VStack(spacing: Space.sm) {
            ZStack {
                // Inset by half the line width so the 4pt stroke stays inside
                // the 58pt frame — a centered stroke would bleed 2pt past the
                // edge and get clipped by the scroll view / card at the top row.
                Circle()
                    .inset(by: 2)
                    .stroke(theme.surfaceElevated, lineWidth: 4)

                if !trophy.achieved {
                    Circle()
                        .inset(by: 2)
                        .trim(from: 0, to: CGFloat(trophy.progress))
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }

                Circle()
                    .fill(trophy.achieved ? theme.accentSoft : theme.surfaceElevated)
                    .padding(5)

                Image(systemName: trophy.icon)
                    .font(.title3.bold())
                    .foregroundStyle(trophy.achieved ? theme.accent : theme.textTertiary)
            }
            .frame(width: 58, height: 58)

            Text(trophy.title)
                .font(.label)
                .foregroundStyle(trophy.achieved ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
        }
        .frame(width: 92)
        .contentShape(Rectangle())
    }
}
