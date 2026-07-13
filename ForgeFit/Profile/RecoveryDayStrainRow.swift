import SwiftUI

/// Full-width strain reading beneath a selected day's recovery scores.
struct RecoveryDayStrainRow: View {
    @Environment(\.theme) private var theme

    let score: Double
    let target: ClosedRange<Double>?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .lastTextBaseline, spacing: Space.sm) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(theme.secondaryAccent)
                    Text("Strain")
                        .foregroundStyle(theme.textPrimary)
                }
                .font(.system(size: 14, weight: .bold))

                Spacer(minLength: Space.md)

                Text(score.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(strainColor)
                    .monospacedDigit()
                Text("/ 10")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }

            StrainTargetBar(score: score, target: target, color: strainColor)

            HStack(spacing: Space.sm) {
                Text("Daily activity load")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: Space.md)
                Text(targetText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Strain")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("recovery-summary-strain")
    }

    private var strainColor: Color {
        if let target, score > target.upperBound {
            return theme.warmup
        }
        return theme.secondaryAccent
    }

    private var targetText: String {
        guard let target else { return "Target building" }
        return "Target \(formatted(target.lowerBound))–\(formatted(target.upperBound))"
    }

    private var accessibilityValue: String {
        let scoreText = score.formatted(.number.precision(.fractionLength(1)))
        guard let target else { return "\(scoreText) out of 10, target building" }
        return "\(scoreText) out of 10, target \(formatted(target.lowerBound)) to \(formatted(target.upperBound))"
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
