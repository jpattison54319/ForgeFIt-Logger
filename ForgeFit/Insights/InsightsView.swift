import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Analytics hub: training trends, weekly muscle-group volume, personal records,
/// and cardio. Everything is derived from `TrainingAnalytics`.
struct InsightsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @State private var metric: TrainingAnalytics.Metric = .volume
    @State private var range: TimeChartRange = .twelveWeeks
    @State private var infoTopic: InsightsInfoTopic?
    // Full-history rollups, memoized: this tab stays alive behind the others
    // and must not recompute on every unrelated @Query re-render.
    @State private var muscleMemo = Memo<String, [MuscleVolumeBars.Row]>()
    @State private var recordsMemo = Memo<String, [TrainingAnalytics.ExerciseRecord]>()
    @State private var seriesMemo = Memo<String, [MetricPoint]>()
    @State private var weekMemo = Memo<String, TrainingAnalytics.WeekTotals>()

    var body: some View {
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        let fingerprint = AnalyticsFingerprint.of(workouts)
        let muscleRows = muscleMemo(fingerprint) { analytics.weeklyMuscleVolume() }
        let records = recordsMemo(fingerprint) { analytics.records() }

        NavigationStack {
            ScreenScaffold("Insights") {
                trendCard(analytics: analytics, fingerprint: fingerprint)

                if !muscleRows.isEmpty {
                    SectionHeader("Weekly volume by muscle") {
                        Button { infoTopic = .muscleVolume } label: {
                            Image(systemName: "info.circle")
                        }
                        .foregroundStyle(theme.textSecondary)
                    }
                    Card { MuscleVolumeBars(rows: muscleRows) }
                }

                SectionHeader("Records") {
                    Text("\(records.count)").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                }
                if records.isEmpty {
                    EmptyStateCard(title: "No records yet", message: "Log some working sets to start tracking estimated 1RMs.", systemImage: "trophy")
                } else {
                    ForEach(records.prefix(8)) { record in
                        NavigationLink(value: InsightsRoute.exercise(record.id)) {
                            RecordRow(record: record, exercise: exercises.first { $0.id == record.id }) {
                                infoTopic = .estimated1RM
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if records.count > 8 {
                        NavigationLink(value: InsightsRoute.records) {
                            Card(padding: Space.md) {
                                HStack {
                                    Text("See all records").font(.bodyStrong).foregroundStyle(theme.accent)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                CardioSummaryCard(analytics: analytics, range: $range)
            }
            .navigationDestination(for: InsightsRoute.self) { route in
                switch route {
                case .exercise(let exerciseID):
                    ExerciseDetailView(exerciseID: exerciseID, workouts: workouts, exercises: exercises)
                case .records:
                    RecordsListView(records: records, workouts: workouts, exercises: exercises)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await AppRefresh.run(in: modelContext) }
            .sheet(item: $infoTopic) { topic in
                InsightsInfoSheet(topic: topic)
            }
        }
        .interactiveBackSwipeEnabled()
    }

    private func trendCard(analytics: TrainingAnalytics, fingerprint: String) -> some View {
        let series = seriesMemo("\(fingerprint)|\(metric.rawValue)|\(range.rawValue)") {
            analytics.weeklySeries(metric, weeks: range.weekCount)
        }
        let week = weekMemo(fingerprint) { analytics.thisWeek() }
        let headline: String = switch metric {
        case .volume: Fmt.volume(week.volume)
        case .reps: "\(week.reps) reps"
        case .duration: Fmt.durationShort(week.durationSeconds)
        }
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(headline).font(.metricValue).foregroundStyle(theme.textPrimary)
                            Text("this week").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer(minLength: Space.md)
                    TimeChartRangePicker(selection: $range)
                }
                if series.contains(where: { $0.value > 0 }) {
                    BarTrendChart(points: series)
                } else {
                    Text("Complete a few workouts to see your trends.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).frame(height: 80)
                }
                SegmentedPills(options: TrainingAnalytics.Metric.allCases, title: { $0.rawValue }, selection: $metric)
            }
        }
    }
}

private enum InsightsRoute: Hashable {
    case exercise(UUID)
    case records
}

private enum InsightsInfoTopic: Identifiable {
    case estimated1RM
    case muscleVolume

    var id: String { title }
    var title: String {
        switch self {
        case .estimated1RM: "Estimated 1RM"
        case .muscleVolume: "Muscle Volume"
        }
    }
    var body: String {
        switch self {
        case .estimated1RM:
            "Estimated 1RM turns a hard set into an estimated max. It is best for spotting strength trends, not for forcing max attempts."
        case .muscleVolume:
            "Muscle volume counts hard sets by the muscles they train. The target line is a coaching landmark, not a rule every week must hit."
        }
    }
}

private struct InsightsInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let topic: InsightsInfoTopic

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                Text(topic.title).font(.cardTitle).foregroundStyle(theme.textPrimary)
                Spacer()
                CircleIconButton(systemImage: "xmark") { dismiss() }
            }
            Text(topic.body)
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(Space.lg)
        .background(theme.background)
    }
}

private struct RecordRow: View {
    @Environment(\.theme) private var theme
    let record: TrainingAnalytics.ExerciseRecord
    let exercise: ExerciseLibraryModel?
    var onInfo: () -> Void = {}

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(theme.warmup)
                    .frame(width: 38, height: 38)
                    .background(theme.surfaceElevated).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    HStack(spacing: 4) {
                        Text("Best estimated 1RM").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        Button(action: onInfo) {
                            Image(systemName: "info.circle")
                                .font(.tag)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                Text(Fmt.loadUnit(record.best1RM, unit: exercise?.effectiveWeightUnit ?? Fmt.unit))
                    .font(.statValue).foregroundStyle(theme.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
            }
        }
    }
}

private struct RecordsListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let records: [TrainingAnalytics.ExerciseRecord]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    @State private var infoTopic: InsightsInfoTopic?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    CircleIconButton(systemImage: "chevron.left") { dismiss() }
                    Spacer()
                    Text("Records").font(.rowValue).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.top, Space.sm)

                ForEach(records) { record in
                    NavigationLink(value: record.id) {
                        RecordRow(record: record, exercise: exercises.first { $0.id == record.id }) {
                            infoTopic = .estimated1RM
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: UUID.self) { exerciseID in
            ExerciseDetailView(exerciseID: exerciseID, workouts: workouts, exercises: exercises)
        }
        .sheet(item: $infoTopic) { topic in
            InsightsInfoSheet(topic: topic)
        }
    }
}

/// Per-exercise progression detail (e1RM over time).
struct ExerciseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let exerciseID: UUID
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @State private var range: TimeChartRange = .all
    @State private var showFullHistory = false
    @State private var showingEdit = false
    @State private var seriesMemo = Memo<String, [MetricPoint]>()
    @State private var bestsMemo = Memo<String, [PersonalRecords.AllTimeBest]>()
    @State private var sessionsMemo = Memo<String, [(workout: WorkoutModel, sets: [SetModel])]>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var exercise: ExerciseLibraryModel? { exercises.first { $0.id == exerciseID } }
    private var name: String { exercise?.name ?? "Exercise" }
    private var unit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }
    private var isCardio: Bool { exercise?.isCardio == true }
    private var detailFingerprint: String {
        "\(AnalyticsFingerprint.of(workouts))|\(exerciseID.uuidString)"
    }
    private var series: [MetricPoint] {
        seriesMemo("\(detailFingerprint)|\(range.rawValue)") {
            range.filtered(analytics.e1rmSeries(for: exerciseID))
        }
    }

    /// Standing all-time records for this exercise (includes an active session).
    private var bests: [PersonalRecords.AllTimeBest] {
        bestsMemo(detailFingerprint) {
            PersonalRecords.allTimeBests(for: exerciseID, in: workouts)
        }
    }
    private var recordSetIDs: Set<UUID> { Set(bests.map(\.set.id)) }

    /// Every session where this exercise was performed, newest first, with its
    /// completed sets in logged order.
    private var sessions: [(workout: WorkoutModel, sets: [SetModel])] {
        sessionsMemo(detailFingerprint) {
            workouts
                .filter { $0.deletedAt == nil }
                .sorted { $0.startedAt > $1.startedAt }
                .compactMap { workout in
                    let sets = workout.exercises
                        .filter { $0.exerciseID == exerciseID }
                        .flatMap(\.sets)
                        .filter { $0.completedAt != nil }
                        .sorted { $0.position < $1.position }
                    return sets.isEmpty ? nil : (workout, sets)
                }
        }
    }
    private static let recentSessionCount = 3
    private var visibleSessions: [(workout: WorkoutModel, sets: [SetModel])] {
        showFullHistory ? sessions : Array(sessions.prefix(Self.recentSessionCount))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    CircleIconButton(systemImage: "chevron.left") { dismiss() }
                    Spacer()
                    Text("Exercise").font(.rowValue).foregroundStyle(theme.textPrimary)
                    Spacer()
                    if exercise != nil {
                        CircleIconButton(systemImage: "square.and.pencil") { showingEdit = true }
                    } else {
                        Color.clear.frame(width: 38, height: 38)
                    }
                }
                .padding(.top, Space.sm)

                Text(name).font(.screenTitle).foregroundStyle(theme.textPrimary)

                if let exercise {
                    ExerciseInfoCard(exercise: exercise)
                }

                if let exercise, !exercise.isCardio {
                    ExerciseUnitSettingsCard(exercise: exercise)
                }

                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Estimated 1RM").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                            Spacer()
                            TimeChartRangePicker(selection: $range)
                        }
                        if let last = series.last {
                            Text(Fmt.loadUnit(last.value, unit: unit)).font(.metricValue).foregroundStyle(theme.textPrimary)
                        }
                        if series.count >= 2 {
                            LineTrendChart(points: series)
                        } else {
                            Text("Log this exercise across multiple sessions to chart strength progress.")
                                .font(.system(size: 14)).foregroundStyle(theme.textSecondary).frame(height: 80)
                        }
                    }
                }

                if !bests.isEmpty {
                    recordsCard
                }

                if !sessions.isEmpty {
                    historyCard
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .sheet(isPresented: $showingEdit) {
            if let exercise {
                CreateExerciseView(editing: exercise) { _ in }
            }
        }
    }

    // MARK: - Records

    private var recordsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Label("Records", systemImage: "trophy.fill")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.warmup)
                ForEach(bests) { best in
                    HStack(spacing: Space.md) {
                        Image(systemName: best.kind.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.warmup)
                            .frame(width: 28, height: 28)
                            .background(theme.warmup.opacity(0.15))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(best.kind.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                            Text(best.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text(best.kind.valueText(for: best.set, unit: unit))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.warmup)
                    }
                }
            }
        }
    }

    // MARK: - History

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("History")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textSecondary)

                ForEach(Array(visibleSessions.enumerated()), id: \.element.workout.id) { index, session in
                    if index > 0 {
                        Divider().overlay(theme.separator)
                    }
                    sessionBlock(session.workout, sets: session.sets)
                }

                if sessions.count > Self.recentSessionCount {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { showFullHistory.toggle() }
                    } label: {
                        Text(showFullHistory ? "Show Recent Only" : "Show All \(sessions.count) Sessions")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sessionBlock(_ workout: WorkoutModel, sets: [SetModel]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                if !isCardio {
                    let volume = sets.reduce(0.0) { $0 + ($1.totalVolume ?? 0) }
                    Text(Fmt.volume(volume, unit: unit))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            ForEach(sets, id: \.id) { set in
                setHistoryRow(set)
            }
        }
    }

    private func setHistoryRow(_ set: SetModel) -> some View {
        let style = SetTypeStyle.of(set.setType)
        return HStack(spacing: Space.sm) {
            Text(style.badge.isEmpty ? "•" : style.badge)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(style.badge.isEmpty ? theme.textTertiary : style.color)
                .frame(width: 18)
            Text(setSummary(set))
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)
            if recordSetIDs.contains(set.id) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.warmup)
            }
            Spacer()
            if !isCardio, let oneRM = set.estimated1RM {
                Text("\(Fmt.load(oneRM, unit: unit)) e1RM")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    /// Mirrors the logger's "previous" column: "225 lbs × 8", or duration for
    /// cardio-style sets.
    private func setSummary(_ set: SetModel) -> String {
        if isCardio { return Fmt.durationShort(set.durationSeconds) }
        let weight = Fmt.load(set.weight, unit: unit)
        let reps = set.reps.map(String.init) ?? "—"
        return "\(weight) \(unit.suffix) × \(reps)"
    }
}

private struct ExerciseUnitSettingsCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Bindable var exercise: ExerciseLibraryModel

    private var unitBinding: Binding<WeightUnit> {
        Binding(
            get: { exercise.effectiveWeightUnit },
            set: { newValue in
                exercise.preferredWeightUnit = newValue
                exercise.updatedAt = Date()
                try? modelContext.save()
            }
        )
    }

    var body: some View {
        Card {
            HStack(spacing: Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exercise unit").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("Sets and history")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Picker("Exercise unit", selection: unitBinding) {
                    Text("lb").tag(WeightUnit.lb)
                    Text("kg").tag(WeightUnit.kg)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
    }
}
