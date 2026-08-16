import SwiftUI

/// Four source-consistent vital readings on one normalized axis. Position and
/// ring treatment carry the state alongside color so the card remains legible
/// with color differentiation enabled.
struct VitalsSummaryTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentation: VitalsTilePresentation
    var isRefreshing = false

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                header
                indicatorPlot
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vitals")
        .accessibilityValue(presentation.accessibilityValue + (isRefreshing ? ". Updating" : ""))
        .accessibilityHint("Opens Vitals details")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.zone2)
            Text("Vitals")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .textCase(.uppercase)
            Spacer(minLength: 0)
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                    .tint(theme.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var indicatorPlot: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let bandHeight = max(0, proxy.size.height - 2 * spacing)

            ZStack {
                VStack(spacing: spacing) {
                    zone(theme.success)
                        .frame(height: bandHeight * CGFloat(VitalBandScale.outerFraction))
                    zone(theme.zone2)
                        .frame(height: bandHeight * CGFloat(VitalBandScale.usualFraction))
                    zone(theme.recoveryLow)
                        .frame(height: bandHeight * CGFloat(VitalBandScale.outerFraction))
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.tag))

                HStack(spacing: 0) {
                    ForEach(presentation.indicators) { indicator in
                        GeometryReader { column in
                            VitalIndicatorView(
                                indicator: indicator,
                                tint: tint(for: indicator.interpretation),
                                differentiateWithoutColor: differentiateWithoutColor
                            )
                            .position(
                                x: column.size.width / 2,
                                y: verticalPosition(
                                    indicator.position,
                                    height: column.size.height
                                )
                            )
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(height: 92)
        .animation(reduceMotion ? nil : Motion.stateChange, value: presentation)
    }

    private func zone(_ color: Color) -> some View {
        color.opacity(0.16)
            .frame(maxWidth: .infinity)
    }

    private func verticalPosition(_ position: Double, height: CGFloat) -> CGFloat {
        let indicatorDiameter = VitalIndicatorView.diameter
        let travel = max(0, height - indicatorDiameter)
        return indicatorDiameter / 2 + (1 - min(1, max(0, position))) * travel
    }

    private func tint(for interpretation: VitalInterpretation) -> Color {
        switch interpretation {
        case .favorable: theme.success
        case .typical: theme.zone2
        case .adverse: theme.recoveryLow
        case .building, .unavailable: theme.textTertiary
        }
    }
}
