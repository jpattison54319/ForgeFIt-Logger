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

                Text("Daily strain is a relative activity-load index. It shows how today's movement and completed training compare with your recent history; it is not fatigue accumulated since midnight.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.sm) {
                    sectionTitle("Reading the gauge")
                    scoreRow("Loading today", detail: "Today's data is still syncing.")
                    scoreRow("Collecting baseline", detail: "No personal score yet; ForgeFit is gathering comparable history.")
                    scoreRow("More history needed", detail: "Today's score is ready, but your personal usual range needs more comparable history.")
                    scoreRow("In your usual range", detail: "Inside your personal usual range — the middle 80% of comparable recent days, not one exact score.")
                    scoreRow("Below or above usual", detail: "Outside your usual range. The arc fills left for lower activity load and right for higher activity load.")
                    scoreRow("Far below or above usual", detail: "Farther from your usual range toward either end of the 0–10 scale.")
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    sectionTitle("How the score is built")
                    takeawayRow("Movement is 35%: steps so far are ranked against your steps at the same local time across up to 56 prior days.")
                    takeawayRow("Training is 65%: whole-session CR10 is preferred. Without it, ForgeFit estimates load from completed strength sets, set RPE or RIR, cardio effort, duration, and recorded heart-rate zones.")
                    takeawayRow("Fallback sessions are labeled Estimated. Missing set effort uses a neutral RPE 6 convention; equipment type does not add a fatigue multiplier.")
                    takeawayRow("A score near 5 means near the middle of your history — not zero activity or half of a daily limit. Missing source data reduces coverage and pulls the score toward 5.")
                    takeawayRow("Active minutes, calories, and recovery may provide context, but they do not change this score. Heart rate is used only inside the unrated-workout fallback.")
                }

                Text("The score appears after at least 14 comparable days. It describes activity load relative to your history; it does not measure physiological fatigue, damage, readiness, or injury risk. The 0–10 scale and 35/65 weights are product settings, not clinical cutoffs.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.lg)
        }
        .background(theme.background)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(theme.textTertiary)
            .textCase(.uppercase)
    }

    private func scoreRow(_ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle()
                .fill(title == "In your usual range" ? theme.success : theme.secondaryAccent)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

}
