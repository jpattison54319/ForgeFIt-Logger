import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

private struct ProfileStats {
    var importedHealthWorkouts: Int
    var lifetimeHours: Int
}

/// Hevy-style profile: identity + lifetime stats, a weekly activity chart with a
/// metric toggle, a dashboard grid, and the workout feed.
struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    @Query(filter: #Predicate<UserProgressModel> { $0.deletedAt == nil }) private var progressRows: [UserProgressModel]
    @Query(filter: ExerciseLibraryModel.pendingImportReviewPredicate, sort: ExerciseLibraryModel.pendingImportReviewSort)
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
                lifetimeHours: totalSeconds / 3600
            )
        }
    }

    private var xpProgress: XPService.Progress {
        XPService.progress(forTotalXP: progressRows.first { $0.userID == ForgeFitDemo.userID }?.totalXP ?? 0)
    }

    @State private var trophiesMemo = Memo<String, [Trophy]>()

    private var trophies: [Trophy] {
        trophiesMemo(profileKey) {
            TrophyCatalog.trophies(TrophyCatalog.inputs(
                workouts: workouts,
                exercises: exercises
            ))
        }
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold("Profile", trailing: {
                HStack(spacing: Space.sm) {
                    CircleIconButton(systemImage: "square.and.pencil", label: "Edit profile") { showProfileEditor = true }
                    CircleIconButton(systemImage: "gearshape", label: "Settings") { showSettings = true }
                }
            }) {
                identityCard
                if reviewCount > 0 {
                    importedExerciseReviewCard
                }
                activityCard

                SectionHeader("Dashboard")
                dashboardGrid

                SectionHeader("Trophy case")
                TrophyCaseCard(trophies: trophies)

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
                        NavigationLink(value: ProfileRoute.history) {
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
                case .calendar: WorkoutCalendarView(workouts: workouts, exercises: exercises)
                case .history: WorkoutHistoryView(workouts: workouts, exercises: exercises)
                case .wrapped: WrappedListView()
                case .community:
                    SocialHubView(makeSnapshot: {
                        SocialProfileComposer.snapshot(
                            workouts: workouts,
                            exercises: exercises,
                            totalXP: progressRows.first { $0.userID == ForgeFitDemo.userID }?.totalXP ?? 0
                        )
                    })
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
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(spacing: Space.lg) {
                    avatarBadge
                    VStack(alignment: .leading, spacing: Space.md) {
                        HStack(spacing: Space.sm) {
                            Text(displayName.isEmpty ? "Athlete" : displayName)
                                .font(.sectionTitle)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            LevelBadge(level: xpProgress.level)
                        }
                        HStack(spacing: Space.sm) {
                            statTile("flame.fill", "\(completed.count)", "Logged")
                            statTile("clock.fill", "\(profileStats.lifetimeHours)", "Hours")
                        }
                    }
                }
                XPProgressBar(progress: xpProgress)
                if completed.count > 0 {
                    Divider().overlay(theme.separator)
                    HStack(spacing: Space.md) {
                        Image(systemName: "heart")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 36, height: 36)
                            .background(theme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.tag))
                            .accessibilityHidden(true)
                        Text(historyScopeText)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var avatarBadge: some View {
        ZStack {
            Circle()
                .stroke(theme.accent.opacity(0.28), lineWidth: 1.5)
                .frame(width: 76, height: 76)
            Circle()
                .fill(theme.recoveryHigh.opacity(0.9))
                .frame(width: 64, height: 64)
                .shadow(color: theme.accent.opacity(0.35), radius: 10)
            Text(profileInitials)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private func statTile(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: Space.xs) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
                Text(value)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.sm)
        .padding(.horizontal, Space.xs)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        .accessibilityElement(children: .combine)
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
                        .font(.cardTitle)
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
            NavigationLink(value: ProfileRoute.calendar) { DashboardTileLabel("Calendar", "calendar") }.buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.wrapped) { DashboardTileLabel("Wrapped", "sparkles") }.buttonStyle(.plain)
            NavigationLink(value: ProfileRoute.community) { DashboardTileLabel("Community", "person.2.fill") }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dashboard-community")
        }
    }

}

/// Shared with the social profile screens so a friend's level renders
/// identically to your own.
struct LevelBadge: View {
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

/// Shared with the social profile screens (a friend's XP bar renders from
/// their published `totalXP`).
struct XPProgressBar: View {
    @Environment(\.theme) private var theme
    let progress: XPService.Progress

    var body: some View {
        HStack(spacing: Space.md) {
            ZStack {
                Image(systemName: "hexagon.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(theme.accentSoft)
                Image(systemName: "hexagon")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text("XP")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(theme.textPrimary)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                (Text("\(progress.xpIntoLevel)").foregroundStyle(theme.accent)
                    + Text(" / \(progress.xpNeededForNextLevel) XP ").foregroundStyle(theme.textPrimary)
                    + Text("to Level \(progress.level + 1)").foregroundStyle(theme.textSecondary))
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ProgressView(value: progress.fraction)
                    .tint(theme.accent)
                    .background(theme.surfaceHighlight)
                    .clipShape(Capsule())
            }
            ZStack {
                Image(systemName: "shield")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                Text("\(progress.level + 1)")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(Space.md)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
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
    case statistics, exercises, importedExerciseReview, measures, calendar, history, wrapped, community
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
                CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
                Spacer()
                Text("Exercises").font(.rowValue).foregroundStyle(theme.textPrimary)
                Spacer()
                CircleIconButton(systemImage: "plus", label: "Create exercise") { showCreate = true }
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
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(theme.accent)
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
    @State private var bodyweightRange: TimeChartRange = .oneYear

    var body: some View {
        DashboardScaffold(title: "Measures", dismiss: dismiss) {
            let series = health.bodyweightSeries
            let chartSeries = bodyweightRange.filtered(
                series.map { MetricPoint(date: $0.date, value: Fmt.unit.displayValue(fromKilograms: $0.value)) }
            )
            PrimaryButton(title: "Log Weight", systemImage: "plus") {
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
                                    Text(Fmt.unit.suffix).font(.bodyStrong).foregroundStyle(theme.textSecondary)
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
            LogWeightSheet()
        }
    }
}

/// Shared chrome for the dashboard sub-screens (back header + scroll).
struct DashboardScaffold<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    let dismiss: DismissAction
    /// Opt-in lazy body: long lists (e.g. the full workout History) pass `true`
    /// so only on-screen rows are built and their per-row summaries computed,
    /// instead of instantiating the whole history up front. Defaults to `false`
    /// so every existing dashboard sub-screen is unchanged.
    var lazy: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            stack
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
    }

    @ViewBuilder
    private var stack: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                header
                content
            }
        } else {
            VStack(alignment: .leading, spacing: Space.lg) {
                header
                content
            }
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            Text(title).font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            Color.clear.frame(width: 44, height: 44)   // mirror the 44 pt leading button so the title centers
        }
        .padding(.top, Space.sm)
    }
}
