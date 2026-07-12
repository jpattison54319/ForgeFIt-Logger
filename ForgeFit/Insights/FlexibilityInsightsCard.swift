import ForgeCore
import ForgeData
import SwiftUI

/// The flexibility pillar's Insights card: weekly time-under-stretch per body
/// region against the evidence-based "effective dose" marker, plus session
/// consistency. Claims are deliberately limited to range of motion — the one
/// outcome the stretch-dose literature actually supports (Thomas et al. 2018;
/// ACSM ≥2–3 sessions/week). Renders nothing when there's no signal, like the
/// other insight cards.
struct FlexibilityInsightsCard: View {
    @Environment(\.theme) private var theme
    let analytics: TrainingAnalytics

    @State private var regionsMemo = Memo<String, [FlexibilityAnalytics.RegionWeek]>()
    @State private var minutesMemo = Memo<String, (active: Int, restorative: Int)>()
    @State private var daysMemo = Memo<String, Int>()

    private var analyticsKey: String {
        var count = 0
        var latest = Date.distantPast
        for workout in analytics.workouts where workout.endedAt != nil && workout.deletedAt == nil {
            count += 1
            latest = max(latest, workout.updatedAt)
        }
        return "\(count)|\(latest.timeIntervalSince1970)"
    }

    /// This calendar week — the dose marker is a weekly target, so the card
    /// always talks about the current week.
    private var weekRange: ClosedRange<Date> {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        return start...Date()
    }

    private var regions: [FlexibilityAnalytics.RegionWeek] {
        regionsMemo(analyticsKey) {
            FlexibilityAnalytics.regionSeconds(
                workouts: analytics.workouts,
                exercises: analytics.exercises,
                range: weekRange
            )
        }
    }

    private var minutes: (active: Int, restorative: Int) {
        minutesMemo(analyticsKey) {
            FlexibilityAnalytics.yogaMinutes(workouts: analytics.workouts, range: weekRange)
        }
    }

    private var sessionDays: Int {
        daysMemo(analyticsKey) {
            FlexibilityAnalytics.sessionDays(
                workouts: analytics.workouts,
                exercises: analytics.exercises,
                range: weekRange
            )
        }
    }

    var body: some View {
        if !regions.isEmpty || minutes.active + minutes.restorative > 0 {
            VStack(alignment: .leading, spacing: Space.lg) {
                SectionHeader("Flexibility")
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        header
                        if !regions.isEmpty {
                            regionBars
                        }
                        consistencyRow
                        Text("Around 10 minutes of stretch per region per week is where range-of-motion gains become reliable.")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(minutes.active + minutes.restorative)")
                    .font(.metricValue).foregroundStyle(theme.textPrimary)
                Text("min this week").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if minutes.restorative > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(minutes.active) active")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.accent)
                    Text("\(minutes.restorative) restorative")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.warmup)
                }
            }
        }
    }

    /// One bar per region: progress toward the weekly effective dose.
    private var regionBars: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ForEach(regions.prefix(6)) { region in
                HStack(spacing: Space.sm) {
                    Text(MuscleTaxonomy.displayName(region.region))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 108, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.surfaceElevated)
                            Capsule()
                                .fill(region.doseFraction >= 1 ? theme.success : theme.accent)
                                .frame(width: max(4, geo.size.width * region.doseFraction))
                        }
                    }
                    .frame(height: 8)
                    Text(Fmt.durationShort(region.seconds))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(region.doseFraction >= 1 ? theme.success : theme.textSecondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    private var consistencyRow: some View {
        HStack(spacing: 6) {
            Image(systemName: sessionDays >= 2 ? "checkmark.seal.fill" : "calendar")
                .font(.system(size: 12))
                .foregroundStyle(sessionDays >= 2 ? theme.success : theme.textTertiary)
            Text(sessionDays >= 2
                 ? "\(sessionDays) flexibility days this week — that's the consistency that moves range of motion."
                 : "\(sessionDays == 0 ? "No" : "\(sessionDays)") flexibility day\(sessionDays == 1 ? "" : "s") this week yet — 2–3 per week is the evidence-backed target.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
