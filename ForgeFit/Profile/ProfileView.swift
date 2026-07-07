import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

private struct ProfileStats {
    var importedHealthWorkouts: Int
    var lifetimeHours: Int
    var streak: Int
}

/// Hevy-style profile: identity + lifetime stats, a weekly activity chart with a
/// metric toggle, a dashboard grid, and the workout feed.
struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    @Query(filter: #Predicate<UserProgressModel> { $0.deletedAt == nil }) private var progressRows: [UserProgressModel]
    @Query(filter: #Predicate<ExerciseLibraryModel> { $0.needsReview == true }, sort: \ExerciseLibraryModel.name)
    private var importedExercisesNeedingReview: [ExerciseLibraryModel]

    @AppStorage("profileDisplayName") private var displayName = "Athlete"
    @State private var metric: TrainingAnalytics.Metric = .duration
    @State private var activityRange: TimeChartRange = .twelveWeeks
    @State private var showSettings = false
    @State private var showProfileEditor = false
    @State private var completedMemo = Memo<String, [WorkoutModel]>()
    @State private var statsMemo = Memo<String, ProfileStats>()
    @State private var activitySeriesMemo = Memo<String, [MetricPoint]>()
    @State private var weekMemo = Memo<String, TrainingAnalytics.WeekTotals>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var profileKey: String { AnalyticsFingerprint.of(workouts) }
    private var completed: [WorkoutModel] {
        completedMemo(profileKey) { analytics.completed }
    }
    private var profileStats: ProfileStats {
        statsMemo(profileKey) {
            let completed = analytics.completed
            let totalSeconds = completed.reduce(0) { $0 + analytics.summary(for: $1).durationSeconds }
            return ProfileStats(
                importedHealthWorkouts: completed.filter { $0.sourceDevice?.hasPrefix("healthkit") == true }.count,
                lifetimeHours: totalSeconds / 3600,
                streak: analytics.currentStreak()
            )
        }
    }

    private var xpProgress: XPService.Progress {
        XPService.progress(forTotalXP: progressRows.first { $0.userID == ForgeFitDemo.userID }?.totalXP ?? 0)
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold("Profile", trailing: {
                HStack(spacing: Space.sm) {
                    CircleIconButton(systemImage: "square.and.pencil") { showProfileEditor = true }
                    CircleIconButton(systemImage: "gearshape") { showSettings = true }
                }
            }) {
                identityCard
                if reviewCount > 0 {
                    importedExerciseReviewCard
                }
                activityCard

                SectionHeader("Dashboard")
                dashboardGrid

                SectionHeader("Workouts")
                if completed.isEmpty {
                    EmptyStateCard(title: "No workouts yet", message: "Your completed sessions will show up here.", systemImage: "dumbbell")
                } else {
                    ForEach(completed.prefix(10)) { workout in
                        NavigationLink(value: ProfileRoute.workout(workout.id)) {
                            WorkoutFeedRow(workout: workout, analytics: analytics)
                        }
                        .buttonStyle(.plain)
                    }
                    if completed.count > 10 {
                        NavigationLink(value: ProfileRoute.calendar) {
                            Card(padding: Space.md) {
                                HStack {
                                    Text("See all workouts").font(.bodyStrong).foregroundStyle(theme.accent)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .statistics: StatisticsView(workouts: workouts, exercises: exercises)
                case .exercises: ExercisesListView(workouts: workouts, exercises: exercises)
                case .importedExerciseReview: ReviewImportedExercisesView(workouts: workouts)
                case .measures: MeasuresView()
                case .calendar: CalendarView(workouts: workouts, exercises: exercises)
                case .workout(let id):
                    if let w = workouts.first(where: { $0.id == id }) {
                        WorkoutDetailView(workout: w, exercises: exercises, history: workouts)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await AppRefresh.run(in: modelContext) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showProfileEditor) { ProfileEditSheet() }
        }
        .interactiveBackSwipeEnabled()
    }

    private var identityCard: some View {
        Card {
            HStack(spacing: Space.lg) {
                Circle().fill(theme.recoveryHigh.opacity(0.9))
                    .frame(width: 64, height: 64)
                    .overlay(Text(profileInitials).font(.system(size: 16, weight: .bold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Text(displayName.isEmpty ? "Athlete" : displayName)
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        LevelBadge(level: xpProgress.level)
                    }
                    HStack(spacing: Space.xl) {
                        miniStat("Logged", "\(completed.count)")
                        miniStat("Hours", "\(profileStats.lifetimeHours)")
                        miniStat("Streak", "\(profileStats.streak)d")
                    }
                    XPProgressBar(progress: xpProgress)
                    if completed.count > 0 {
                        Text(historyScopeText)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
        }
    }

    private var profileInitials: String {
        let parts = displayName.split(separator: " ")
        let initials = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return initials.isEmpty ? "You" : initials.uppercased()
    }

    private var historyScopeText: String {
        if profileStats.importedHealthWorkouts > 0 {
            "Includes \(profileStats.importedHealthWorkouts) Apple Health imports from the last 60 days, plus workouts logged in ForgeFit."
        } else {
            "Completed workouts logged in ForgeFit."
        }
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 18, weight: .bold)).foregroundStyle(theme.textPrimary)
            Text(label).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
        }
    }

    private var activityCard: some View {
        let series = activitySeriesMemo("\(profileKey)|\(metric.rawValue)|\(activityRange.rawValue)") {
            analytics.weeklySeries(metric, weeks: activityRange.weekCount)
        }
        let week = weekMemo(profileKey) { analytics.thisWeek() }
        let headline: String = switch metric {
        case .duration: Fmt.durationShort(week.durationSeconds)
        case .volume: Fmt.volume(week.volume)
        case .reps: "\(week.reps) reps"
        }
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .top) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(headline).font(.metricValue).foregroundStyle(theme.textPrimary)
                        Text("this week").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Space.md)
                    TimeChartRangePicker(selection: $activityRange)
                }
                if series.contains(where: { $0.value > 0 }) {
                    BarTrendChart(points: series)
                } else {
                    Text("Train this week to fill in your activity chart.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).frame(height: 80)
                }
                SegmentedPills(options: TrainingAnalytics.Metric.allCases, title: { $0.rawValue }, selection: $metric)
            }
        }
    }

    private var importedExerciseReviewCard: some View {
        NavigationLink(value: ProfileRoute.importedExerciseReview) {
            Card(fill: theme.danger.opacity(0.12)) {
                HStack(spacing: Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.danger)
                        .frame(width: 42, height: 42)
                        .background(theme.danger.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Review \(reviewCount) imported exercise\(reviewCount == 1 ? "" : "s")")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Confirm the muscle guesses, edit details, or merge duplicates.")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.sm)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var reviewCount: Int {
        importedExercisesNeedingReview.count { $0.ownerID != nil && $0.deletedAt == nil }
    }

    private var dashboardGrid: some View {
        let columns = [GridItem(.flexible(), spacing: Space.md), GridItem(.flexible(), spacing: Space.md)]
        return LazyVGrid(columns: columns, spacing: Space.md) {
            NavigationLink(value: ProfileRoute.statistics) { DashboardTileLabel("Statistics", "chart.line.uptrend.xyaxis") }.buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.exercises) { DashboardTileLabel("Exercises", "dumbbell") }.buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.measures) { DashboardTileLabel("Measures", "figure") }.buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.calendar) { DashboardTileLabel("History", "clock.arrow.circlepath") }.buttonStyle(.plain)
        }
    }

}

private struct LevelBadge: View {
    @Environment(\.theme) private var theme
    let level: Int

    var body: some View {
        Text("Level \(level)")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(theme.accent)
            .clipShape(Capsule())
            .accessibilityLabel("Level \(level)")
    }
}

private struct XPProgressBar: View {
    @Environment(\.theme) private var theme
    let progress: XPService.Progress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress.fraction)
                .tint(theme.accent)
                .background(theme.surfaceElevated)
                .clipShape(Capsule())
            Text("\(progress.xpIntoLevel) / \(progress.xpNeededForNextLevel) XP to Level \(progress.level + 1)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.xpIntoLevel) of \(progress.xpNeededForNextLevel) XP to Level \(progress.level + 1)")
    }
}

private struct ProfileEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage("profileDisplayName") private var displayName = "Athlete"
    @State private var draftName = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                FieldLabel("Display name")
                DarkTextField(text: $draftName, placeholder: "Athlete")
                Text("This only changes how ForgeFit greets you in the app.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(Space.lg)
            .background(theme.background)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        displayName = trimmed.isEmpty ? "Athlete" : trimmed
                        dismiss()
                    }
                    .font(.bodyStrong)
                }
            }
        }
        .onAppear { draftName = displayName }
    }
}

enum ProfileRoute: Hashable {
    case statistics, exercises, importedExerciseReview, measures, calendar
    case workout(UUID)
}

private struct DashboardTileLabel: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    init(_ title: String, _ systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        GlassTile {
            HStack(spacing: Space.md) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .semibold)).frame(width: 24)
                Text(title).font(.bodyStrong)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textPrimary)
        }
    }
}

// MARK: - Dashboard destinations

/// The exercise library browser — same search / filter / create experience as
/// the in-workout picker, plus per-exercise history via the detail screen.
struct ExercisesListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @State private var query = ""
    @State private var muscle: String?
    @State private var equipment: String?
    @State private var customOnly = false
    @State private var showCreate = false
    @State private var filteredMemo = Memo<String, [ExerciseLibraryModel]>()

    private var filtered: [ExerciseLibraryModel] {
        var count = 0
        var latest = Date.distantPast
        for exercise in exercises where exercise.deletedAt == nil {
            count += 1
            latest = max(latest, exercise.updatedAt)
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "\(count)|\(latest.timeIntervalSince1970)|\(normalizedQuery)|\(muscle ?? "")|\(equipment ?? "")|\(customOnly)"
        return filteredMemo(key) {
            // Dedupe by id: CloudKit duplicates would corrupt ForEach layout.
            var seen = Set<UUID>()
            return exercises
                .filter { ex in
                    guard ex.deletedAt == nil, seen.insert(ex.id).inserted else { return false }
                    if !normalizedQuery.isEmpty, !ex.name.lowercased().contains(normalizedQuery) { return false }
                    if let muscle, !ex.primaryMuscles.contains(muscle), !ex.secondaryMuscles.contains(muscle) { return false }
                    if let equipment, ex.equipment != equipment { return false }
                    if customOnly, ex.ownerID == nil { return false }
                    return true
                }
                .sorted { $0.name < $1.name }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                CircleIconButton(systemImage: "chevron.left") { dismiss() }
                Spacer()
                Text("Exercises").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                CircleIconButton(systemImage: "plus") { showCreate = true }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.sm)

            DarkTextField(text: $query, placeholder: "Search exercises")
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.md)

            ScrollView(.horizontal, showsIndicators: false) {
                GlassEffectContainer(spacing: Space.sm) {
                    HStack(spacing: Space.sm) {
                        Menu {
                            Button("All muscles") { muscle = nil }
                            ForEach(ExerciseCatalog.muscleGroups, id: \.self) { m in
                                Button(m.capitalized) { muscle = m }
                            }
                        } label: {
                            FilterChip(title: muscle?.capitalized ?? "Muscle", active: muscle != nil, systemImage: "figure.arms.open")
                        }
                        Menu {
                            Button("All equipment") { equipment = nil }
                            ForEach(ExerciseCatalog.equipmentTypes, id: \.self) { e in
                                Button(e.capitalized) { equipment = e }
                            }
                        } label: {
                            FilterChip(title: equipment?.capitalized ?? "Equipment", active: equipment != nil, systemImage: "dumbbell")
                        }
                        Button { customOnly.toggle() } label: {
                            FilterChip(title: "Custom", active: customOnly, systemImage: "person")
                        }
                        if muscle != nil || equipment != nil || customOnly {
                            Button { muscle = nil; equipment = nil; customOnly = false } label: {
                                FilterChip(title: "Clear", active: false, systemImage: "xmark")
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: Space.sm) {
                    HStack {
                        Text("\(filtered.count) exercises").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                    ForEach(filtered) { exercise in
                        NavigationLink(value: exercise.id) {
                            HStack(spacing: Space.md) {
                                ExerciseThumbnail(exercise: exercise)
                                VStack(alignment: .leading, spacing: 2) {
                                    // Browsing/search context: show the full name,
                                    // wrapped, so long variants stay readable.
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(exercise.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                        if exercise.ownerID != nil { Tag(text: "Custom", color: theme.accent, background: theme.accentSoft) }
                                    }
                                    Text([exercise.primaryMuscles.first?.capitalized, exercise.equipment?.capitalized]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                            }
                            .padding(Space.md)
                            .background(theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.sm)
                .padding(.bottom, Space.tabBarClearance)
            }
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
        .sheet(isPresented: $showCreate) {
            CreateExerciseView { _ in }
        }
        .navigationDestination(for: UUID.self) { id in
            ExerciseDetailView(exerciseID: id, workouts: workouts, exercises: exercises)
        }
    }
}

/// Body-mass tracking, sourced from Apple Health. The latest reading also
/// powers bodyweight-exercise volume math.
struct MeasuresView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var health = HealthMetricsStore.shared
    @State private var showLogWeight = false
    @State private var weightDraft = ""
    @State private var savingWeight = false
    @State private var bodyweightRange: TimeChartRange = .oneYear

    var body: some View {
        DashboardScaffold(title: "Measures", dismiss: dismiss) {
            let series = health.bodyweightSeries
            let chartSeries = bodyweightRange.filtered(
                series.map { MetricPoint(date: $0.date, value: Fmt.unit.displayValue(fromKilograms: $0.value)) }
            )
            PrimaryButton(title: "Log Weight", systemImage: "plus") {
                weightDraft = series.last.map { Fmt.load($0.value) } ?? ""
                showLogWeight = true
            }
            if let latest = series.last {
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bodyweight").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(Fmt.load(latest.value))
                                        .font(.system(size: 34, weight: .bold, design: .rounded))
                                        .foregroundStyle(theme.textPrimary)
                                    Text(Fmt.unit.suffix).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textSecondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: Space.sm) {
                                TimeChartRangePicker(selection: $bodyweightRange)
                                if chartSeries.count >= 2, let first = chartSeries.first {
                                    let displayDelta = chartSeries.last!.value - first.value
                                    Text("\(displayDelta >= 0 ? "+" : "")\(displayDelta.formatted(.number.precision(.fractionLength(0...1)))) \(Fmt.unit.suffix)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.textSecondary)
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(theme.surfaceElevated)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        Text("Updated \(latest.date.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                        if chartSeries.count >= 2 {
                            LineTrendChart(points: chartSeries)
                        }
                    }
                }
                Card {
                    Text("Your latest bodyweight is used to count volume for bodyweight exercises like pull-ups and dips.")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
                Text("Log weigh-ins here, in the Health app, or with a smart scale. They sync through Apple Health.")
                    .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            } else {
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Bodyweight").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("No weigh-ins found. Log your weight here or connect Apple Health. Bodyweight improves volume tracking for pull-ups, dips, and similar exercises.")
                            .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .onAppear { health.refresh() }
        .sheet(isPresented: $showLogWeight) {
            logWeightSheet
        }
    }

    private var logWeightSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                FieldLabel("Weight")
                HStack(spacing: Space.sm) {
                    DarkTextField(text: $weightDraft, placeholder: "180")
                        .keyboardType(.decimalPad)
                    Text(Fmt.unit.suffix)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                }
                Text("ForgeFit writes this weigh-in to Apple Health so your other health apps can use the same source of truth.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(Space.lg)
            .background(theme.background)
            .navigationTitle("Log Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showLogWeight = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savingWeight ? "Saving..." : "Save") { saveWeight() }
                        .font(.bodyStrong)
                        .disabled(savingWeight || Fmt.loadKilograms(from: weightDraft) == nil)
                }
            }
        }
    }

    private func saveWeight() {
        guard let kilograms = Fmt.loadKilograms(from: weightDraft) else { return }
        savingWeight = true
        Task {
            let saved = await HealthService.shared.logBodyMass(kilograms: kilograms)
            await MainActor.run {
                savingWeight = false
                if saved {
                    showLogWeight = false
                    health.refresh(force: true)
                }
            }
        }
    }
}

struct CalendarView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    @State private var monthMemo = Memo<String, [(month: String, items: [WorkoutModel])]>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var byMonth: [(month: String, items: [WorkoutModel])] {
        monthMemo(AnalyticsFingerprint.of(workouts)) {
            let completed = analytics.completed
            var order: [String] = []
            var map: [String: [WorkoutModel]] = [:]
            for w in completed {
                let key = w.startedAt.formatted(.dateTime.month(.wide).year())
                if map[key] == nil { order.append(key); map[key] = [] }
                map[key]?.append(w)
            }
            return order.map { ($0, map[$0] ?? []) }
        }
    }

    var body: some View {
        DashboardScaffold(title: "History", dismiss: dismiss) {
            ForEach(byMonth, id: \.month) { group in
                Text(group.month).font(.bodyStrong).foregroundStyle(theme.textSecondary)
                ForEach(group.items) { workout in
                    NavigationLink(value: workout.id) {
                        WorkoutFeedRow(workout: workout, analytics: analytics)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationDestination(for: UUID.self) { id in
            if let w = workouts.first(where: { $0.id == id }) {
                WorkoutDetailView(workout: w, exercises: exercises, history: workouts)
            }
        }
    }
}

/// Shared chrome for the dashboard sub-screens (back header + scroll).
struct DashboardScaffold<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let dismiss: DismissAction
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    CircleIconButton(systemImage: "chevron.left") { dismiss() }
                    Spacer()
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Color.clear.frame(width: 38, height: 38)
                }
                .padding(.top, Space.sm)
                content
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
    }
}
