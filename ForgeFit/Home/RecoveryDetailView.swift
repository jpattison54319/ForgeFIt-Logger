import ForgeData
import SwiftData
import SwiftUI

/// Full recovery breakdown focused on action first: what to do today, why the
/// app thinks that, and only then the supporting details. Leads with three
/// evidence-based scores — systemic, per-muscle, and cardio — each of which
/// admits when it doesn't have enough data yet.
struct RecoveryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    var exercises: [ExerciseLibraryModel] = []

    @State private var selectedInfo: RecoveryInfoTopic?
    @State private var reportMemo = Memo<String, RecoveryEngine.Report>()

    private var report: RecoveryEngine.Report {
        reportMemo(AnalyticsFingerprint.withHealth(workouts)) {
            RecoveryEngine(
                workouts: workouts,
                exercises: exercises,
                healthMetrics: HealthMetricsStore.shared.metrics,
                supplementalSignals: HealthMetricsStore.shared.extraSignals
            ).report()
        }
    }

    var body: some View {
        let report = self.report
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                header

                RecoverySummaryCard(report: report) { selectedInfo = $0 }

                SectionHeader("Systemic recovery")
                SystemicScoreCard(systemic: report.recovery.systemic) { selectedInfo = $0 }

                SectionHeader("Muscle recovery")
                MuscleRecoveryCard(muscles: report.recovery.muscles) { selectedInfo = $0 }

                SectionHeader("Cardio recovery")
                CardioRecoveryCard(cardio: report.recovery.cardio) { selectedInfo = $0 }

                ReadinessReasonList(report: report)

                SectionHeader("Signals from Apple Health")
                HealthSignalRows(report: report)

                AdvancedLoadDisclosure(report: report) { selectedInfo = $0 }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        // Pull down to re-query Apple Health and recompute readiness.
        .refreshable { await AppRefresh.run(in: modelContext) }
        .sheet(item: $selectedInfo) { topic in
            MetricInfoSheet(topic: topic)
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left") { dismiss() }
            Spacer()
            Text("Recovery").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.top, Space.sm)
    }
}

// MARK: - Summary

private struct RecoverySummaryCard: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .center, spacing: Space.lg) {
                    ZStack {
                        ProgressRing(progress: report.displayScore, lineWidth: 14, color: theme.readinessColor(report.displayScore))
                            .frame(width: 132, height: 132)
                        Text("\(Int(report.displayScore * 100))")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .accessibilityLabel("Recovery score \(Int(report.displayScore * 100))")

                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.sm) {
                            Text("Today")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.textSecondary)
                                .textCase(.uppercase)
                            InfoButton { onInfo(.readinessScore) }
                        }
                        HStack(spacing: Space.sm) {
                            Image(systemName: report.action.systemImage)
                                .font(.system(size: 15, weight: .bold))
                            Text(report.action.title)
                                .font(.cardTitle)
                        }
                        .foregroundStyle(report.action.tint)

                        Text(report.preWorkoutAdjustment)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(report.recommendation)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.sm) {
                    Text("Confidence \(Int(report.confidence * 100))%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    InfoButton { onInfo(.confidence) }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Systemic score

private struct SystemicScoreCard: View {
    @Environment(\.theme) private var theme
    let systemic: RecoveryEngine.SystemicRecovery
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Whole body", systemImage: "figure.mind.and.body")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.systemicScore) }
                    Spacer()
                    ScoreBadge(state: systemic.state)
                }

                if let score = systemic.state.value {
                    ScoreBar(progress: score)
                }

                Text(guidanceText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(theme.separator)

                VStack(spacing: Space.md) {
                    ForEach(systemic.parts) { part in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            if let value = part.state.value {
                                Circle().fill(theme.readinessColor(value)).frame(width: 8, height: 8)
                            } else {
                                Image(systemName: "hourglass")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                    .frame(width: 8)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(part.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Text(detailText(for: part))
                                    .font(.system(size: 12))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Text(part.valueText)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(part.state.value == nil ? theme.textTertiary : theme.textPrimary)
                        }
                    }
                }
            }
        }
    }

    private var guidanceText: String {
        if case .building(let needed) = systemic.state { return needed }
        return systemic.guidance
    }

    private func detailText(for part: RecoveryEngine.ScorePart) -> String {
        if case .building(let needed) = part.state { return needed }
        return part.detailText
    }
}

// MARK: - Muscle scores

private struct MuscleRecoveryCard: View {
    @Environment(\.theme) private var theme
    let muscles: [RecoveryEngine.MuscleRecoveryScore]
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Per muscle", systemImage: "figure.strengthtraining.traditional")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.muscleScore) }
                    Spacer()
                }

                if muscles.allSatisfy({ $0.state.value == nil }) {
                    Text("Log strength workouts and each muscle gets its own recovery estimate here.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                } else {
                    VStack(spacing: Space.md) {
                        ForEach(muscles) { muscle in
                            MuscleRecoveryRow(muscle: muscle)
                        }
                    }
                }
            }
        }
    }
}

private struct MuscleRecoveryRow: View {
    @Environment(\.theme) private var theme
    let muscle: RecoveryEngine.MuscleRecoveryScore

    var body: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(muscle.muscle.capitalized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(width: 104, alignment: .leading)

            if let score = muscle.state.value {
                ScoreBar(progress: score)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(score * 100))%")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.readinessColor(score))
                    Text(trailingLabel(score: score))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(width: 62, alignment: .trailing)
            } else {
                Spacer()
                Text("No sets yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var subtitle: String {
        guard let days = muscle.lastTrainedDaysAgo else { return "Not trained" }
        if days == 0 { return "Trained today" }
        if days == 1 { return "Trained yesterday" }
        return "Trained \(days)d ago"
    }

    private func trailingLabel(score: Double) -> String {
        if score >= 0.9 { return "Ready" }
        if let hours = muscle.readyInHours {
            return hours >= 24 ? "~\((Double(hours) / 24).formatted(.number.precision(.fractionLength(0...1))))d" : "~\(hours)h"
        }
        return muscle.statusLabel
    }
}

// MARK: - Cardio score

private struct CardioRecoveryCard: View {
    @Environment(\.theme) private var theme
    let cardio: RecoveryEngine.CardioRecovery
    let onInfo: (RecoveryInfoTopic) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Label("Cardiovascular", systemImage: "heart.circle.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.cardioScore) }
                    Spacer()
                    ScoreBadge(state: cardio.state)
                }

                if let score = cardio.state.value {
                    ScoreBar(progress: score)
                }

                if let lastSessionText = cardio.lastSessionText {
                    Text("Last session: \(lastSessionText)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textTertiary)
                }

                Text(guidanceText)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var guidanceText: String {
        if case .building(let needed) = cardio.state { return needed }
        return cardio.guidance
    }
}

// MARK: - Shared score chrome

private struct ScoreBadge: View {
    @Environment(\.theme) private var theme
    let state: RecoveryEngine.ScoreState

    var body: some View {
        if let value = state.value {
            Text("\(Int(value * 100))")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(theme.readinessColor(value))
        } else {
            Tag(text: "Needs data", color: theme.textSecondary, background: theme.surfaceHighlight)
        }
    }
}

private struct ScoreBar: View {
    @Environment(\.theme) private var theme
    let progress: Double

    var body: some View {
        ProgressBar(progress: progress, color: theme.readinessColor(progress))
            .frame(height: 6)
    }
}

// MARK: - Reasons

private struct ReadinessReasonList: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Why this recommendation")

            HStack(spacing: Space.sm) {
                ForEach(report.reasonChips.prefix(3)) { chip in
                    Tag(text: chip.text, color: chip.tone.foreground, background: chip.tone.background)
                }
            }

            if !report.insights.isEmpty {
                Card(padding: Space.md, fill: theme.surfaceElevated) {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        ForEach(Array(report.insights.prefix(2)), id: \.self) { insight in
                            HStack(alignment: .top, spacing: Space.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                                    .padding(.top, 2)
                                Text(insight)
                                    .font(.system(size: 14))
                                    .foregroundStyle(theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Health signals

private struct HealthSignalRows: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report

    private var healthSignals: [RecoveryEngine.Signal] {
        report.signals.filter { !["Load ratio", "Monotony"].contains($0.name) }
    }

    var body: some View {
        VStack(spacing: Space.md) {
            ForEach(healthSignals) { signal in
                Card(padding: Space.md) {
                    HStack(spacing: Space.md) {
                        Image(systemName: signal.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(signal.connected ? theme.accent : theme.textTertiary)
                            .frame(width: 38, height: 38)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(signalHeadline(signal))
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(signal.detail)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: Space.sm)

                        Text(signal.value)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(signal.connected ? theme.textPrimary : theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    private func signalHeadline(_ signal: RecoveryEngine.Signal) -> String {
        guard signal.connected else { return "Connect Apple Health for \(signal.name.lowercased())" }
        let chips = Set(report.reasonChips.map(\.text))
        switch signal.name {
        case "HRV":
            if chips.contains("HRV low trend") { return "HRV has been low for multiple readings" }
            if chips.contains("HRV low today") { return "HRV is below your baseline today" }
            if chips.contains("HRV normal") { return "HRV is near your baseline" }
            return "HRV baseline is building"
        case "Resting HR":
            if chips.contains("RHR elevated") { return "Resting heart rate is elevated" }
            if chips.contains("RHR normal") { return "Resting heart rate is near baseline" }
            return "Resting heart rate baseline is building"
        case "Sleep":
            if chips.contains("Sleep debt") { return "Sleep debt is high enough to matter" }
            if chips.contains("Sleep slightly short") { return "Sleep is a little short" }
            if chips.contains("Sleep okay") { return "Sleep is supporting normal training" }
            return "Sleep history is building"
        default:
            return "\(signal.name) is available"
        }
    }
}

// MARK: - Advanced load

private struct AdvancedLoadDisclosure: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report
    let onInfo: (RecoveryInfoTopic) -> Void
    @State private var expanded = false

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("These numbers are used behind the scenes to spot load spikes and trends. They should guide coaching adjustments, not diagnose injury risk.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        StatColumn(label: "Acute 7d", value: Int(report.acuteLoad).formatted())
                        StatColumn(label: "Chronic", value: Int(report.chronicLoad).formatted())
                        StatColumn(label: "Ratio", value: report.acwr.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "-")
                    }

                    HStack {
                        StatColumn(label: "Strength", value: Int(report.strengthLoad).formatted())
                        StatColumn(label: "Cardio", value: Int(report.cardioLoad).formatted())
                        StatColumn(label: "Monotony", value: report.monotony.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "-")
                    }

                    if !report.missingInputs.isEmpty {
                        Text("Missing: \(report.missingInputs.joined(separator: ", "))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Space.md)
            } label: {
                HStack(spacing: Space.sm) {
                    Text("Advanced load details")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    InfoButton { onInfo(.trainingLoad) }
                    Spacer()
                }
            }
            .tint(theme.textSecondary)
        }
    }
}

// MARK: - Info sheets

private struct MetricInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let topic: RecoveryInfoTopic

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text(topic.title)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    CircleIconButton(systemImage: "xmark") { dismiss() }
                }

                Text(topic.explanation)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let takeaway = topic.takeaway {
                    Card(padding: Space.md, fill: theme.surfaceElevated) {
                        HStack(alignment: .top, spacing: Space.sm) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundStyle(theme.warmup)
                            Text(takeaway)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let evidence = topic.evidence {
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Grounded in")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                            .textCase(.uppercase)
                        ForEach(evidence, id: \.self) { line in
                            HStack(alignment: .top, spacing: Space.sm) {
                                Image(systemName: "book.closed.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.top, 2)
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(Space.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
        .preferredColorScheme(.dark)
    }
}

private enum RecoveryInfoTopic: String, Identifiable {
    case readinessScore
    case systemicScore
    case muscleScore
    case cardioScore
    case trainingLoad
    case confidence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readinessScore: "Today's recommendation"
        case .systemicScore: "Systemic recovery"
        case .muscleScore: "Muscle recovery"
        case .cardioScore: "Cardio recovery"
        case .trainingLoad: "Training load"
        case .confidence: "Confidence"
        }
    }

    var explanation: String {
        switch self {
        case .readinessScore:
            return "The headline combines the systemic score with muscle and cardio recovery into one action for today: Push, Train as planned, Reduce volume, or Deload/recover."
        case .systemicScore:
            return "Whole-body recovery blends four signals, each judged against your own baseline: a 7-day rolling HRV average, last night's sleep plus your 7-day sleep debt, today's resting heart rate, and the balance between your last 7 days and last 28 days of training stress. Any signal without enough history says so instead of guessing."
        case .muscleScore:
            return "Each muscle recovers on its own clock. A session deposits fatigue proportional to the sets you logged and how close to failure they were, then recovery follows an exponential curve — roughly 24–72 hours depending on the muscle and the dose. Bigger muscles (quads, hamstrings, back) recover more slowly than smaller ones (arms, calves)."
        case .cardioScore:
            return "Cardio stress depends on intensity, not just minutes. Easy Zone 2 work clears in about a day, threshold work needs one to two days, and high-intensity intervals suppress the nervous system for two to three. Sessions are weighted by time in heart-rate zones when available."
        case .trainingLoad:
            return "Training load compares recent work with your normal baseline using an exponentially weighted average. It helps flag big spikes or unusually flat weeks, but it is not an injury prediction."
        case .confidence:
            return "Confidence reflects how much useful data was available. More logged workouts and more consistent Health data make the recommendation sharper."
        }
    }

    var takeaway: String? {
        switch self {
        case .readinessScore:
            return "Use the action first. The exact number matters less than whether the app says Push, Train as planned, Reduce volume, or Deload."
        case .systemicScore:
            return "One rough night or one low HRV morning rarely matters — sustained trends against your own baseline are the real signal."
        case .muscleScore:
            return "A fatigued muscle doesn't mean skipping the gym. Rotate to a muscle that shows Ready, or train the fatigued one lighter."
        case .cardioScore:
            return "You can layer easy Zone 2 on most days. It's back-to-back hard interval days that this score will warn you about."
        case .trainingLoad:
            return "If load is spiking, keep intensity controlled or drop sets even when motivation is high."
        case .confidence:
            return "Low confidence does not mean the recommendation is useless; it means the app is being appropriately humble."
        }
    }

    var evidence: [String]? {
        switch self {
        case .systemicScore:
            return [
                "Plews et al. 2013 (Sports Med) — 7-day rolling HRV averages track training status better than single readings.",
                "Buchheit 2014 (Front Physiol) — interpret HRV and resting HR against your own baseline variability.",
                "Fullagar et al. 2015 (Sports Med) — sleep loss measurably impairs strength, sprint, and endurance performance.",
                "Williams et al. 2017 (BJSM) — exponentially weighted workload ratios outperform rolling averages.",
                "Foster 1998 (MSSE) — monotonous training weeks raise strain at the same total load.",
            ]
        case .muscleScore:
            return [
                "McLester et al. 2003 (JSCR) — force recovery commonly needs 48–72 h after a full resistance bout.",
                "Morán-Navarro et al. 2017 (Eur J Appl Physiol) — training to failure lengthens recovery by 24–48 h versus stopping short.",
                "Schoenfeld et al. 2016 (Sports Med) — training each muscle ~2×/week implies roughly 48–72 h between hard sessions.",
            ]
        case .cardioScore:
            return [
                "Stanley, Peake & Buchheit 2013 (Sports Med) — parasympathetic recovery: ≈24 h after easy sessions, 24–48 h after threshold, 48 h+ after high-intensity work.",
                "Seiler 2010 (IJSPP) — most endurance volume belongs at low intensity precisely because it recovers quickly.",
            ]
        case .readinessScore, .trainingLoad, .confidence:
            return nil
        }
    }
}

private struct InfoButton: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
    }
}

private struct ProgressBar: View {
    @Environment(\.theme) private var theme
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceHighlight)
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * max(0.04, min(1, progress)))
            }
        }
        .frame(height: 6)
    }
}

extension RecoveryEngine.Action {
    var tint: Color {
        let t = AppTheme.sage
        switch self {
        case .push: return t.recoveryHigh
        case .trainAsPlanned: return t.accent
        case .reduceVolume: return t.warmup
        case .deloadRecover: return t.recoveryLow
        }
    }
}

extension RecoveryEngine.ReasonTone {
    var foreground: Color {
        let t = AppTheme.sage
        switch self {
        case .positive: return t.recoveryHigh
        case .caution: return t.warmup
        case .neutral: return t.textSecondary
        }
    }

    var background: Color {
        let t = AppTheme.sage
        switch self {
        case .positive: return t.recoveryHigh.opacity(0.16)
        case .caution: return t.warmup.opacity(0.16)
        case .neutral: return t.surfaceHighlight
        }
    }
}
