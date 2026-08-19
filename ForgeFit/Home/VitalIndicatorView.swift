import SwiftUI

struct VitalIndicatorView: View {
    static let diameter: CGFloat = 18

    @Environment(\.theme) private var theme

    let indicator: VitalIndicatorPresentation
    let tint: Color
    let differentiateWithoutColor: Bool

    private var usesDashedRing: Bool {
        indicator.interpretation == .building || indicator.interpretation == .unavailable
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.surface)
            Circle()
                .stroke(
                    tint,
                    style: StrokeStyle(
                        lineWidth: indicator.interpretation == .adverse && differentiateWithoutColor ? 2.5 : 1.5,
                        dash: usesDashedRing ? [2.5, 1.5] : []
                    )
                )
            Image(systemName: indicator.kind.systemImage)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
                .opacity(indicator.interpretation == .unavailable ? 0.45 : 1)
            if indicator.interpretation == .unavailable {
                Capsule()
                    .fill(tint)
                    .frame(width: 11, height: 1.5)
                    .rotationEffect(.degrees(-45))
            }
            if differentiateWithoutColor, let marker = stateMarker {
                Image(systemName: marker)
                    .font(.system(size: 5, weight: .bold))
                    .foregroundStyle(theme.surface)
                    .frame(width: 7, height: 7)
                    .background(tint, in: Circle())
                    .offset(x: 5.5, y: 5.5)
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .accessibilityHidden(true)
    }

    private var stateMarker: String? {
        switch indicator.interpretation {
        case .favorable: "checkmark"
        case .typical: "minus"
        case .adverse: "exclamationmark"
        case .building: "ellipsis"
        case .unavailable: nil
        }
    }
}
