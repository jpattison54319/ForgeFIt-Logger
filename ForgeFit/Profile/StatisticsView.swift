import Charts
import ForgeCore
import ForgeData
import SwiftUI

/// Profile → Statistics: a full analytics hub. Lifetime totals up top, then
/// three tabs — Strength (muscle distribution, split, sets per muscle, top
/// exercises, rep ranges, weekday habit, e1RM movers), Cardio (minutes /
/// distance trends, modality mix, HR zones, pace, bests), and Monthly
/// (per-month report with deltas vs the previous month).
/// A stat card with a persistent collapse toggle — Strength and Cardio each
/// stack 7-8 cards below their headline summary, with no way to hide ones a
/// user doesn't care about. Collapsed state is remembered per card (keyed by
/// a stable id, independent of any dynamic display title) so a preference
/// like "always collapse Training days" sticks across visits.
private struct CollapsibleStatCard<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var systemImage: String?
    var tint: Color?
    @AppStorage private var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(title: String, systemImage: String? = nil, tint: Color? = nil, key: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self._isExpanded = AppStorage(wrappedValue: true, "statsSectionExpanded.\(key)")
        self.content = content
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack {
                        if let systemImage {
                            Label(title, systemImage: systemImage)
                                .font(.bodyStrong)
                                .foregroundStyle(tint ?? theme.textPrimary)
                        } else {
                            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stats-section-\(title)")

                if isExpanded {
                    content()
                }
            }
        }
    }
}

struct StatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    private enum StatsTab: String, CaseIterable {
        case strength = "Strength"
        case cardio = "Cardio"
        case monthly = "Monthly"
    }

    @State private var tab: StatsTab = .strength
    @State private var range: TimeChartRange = .twelveWeeks
    @State private var trendMetric: TrainingAnalytics.Metric = .volume
    @State private var cardioTrend: CardioTrendMetric = .minutes
    @State private var monthIndex = 0
    // Full-history rollups survive body re-evaluations (tab/range toggles).
    @State private var distributionMemo = Memo<String, [TrainingAnalytics.MuscleShare]>()
    @State private var monthlyMemo = Memo<String, TrainingAnalytics.MonthlyReport>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var statsKey: String { AnalyticsFingerprint.of(workouts) }

    var body: some View {
        DashboardScaffold(title: "Statistics", dismiss: dismiss) {
            lifetimeCard

            SegmentedPills(options: StatsTab.allCases, title: { $0.rawValue }, selection: $tab)

            switch tab {
            case .strength: strengthSections
            case .cardio: cardioSections
            case .monthly: monthlySections
            }
        }
        .navigationDestination(for: UUID.self) { id in
            ExerciseDetailView(exerciseID: id, workouts: workouts, exercises: exercises)
        }
    }

    // MARK: - Lifetime header

    private var lifetimeCard: some View {
        let completed = analytics.completed
        let summaries = completed.map(analytics.summary(for:))
        let totalSeconds = summaries.reduce(0) { $0 + $1.durationSeconds }
        let totalVolume = summaries.reduce(0.0) { $0 + $1.volume }
        let totalSets = summaries.reduce(0) { $0 + $1.sets }
        return Card {
            VStack(spacing: Space.lg) {
                HStack {
                    StatColumn(label: "Workouts", value: "\(completed.count)")
                    StatColumn(label: "Total time", value: Fmt.durationShort(totalSeconds))
                }
                HStack {
                    StatColumn(label: "Total volume", value: Fmt.volume(totalVolume))
                    StatColumn(label: "Total sets", value: "\(totalSets)")
                }
            }
        }
    }

    // MARK: - Strength tab

    @ViewBuilder
    private var strengthSections: some View {
        let distribution = distributionMemo("\(statsKey)|\(range.rawValue)") {
            analytics.muscleDistribution(in: range)
        }

        HStack {
            SectionHeader("Training")
            Spacer()
            TimeChartRangePicker(selection: $range)
        }

        trendCard

        if distribution.isEmpty {
            EmptyStateCard(
                title: "No strength data in range",
                message: "Log working sets and your muscle breakdowns will appear here.",
                systemImage: "chart.pie"
            )
        } else {
            muscleDistributionCard(distribution)
            trainingSplitCard
            setsPerMuscleCard(distribution)
            topExercisesCard
            repRangeCard
            weekdayCard
            strengthGainersCard
        }
    }

    private var trendCard: some View {
        let series = analytics.weeklySeries(trendMetric, weeks: range.weekCount)
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Weekly trend").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                if series.contains(where: { $0.value > 0 }) {
                    BarTrendChart(points: series)
                } else {
                    Text("No data in this range yet.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).frame(height: 80)
                }
                SegmentedPills(options: TrainingAnalytics.Metric.allCases, title: { $0.rawValue }, selection: $trendMetric)
            }
        }
    }

    private func muscleDistributionCard(_ distribution: [TrainingAnalytics.MuscleShare]) -> some View {
        let top = Array(distribution.prefix(6))
        let otherSets = distribution.dropFirst(6).reduce(0.0) { $0 + $1.sets }
        let totalSets = distribution.reduce(0.0) { $0 + $1.sets }
        struct Slice: Identifiable {
            let id: String
            let label: String
            let sets: Double
            let color: Color
        }
        var slices = top.enumerated().map { index, share in
            Slice(id: share.muscle, label: share.muscle.capitalized, sets: share.sets, color: palette[index % palette.count])
        }
        if otherSets > 0 {
            slices.append(Slice(id: "other", label: "Other", sets: otherSets, color: theme.textTertiary))
        }

        return CollapsibleStatCard(title: "Muscle distribution", key: "muscleDistribution") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.lg) {
                    Chart(slices) { slice in
                        SectorMark(
                            angle: .value("Sets", slice.sets),
                            innerRadius: .ratio(0.62),
                            angularInset: 1.5
                        )
                        .foregroundStyle(slice.color)
                        .cornerRadius(3)
                    }
                    .frame(width: 132, height: 132)
                    .chartBackground { _ in
                        VStack(spacing: 0) {
                            Text("\(Int(totalSets.rounded()))")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                            Text("sets")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(slices) { slice in
                            HStack(spacing: 7) {
                                Circle().fill(slice.color).frame(width: 8, height: 8)
                                Text(slice.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int((slice.sets / max(totalSets, 1) * 100).rounded()))%")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Text("Fractional working sets per muscle (secondary muscles count half).")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var trainingSplitCard: some View {
        let split = analytics.trainingSplit(in: range)
        return CollapsibleStatCard(title: "Push · Pull · Legs balance", key: "trainingSplit") {
            VStack(alignment: .leading, spacing: Space.md) {

                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(split) { share in
                            splitColor(share.name)
                                .frame(width: max(4, geo.size.width * share.fraction))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())

                HStack(spacing: Space.lg) {
                    ForEach(split) { share in
                        HStack(spacing: 5) {
                            Circle().fill(splitColor(share.name)).frame(width: 8, height: 8)
                            Text("\(share.name) \(Int((share.fraction * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func setsPerMuscleCard(_ distribution: [TrainingAnalytics.MuscleShare]) -> some View {
        let weeks = analytics.weeksOfHistory(in: range)
        let rows = distribution.prefix(8).map { share in
            MuscleVolumeBars.Row(muscle: share.muscle, sets: share.sets / weeks, target: 14)
        }
        return CollapsibleStatCard(title: "Weekly sets per muscle", key: "setsPerMuscle") {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("vs ~14-set target")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                MuscleVolumeBars(rows: Array(rows))
            }
        }
    }

    private var topExercisesCard: some View {
        let top = analytics.topExercises(in: range, limit: 5)
        let maxSets = top.map(\.workingSets).max() ?? 1
        return CollapsibleStatCard(title: "Main exercises", key: "topExercises") {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(top) { usage in
                    NavigationLink(value: usage.id) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(usage.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                Spacer()
                                Text("\(usage.workingSets) sets · \(Fmt.volume(usage.volume))")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.surfaceHighlight)
                                    Capsule()
                                        .fill(theme.accent)
                                        .frame(width: geo.size.width * (Double(usage.workingSets) / Double(maxSets)))
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var repRangeCard: some View {
        let buckets = analytics.repRangeDistribution(in: range)
        return CollapsibleStatCard(title: "Rep ranges", key: "repRanges") {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(buckets) { bucket in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(bucket.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text(bucket.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textTertiary)
                            Spacer()
                            Text("\(bucket.sets) sets · \(Int((bucket.fraction * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(theme.surfaceHighlight)
                                Capsule()
                                    .fill(repRangeColor(bucket.label))
                                    .frame(width: geo.size.width * max(0.02, bucket.fraction))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
    }

    private var weekdayCard: some View {
        let frequency = analytics.weekdayFrequency(in: range)
        struct DayCount: Identifiable {
            let id = UUID()
            let label: String
            let position: Int
            let count: Int
        }
        let days = frequency.enumerated().map { DayCount(label: $1.label, position: $0, count: $1.count) }
        return CollapsibleStatCard(title: "Training days", key: "trainingDays") {
            VStack(alignment: .leading, spacing: Space.md) {
                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.position),
                        y: .value("Workouts", day.count)
                    )
                    .foregroundStyle(theme.accent)
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: days.map(\.position)) { value in
                        AxisValueLabel {
                            if let position = value.as(Int.self), position < days.count {
                                Text(days[position].label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                        AxisValueLabel().foregroundStyle(theme.textTertiary)
                    }
                }
                .frame(height: 120)
            }
        }
    }

    @ViewBuilder
    private var strengthGainersCard: some View {
        let gainers = analytics.topStrengthGainers(in: range)
        if !gainers.isEmpty {
            CollapsibleStatCard(title: "Strength movers", systemImage: "chart.line.uptrend.xyaxis", tint: theme.recoveryHigh, key: "strengthGainers") {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(gainers) { gainer in
                        NavigationLink(value: gainer.id) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(gainer.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Text("e1RM \(Fmt.loadUnit(gainer.fromE1RM, unit: unit(for: gainer.id))) → \(Fmt.loadUnit(gainer.toE1RM, unit: unit(for: gainer.id)))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Text("+\(Int((gainer.gainFraction * 100).rounded()))%")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(theme.recoveryHigh)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Cardio tab

    private enum CardioTrendMetric: String, CaseIterable {
        case minutes = "Minutes"
        case distance = "Distance"
    }

    @ViewBuilder
    private var cardioSections: some View {
        let breakdown = analytics.cardioModalityBreakdown(in: range)

        HStack {
            SectionHeader("Cardio")
            Spacer()
            TimeChartRangePicker(selection: $range)
        }

        if breakdown.isEmpty {
            EmptyStateCard(
                title: "No cardio in range",
                message: "Log runs, rides, rows, or walks and your cardio analytics will appear here.",
                systemImage: "figure.run"
            )
        } else {
            cardioTotalsCard(breakdown)
            cardioTrendCard
            modalityCard(breakdown)
            zoneCard
            efficiencyCard
            criticalPaceCard
            paceCard
            cardioBestsCard
        }
    }

    private func cardioTotalsCard(_ breakdown: [TrainingAnalytics.ModalityShare]) -> some View {
        let sessions = breakdown.reduce(0) { $0 + $1.sessions }
        let minutes = breakdown.reduce(0.0) { $0 + $1.minutes }
        let distance = breakdown.reduce(0.0) { $0 + $1.distanceMeters }
        return Card {
            HStack {
                StatColumn(label: "Sessions", value: "\(sessions)")
                StatColumn(label: "Time", value: Fmt.durationShort(Int(minutes * 60)), valueColor: theme.secondaryAccent)
                StatColumn(label: "Distance", value: distance > 0 ? Fmt.distance(distance) : "—")
            }
        }
    }

    private var cardioTrendCard: some View {
        let points = cardioTrend == .minutes
            ? analytics.cardioWeeklyMinutes(weeks: range.weekCount)
            : analytics.cardioWeeklyDistance(weeks: range.weekCount)
        return CollapsibleStatCard(title: "Weekly \(cardioTrend.rawValue.lowercased())", key: "cardioTrend") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    Text(cardioTrend == .minutes ? "min / week" : "km / week")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
                if points.contains(where: { $0.value > 0 }) {
                    BarTrendChart(points: points, color: theme.secondaryAccent)
                } else {
                    Text("No data in this range yet.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).frame(height: 80)
                }
                SegmentedPills(options: CardioTrendMetric.allCases, title: { $0.rawValue }, selection: $cardioTrend)
            }
        }
    }

    private func modalityCard(_ breakdown: [TrainingAnalytics.ModalityShare]) -> some View {
        let totalMinutes = max(1, breakdown.reduce(0.0) { $0 + $1.minutes })
        return CollapsibleStatCard(title: "By activity", key: "cardioModality") {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(breakdown) { share in
                    HStack(spacing: Space.md) {
                        Image(systemName: share.kind.systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.secondaryAccent)
                            .frame(width: 32, height: 32)
                            .background(theme.surfaceElevated)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(share.kind.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(shareDetail(share))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(theme.surfaceHighlight)
                                    Capsule()
                                        .fill(theme.secondaryAccent)
                                        .frame(width: geo.size.width * (share.minutes / totalMinutes))
                                }
                            }
                            .frame(height: 5)
                        }
                    }
                }
            }
        }
    }

    private func shareDetail(_ share: TrainingAnalytics.ModalityShare) -> String {
        var parts = ["\(share.sessions)×", Fmt.durationShort(Int(share.minutes * 60))]
        if share.distanceMeters > 0 { parts.append(Fmt.distance(share.distanceMeters)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var zoneCard: some View {
        let zones = analytics.cardioZoneTotals(in: range)
        if zones.contains(where: { $0 > 0 }) {
            CollapsibleStatCard(title: "Intensity", key: "cardioZones") {
                VStack(alignment: .leading, spacing: Space.md) {
                    ZoneSecondsBar(zoneSeconds: zones)
                    Text("Zones 1–2 build the aerobic base; zones 4–5 are your hard interval work. Most endurance plans keep ~80% of time easy.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var efficiencyCard: some View {
        if let kind = analytics.dominantAerobicModality(in: range) {
            let series = analytics.efficiencySeries(for: kind, in: range)
            if series.count >= 2 {
                let delta = series.last!.value - series.first!.value
                let pct = series.first!.value > 0 ? delta / series.first!.value * 100 : 0
                CollapsibleStatCard(title: "\(kind.title) efficiency", key: "cardioEfficiency") {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Spacer()
                            Text(pct >= 0 ? "▲ \(pct.formatted(.number.precision(.fractionLength(0))))%" : "▼ \(abs(pct).formatted(.number.precision(.fractionLength(0))))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(pct >= 0 ? theme.success : theme.danger)
                        }
                        Text("More distance per heartbeat at easy effort — cardio's version of adding weight to the bar.")
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        LineTrendChart(points: series, color: theme.accent)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var criticalPaceCard: some View {
        let curve = analytics.criticalPaceCurve(in: range)
        if curve.current.count >= 2 {
            CollapsibleStatCard(title: "Critical pace", key: "criticalPace") {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        Spacer()
                        Text("best sustained pace").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                    Text("Your fastest pace held for each duration — this is fitness change, not one session.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    CriticalPaceCurveView(current: curve.current, prior: curve.prior)
                }
            }
        } else if curve.hasAnyData {
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(theme.textTertiary)
                    Text("Keep logging runs and your critical-pace curve will build here.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var paceCard: some View {
        if let kind = analytics.dominantPaceModality(in: range) {
            let series = analytics.paceSeries(for: kind, in: range)
            if series.count >= 2 {
                CollapsibleStatCard(title: "\(kind.title) pace", key: "cardioPace") {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Spacer()
                            Text("min\(Fmt.distanceUnit.paceSuffix) · lower is faster")
                                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        }
                        LineTrendChart(points: series, color: theme.secondaryAccent)
                    }
                }
            }
        }
    }

    private var cardioBestsCard: some View {
        let bests = analytics.cardioBests(in: range)
        return CollapsibleStatCard(title: "Cardio bests", systemImage: "trophy.fill", tint: theme.warmup, key: "cardioBests") {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    StatColumn(label: "Longest", value: bests.longestSeconds.map { Fmt.durationShort($0) } ?? "—")
                    StatColumn(label: "Farthest", value: bests.longestDistanceMeters.map { Fmt.distance($0) } ?? "—")
                    StatColumn(label: "Best pace", value: bests.bestPaceMinutesPerKm.map(paceText) ?? "—")
                }
            }
        }
    }

    private func paceText(_ minutesPerKm: Double) -> String {
        let unit = Fmt.distanceUnit
        let totalSeconds = Int((minutesPerKm * 60 * (unit.metersPerUnit / 1000)).rounded())
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60)) \(unit.paceSuffix)"
    }

    // MARK: - Monthly tab

    @ViewBuilder
    private var monthlySections: some View {
        let months = analytics.monthsWithHistory()
        if months.isEmpty {
            EmptyStateCard(
                title: "No months yet",
                message: "Finish a workout and your first monthly report will appear here.",
                systemImage: "calendar"
            )
        } else {
            let clamped = min(monthIndex, months.count - 1)
            let report = monthlyMemo("\(statsKey)|\(months[clamped].timeIntervalSince1970)") {
                analytics.monthlyReport(for: months[clamped])
            }

            monthPicker(months: months, index: clamped)
            monthlyReportCards(report)
        }
    }

    private func monthPicker(months: [Date], index: Int) -> some View {
        HStack {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { monthIndex = min(months.count - 1, index + 1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(index + 1 < months.count ? theme.textPrimary : theme.textTertiary)
                    .frame(width: 38, height: 38)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(index + 1 >= months.count)

            Spacer()
            Text(months[index].formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { monthIndex = max(0, index - 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(index > 0 ? theme.textPrimary : theme.textTertiary)
                    .frame(width: 38, height: 38)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(index <= 0)
        }
    }

    @ViewBuilder
    private func monthlyReportCards(_ report: TrainingAnalytics.MonthlyReport) -> some View {
        Card {
            VStack(spacing: Space.lg) {
                HStack {
                    monthStat("Workouts", "\(report.workouts)", delta: report.workoutsDelta.map { Double($0) }, formatter: { "\(Int($0))" })
                    monthStat("Time", Fmt.durationShort(report.durationSeconds), delta: report.durationDelta.map { Double($0) }, formatter: { Fmt.durationShort(Int(abs($0))) })
                    monthStat("Volume", Fmt.volume(report.volume), delta: report.volumeDelta, formatter: { Fmt.volume(abs($0)) })
                }
                HStack {
                    StatColumn(label: "Sets", value: "\(report.workingSets)")
                    StatColumn(label: "Reps", value: "\(report.reps)")
                    StatColumn(label: "Cardio", value: report.cardioMinutes > 0 ? Fmt.durationShort(Int(report.cardioMinutes * 60)) : "—")
                }
            }
        }

        if report.recordsSet > 0 {
            Card {
                HStack(spacing: Space.md) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.warmup)
                        .frame(width: 34, height: 34)
                        .background(theme.warmup.opacity(0.15))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(report.recordsSet) record\(report.recordsSet == 1 ? "" : "s") set")
                            .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("All-time bests that still stand today")
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
            }
        }

        if !report.topMuscles.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Muscle focus").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    ForEach(report.topMuscles) { share in
                        HStack {
                            Text(share.muscle.capitalized)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text("\(share.sets.formatted(.number.precision(.fractionLength(0)))) sets · \(Int((share.fraction * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }

        if !report.topExercises.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Top exercises").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    ForEach(report.topExercises) { usage in
                        NavigationLink(value: usage.id) {
                            HStack {
                                Text(usage.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                Spacer()
                                Text("\(usage.workingSets) sets · \(usage.sessions) session\(usage.sessions == 1 ? "" : "s")")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(theme.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        if report.distanceMeters > 0 {
            Card {
                HStack {
                    StatColumn(label: "Distance", value: Fmt.distance(report.distanceMeters), valueColor: theme.secondaryAccent)
                    StatColumn(label: "Cardio time", value: Fmt.durationShort(Int(report.cardioMinutes * 60)))
                }
            }
        }
    }

    private func monthStat(_ label: String, _ value: String, delta: Double?, formatter: (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.label).foregroundStyle(theme.textSecondary)
            Text(value).font(.statValue).foregroundStyle(theme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
            if let delta, delta != 0 {
                HStack(spacing: 2) {
                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(formatter(delta))
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(delta > 0 ? theme.recoveryHigh : theme.recoveryLow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Shared bits

    private var palette: [Color] {
        [theme.accent, theme.secondaryAccent, theme.warmup,
         theme.success, theme.danger, Color(hex: 0xFF9F0A)]
    }

    private func splitColor(_ name: String) -> Color {
        switch name {
        case "Push": theme.accent
        case "Pull": theme.secondaryAccent
        case "Legs": theme.warmup
        case "Core": theme.success
        default: theme.textTertiary
        }
    }

    private func repRangeColor(_ label: String) -> Color {
        switch label {
        case "Strength": theme.accent
        case "Hypertrophy": theme.secondaryAccent
        default: theme.warmup
        }
    }

    private func unit(for exerciseID: UUID) -> WeightUnit {
        exercises.first { $0.id == exerciseID }?.effectiveWeightUnit ?? Fmt.unit
    }
}
