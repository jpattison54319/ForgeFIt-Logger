import SwiftUI

struct StrainTargetBar: View {
    @Environment(\.theme) private var theme
    let score: Double
    let target: ClosedRange<Double>?
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceElevated)
                Capsule()
                    .fill(color)
                    .frame(width: max(5, width * min(1, max(0, score / 10))))
                if let target {
                    let start = width * min(1, max(0, target.lowerBound / 10))
                    let end = width * min(1, max(0, target.upperBound / 10))
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(theme.textPrimary.opacity(0.8), lineWidth: 2)
                        .frame(width: max(7, end - start), height: 10)
                        .offset(x: start)
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
