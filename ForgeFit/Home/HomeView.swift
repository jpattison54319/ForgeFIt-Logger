import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The "Today" landing screen. Leads with a recovery/readiness read (the
/// signal that most reduces "what should I do today?" cognitive load), then
/// this week's training at a glance, quick starts, and recent activity.
struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @State private var showSettings = false
    @State private var showCoach = false
    @State private var showExploreLibrary = false
    @State private var quickStartEditing = false
    @State private var draggedQuickStartAction: HomeQuickStartAction?
    @State private var showQuickStartAdd = false
    @State private var editingRoutine: RoutineModel?
    @State private var presentedWrappedReport: WrappedReportModel?
    @State private var reviewRequest: CoachReviewRequest?

    /// New (unopened) Wrapped reports — drives the "Report Available" card,
    /// which disappears the moment the story is opened (viewedAt set).
    @Query(
        filter: #Predicate<WrappedReportModel> { $0.viewedAt == nil && $0.deletedAt == nil },
        sort: \WrappedReportModel.generatedAt, order: .reverse
    ) private var unviewedWrappedReports: [WrappedReportModel]
    @Query private var checkins: [DailyCheckinModel]
    /// This week's Coach's Corner weekly-review overrides — only used to
    /// check whether a deload week is currently active, so
    /// `CoachAdjustments.effectivePlan` can resolve it against today's
    /// readiness call without ever stacking two reductions.
    @Query private var weekOverrides: [CoachingWeekOverrideModel]

    private var weeklyDeloadActive: Bool {
        let anchor = CoachWeeklyReview.weekAnchor(for: Date())
        return weekOverrides.contains {
            $0.statusRaw == CoachingOverrideStatus.active.rawValue
                && $0.kindRaw == CoachingOverrideKind.deloadWeek.rawValue
                && $0.weekStart == anchor
        }
    }

    let workouts: [WorkoutModel]
    let routines: [RoutineModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    // Recovery reports are full-history passes — memoized so the always-alive
    // tab doesn't recompute them on every unrelated re-render.
    @AppStorage("homeQuickStartActions.v1") private var quickStartActionsJSON = ""
    @State private var connectingHealth = false
    // Keeps the check-in strip visible while the user is mid-selection —
    // without it the row would vanish on the first tap. Resets when Home
    // reloads, so an answered check-in stays collapsed on later visits.
    @State private var checkinStripEngaged = false
    @State private var recoveryMemo = Memo<String, RecoveryEngine.Report>()
    @State private var targetRecoveryMemo = Memo<String, RoutineDoseContext>()
    @State private var weekMemo = Memo<String, TrainingAnalytics.WeekTotals>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var todayCheckin: DailyCheckinModel? {
        checkins
            .filter { $0.deletedAt == nil && Calendar.current.isDate($0.date, inSameDayAs: Date()) }
            .max { $0.updatedAt < $1.updatedAt }
    }
    private var todayCheckinTags: [String] { todayCheckin?.tags ?? [] }

    private var recovery: RecoveryEngine.Report {
        recoveryMemo("\(AnalyticsFingerprint.withHealth(workouts))|\(todayCheckinTags.joined(separator: ","))") {
            RecoveryEngine(
                workouts: workouts,
                exercises: exercises,
                healthMetrics: HealthMetricsStore.shared.metrics,
                todayCheckinTags: todayCheckinTags
            ).report()
        }
    }
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    private var recentCompleted: [WorkoutModel] {
        workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }.prefix(4).map { $0 }
    }

    private var hasReadinessSignal: Bool {
        workouts.contains { $0.endedAt != nil && $0.deletedAt == nil }
            || !HealthMetricsStore.shared.metrics.isEmpty
    }

    // MARK: - Smart next-workout suggestion

    /// A macrocycle can hold several mesocycles, only one of which you're
    /// actually running — these are independent so both can be active at
    /// once. `suggestion` drills into the mesocycle first, then falls back
    /// to the macrocycle, then to best-guessing across every routine.
    @AppStorage("activeMacroFolderID") private var activeMacroFolderRaw = ""
    @AppStorage("activeMesoFolderID") private var activeMesoFolderRaw = ""
    @Query private var allFolders: [RoutineFolderModel]

    /// The active folder plus its whole subtree, so an active macrocycle picks
    /// up routines inside its mesocycle subfolders too.
    private func folderSubtree(rootID: UUID) -> Set<UUID> {
        let live = allFolders.filter { $0.deletedAt == nil }
        var result: Set<UUID> = [rootID]
        var queue = [rootID]
        while let next = queue.popLast() {
            for child in live where child.parentID == next && !result.contains(child.id) {
                result.insert(child.id)
                queue.append(child.id)
            }
        }
        return result
    }

    /// What the app thinks you'll want to train next — see
    /// `NextRoutineSuggestion` for the drilldown logic (mesocycle → macrocycle
    /// → best guess).
    private var suggestion: (routine: RoutineModel, reason: String)? {
        guard let result = NextRoutineSuggestion.suggest(
            routines: routines,
            completedWorkouts: workouts,
            activeMesoFolderID: UUID(uuidString: activeMesoFolderRaw),
            activeMacroFolderID: UUID(uuidString: activeMacroFolderRaw),
            macroSubtree: folderSubtree(rootID:)
        ), let routine = routines.first(where: { $0.id == result.routineID }) else { return nil }
        return (routine, result.reason)
    }

    var body: some View {
        NavigationStack {
            ScreenScaffold(greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month().day()), trailing: {
                CircleIconButton(systemImage: "figure.strengthtraining.traditional", label: "Coach's Corner") { showCoach = true }
            }) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if welcomeBackGapDays >= 7, !trainedToday {
                        welcomeBackCard
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    if hasReadinessSignal {
                        NavigationLink(value: HomeRoute.recovery) {
                            RecoveryHeroCard(report: recovery)
                        }
                        .buttonStyle(.plain)
                        .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    } else {
                        readinessEmptyState
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    if showsCheckinStrip {
                        morningCheckinStrip
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    weekCard
                        .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)

                    if let newReport = unviewedWrappedReports.first {
                        wrappedAvailableCard(newReport)
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    // "Jump back in" only when there is something to jump back
                    // into — a brand-new user gets "Get started" and a route
                    // into the program library instead of a dangling header.
                    SectionHeader(suggestion != nil || !recentCompleted.isEmpty ? "Jump back in" : "Get started")
                    if let suggestion {
                        suggestionCard(suggestion.routine, reason: suggestion.reason)
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    } else {
                        explorePromptCard
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }
                    quickStart

                    if !recentCompleted.isEmpty {
                        SectionHeader("Recent")
                        ForEach(recentCompleted) { workout in
                            NavigationLink(value: workout) {
                                WorkoutFeedRow(workout: workout, analytics: analytics)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("home-workout-\(workout.title ?? "Workout")")
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if quickStartEditing {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: dismissQuickStartEdit)
                            .accessibilityHidden(true)
                    }
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .recovery: RecoveryDetailView(workouts: workouts, exercises: exercises)
                }
            }
            .navigationDestination(for: WorkoutModel.self) { workout in
                WorkoutDetailView(workout: workout, exercises: exercises, history: workouts)
            }
            .navigationDestination(item: $editingRoutine) { routine in
                RoutineEditorView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
            .toolbar(.hidden, for: .navigationBar)
            // Pull down to re-query Apple Health and recompute readiness.
            .refreshable { await AppRefresh.run(in: modelContext) }
            .fullScreenCover(item: $presentedWrappedReport) { report in
                WrappedStoryView(report: report)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCoach) {
                CoachCornerView(
                    workouts: workouts,
                    routines: routines,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    recovery: recovery,
                    suggestion: suggestion
                )
            }
            .sheet(item: $reviewRequest) { request in
                CoachAdjustmentReviewView(
                    plan: request.plan,
                    routine: request.routine,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    reasons: recovery.reasonChips.prefix(3).map(\.text),
                    sourceLabel: request.sourceLabel
                )
            }
            .sheet(isPresented: $showQuickStartAdd) {
                QuickStartAddSheet(
                    routines: activeRoutines,
                    configuredActions: quickStartActions,
                    onAdd: { action in
                        addQuickStartAction(action)
                        showQuickStartAdd = false
                    },
                    onCreateRoutine: {
                        showQuickStartAdd = false
                        editingRoutine = createRoutine()
                    }
                )
            }
            // Screenshot/UI-test hook, same family as -initialTab (unset in
            // production).
            .onAppear {
                if UserDefaults.standard.bool(forKey: "openSettings") { showSettings = true }
            }
            .sheet(isPresented: $showExploreLibrary) {
                let templates = RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises)
                RoutineLibraryView(
                    programs: RoutineTemplateCatalog.validPrograms(
                        from: RoutineTemplateCatalog.loadPrograms(),
                        templates: templates,
                        exercises: exercises
                    ),
                    templates: templates,
                    exercises: exercises,
                    onImport: { program in
                        // A program is a whole mesocycle: it always lands as its
                        // own new top-level folder with the day routines inside.
                        RoutineTemplateCatalog.importProgram(program, templates: templates, in: modelContext)
                        showExploreLibrary = false
                    }
                )
            }
        }
        .interactiveBackSwipeEnabled()
    }

    private var activeRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil && !$0.exercises.isEmpty }.sorted { $0.position < $1.position }
    }

    /// Shown in place of "Up next" when no routine exists yet — the way into
    /// a plan for users who skipped the starter program.
    private var explorePromptCard: some View {
        Button {
            showExploreLibrary = true
        } label: {
            Card {
                HStack(spacing: Space.md) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 38, height: 38)
                        .background(theme.accentSoft)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Find your program").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Browse ready-made training programs, or start below.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var readinessEmptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 38, height: 38)
                        .background(theme.accentSoft)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ready when you are").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Connect Apple Health or add a training program to build your baseline.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                }
                HStack(spacing: Space.md) {
                    // Triggers the Health permission directly — no detour
                    // through the full Settings sheet to find the right card.
                    Button(connectingHealth ? "Connecting…" : "Connect Apple Health") {
                        connectingHealth = true
                        Task {
                            _ = await HealthService.shared.requestAuthorization()
                            await HealthWorkoutImporter.shared.importRecent(in: modelContext)
                            HealthMetricsStore.shared.refresh(force: true)
                            connectingHealth = false
                        }
                    }
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    .disabled(connectingHealth)
                    Button("Explore programs") { showExploreLibrary = true }
                        .font(.bodyStrong)
                        .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
            }
        }
    }

    /// "Your June Wrapped is ready" — shown until the story is opened, then
    /// gone for good (the report lives on in Profile).
    private func wrappedAvailableCard(_ report: WrappedReportModel) -> some View {
        Button {
            presentedWrappedReport = report
        } label: {
            Card {
                HStack(spacing: Space.md) {
                    ZStack {
                        Circle()
                            .fill(theme.accentSoft)
                            .frame(width: 44, height: 44)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(report.isMonthly ? "Monthly" : "Yearly") Report Available")
                            .font(.tag)
                            .foregroundStyle(theme.accent)
                        Text("Your \(WrappedReportService.title(for: report)) is ready.")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("View Report")
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("wrapped-report-available")
    }

    @AppStorage("weeklyWorkoutGoal") private var weeklyWorkoutGoal = 3

    private var weeklyStreak: WeeklyStreak.Result {
        WeeklyStreak.compute(
            workoutDates: workouts.compactMap { $0.endedAt != nil && $0.deletedAt == nil ? $0.startedAt : nil },
            goalPerWeek: weeklyWorkoutGoal
        )
    }

    private var weekCard: some View {
        let week = weekMemo(AnalyticsFingerprint.of(workouts)) { analytics.thisWeek() }
        let streak = weeklyStreak
        return Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack {
                    Text("This week").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                    Spacer()
                    // Weekly streak: consecutive weeks hitting the goal, with
                    // auto-freezes for a missed week — rest-day aware by
                    // design, unlike a daily chain. Long-press to set the goal.
                    Menu {
                        Section("Weekly goal") {
                            ForEach([2, 3, 4, 5, 6], id: \.self) { goal in
                                Button {
                                    weeklyWorkoutGoal = goal
                                } label: {
                                    Label("\(goal) workouts", systemImage: goal == weeklyWorkoutGoal ? "checkmark" : "")
                                }
                            }
                        }
                        if streak.freezesBanked > 0 {
                            Text("\(streak.freezesBanked) streak freeze\(streak.freezesBanked == 1 ? "" : "s") banked — a missed week won't break the run.")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if streak.weeks > 0 {
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(theme.accent)
                                Text("\(streak.weeks)w")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.textPrimary)
                            }
                            Text("\(min(streak.thisWeekCount, streak.goalPerWeek))/\(streak.goalPerWeek)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(streak.thisWeekMet ? theme.success : theme.textSecondary)
                            ForEach(0..<streak.freezesBanked, id: \.self) { _ in
                                Image(systemName: "snowflake")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(theme.secondaryAccent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.surfaceElevated))
                    }
                    .accessibilityLabel("Weekly streak \(streak.weeks) weeks, \(streak.thisWeekCount) of \(streak.goalPerWeek) workouts this week. Tap to change goal.")
                }
                HStack {
                    StatColumn(label: "Workouts", value: "\(week.workoutCount)")
                    StatColumn(label: "Time", value: Fmt.durationShort(week.durationSeconds))
                    StatColumn(label: "Volume", value: Fmt.volume(week.volume))
                    StatColumn(label: "Sets", value: Fmt.sets(week.sets))
                }
            }
        }
    }

    // MARK: - Welcome back (F10)

    @AppStorage("welcomeBackPendingGapDays") private var welcomeBackGapDays = 0

    private var trainedToday: Bool {
        workouts.contains { $0.endedAt != nil && $0.deletedAt == nil && Calendar.current.isDateInToday($0.startedAt) }
    }

    /// Re-entry after a 7+ day lapse: most lapsed users DO come back — the
    /// mistake is treating their return like a fresh start or shaming the
    /// gap. One card: acknowledge, offer a deliberately lighter first
    /// session (coach's reduce-volume dose), get out of the way.
    private var welcomeBackCard: some View {
        Card(fill: theme.accentSoft) {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Welcome back")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text("It's been \(welcomeBackGapDays) days. A lighter first session is the fastest way back.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.sm) {
                    if let suggestion,
                       let effective = CoachAdjustments.effectivePlan(
                           daily: CoachAdjustments.plan(for: .reduceVolume),
                           weeklyDeloadActive: weeklyDeloadActive
                       ) {
                        PrimaryButton(title: "Ease back in", systemImage: "figure.walk") {
                            welcomeBackGapDays = 0
                            reviewRequest = CoachReviewRequest(plan: effective.plan, routine: suggestion.routine, sourceLabel: effective.sourceLabel)
                        }
                    }
                    SecondaryButton(title: "I've got this") {
                        welcomeBackGapDays = 0
                    }
                }
            }
        }
    }

    // MARK: - Morning check-in strip

    /// The check-in's output (reason chips) leads the hero card, so its input
    /// lives on the same screen: one row of tags, gone once answered. The full
    /// card with explanations stays on the Recovery screen.
    private var showsCheckinStrip: Bool { todayCheckinTags.isEmpty || checkinStripEngaged }

    private var morningCheckinStrip: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("How do you feel?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CheckinTags.all, id: \.id) { tag in
                        let on = todayCheckinTags.contains(tag.id)
                        Button {
                            checkinStripEngaged = true
                            toggleCheckinTag(tag.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tag.icon).font(.system(size: 11, weight: .semibold))
                                Text(tag.label).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(on ? .white : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(on ? theme.accent : theme.surfaceElevated))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("home-checkin-\(tag.id)")
                    }
                }
            }
        }
    }

    private func toggleCheckinTag(_ tag: String) {
        let model: DailyCheckinModel
        if let existing = todayCheckin {
            model = existing
        } else {
            model = DailyCheckinModel(userID: ForgeFitDemo.userID, date: Calendar.current.startOfDay(for: Date()))
            modelContext.insert(model)
        }
        var tags = model.tags
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        model.tags = tags
        model.updatedAt = Date()
        try? modelContext.save()
    }

    private func suggestionCard(_ routine: RoutineModel, reason: String) -> some View {
        let doseContext = targetRecoveryMemo("\(AnalyticsFingerprint.withHealth(workouts))|\(todayCheckinTags.joined(separator: ","))|\(routine.id)|\(routine.updatedAt.timeIntervalSince1970)") {
            RoutineDoseContext.make(
                routine: routine,
                workouts: workouts,
                exercises: exercises,
                recovery: recovery
            )
        }
        let globalCoachPlan = CoachAdjustments.plan(for: recovery.action)
        let localCoachPlan = recovery.action == .trainAsPlanned
            ? CoachAdjustments.localizedPlan(for: doseContext)
            : nil
        // A weekly deload (Coach's Corner) always wins outright over the
        // daily call — see `CoachAdjustments.effectivePlan` — so the
        // "lighter localized version" framing only applies when nothing
        // weekly is overriding it.
        let effective = CoachAdjustments.effectivePlan(daily: globalCoachPlan ?? localCoachPlan, weeklyDeloadActive: weeklyDeloadActive)
        let coachPlan = effective?.plan
        let isLocalizedCoachPlan = !weeklyDeloadActive && globalCoachPlan == nil && localCoachPlan != nil
        // This is THE answer to "what should I do today" — the one card on
        // Home that should visually outrank everything else, so its Start
        // button is a full-width PrimaryButton, not a small corner capsule.
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Up next")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .textCase(.uppercase)
                    Text(routine.name)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(reason)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    // No readiness action line here: the RecoveryHeroCard above
                    // already makes today's call, and per-muscle state lives in
                    // Recovery → Per muscle. This card answers one question —
                    // "what's next" — and the coach button below carries any
                    // adjustment.
                }

                // Always "Start" — the coach's modified dose lives entirely
                // in the button below, so this one never needs to say
                // anything other than what it does.
                PrimaryButton(title: "Start", systemImage: "play.fill") {
                    appState.requestStart {
                        _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
                        appState.showingLogger = true
                    }
                }
                .accessibilityIdentifier("start-suggested-routine-\(routine.name)")

                // Advice→action, review-first: today's dose is fully
                // editable before anything starts (Coach's Corner review).
                if let coachPlan, let effective {
                    Button {
                        reviewRequest = CoachReviewRequest(plan: coachPlan, routine: routine, sourceLabel: effective.sourceLabel)
                    } label: {
                        HStack(spacing: Space.sm) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .bold))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(isLocalizedCoachPlan ? "Review lighter \(doseContext.affectedMuscleNames) version" : "Review coach's version")
                                    .font(.system(size: 14, weight: .bold))
                                Text("\(effective.sourceLabel) · \(coachPlan.summary) · routine unchanged")
                                    .font(.system(size: 11, weight: .medium))
                                    .opacity(0.85)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(recovery.action.tint(in: theme))
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(recovery.action.tint(in: theme).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("review-coach-version-\(routine.name)")
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var quickStart: some View {
        VStack(spacing: Space.md) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Space.md) {
                    // Fixed leading tile, not part of the customizable/
                    // reorderable quick-start actions (it's a fundamental
                    // capability, not a preference) — folded in here instead
                    // of its own full-width button so it stops competing
                    // with the "Up next" suggestion's Start button above.
                    QuickStartTile(
                        title: "Empty",
                        systemImage: "square.and.pencil",
                        accessibilityIdentifier: "start-empty-workout",
                        isEditing: false,
                        isDragging: false,
                        onTap: {
                            appState.requestStart {
                                _ = WorkoutFactory.startEmpty(in: modelContext)
                                appState.showingLogger = true
                            }
                        },
                        onLongPress: {},
                        onRemove: {}
                    )

                    ForEach(quickStartActions) { action in
                        QuickStartTile(
                            title: title(for: action),
                            systemImage: systemImage(for: action),
                            accessibilityIdentifier: accessibilityIdentifier(for: action),
                            isEditing: quickStartEditing,
                            isDragging: draggedQuickStartAction == action,
                            onTap: { start(action) },
                            onLongPress: { withAnimation(.spring(duration: 0.28)) { quickStartEditing = true } },
                            onRemove: { removeQuickStartAction(action) }
                        )
                        .onDrag {
                            withAnimation(.spring(duration: 0.28)) { quickStartEditing = true }
                            draggedQuickStartAction = action
                            return NSItemProvider(object: action.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: QuickStartReorderDropDelegate(
                                target: action,
                                draggedAction: $draggedQuickStartAction,
                                moveAction: reorderQuickStartAction
                            )
                        )
                    }

                    Button {
                        showQuickStartAdd = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 19, weight: .bold))
                            Text("Add")
                                .font(.tag)
                        }
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 104, height: 76)
                        .background(theme.surface.opacity(0.34))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .stroke(style: StrokeStyle(lineWidth: 1.3, dash: [6, 5]))
                                .foregroundStyle(theme.separator)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            if quickStartEditing {
                Button("Done") {
                    dismissQuickStartEdit()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var quickStartActions: [HomeQuickStartAction] {
        let decoded = HomeQuickStartAction.decodeList(from: quickStartActionsJSON)
        let actions = decoded.isEmpty ? HomeQuickStartAction.defaults : decoded
        return actions.filter { action in
            switch action.kind {
            case .cardio: true
            case .routine(let id): routines.contains { $0.id == id && $0.deletedAt == nil }
            case .yoga(let slug): YogaFlowCatalog.flow(forSlug: slug) != nil
            }
        }
    }

    private func writeQuickStartActions(_ actions: [HomeQuickStartAction]) {
        quickStartActionsJSON = HomeQuickStartAction.encodeList(actions)
    }

    private func dismissQuickStartEdit() {
        guard quickStartEditing else { return }
        draggedQuickStartAction = nil
        withAnimation(.spring(duration: 0.24)) { quickStartEditing = false }
    }

    private func addQuickStartAction(_ action: HomeQuickStartAction) {
        var actions = quickStartActions
        guard !actions.contains(action) else { return }
        actions.append(action)
        writeQuickStartActions(actions)
    }

    private func removeQuickStartAction(_ action: HomeQuickStartAction) {
        let actions = quickStartActions.filter { $0.id != action.id }
        writeQuickStartActions(actions)
    }

    private func reorderQuickStartAction(_ dragged: HomeQuickStartAction, over target: HomeQuickStartAction) {
        var actions = quickStartActions
        guard let from = actions.firstIndex(of: dragged),
              let to = actions.firstIndex(of: target),
              from != to else { return }
        withAnimation(.spring(duration: 0.24)) {
            actions.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            writeQuickStartActions(actions)
        }
    }

    private func start(_ action: HomeQuickStartAction) {
        guard !quickStartEditing else { return }
        appState.requestStart {
            switch action.kind {
            case .cardio(let modality):
                _ = WorkoutFactory.startCardio(modality, exercises: exercises, in: modelContext)
            case .routine(let id):
                guard let routine = routines.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
                _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
            case .yoga(let slug):
                guard let seed = YogaFlowCatalog.flow(forSlug: slug) else { return }
                _ = WorkoutFactory.startYoga(
                    flow: YogaFlowCatalog.plan(for: seed),
                    named: seed.name,
                    exercises: exercises,
                    in: modelContext
                )
            }
            appState.showingLogger = true
        }
    }

    private func title(for action: HomeQuickStartAction) -> String {
        switch action.kind {
        case .cardio(let modality): modality.title
        case .routine(let id): routines.first { $0.id == id }?.name ?? "Routine"
        case .yoga(let slug): YogaFlowCatalog.flow(forSlug: slug)?.name ?? "Yoga"
        }
    }

    private func systemImage(for action: HomeQuickStartAction) -> String {
        switch action.kind {
        case .cardio(let modality): modality.systemImage
        case .routine: "list.bullet.clipboard"
        case .yoga(let slug): YogaFlowCatalog.flow(forSlug: slug)?.style.systemImage ?? "figure.yoga"
        }
    }

    private func accessibilityIdentifier(for action: HomeQuickStartAction) -> String {
        switch action.kind {
        case .cardio(let modality): "start-cardio-\(modality.rawValue)"
        case .routine(let id): "start-home-routine-\(id.uuidString)"
        case .yoga(let slug): "start-yoga-\(slug)"
        }
    }

    private func createRoutine() -> RoutineModel {
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "New Routine", position: routines.count)
        modelContext.insert(routine)
        try? modelContext.save()
        addQuickStartAction(.routine(routine.id))
        return routine
    }
}

enum HomeRoute: Hashable { case recovery }

private struct HomeQuickStartAction: Codable, Hashable, Identifiable {
    enum Kind: Hashable {
        case cardio(CardioModality)
        case routine(UUID)
        /// A built-in guided yoga class, keyed by its catalog flow slug.
        case yoga(String)
    }

    var kind: Kind

    var id: String {
        switch kind {
        case .cardio(let modality): "cardio:\(modality.rawValue)"
        case .routine(let id): "routine:\(id.uuidString)"
        case .yoga(let slug): "yoga:\(slug)"
        }
    }

    static let defaults: [HomeQuickStartAction] = [.cardio(.run), .cardio(.cycle), .cardio(.row), .cardio(.walk)]

    static func cardio(_ modality: CardioModality) -> HomeQuickStartAction {
        HomeQuickStartAction(kind: .cardio(modality))
    }

    static func routine(_ id: UUID) -> HomeQuickStartAction {
        HomeQuickStartAction(kind: .routine(id))
    }

    static func yoga(_ slug: String) -> HomeQuickStartAction {
        HomeQuickStartAction(kind: .yoga(slug))
    }

    init(kind: Kind) {
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let modalityRaw = raw.removingPrefix("cardio:"),
           let modality = CardioModality(rawValue: modalityRaw) {
            kind = .cardio(modality)
        } else if let idRaw = raw.removingPrefix("routine:"),
                  let id = UUID(uuidString: idRaw) {
            kind = .routine(id)
        } else if let slug = raw.removingPrefix("yoga:") {
            kind = .yoga(slug)
        } else {
            kind = .cardio(.run)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    static func decodeList(from json: String) -> [HomeQuickStartAction] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HomeQuickStartAction].self, from: data) else { return [] }
        return decoded
    }

    static func encodeList(_ actions: [HomeQuickStartAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}

private extension View {
    func dismissesQuickStartEdit(isEditing: Bool, dismiss: @escaping () -> Void) -> some View {
        overlay {
            if isEditing {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismiss)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct QuickStartTile: View {
    @Environment(\.theme) private var theme
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let isEditing: Bool
    let isDragging: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onRemove: () -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isDragging)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = isDragging ? sin(t * 7.0) * 0.9 : (isEditing ? -0.45 : 0)

            ZStack(alignment: .topTrailing) {
                GlassTile(tint: theme.secondaryAccent.opacity(0.12), verticalPadding: Space.md, horizontalPadding: Space.sm) {
                    VStack(spacing: 6) {
                        Image(systemName: systemImage).font(.system(size: 18, weight: .semibold))
                        // Two-word titles ("Treadmill Walk") wrap to a second
                        // line instead of spilling past the fixed-width tile.
                        // `reservesSpace` keeps every tile the same height so the
                        // row stays aligned whether the label is one line or two;
                        // `minimumScaleFactor` is a last-resort guard for an
                        // unbreakable long word.
                        Text(title)
                            .font(.tag)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity)
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .onTapGesture { onTap() }
                .onLongPressGesture(minimumDuration: 0.35) { onLongPress() }
                // Without an explicit accessibility boundary here, the
                // `.accessibilityIdentifier` applied below (on the outer view)
                // has no single element of its own to bind to and lands on an
                // arbitrary descendant leaf — in practice the tiny SF Symbol
                // Image instead of the full tappable tile, which made this
                // control unreliably hittable for UI testing (and for
                // VoiceOver/Switch Control, since a custom `.onTapGesture`
                // isn't announced as a button on its own).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isButton)

                if isEditing {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 24, height: 24)
                            .background(theme.danger)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("Remove \(title)")
                }
            }
            .rotationEffect(.degrees(angle))
        }
        .frame(width: 104)
        .scaleEffect(isDragging ? 1.03 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.28 : 0), radius: isDragging ? 12 : 0, y: isDragging ? 6 : 0)
        .animation(.easeInOut(duration: 0.18), value: isEditing)
        .animation(.easeInOut(duration: 0.16), value: isDragging)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct QuickStartReorderDropDelegate: DropDelegate {
    let target: HomeQuickStartAction
    @Binding var draggedAction: HomeQuickStartAction?
    let moveAction: (HomeQuickStartAction, HomeQuickStartAction) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedAction, draggedAction != target else { return }
        moveAction(draggedAction, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedAction = nil
        return true
    }
}

private struct QuickStartAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let routines: [RoutineModel]
    let configuredActions: [HomeQuickStartAction]
    let onAdd: (HomeQuickStartAction) -> Void
    let onCreateRoutine: () -> Void

    private var configuredIDs: Set<String> {
        Set(configuredActions.map(\.id))
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    SectionHeader("Presets")
                    VStack(spacing: Space.sm) {
                        presetRow(.run)
                        presetRow(.cycle)
                        presetRow(.row)
                        presetRow(.walk)
                    }

                    SectionHeader("Guided Yoga")
                    VStack(spacing: Space.sm) {
                        ForEach(YogaFlowCatalog.load(), id: \.slug) { seed in
                            let plan = YogaFlowCatalog.plan(for: seed)
                            addRow(
                                title: seed.name,
                                subtitle: "\(seed.style.title) · \(Fmt.durationShort(plan.totalSeconds)) · \(plan.steps.count) poses",
                                systemImage: seed.style.systemImage,
                                isAdded: configuredIDs.contains(HomeQuickStartAction.yoga(seed.slug).id)
                            ) {
                                onAdd(.yoga(seed.slug))
                            }
                        }
                    }

                    SectionHeader("Your Routines")
                    VStack(spacing: Space.sm) {
                        if routines.isEmpty {
                            EmptyStateCard(
                                title: "No routines yet",
                                message: "Create one here and it will be added to Home.",
                                systemImage: "list.bullet.clipboard"
                            )
                        } else {
                            ForEach(routines) { routine in
                                addRow(
                                    title: routine.name,
                                    subtitle: "\(routine.exercises.count) exercises",
                                    systemImage: "list.bullet.clipboard",
                                    isAdded: configuredIDs.contains(HomeQuickStartAction.routine(routine.id).id)
                                ) {
                                    onAdd(.routine(routine.id))
                                }
                            }
                        }
                    }

                    SecondaryButton(title: "Create New Routine", systemImage: "plus") {
                        onCreateRoutine()
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xl)
            }
            .background(theme.background)
            .navigationTitle("Add Quick Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                }
            }
        }
    }

    private func presetRow(_ modality: CardioModality) -> some View {
        addRow(
            title: modality.title,
            subtitle: "Quick cardio workout",
            systemImage: modality.systemImage,
            isAdded: configuredIDs.contains(HomeQuickStartAction.cardio(modality).id)
        ) {
            onAdd(.cardio(modality))
        }
    }

    private func addRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isAdded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.surfaceElevated)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(isAdded ? theme.success : theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isAdded)
    }
}

/// The compact readiness card shown on Home.
struct RecoveryHeroCard: View {
    @Environment(\.theme) private var theme
    let report: RecoveryEngine.Report

    /// Below this confidence the engine is still learning the user's
    /// baselines — showing a precise 0–100 there is false authority, so the
    /// card switches to an explicit building state instead.
    private var isBuilding: Bool { report.confidence < 0.75 }

    var body: some View {
        Card {
            VStack(spacing: Space.md) {
                heroRow
                // Exertion vs your own norm (acute:chronic) — promoted from
                // the recovery screen's Advanced disclosure so the week's
                // dose is visible where training decisions happen.
                if !isBuilding, let acwr = report.acwr {
                    exertionGauge(acwr)
                }
            }
        }
    }

    private var heroRow: some View {
            HStack(spacing: Space.lg) {
                ZStack {
                    ProgressRing(
                        progress: isBuilding ? max(0.05, report.confidence) : report.displayScore,
                        lineWidth: 10,
                        color: isBuilding ? theme.textTertiary : theme.readinessColor(report.displayScore)
                    )
                    .frame(width: 76, height: 76)
                    if isBuilding {
                        Image(systemName: "hourglass")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        VStack(spacing: 0) {
                            Text("\(Int(report.displayScore * 100))")
                                .font(.system(size: 24, weight: .bold)).foregroundStyle(theme.textPrimary)
                            Text("ready").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if isBuilding {
                        Text("Building your baseline")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textSecondary)
                        Text("Your readiness score unlocks after a few more nights of data.")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        HStack(spacing: 6) {
                            Text("Recovery").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                            Image(systemName: report.action.systemImage)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(report.action.tint(in: theme))
                            Text(report.action.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(report.action.tint(in: theme))
                        }
                        Text(report.recommendation)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        ForEach(report.reasonChips.prefix(2)) { chip in
                            Tag(text: chip.text, color: chip.tone.foreground(in: theme), background: chip.tone.background(in: theme))
                        }
                    }
                }
                Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
            }
    }

    /// This week's training dose against the user's own 4-week norm: filled
    /// to acwr/2 so 1.0 (exactly your norm) sits at the center tick. Framed
    /// as a dose gauge, not an injury predictor.
    private func exertionGauge(_ acwr: Double) -> some View {
        let tint: Color = acwr < 0.8 ? theme.textTertiary
            : acwr <= 1.3 ? theme.success
            : acwr <= 1.5 ? theme.recoveryMid
            : theme.danger
        let label = acwr < 0.8 ? "Light week — room to push"
            : acwr <= 1.3 ? "On target"
            : acwr <= 1.5 ? "Elevated"
            : "Spiking"
        return VStack(spacing: 4) {
            HStack {
                Text("This week vs your norm")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceElevated)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(6, geo.size.width * min(acwr, 2) / 2))
                    // Center tick = 1.0, exactly your 4-week norm.
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.textTertiary)
                        .frame(width: 2, height: 10)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("This week's training load is \(Int((acwr * 100).rounded())) percent of your norm — \(label)")
    }
}

/// A workout row used across Home / Profile feeds.
struct WorkoutFeedRow: View {
    @Environment(\.theme) private var theme
    let workout: WorkoutModel
    let analytics: TrainingAnalytics

    var body: some View {
        let s = analytics.summary(for: workout)
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Image(systemName: s.isCardio ? "figure.run" : "dumbbell.fill")
                        .foregroundStyle(theme.accent)
                        .frame(width: 34, height: 34)
                        .background(theme.surfaceElevated).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workout.title ?? "Workout").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text(workout.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(theme.textTertiary)
                }
                HStack {
                    StatColumn(label: "Time", value: Fmt.durationShort(s.durationSeconds))
                    if s.isCardio {
                        StatColumn(label: "Avg HR", value: Fmt.bpm(s.avgHR))
                    } else {
                        StatColumn(label: "Volume", value: Fmt.volume(s.volume))
                        StatColumn(label: "Sets", value: Fmt.sets(s.sets))
                    }
                }
            }
        }
        .accessibilityIdentifier("home-workout-\(workout.title ?? "Workout")")
    }
}
