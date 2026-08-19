import SwiftUI

/// A compact, non-verbal preview of one theme's two brand colors. The split
/// runs exactly from the lower-left corner to the upper-right corner.
struct DiagonalThemeSwatch: View {
    @Environment(\.theme) private var theme

    let primary: Color
    let accent: Color
    var isSelected = false

    var body: some View {
        Canvas { context, size in
            var primaryHalf = Path()
            primaryHalf.move(to: .zero)
            primaryHalf.addLine(to: CGPoint(x: size.width, y: 0))
            primaryHalf.addLine(to: CGPoint(x: 0, y: size.height))
            primaryHalf.closeSubpath()
            context.fill(primaryHalf, with: .color(primary))

            var accentHalf = Path()
            accentHalf.move(to: CGPoint(x: size.width, y: 0))
            accentHalf.addLine(to: CGPoint(x: size.width, y: size.height))
            accentHalf.addLine(to: CGPoint(x: 0, y: size.height))
            accentHalf.closeSubpath()
            context.fill(accentHalf, with: .color(accent))
        }
        .clipShape(.rect(cornerRadius: Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control)
                .stroke(
                    isSelected ? theme.textPrimary : theme.separator,
                    lineWidth: isSelected ? 3 : 1
                )
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 24, height: 24)
                    .background(theme.surfaceElevated)
                    .clipShape(.circle)
                    .padding(Space.xs)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }
}
