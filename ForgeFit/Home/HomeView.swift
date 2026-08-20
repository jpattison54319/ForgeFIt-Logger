import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The "Today" landing screen. Leads with a recovery/readiness read (the
/// signal that most reduces "what should I do today?" cognitive load), then
/// this week's training at a glance, quick starts, and recent activity.
struct HomeView: View {
    @Environment(\.tabRootRequestID) private var tabRootRequestID
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var healthMetrics = HealthMetricsStore.shared
    @State private var performanceGate = LiveWorkoutPerformanceGate.shared
    @State private var navigationPath = NavigationPath()
    @State private var showSettings = false
    // Coach surfaces remain implemented and testable, but are intentionally
    // dormant while the Home header uses its more useful calendar shortcut.
    @State private var showCoach = false
    @State private var showCoachChat = false
    @State private var showExploreLibrary = false
    @State private var quickStartEditing = false
    @State private var draggedQuickStartAction: HomeQuickStartAction?
    @State private var showQuickStartAdd = false
    @State private var editingRoutine: RoutineModel?
    @State private var presentedWrappedReport: WrappedReportModel?
    @State private var reviewRequest: CoachReviewRequest?
    @State private var showingExperiments = false
    @State private var loggingExperiment: ExperimentModel?

    /// New (unopened) Wrapped reports — drives the "Report Available" card,
    /// which disappears the moment the story is opened (viewedAt set).
    @Query(
        filter: #Predicate<WrappedReportModel> { $0.viewedAt == nil && $0.deletedAt == nil },
        sort: \WrappedReportModel.generatedAt, order: .reverse
    ) private var unviewedWrappedReports: [WrappedReportModel]
    @Query private var checkins: [DailyCheckinModel]
    @Query(sort: \ExperimentModel.startedAt, order: .reverse)
    private var experiments: [ExperimentModel]
    @Query(sort: \ExperimentTrackerModel.position)
    private var experimentTrackers: [ExperimentTrackerModel]
    @Query(sort: \ExperimentEntryModel.observedAt, order: .reverse)
    private var experimentEntries: [ExperimentEntryModel]
    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var microcycleTrackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var microcycleWindows: [MicrocycleWindowModel]
    @Query(sort: \RestDayModel.date, order: .reverse)
    private var restDays: [RestDayModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse)
    private var alternations: [RoutineAlternationModel]
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
    @AppStorage("profileDisplayName") private var displayName = "Athlete"
    @AppStorage(HomeQuickStartAction.preferenceKey) private var quickStartActionsJSON = ""
    @State private var healthAuthorization = HealthAuthorizationStore.shared

    private var connectingHealth: Bool { healthAuthorization.state.isRequesting }
    private var healthConnected: Bool { healthAuthorization.state.isConnected }
    // Keeps the check-in strip visible while the user is mid-selection —
    // without it the row would vanish on the first tap. Resets when Home
    // reloads, so an answered check-in stays collapsed on later visits.
    @State private var checkinStripEngaged = false
    // Optimistic overlay for the mood strip: the tap updates this instantly so
    // the capsule fills on touch, decoupled from the debounced model write and
    // the RecoveryEngine recompute (which stays keyed on the persisted tags, so
    // it runs once per commit rather than once per tap). Cleared only when the
    // @Query reflects the write, to avoid a one-frame flicker to the old value.
    @State private var checkinDraft: [String]?
    @State private var checkinCommitTask: Task<Void, Never>?
    @State private var pendingCheckinID = UUID()
    @State private var dashboardAnalytics: HomeAnalyticsResult?
    @State private var dashboardAnalyticsKey: String?
    @State private var dashboardIsComputing = false
    @State private var dashboardMaintenanceTask: Task<Void, Never>?
    @State private var targetRecoveryMemo = Memo<String, RoutineDoseContext>()
    @State private var weekMemo = Memo<Int, HomeWeekMetrics.Summary>()

    private var analytics: TrainingAnalytics { TrainingAnalytics(workouts: workouts, exercises: exercises) }
    private var todayCheckin: DailyCheckinModel? {
        checkins
            .filter { $0.deletedAt == nil && Calendar.current.isDate($0.date, inSameDayAs: Date()) }
            .max { $0.updatedAt < $1.updatedAt }
    }
    private var todayCheckinTags: [String] { todayCheckin?.tags ?? [] }
    /// What the mood strip draws: the optimistic draft while a tap is pending,
    /// otherwise the persisted tags. Only the chip fill reads this — the memo
    /// keys deliberately stay on `todayCheckinTags` so the engine recompute
    /// waits for the debounced commit instead of firing on every tap.
    private var effectiveCheckinTags: [String] { checkinDraft ?? todayCheckinTags }

    private static let loadingRecovery = RecoveryEngine(workouts: []).report()
    private static let loadingStrain = DailyStrainEngine(
        workouts: [],
        activityMetrics: [],
        dailyReadiness: nil,
        trendRecovery: nil
    ).report()

    private var analyticsRequestKey: String {
        "\(AnalyticsFingerprint.withHealth(workouts))|"
            + "\(healthMetrics.lastRefreshed?.timeIntervalSinceReferenceDate ?? 0)|"
            + "\(healthMetrics.metricsRevision)|"
            + todayCheckinTags.joined(separator: ",")
    }

    private var pausesForLiveWorkout: Bool {
        performanceGate.isLiveWorkoutActive
            || workouts.contains { $0.endedAt == nil && $0.deletedAt == nil }
    }

    private var analyticsTaskKey: String {
        "\(analyticsRequestKey)|live:\(pausesForLiveWorkout)"
    }

    private var todayAnalytics: HomeAnalyticsResult? {
        guard let dashboardAnalytics,
              Calendar.current.isDate(dashboardAnalytics.generatedAt, inSameDayAs: Date()) else {
            return nil
        }
        return dashboardAnalytics
    }

    private var recovery: RecoveryEngine.Report {
        todayAnalytics?.recovery ?? Self.loadingRecovery
    }

    private var dailyStrain: DailyStrainEngine.Report {
        todayAnalytics?.strain ?? Self.loadingStrain
    }

    private var latestHealthMetric: RecoveryEngine.DailyHealthMetric? {
        todayAnalytics?.latestHealthMetric
    }

    private var healthAssessment: HealthRangeAssessment {
        todayAnalytics?.healthAssessment ?? HealthRangeAssessment(readings: [])
    }
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation = switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? salutation : "\(salutation), \(name)"
    }

    private var recentCompleted: [WorkoutModel] {
        workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }.prefix(4).map { $0 }
    }

    private var activeExperiment: ExperimentModel? {
        experiments.first {
            $0.deletedAt == nil && $0.isActive && $0.plannedEndAt > .now
        }
    }

    private var activeMicrocycle: MicrocycleTrackingModel? {
        MicrocycleTrackingService.activeTracking(microcycleTrackings)
    }

    private var activeMicrocycleWindow: MicrocycleWindowModel? {
        guard let activeMicrocycle else { return nil }
        return MicrocycleTrackingService.currentWindow(
            for: activeMicrocycle,
            windows: microcycleWindows
        )
    }

    private func trackers(for experiment: ExperimentModel) -> [ExperimentTrackerModel] {
        experimentTrackers.filter {
            $0.experimentID == experiment.id
                && $0.deletedAt == nil
                && $0.archivedAt == nil
        }
    }

    private func entries(for experiment: ExperimentModel) -> [ExperimentEntryModel] {
        experimentEntries.filter {
            $0.experimentID == experiment.id && $0.deletedAt == nil
        }
    }

    private var hasReadinessSignal: Bool {
        workouts.contains { $0.endedAt != nil && $0.deletedAt == nil }
            || !healthMetrics.metrics.isEmpty
            || todayDashboardCache != nil
    }

    /// Today's cached Home render, if this day already produced one. Strictly
    /// keyed to the current calendar day. Right after midnight there is no
    /// cache: a connected Health dashboard shows its loader, while a
    /// disconnected Home keeps that empty dashboard collapsed. Yesterday's
    /// values must never stand in for either state.
    private var todayDashboardCache: (RecoverySnapshot, HomeDashboardCache)? {
        guard let snapshot = RecoverySnapshotStore.shared.snapshot(for: Date()),
              let cache = snapshot.dashboard else { return nil }
        return (snapshot, cache)
    }

    /// Live once this launch's HealthKit refresh has landed; otherwise today's
    /// cached render when one exists, otherwise the loading state.
    private var dashboardSource: HomeDashboardSource {
        // Keep a same-day result visible while its replacement computes. A
        // refresh must never blank usable numbers or make the scroll view wait.
        if todayAnalytics != nil { return .live }
        if let (snapshot, cache) = todayDashboardCache { return .cached(snapshot, cache) }
        return .loading
    }

    private var dashboardIsRefreshing: Bool {
        healthMetrics.isRefreshing || dashboardIsComputing
    }

    /// The dashboard as currently rendered, for the same-day cache. Callers
    /// must hold the live-refresh gate (see the recording `.task`): before the
    /// first refresh lands the engines run on empty health data, and caching
    /// that render would clobber the morning's real one with placeholders.
    private func liveDashboardCache(result: HomeAnalyticsResult) -> HomeDashboardCache {
        let report = result.recovery
        let sleep = result.latestHealthMetric
        let health = result.healthAssessment
        return HomeDashboardCache(
            recoveryDisplayScore: report.displayScore,
            readinessIsDaily: report.displayScore.map {
                report.recovery.daily.state.value != nil
            },
            baselineReady: report.baselineReady,
            actionRaw: report.action.rawValue,
            recommendation: report.recommendation,
            reasonTexts: report.reasonChips.prefix(2).map(\.text),
            sleepValue: SleepMetricPresentation.value(for: sleep),
            sleepCaption: SleepMetricPresentation.caption(for: sleep),
            sleepProgress: SleepMetricPresentation.progress(for: sleep),
            sleepLooksPartial: sleep?.sleepLikelyPartial == true && sleep?.sleepUserCorrected == false,
            healthHeadline: health.headline,
            healthCaption: health.caption,
            healthEvaluatedCount: health.evaluatedCount,
            healthOutsideRangeCount: health.outsideRangeCount,
            vitals: .make(assessment: health),
            preWorkoutAdjustment: report.preWorkoutAdjustment,
            readinessMethodID: report.displayScore == nil ? nil : report.recovery.daily.methodID,
            readinessCoverage: report.displayScore == nil ? nil : report.dataCoverage)
    }

    private func refreshDashboardAnalytics(for key: String) async {
        // Before the first Health query, a workouts-only strain value can look
        // real and overwrite today's valid cache. Keep the same launch gate,
        // but do no score work on MainActor while waiting.
        guard healthMetrics.lastRefreshed != nil,
              !pausesForLiveWorkout else { return }

        dashboardMaintenanceTask?.cancel()
        dashboardMaintenanceTask = nil
        dashboardIsComputing = true
        defer {
            if key == analyticsRequestKey {
                dashboardIsComputing = false
            }
        }

        let worker = HomeAnalyticsWorker(modelContainer: modelContext.container)
        let input = HomeAnalyticsInput(
            healthMetrics: healthMetrics.metrics,
            supplementalSignals: healthMetrics.extraSignals,
            activityMetrics: healthMetrics.activityMetrics,
            todayCheckinTags: todayCheckinTags,
            now: Date()
        )

        do {
            let result = try await worker.calculateCurrent(input)
            guard !Task.isCancelled,
                  !pausesForLiveWorkout,
                  key == analyticsRequestKey else { return }

            dashboardAnalytics = result
            dashboardAnalyticsKey = key

            // Store the acute and trend channels separately; displayScore may
            // fall back to trend and must never blur that distinction.
            RecoverySnapshotStore.shared.recordToday(
                daily: result.recovery.recovery.daily.state.value,
                trend: result.recovery.recovery.systemic.state.value,
                strain: result.strain.score,
                strainTarget: result.strain.targetRange,
                dashboard: liveDashboardCache(result: result)
            )
            ReadinessSurfacePublisher.publishFresh(result.recovery)
            WatchLink.shared.publishState()
            scheduleDashboardMaintenance(worker: worker, input: input)
        } catch is CancellationError {
            // A newer Health/check-in/workout fingerprint owns the next result.
        } catch {
            // Keep the last same-day result or persisted dashboard visible.
        }
    }

    private func scheduleDashboardMaintenance(
        worker: HomeAnalyticsWorker,
        input: HomeAnalyticsInput
    ) {
        guard !pausesForLiveWorkout else { return }
        let snapshotStore = RecoverySnapshotStore.shared
        let backfillEligible = workouts.contains {
            $0.endedAt != nil && $0.deletedAt == nil
        } || !input.healthMetrics.isEmpty || !input.activityMetrics.isEmpty
        let shouldBackfill = snapshotStore.needsBackfill && backfillEligible
        let bodyweight = healthMetrics.bodyweightSeries.map {
            BodyweightSample(date: $0.date, value: $0.value)
        }
        guard shouldBackfill || !bodyweight.isEmpty else { return }

        dashboardMaintenanceTask = Task(priority: .utility) { @MainActor in
            do {
                if shouldBackfill {
                    let snapshots = try await worker.calculateBackfill(input)
                    guard !Task.isCancelled, !pausesForLiveWorkout else { return }
                    snapshotStore.mergeBackfill(snapshots)
                }
                if !bodyweight.isEmpty {
                    try await worker.fillMissingBodyweight(from: bodyweight)
                }
            } catch {
                // Maintenance is retryable on the next refresh. Visible scores
                // have already published and remain fully interactive.
            }
            guard !Task.isCancelled, !pausesForLiveWorkout else { return }
            dashboardMaintenanceTask = nil
        }
    }

    // MARK: - Smart next-workout suggestion

    /// A mesocycle can contain several microcycles. The active microcycle is
    /// most specific, then Home falls back to the broader active mesocycle.
    @AppStorage(CyclePreferenceMigration.activeMesocycleKey) private var activeMesocycleFolderRaw = ""
    @AppStorage(CyclePreferenceMigration.activeMicrocycleKey) private var activeMicrocycleFolderRaw = ""
    @Query private var allFolders: [RoutineFolderModel]

    /// The active mesocycle plus its microcycle children.
    private func mesocycleSubtree(rootID: UUID) -> Set<UUID> {
        let live = allFolders.filter { $0.deletedAt == nil && $0.archivedAt == nil }
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
    /// `NextRoutineSuggestion` for the drilldown logic (microcycle → mesocycle
    /// → best guess).
    private var suggestion: (routine: RoutineModel, reason: String, alternatingWith: String?)? {
        guard let result = NextRoutineSuggestion.suggest(
            routines: routines,
            completedWorkouts: workouts,
            alternations: alternations,
            activeMicrocycleFolderID: UUID(uuidString: activeMicrocycleFolderRaw),
            activeMesocycleFolderID: UUID(uuidString: activeMesocycleFolderRaw),
            mesocycleSubtree: mesocycleSubtree(rootID:)
        ), let routine = routines.first(where: { $0.id == result.routineID }) else { return nil }
        return (routine, result.reason, result.alternatingWith)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScreenScaffold(
                greeting,
                subtitle: Date().formatted(.dateTime.weekday(.wide).month().day()),
                titleFont: .system(.title, design: .default, weight: .bold),
                trailing: {
                    CircleIconNavigationLink(systemImage: "calendar", label: "Open calendar", value: HomeRoute.calendar)
                        .accessibilityIdentifier("home-calendar")
                }
            ) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    // Gated with the coach dose review it exists to launch:
                    // the card's whole content is "a lighter first session is
                    // the fastest way back" plus a button that starts one. With
                    // no modified dose to offer there is nothing left to say
                    // that Up next doesn't already say.
                    if FeatureFlags.coachDoseReview, welcomeBackGapDays >= 7, !trainedToday {
                        welcomeBackCard
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    // Without Health there is no recovery surface to show, only
                    // four tiles explaining their own emptiness. In that state
                    // training leads and the dashboard collapses to one row
                    // that says what's missing and offers to fix it.
                    if !showsRecoveryDashboard {
                        trainingSurface
                        connectHealthPrompt
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    } else {
                        if FeatureFlags.homeDailyRecommendation {
                            if hasReadinessSignal {
                                RecoveryHeroCard(
                                    report: recovery,
                                    source: dashboardSource,
                                    isRefreshing: dashboardIsRefreshing
                                )
                                .accessibilityIdentifier("home-guidance")
                                .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                            } else {
                                readinessEmptyState
                                    .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                            }
                        }

                        HomeMetricGrid(
                            recovery: recovery,
                            strain: dailyStrain,
                            sleep: latestHealthMetric,
                            health: healthAssessment,
                            source: dashboardSource,
                            isRefreshing: dashboardIsRefreshing
                        )
                        .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)

                        // A night flagged as partial-wear capture: offer a
                        // one-tap correction so a data gap never reads as
                        // lost sleep.
                        if let sleepAlert = todayAnalytics?.sleepIntegrityAlert {
                            SleepIntegrityCard(alert: sleepAlert)
                                .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                        }
                    }

                    if showsCheckinStrip {
                        morningCheckinStrip
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    if let activeMicrocycle,
                       activeMicrocycle.showsOnHome,
                       activeMicrocycle.needsAttention {
                        microcycleNeedsAttentionCard(activeMicrocycle)
                        .dismissesQuickStartEdit(
                            isEditing: quickStartEditing,
                            dismiss: dismissQuickStartEdit
                        )
                    } else if let activeMicrocycle,
                              activeMicrocycle.showsOnHome,
                              let activeMicrocycleWindow {
                        ActiveMicrocycleHomeCard(
                            tracking: activeMicrocycle,
                            window: activeMicrocycleWindow,
                            progress: MicrocycleTrackingService.progress(
                                for: activeMicrocycleWindow,
                                windows: microcycleWindows,
                                workouts: workouts
                            ),
                            workouts: workouts,
                            restDays: RestDayService.live(restDays),
                            windows: microcycleWindows,
                            exercises: exercises,
                            detailsDestination: HomeRoute.microcycle(activeMicrocycle.id),
                            onRemoveFromHome: {
                                updateMicrocyclePresentation(
                                    activeMicrocycle,
                                    showsOnHome: false
                                )
                            }
                        )
                        .dismissesQuickStartEdit(
                            isEditing: quickStartEditing,
                            dismiss: dismissQuickStartEdit
                        )
                    }

                    if let activeExperiment {
                        ActiveExperimentHomeCard(
                            experiment: activeExperiment,
                            trackers: trackers(for: activeExperiment),
                            entries: entries(for: activeExperiment),
                            onLogUpdate: { loggingExperiment = activeExperiment },
                            onOpen: { showingExperiments = true }
                        )
                        .dismissesQuickStartEdit(
                            isEditing: quickStartEditing,
                            dismiss: dismissQuickStartEdit
                        )
                    }

                    weekCard
                        .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)

                    if let newReport = unviewedWrappedReports.first {
                        wrappedAvailableCard(newReport)
                            .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    }

                    if showsRecoveryDashboard {
                        trainingSurface
                    }

                    if !recentCompleted.isEmpty {
                        SectionHeader("Recent") {
                            NavigationLink(value: HomeRoute.history) {
                                HStack(spacing: Space.xs) {
                                    Text("See all")
                                    Image(systemName: "chevron.right")
                                }
                                .minimumTouchTarget()
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.accentForeground)
                            .buttonStyle(.plain)
                            .accessibilityLabel("See all workouts")
                            .accessibilityIdentifier("home-see-all-workouts")
                        }
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
                // Crossfades the suggestion ↔ explore-prompt swap (each carries
                // `.transition(.opacity)`); scoped by key so it only fires when
                // the branch actually flips.
                .animation(Motion.stateChange, value: suggestion == nil)
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
                case .sleep: SleepDetailView(metrics: healthMetrics.metrics)
                case .strain: StrainDetailView(report: dailyStrain)
                case .health: HealthDetailView(report: recovery, metrics: healthMetrics.metrics)
                case .calendar: WorkoutCalendarView(workouts: workouts, exercises: exercises)
                case .history: WorkoutHistoryView(workouts: workouts, exercises: exercises)
                case .microcycle(let trackingID):
                    MicrocycleDetailView(trackingID: trackingID)
                }
            }
            .navigationDestination(for: WorkoutModel.self) { workout in
                WorkoutDetailView(workout: workout, exercises: exercises, history: workouts)
            }
            .navigationDestination(item: $editingRoutine) { routine in
                RoutineEditorView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
            .navigationDestination(isPresented: $showingExperiments) {
                ExperimentsDestinationView(workouts: workouts, exercises: exercises)
            }
            .toolbar(.hidden, for: .navigationBar)
            // Pull down to re-query Apple Health and recompute readiness.
            .refreshable { await AppRefresh.run(in: modelContext) }
            // Health/SwiftData snapshots are captured quickly on MainActor;
            // every history-wide score pass then runs on HomeAnalyticsWorker's
            // detached context. SwiftUI receives only the finished projection.
            .task(id: analyticsTaskKey) {
                guard !pausesForLiveWorkout else {
                    dashboardMaintenanceTask?.cancel()
                    dashboardMaintenanceTask = nil
                    dashboardIsComputing = false
                    return
                }
                await refreshDashboardAnalytics(for: analyticsRequestKey)
            }
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
                    suggestion: suggestion.map { (routine: $0.routine, reason: $0.reason) }
                )
            }
            .sheet(isPresented: $showCoachChat) { coachChatSheet }
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
            .sheet(item: $loggingExperiment) { experiment in
                ExperimentLogUpdateSheet(
                    experiment: experiment,
                    trackers: trackers(for: experiment),
                    entries: entries(for: experiment)
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
                        createRoutine()
                    }
                )
            }
            // Screenshot/UI-test hook, same family as -initialTab (unset in
            // production).
            .onAppear {
                healthAuthorization.refresh()
                if UserDefaults.standard.bool(forKey: "openSettings") { showSettings = true }
                #if DEBUG
                // UI automation keeps exercising the dormant coach surfaces
                // without exposing a production Home entry point.
                if UserDefaults.standard.bool(forKey: "openCoachCorner") { showCoach = true }
                if UserDefaults.standard.bool(forKey: "openCoachChat") { showCoachChat = true }
                #endif
            }
            // Drop the optimistic overlay only once the persisted tags catch up,
            // so the mood capsules never flash back to the pre-commit state.
            .onChange(of: todayCheckinTags) { _, newTags in
                if checkinDraft == newTags { checkinDraft = nil }
            }
            // Never lose a pending check-in: flush before the app suspends or the
            // screen goes away (the 400 ms debounce may not have fired yet).
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { commitCheckinDraft() }
                // Granting or revoking access happens in Apple's Health app,
                // so the answer can only have changed while we were away.
                if phase == .active { healthAuthorization.refresh() }
            }
            .onDisappear { commitCheckinDraft() }
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
                        // A catalog program lands as one standalone microcycle
                        // folder containing its day routines.
                        let attempt = RoutineProgramImportAttempt(
                            program: program,
                            templates: templates,
                            in: modelContext
                        )
                        attempt.commit(into: modelContext) { _ in
                            showExploreLibrary = false
                        }
                    }
                )
            }
        }
        .onChange(of: tabRootRequestID) { navigationPath = NavigationPath() }
        .interactiveBackSwipeEnabled()
    }

    private var activeRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil && $0.archivedAt == nil && !$0.exercises.isEmpty }.sorted { $0.position < $1.position }
    }

    private func microcycleNeedsAttentionCard(
        _ tracking: MicrocycleTrackingModel
    ) -> some View {
        Card {
            HStack(spacing: Space.md) {
                NavigationLink(value: HomeRoute.microcycle(tracking.id)) {
                    HStack(spacing: Space.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(theme.danger)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Microcycle needs attention")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Open \(tracking.folderName) to fix its folder or routines.")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button("Remove microcycle from Home", systemImage: "xmark") {
                    updateMicrocyclePresentation(tracking, showsOnHome: false)
                }
                .labelStyle(.iconOnly)
                .font(.caption.bold())
                .foregroundStyle(theme.textTertiary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
            }
        }
        .accessibilityIdentifier("home-microcycle-needs-attention")
    }

    private func updateMicrocyclePresentation(
        _ tracking: MicrocycleTrackingModel,
        showsOnHome: Bool
    ) {
        PersistentChangeSaveCenter.shared.perform {
            try MicrocycleTrackingService.setPresentation(
                tracking,
                showsOnHome: showsOnHome,
                in: modelContext
            )
        }
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
                        .foregroundStyle(theme.accentForeground)
                        .frame(width: 38, height: 38)
                        .background(theme.accentSoft)
                        .clipShape(Circle())
                    Text("Find your program").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(theme.textTertiary)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// Whether the recovery dashboard (hero + four tiles) earns its place at
    /// the top of Home. Recovery, sleep, and the health readings all come from
    /// Apple Health — with no authorization they can never populate, so the
    /// dashboard becomes four cards each explaining that it has nothing, above
    /// the fold, every launch. Strain and the week card still carry the
    /// training-derived numbers further down.
    private var showsRecoveryDashboard: Bool {
        healthConnected || !healthMetrics.metrics.isEmpty || todayDashboardCache != nil
    }

    /// The workout entry point: quick-launch tiles, with the existing suggested
    /// workout retained behind a presentation flag for a possible return.
    /// Rendered near the top when the recovery dashboard is suppressed, in its
    /// usual place below the week card otherwise.
    @ViewBuilder
    private var trainingSurface: some View {
        SectionHeader("Quick start") {
            quickStartEditButton
        }
        if FeatureFlags.homeSuggestedWorkout {
            if let suggestion {
                suggestionCard(
                    suggestion.routine,
                    reason: suggestion.reason,
                    alternatingWith: suggestion.alternatingWith
                )
                .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                .transition(.opacity)
            } else {
                explorePromptCard
                    .dismissesQuickStartEdit(isEditing: quickStartEditing, dismiss: dismissQuickStartEdit)
                    .transition(.opacity)
            }
        }
        quickStart
    }

    /// One row standing in for the whole recovery dashboard while Health is
    /// disconnected. States the consequence rather than selling the feature —
    /// what ForgeFit can and can't tell you until it has the data.
    private var connectHealthPrompt: some View {
        Card {
            HStack(spacing: Space.md) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.accentForeground)
                    .frame(width: 36, height: 36)
                    .background(theme.accentSoft)
                    .clipShape(Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Readiness needs Apple Health")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(healthAuthorization.state.issueMessage
                        ?? "Sleep, HRV, and resting heart rate come from Health. Until it's connected, ForgeFit tracks your training only.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.sm)
                Button {
                    performHomeHealthAction()
                } label: {
                    Text(homeHealthActionTitle)
                        .minimumTouchTarget()
                }
                .font(.bodyStrong)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(theme.accent)
                .disabled(connectingHealth || healthAuthorization.state == .unavailable)
                .accessibilityIdentifier("home-connect-health")
            }
        }
        .accessibilityIdentifier("home-connect-health-prompt")
    }

    private var readinessEmptyState: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.accentForeground)
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
                    Button {
                        performHomeHealthAction()
                    } label: {
                        Text(homeHealthActionTitle)
                            .minimumTouchTarget()
                    }
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    .disabled(connectingHealth || healthAuthorization.state == .unavailable)
                    Button {
                        showExploreLibrary = true
                    } label: {
                        Text("Explore programs")
                            .font(.bodyStrong)
                            .minimumTouchTarget()
                    }
                        .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
            }
        }
    }

    private var homeHealthActionTitle: String {
        if connectingHealth { return "Connecting…" }
        if healthAuthorization.state.requiresPermissionReview { return "Open Settings" }
        if healthAuthorization.state == .notDetermined { return "Connect" }
        return "Try Again"
    }

    private func performHomeHealthAction() {
        if healthAuthorization.state.requiresPermissionReview {
            HealthAuthorizationRecovery.openSettings()
            return
        }
        Task {
            guard await healthAuthorization.connect() else { return }
            await HealthWorkoutImporter.shared.importRecent(in: modelContext.container)
            healthMetrics.refresh(force: true)
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
                            .foregroundStyle(theme.accentForeground)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(report.isMonthly ? "Monthly" : "Yearly") Report Available")
                            .font(.tag)
                            .foregroundStyle(theme.accentForeground)
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

    private var weekCard: some View {
        let now = Date()
        let week = weekMemo(HomeWeekMetrics.fingerprint(
            workouts: workouts,
            exercises: exercises,
            containing: now
        )) {
            HomeWeekMetrics.summary(
                workouts: workouts,
                exercises: exercises,
                containing: now
            )
        }
        let days = TrainingWeekSupport.days(workouts: workouts, containing: now)
        return Card {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                    Text("This week")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                    Spacer(minLength: Space.md)
                    Text(TrainingWeekSupport.rangeLabel(containing: now))
                        .font(.tag)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("home-week-date-range")
                }

                HomeWeekCalendarStrip(days: days)

                TrainingLoadGauge(comparison: recovery.trainingLoad)

                HStack {
                    ForEach(week.metrics) { metric in
                        StatColumn(
                            label: metric.label,
                            value: metric.formatted(
                                weightUnit: Fmt.unit,
                                distanceUnit: Fmt.distanceUnit
                            )
                        )
                    }
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
            // Six tags never fit. Bled out to the true screen edge so the next
            // chip is visibly cut by the display rather than by the content
            // margin — a chip that stops short of the edge reads as a clipping
            // bug, one that runs off it reads as a row you can push.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CheckinTags.all, id: \.id) { tag in
                        let on = effectiveCheckinTags.contains(tag.id)
                        Button {
                            checkinStripEngaged = true
                            toggleCheckinTag(tag.id)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: tag.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .symbolEffect(.bounce, value: reduceMotion ? false : on)
                                Text(tag.label).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(on ? .white : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(on ? theme.accent : theme.surfaceElevated))
                            .animation(Motion.tap, value: on)
                            .minimumTouchTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("home-checkin-\(tag.id)")
                    }
                }
            }
            // Widen past the scaffold's gutter so the row clips at the display
            // edge, then put the gutter back as a content margin so the first
            // chip still lines up with the cards above it.
            .padding(.horizontal, -Space.lg)
            .contentMargins(.horizontal, Space.lg, for: .scrollContent)
        }
    }

    /// Toggle is optimistic: it updates the draft immediately (the capsule
    /// repaints from the draft, never waiting on the persist) and debounces
    /// the persist so rapid multi-tag tapping neither writes to disk nor
    /// re-runs RecoveryEngine per tap.
    private func toggleCheckinTag(_ tag: String) {
        var tags = effectiveCheckinTags
        if let index = tags.firstIndex(of: tag) {
            tags.remove(at: index)
        } else {
            tags.append(tag)
        }
        checkinDraft = tags
        scheduleCheckinCommit()
    }

    private func scheduleCheckinCommit() {
        checkinCommitTask?.cancel()
        checkinCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitCheckinDraft()
        }
    }

    /// Persist the pending mood tags. Idempotent and safe to call from the
    /// debounce, on scene-background, and on disappear — a nil/unchanged draft
    /// is a no-op, so a tapped-then-backgrounded check-in is never lost. Writing
    /// The committed private-context row is what finally moves
    /// `todayCheckinTags`, so this is the single point where the (memoized)
    /// recovery recompute is triggered.
    private func commitCheckinDraft() {
        checkinCommitTask?.cancel()
        checkinCommitTask = nil
        guard let tags = checkinDraft else { return }
        guard tags != todayCheckinTags else { checkinDraft = nil; return }
        let attempt = DailyCheckinCommitAttempt(
            id: todayCheckin?.id ?? pendingCheckinID,
            userID: ForgeFitDemo.userID,
            day: Date(),
            tags: tags
        )
        PersistentChangeSaveCenter.shared.perform({
            _ = try attempt.commit(in: modelContext)
        }, onSuccess: {
            pendingCheckinID = UUID()
        })
        // Draft is cleared by the todayCheckinTags onChange once the write is
        // reflected, so the capsule never flickers back mid-commit.
    }

    /// The direct coach chat presented from Home when Coach's Corner is gated
    /// off. Same view the Corner uses, wired with today's suggested session and
    /// daily coach dose so advice can still turn into a one-tap start — the
    /// saved routine is never modified (`CoachAdjustments.apply` mutates only
    /// the freshly started workout).
    @ViewBuilder private var coachChatSheet: some View {
        let context = AICoachContext.build(
            workouts: workouts, routines: routines, exercises: exercises,
            recovery: recovery,
            suggestion: suggestion.map { (routine: $0.routine, reason: $0.reason) }
        )
        let effective: (plan: CoachAdjustments.Plan, sourceLabel: String)? = {
            guard let suggestion else { return nil }
            let global = CoachAdjustments.plan(for: recovery.action)
            let local = recovery.action == .trainAsPlanned
                ? CoachAdjustments.localizedPlan(for: RoutineDoseContext.make(
                    routine: suggestion.routine, workouts: workouts,
                    exercises: exercises, recovery: recovery))
                : nil
            return CoachAdjustments.effectivePlan(daily: global ?? local, weeklyDeloadActive: weeklyDeloadActive)
        }()
        AICoachChatView(
            context: context,
            coachPlan: effective?.plan,
            suggestedRoutineName: suggestion?.routine.name,
            onApplyPlan: effective != nil ? { plan in
                guard let suggestion else { return }
                appState.requestStart {
                    _ = WorkoutFactory.start(
                        routine: suggestion.routine,
                        exercises: exercises,
                        setupNotes: setupNotes,
                        in: modelContext,
                        prepare: { workout, context in
                            CoachAdjustments.apply(
                                plan,
                                to: workout,
                                in: context,
                                saveChanges: false
                            )
                        },
                        onCommit: { _ in appState.showingLogger = true }
                    )
                }
            } : nil
        )
    }

    /// Today's coach-adjusted dose for `routine`, or nil when there is nothing
    /// to offer — or when `coachDoseReview` is off, in which case none of the
    /// work runs at all. `RoutineDoseContext.make` walks the training history,
    /// so computing it for a button that isn't drawn is pure waste on every
    /// Home render.
    private func coachReview(
        for routine: RoutineModel
    ) -> (plan: CoachAdjustments.Plan, sourceLabel: String, isLocalized: Bool, affectedMuscles: String)? {
        guard FeatureFlags.coachDoseReview else { return nil }
        let doseContext = targetRecoveryMemo("\(AnalyticsFingerprint.withHealth(workouts))|\(todayCheckinTags.joined(separator: ","))|\(dashboardAnalyticsKey ?? "pending")|\(routine.id)|\(routine.updatedAt.timeIntervalSince1970)") {
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
        guard let effective = CoachAdjustments.effectivePlan(
            daily: globalCoachPlan ?? localCoachPlan,
            weeklyDeloadActive: weeklyDeloadActive
        ) else { return nil }
        return (
            plan: effective.plan,
            sourceLabel: effective.sourceLabel,
            isLocalized: !weeklyDeloadActive && globalCoachPlan == nil && localCoachPlan != nil,
            affectedMuscles: doseContext.affectedMuscleNames
        )
    }

    private func suggestionCard(
        _ routine: RoutineModel,
        reason: String,
        alternatingWith: String?
    ) -> some View {
        let coach = coachReview(for: routine)
        // This is THE answer to "what should I do today" — the one card on
        // Home that should visually outrank everything else, so its Start
        // button is a full-width PrimaryButton, not a small corner capsule.
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Up next")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.accentForeground)
                        .textCase(.uppercase)
                    Text(routine.name)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(reason)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    if let alternatingWith {
                        Label(
                            "Alternates with \(alternatingWith)",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accentForeground)
                        .accessibilityIdentifier("home-alternating-routine")
                    }
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
                        _ = WorkoutFactory.start(
                            routine: routine,
                            exercises: exercises,
                            setupNotes: setupNotes,
                            in: modelContext,
                            onCommit: { _ in appState.showingLogger = true }
                        )
                    }
                }
                .accessibilityIdentifier("start-suggested-routine-\(routine.name)")

                // Advice→action, review-first: today's dose is fully
                // editable before anything starts (Coach's Corner review).
                if let coach {
                    Button {
                        reviewRequest = CoachReviewRequest(plan: coach.plan, routine: routine, sourceLabel: coach.sourceLabel)
                    } label: {
                        HStack(spacing: Space.sm) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .bold))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(coach.isLocalized ? "Review lighter \(coach.affectedMuscles) version" : "Review coach's version")
                                    .font(.system(size: 14, weight: .bold))
                                Text("\(coach.sourceLabel) · \(coach.plan.summary) · routine unchanged")
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
                            _ = WorkoutFactory.startEmpty(
                                in: modelContext,
                                onCommit: { _ in appState.showingLogger = true }
                            )
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
    }

    private var quickStartEditButton: some View {
        Button {
            if quickStartEditing {
                dismissQuickStartEdit()
            } else {
                withAnimation(.spring(duration: 0.28)) { quickStartEditing = true }
            }
        } label: {
            Label(
                quickStartEditing ? "Done" : "Edit",
                systemImage: quickStartEditing ? "checkmark" : "pencil"
            )
            .minimumTouchTarget()
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(theme.accentForeground)
        .accessibilityIdentifier("home-quick-start-edit")
    }

    private var quickStartActions: [HomeQuickStartAction] {
        let actions = HomeQuickStartAction.resolvedList(from: quickStartActionsJSON)
        return actions.filter { action in
            switch action.kind {
            case .cardio: true
            case .routine(let id): routines.contains { $0.id == id && $0.deletedAt == nil && $0.archivedAt == nil }
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
                _ = WorkoutFactory.startCardio(
                    modality,
                    exercises: exercises,
                    in: modelContext,
                    onCommit: { _ in appState.showingLogger = true }
                )
            case .routine(let id):
                guard let routine = routines.first(where: { $0.id == id && $0.deletedAt == nil && $0.archivedAt == nil }) else { return }
                _ = WorkoutFactory.start(
                    routine: routine,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    in: modelContext,
                    onCommit: { _ in appState.showingLogger = true }
                )
            case .yoga(let slug):
                guard let seed = YogaFlowCatalog.flow(forSlug: slug) else { return }
                _ = WorkoutFactory.startYoga(
                    flow: YogaFlowCatalog.plan(for: seed),
                    named: seed.name,
                    exercises: exercises,
                    in: modelContext,
                    onCommit: { _ in appState.showingLogger = true }
                )
            }
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

    private func createRoutine() {
        let attempt = RoutineCreationAttempt(
            name: "New Routine",
            folderID: nil,
            position: routines.count,
            in: modelContext
        )
        attempt.commit(into: modelContext) { routine in
            addQuickStartAction(.routine(routine.id))
            showQuickStartAdd = false
            editingRoutine = routine
        }
    }
}

enum HomeRoute: Hashable {
    case recovery
    case sleep
    case strain
    case health
    case calendar
    case history
    case microcycle(UUID)
}

struct HomeQuickStartAction: Hashable, Identifiable {
    static let preferenceKey = "homeQuickStartActions.v1"

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

    init?(id raw: String) {
        if let modalityRaw = raw.removingPrefix("cardio:"),
           let modality = CardioModality(rawValue: modalityRaw) {
            kind = .cardio(modality)
        } else if let idRaw = raw.removingPrefix("routine:"),
                  let id = UUID(uuidString: idRaw) {
            kind = .routine(id)
        } else if let slug = raw.removingPrefix("yoga:") {
            kind = .yoga(slug)
        } else {
            return nil
        }
    }

    /// Nil means the stored payload is malformed. An empty array is a valid,
    /// intentional choice because Home always retains its fixed Empty tile.
    static func decodeList(from json: String) -> [HomeQuickStartAction]? {
        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        var seen = Set<String>()
        return ids
            .compactMap { HomeQuickStartAction(id: $0) }
            .filter { seen.insert($0.id).inserted }
    }

    /// An absent preference gets the onboarding defaults. A persisted `[]`
    /// stays empty, so removing the final configurable tile survives redraws
    /// and relaunches instead of silently restoring the defaults.
    static func resolvedList(from json: String) -> [HomeQuickStartAction] {
        guard !json.isEmpty else { return defaults }
        return decodeList(from: json) ?? defaults
    }

    static func encodeList(_ actions: [HomeQuickStartAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions.map(\.id)),
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
                            .padding(4)
                            .frame(width: 44, height: 44, alignment: .topTrailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                        .foregroundStyle(theme.accentForeground)
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

/// Home's action-first guidance. The metric grid below owns navigation and
/// score exploration; this block answers only "what should I do today?"
struct RecoveryHeroCard: View {
    @Environment(\.theme) private var theme
    @State private var isExpanded = true
    let report: RecoveryEngine.Report
    let source: HomeDashboardSource
    let isRefreshing: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: isExpanded ? Space.md : 0) {
                HStack(spacing: Space.sm) {
                    Text("Today's recommendation")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: Space.sm)
                    if isRefreshing, source != .loading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(theme.textTertiary)
                    }
                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                            .minimumTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse today's recommendation" : "Expand today's recommendation")
                    .accessibilityIdentifier("home-recommendation-disclosure")
                }

                if isExpanded {
                    guidance
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("home-recommendation-details")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch source {
            case .loading:
                HStack(spacing: Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.accent)
                    Text("Crunching the numbers...")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                }
            case .cached(_, let cache):
                if cache.baselineReady, let action = RecoveryEngine.Action(rawValue: cache.actionRaw) {
                    recommendationBody(
                        action: action,
                        recommendation: cache.recommendation,
                        reasons: cache.reasonTexts)
                } else {
                    buildingBody
                }
            case .live:
                if report.baselineReady {
                    recommendationBody(
                        action: report.action,
                        recommendation: report.recommendation,
                        reasons: report.reasonChips.prefix(2).map(\.text))
                } else {
                    buildingBody
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buildingBody: some View {
        Group {
            Text("Building your baseline")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
            Text("Keep logging and wearing your watch to unlock daily guidance.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func recommendationBody(
        action: RecoveryEngine.Action,
        recommendation: String,
        reasons: [String]
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: action.systemImage)
                .font(.system(size: 12, weight: .bold))
            Text(action.title)
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(action.tint(in: theme))
        Text(recommendation)
            .font(.system(size: 13))
            .foregroundStyle(theme.textPrimary)
            .lineLimit(3)
        let joined = reasons.joined(separator: "  |  ")
        if !joined.isEmpty {
            Text(joined)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
        }
    }
}

/// A workout row used across Home / Profile feeds.
struct WorkoutFeedRow: View {
    @Environment(\.theme) private var theme
    let workout: WorkoutModel
    let analytics: TrainingAnalytics

    var body: some View {
        let s = analytics.summary(for: workout)
        let shape = WorkoutShareShape.of(workout: workout, summary: s)
        let facts = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: analytics.exercises,
            durationSeconds: s.durationSeconds
        ).facts
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Image(systemName: shape.systemImage)
                        .foregroundStyle(theme.accentForeground)
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
                    ForEach(Array(facts.prefix(3).enumerated()), id: \.offset) { _, fact in
                        StatColumn(label: fact.label, value: fact.value)
                    }
                }
            }
        }
        .accessibilityIdentifier("home-workout-\(workout.title ?? "Workout")")
    }
}
