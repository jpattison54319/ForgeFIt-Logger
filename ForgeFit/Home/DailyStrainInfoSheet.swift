import SwiftUI

struct DailyStrainInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text("Daily strain")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                }

                Text("Recovery is your capacity at the start of the day; strain is the movement and training you accumulate after midnight. Finishing a workout raises strain without rewriting the morning recovery measurement.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.sm) {
                    takeawayRow("Your score is relative to the prior 28 days. Walking, exercise minutes, and active energy count; recorded workouts add duration and intensity through session RPE or heart rate.")
                    takeawayRow("Today's target uses 70% daily readiness and 30% recovery trend. The adjustment is capped, because a green morning should not authorize a sudden load spike.")
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Grounded in")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                        .textCase(.uppercase)
                    evidenceRow("Foster et al. 2001 (JSCR) — session RPE combines duration and perceived intensity into a practical internal training-load measure.")
                    evidenceRow("Lee et al. 2019 (JAMA Internal Medicine) — device-measured step volume showed a graded association with health outcomes; everyday movement should not count as zero.")
                    evidenceRow("Vesterinen et al. 2016 (Medicine & Science in Sports & Exercise) — HRV-guided training supports adapting training timing, while not validating an exact universal target.")
                    evidenceRow("Impellizzeri et al. 2020 (IJSPP) — acute:chronic workload ratios have conceptual and mathematical pitfalls, so ForgeFit does not use a ratio threshold as injury prediction.")
                }

                Text("This is a coaching guide, not a measure of physiological damage or injury risk. The 0–10 scale and target range are transparent heuristics built on personal trends, not clinical cutoffs.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.lg)
        }
        .background(theme.background)
    }

    private func takeawayRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryAccent)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
