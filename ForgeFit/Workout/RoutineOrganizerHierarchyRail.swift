import SwiftUI

/// One passive segment of the continuous folder-to-routines hierarchy rail.
/// Every participating row has zero vertical list insets, so adjacent segments
/// meet at the row boundary without entering the routine cards.
struct RoutineOrganizerHierarchyRail: View {
    @Environment(\.theme) private var theme

    let x: CGFloat
    let startsAtMidpoint: Bool
    let endsAtMidpoint: Bool
    let branchEndX: CGFloat?

    var body: some View {
        Canvas { context, size in
            let midpoint = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: x, y: startsAtMidpoint ? midpoint : 0))
            path.addLine(to: CGPoint(x: x, y: endsAtMidpoint ? midpoint : size.height))
            if let branchEndX {
                path.move(to: CGPoint(x: x, y: midpoint))
                path.addLine(to: CGPoint(x: branchEndX, y: midpoint))
            }
            context.stroke(
                path,
                with: .color(theme.textTertiary),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .butt)
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
