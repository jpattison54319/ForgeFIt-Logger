import SwiftUI

/// Calendar-scale strain meter. Fill length carries the score even without
/// color; the detailed target range stays in the selected-day view where it
/// has enough room to remain legible.
struct CalendarStrainBar: View {
    @Environment(\.theme) private var theme

    let score: Double?
    let target: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            if let score {
                let width = geometry.size.width
                let progress = min(1, max(0, score / 10))

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.surfaceElevated)
                    Capsule()
                        .fill(strainColor(score))
                        .frame(width: max(3, width * progress))
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private func strainColor(_ score: Double) -> Color {
        if let target, score > target.upperBound {
            return theme.warmup
        }
        return theme.secondaryAccent
    }
}
