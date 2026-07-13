import Combine
import ForgeCore
import ForgeData
import Observation
import SwiftData
import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// App-wide UI state that isn't persisted: which tab is showing and whether the
/// active-workout logger is presented full-screen.
@Observable
final class AppState {
    var selectedTab: AppTab = .home
    var showingLogger = false

    /// Guarded workout start: every "start a workout" action funnels through
    /// here so ContentView can warn before discarding an active session.
    var startRequestID = 0
    var pendingWorkoutStart: (() -> Void)?

    func requestStart(_ action: @escaping () -> Void) {
        pendingWorkoutStart = action
        startRequestID += 1
    }
}

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, workout, insights, profile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .workout: "Workout"
        case .insights: "Insights"
        case .profile: "Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .workout: "dumbbell.fill"
        case .insights: "chart.bar.fill"
        case .profile: "person.fill"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @EnvironmentObject private var themeManager: ThemeManager
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @Query(sort: \UserExerciseNoteModel.updatedAt, order: .reverse) private var setupNotes: [UserExerciseNoteModel]
    @Query(sort: \RoutineModel.position) private var routines: [RoutineModel]
    @Query(sort: \RoutineFolderModel.position) private var routineFolders: [RoutineFolderModel]
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var workouts: [WorkoutModel]
    @Query(filter: #Predicate<WorkoutModel> { $0.endedAt == nil && $0.deletedAt == nil }, sort: \WorkoutModel.startedAt, order: .reverse) private var activeWorkouts: [WorkoutModel]
    @Query(sort: \DailyCheckinModel.updatedAt, order: .reverse) private var checkins: [DailyCheckinModel]

    @State private var appState = AppState()
    @State private var social = SocialService.make()
    @State private var restTimer = RestTimerController.shared
    @State private var intervalHub = IntervalRunnerHub.shared
    @State private var yogaHub = YogaFlowRunnerHub.shared
    @State private var showReplaceWorkoutConfirm = false
    @State private var workoutPendingDiscard: WorkoutModel?
    @State private var cleanedOnboardingSlate = false
    @State private var lastHealthWorkoutImportAt: Date?
    @State private var workoutCountReactionTask: Task<Void, Never>?
    @State private var readinessStampTask: Task<Void, Never>?
    @State private var liveSurfaceUpdateTask: Task<Void, Never>?
    @State private var planDeduplicationTask: Task<Void, Never>?
    @State private var lastLiveActivityHRPushAt = Date.distantPast
    @State private var didStartLaunchTasks = false
    // Tabs that have been visited at least once. They stay mounted behind the
    // current tab (keep-resident) so their @State-held Memo caches survive —
    // switching back is instant instead of re-running full-history analytics in
    // `body`. Seeded lazily (only the first tab mounts at launch).
    @State private var mountedTabs: Set<AppTab> = []
    @State private var showBootSplash = true
    // First launch only; UI-test launch hooks skip it.
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didOnboard")
        && UserDefaults.standard.string(forKey: "initialTab") == nil
        && !UserDefaults.standard.bool(forKey: "autoStartRoutine")
        && !ProcessInfo.processInfo.arguments.contains("--auto-start-routine")
        && !ProcessInfo.processInfo.arguments.contains("--reset-store")

    private var activeWorkout: WorkoutModel? {
        activeWorkouts.first
    }

    /// The single source of truth for the app's appearance: combines the
    /// user's chosen mode with the device's live system scheme so `.system`
    /// mode tracks appearance changes without a restart.
    private var resolvedColorScheme: ColorScheme {
        themeManager.mode.resolvedColorScheme(system: systemColorScheme)
    }
    private var activeTheme: AppTheme {
        .active(for: themeManager.mode, system: systemColorScheme)
    }

    /// Count of live completed workouts — changes when one is finished or
    /// deleted, so the widget and watch react immediately.
    private var completedWorkoutCount: Int {
        workouts.count { $0.endedAt != nil && $0.deletedAt == nil }
    }

    private var routineListVersion: String {
        let latest = routines.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(routines.count)|\(latest)"
    }

    /// CloudKit imports can land after launch seeding has already performed
    /// its cleanup. Count + unique-count detects duplicate-id arrivals, while
    /// latest-update also catches a same-count remote replacement.
    private var planRowsVersion: String {
        let latestRoutine = routines.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let latestFolder = routineFolders.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(routines.count)|\(Set(routines.map(\.id)).count)|\(latestRoutine)|"
            + "\(routineFolders.count)|\(Set(routineFolders.map(\.id)).count)|\(latestFolder)"
    }

    private var todayCheckinTags: [String] {
        checkins
            .first { $0.deletedAt == nil && Calendar.current.isDate($0.date, inSameDayAs: Date()) }?
            .tags ?? []
    }

    // The root modifier chain is split in two (`presentedShell` + `body`)
    // purely for the type-checker: as one expression it exceeded the
    // reasonable-time limit once the deep-link hook landed.
    private var presentedShell: some View {
        ZStack {
            appShell

            if showBootSplash {
                BootSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
            .environment(appState)
            .environment(social)
            .environment(\.theme, activeTheme)
            .preferredColorScheme(resolvedColorScheme)
            .tint(activeTheme.accent)
            .task { await social.bootstrap() }
            .fullScreenCover(isPresented: $appState.showingLogger) {
            if let activeWorkout = activeWorkoutForPresentation() {
                ActiveWorkoutLoggerView(
                    workout: activeWorkout,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    history: workouts,
                    onMinimize: { appState.showingLogger = false },
                    onFinished: { publishFinishedWorkout($0) }
                )
                .environment(social)
            }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                // `showOnboarding` can already be `true` on the very first
                // render (computed synchronously at launch, unlike other
                // presentations that flip true reactively later) — a
                // fullScreenCover presented that early doesn't reliably pick
                // up the environment set higher in this same modifier chain,
                // so the theme is pinned explicitly here rather than relied
                // on to cascade.
                OnboardingView(isPresented: $showOnboarding)
                    .environment(\.theme, activeTheme)
                    .preferredColorScheme(resolvedColorScheme)
                    // Mirrors the app-root Dynamic Type clamp — this cover can
                    // present before the root environment lands (see above).
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            .confirmationDialog(
                "You have a workout in progress",
                isPresented: $showReplaceWorkoutConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard Current & Start New", role: .destructive) {
                    if let activeWorkout { discard(activeWorkout) }
                    runPendingStart()
                }
                Button("Keep Current Workout", role: .cancel) {
                    appState.pendingWorkoutStart = nil
                }
            } message: {
                Text("Starting a new workout will discard the active one and its logged sets.")
            }
            .confirmationDialog(
                "Discard this workout?",
                isPresented: Binding(
                    get: { workoutPendingDiscard != nil },
                    set: { if !$0 { workoutPendingDiscard = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Discard Workout", role: .destructive) {
                    if let workoutPendingDiscard { discard(workoutPendingDiscard) }
                    workoutPendingDiscard = nil
                }
                Button("Keep Logging", role: .cancel) { workoutPendingDiscard = nil }
            } message: {
                Text("All logged sets from this session will be lost.")
            }
    }

    var body: some View {
        shellLifecycleHandlers
    }

    private var shellLifecycleHandlers: some View {
        shellWorkoutHandlers
            .task { await runLaunchTasksIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: .forgeFitAccountResetDidComplete)) { _ in
                handleAccountReset()
            }
            .onChange(of: scenePhase) { _, phase in handleScenePhaseChange(phase) }
            .onOpenURL { url in handleDeepLink(url) }
    }

    private var shellWorkoutHandlers: some View {
        shellRealtimeHandlers
            .onChange(of: activeWorkout?.id) { oldID, newID in
                handleActiveWorkoutChange(oldID: oldID, newID: newID)
            }
            .onChange(of: appState.showingLogger) { _, isPresented in
                if !isPresented, let activeWorkout {
                    scheduleReadinessStamp(for: activeWorkout, delayMilliseconds: 100)
                }
            }
            // Deleting or finishing a workout changes today's training reality —
            // the widget and watch snapshot must follow. Deferred
            // and coalesced: the refreshes run full recovery/analytics passes, and
            // doing that synchronously stalls the dismiss/pop animation the user
            // is watching (first delete used to lag and drop its dismissal).
            .onChange(of: completedWorkoutCount) { handleCompletedWorkoutCountChange() }
    }

    private var shellRealtimeHandlers: some View {
        presentedShell
            .onChange(of: showOnboarding) { _, isPresented in handleOnboardingPresentationChange(isPresented) }
            .onChange(of: appState.startRequestID) { _, requestID in handleStartRequestChange(requestID) }
            .onChange(of: routineListVersion) { WatchLink.shared.publishState() }
            .onChange(of: planRowsVersion) { schedulePlanDeduplication() }
            .onChange(of: todayCheckinTags) { _, _ in handleTodayCheckinChange() }
            .onChange(of: restTimer.endsAt) { _, endsAt in handleRestTimerChange(endsAt) }
            // Interval step transitions repaint the watch + Live Activity.
            .onChange(of: intervalHub.runner?.stepEndsAt) {
                WatchLink.shared.publishState()
                WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
            }
            // Yoga pose transitions (and pause/resume) do the same.
            .onChange(of: yogaHub.runner?.stepEndsAt) {
                WatchLink.shared.publishState()
                WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
            }
            .onChange(of: yogaHub.runner?.isPaused) {
                WatchLink.shared.publishState()
                WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
            }
            // HR observation lives in a zero-sized child view: reading
            // LiveMetricsHub.liveMetrics here would register the Observation
            // dependency on ContentView itself and re-render the whole app
            // shell on every heart-rate tick (~1/s during workouts).
            .background(LiveHeartRateObserver(onChange: handleLiveHeartRateChange))
    }

    private var appShell: some View {
        ZStack(alignment: .bottom) {
            ScreenBackground()

            tabScreens
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: Space.sm) {
                if let activeWorkout {
                    MiniWorkoutBar(
                        workout: activeWorkout,
                        exercises: exercises,
                        onExpand: { appState.showingLogger = true },
                        onDiscard: { workoutPendingDiscard = activeWorkout }
                    )
                    .padding(.horizontal, Space.lg)
                }
                ForgeTabBar(selection: $appState.selectedTab)
            }
            .padding(.bottom, Space.sm)
            // Scoped to just this bottom-bar layer (not the whole `appShell`
            // ZStack): SwiftUI's default keyboard avoidance would otherwise
            // lift this VStack — tab bar + mini bar — above the keyboard,
            // colliding with the logger's keyboard accessory pills. Apple's
            // own tab bars don't avoid the keyboard either; it should slide
            // over them. `tabScreens` is a separate ZStack sibling below,
            // untouched by this modifier, so its own ScrollView content still
            // gets normal keyboard avoidance/insetting.
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }

    // Keep-resident tab host. Previously a `switch`, which is `_ConditionalContent`
    // and tears down the outgoing tab's identity + @State (wiping every Memo
    // cache) on each switch — so Home/Insights/Profile re-ran their full-history
    // analytics synchronously in `body` on every visit, stalling the tab
    // animation. Here each visited tab stays alive (hidden via opacity/hit-
    // testing), so the memos the tabs' own comments assume ("stays alive behind
    // the others") actually persist. Tabs mount lazily on first selection, so a
    // cold launch still builds only Home.
    @ViewBuilder
    private var tabScreens: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                if appState.selectedTab == tab || mountedTabs.contains(tab) {
                    tabContent(for: tab)
                        .opacity(appState.selectedTab == tab ? 1 : 0)
                        .allowsHitTesting(appState.selectedTab == tab)
                        .accessibilityHidden(appState.selectedTab != tab)
                        .zIndex(appState.selectedTab == tab ? 1 : 0)
                }
            }
        }
        .onChange(of: appState.selectedTab, initial: true) { _, tab in
            mountedTabs.insert(tab)
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView(workouts: workouts, routines: routines, exercises: exercises, setupNotes: setupNotes)
        case .workout:
            WorkoutHomeView(routines: routines, workouts: workouts, exercises: exercises, setupNotes: setupNotes)
        case .insights:
            InsightsView(workouts: workouts, exercises: exercises)
        case .profile:
            ProfileView(workouts: workouts, exercises: exercises)
        }
    }

    private func handleOnboardingPresentationChange(_ isPresented: Bool) {
        guard !isPresented,
              !cleanedOnboardingSlate,
              UserDefaults.standard.bool(forKey: "didOnboard"),
              !isAutomationLaunch else { return }
        cleanedOnboardingSlate = true
        clearStarterSlate()
    }

    private func handleStartRequestChange(_ _: Int) {
        guard appState.pendingWorkoutStart != nil else { return }
        if activeWorkout == nil {
            runPendingStart()
        } else {
            showReplaceWorkoutConfirm = true
        }
    }

    private func handleRestTimerChange(_ _: Date?) {
        WatchLink.shared.publishState()
        // Structural change (start/skip/replace, not a per-second tick):
        // both surfaces carry restEndsAt, so push both immediately.
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
        updateWidgetSnapshot()
    }

    private func handleTodayCheckinChange() {
        guard activeWorkout == nil else { return }
        updateWidgetSnapshot()
        WatchLink.shared.publishState(force: true)
        ReadinessDelivery.shared.refreshMorningNotification()
    }

    private func handleCompletedWorkoutCountChange() {
        workoutCountReactionTask?.cancel()
        workoutCountReactionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            updateWidgetSnapshot()
            WatchLink.shared.publishState()
        }
    }

    /// CloudKit may deliver several related rows in a short burst. Debounce the
    /// cleanup so one pass handles the batch; a resulting query change is safe
    /// because the follow-up pass is idempotent and performs no save.
    private func schedulePlanDeduplication() {
        planDeduplicationTask?.cancel()
        planDeduplicationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            do {
                try RoutineDeduplicator.removeDuplicates(in: modelContext)
            } catch {
                assertionFailure("Plan deduplication after CloudKit change failed: \(error)")
            }
        }
    }

    private func handleLiveHeartRateChange(_ heartRate: Int?) {
        // Zone-lock guard: fire audible/haptic cues on leaving/re-entering the
        // target zone. Runs app-wide so it works on any screen.
        HRZoneGuard.shared.evaluate(hr: heartRate)
        scheduleLiveActivityHRUpdate()
    }

    /// HR ticks arrive ~1/s. The Live Activity's countdowns self-update
    /// in-widget, so a push only carries the HR number — a ≥3 s throttle is
    /// plenty and respects the ActivityKit update budget. The home-screen
    /// widget does NOT ride HR at all: reloading its timeline every second
    /// burned battery for a surface nobody sees mid-workout; it refreshes on
    /// structural events instead (workout start/end, set logged, rest timer,
    /// scene phase).
    private func scheduleLiveActivityHRUpdate() {
        guard liveSurfaceUpdateTask == nil else { return }   // throttle: absorb ticks while scheduled
        let sinceLastPush = Date().timeIntervalSince(lastLiveActivityHRPushAt)
        let delay = max(0, 3 - sinceLastPush)
        liveSurfaceUpdateTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let cancelled = Task.isCancelled
            liveSurfaceUpdateTask = nil
            guard !cancelled else { return }
            lastLiveActivityHRPushAt = Date()
            WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
        }
    }

    /// forgefit:// router — the app-side half of every widget, Live
    /// Activity, and notification deep link:
    ///   forgefit://workout          → active logger (or Workout tab)
    ///   forgefit://readiness        → Home (readiness leads the screen)
    ///   forgefit://insights         → Insights tab
    ///   forgefit://start/<routine>  → start that routine, open the logger
    private func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "forgefit" else { return }
        switch url.host?.lowercased() {
        case "workout":
            if activeWorkoutForPresentation() != nil {
                appState.showingLogger = true
            } else {
                appState.selectedTab = .workout
            }
        case "insights":
            appState.selectedTab = .insights
        case "u":   // forgefit://u/<handle> — visit a friend's profile
            if let handle = SocialLinks.handle(from: url) {
                social.pendingFollowHandle = handle
                appState.selectedTab = .profile
            }
        case "start":
            let routineID = url.pathComponents.dropFirst().first.flatMap(UUID.init)
            if let routineID,
               let routine = routines.first(where: { $0.id == routineID && $0.deletedAt == nil && !$0.exercises.isEmpty }) {
                appState.requestStart {
                    _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
                    appState.showingLogger = true
                }
            } else {
                appState.selectedTab = .workout
            }
        default:   // "readiness" and anything unrecognized
            appState.selectedTab = .home
        }
    }

    /// Projects a just-finished workout to its health-safe shared form and
    /// publishes it (no-op unless the user opted into social). Skips workouts
    /// with no strength exercises (v1 shares strength content only).
    private func publishFinishedWorkout(_ workout: WorkoutModel) {
        guard social.isOptedIn else { return }
        let names = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let dto = SocialWorkoutMapper.shared(from: workout, exerciseNames: names)
        guard !dto.exercises.isEmpty else { return }
        let summary = dto.summary
        Task { await social.publish(dto, summary: summary) }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        // Guided yoga backstop: iOS suspends the app soon after backgrounding
        // (the runner's in-process timers stop), so hand the remaining pose
        // schedule to the notification center — and take it back on return.
        if phase == .background, let runner = yogaHub.runner {
            NotificationScheduler.shared.scheduleYogaCueSchedule(runner.upcomingTransitions())
        } else if phase == .active {
            NotificationScheduler.shared.cancelYogaCueSchedule()
        }
        if phase == .active {
            UserDefaults.standard.set(Date(), forKey: "lastActiveDate")
            Task { await importHealthWorkoutHistory() }
            // Force: every app open must pick up the day's new Health data
            // (overnight sleep, morning HRV, weigh-ins) so readiness is
            // never stale. Re-write the idle widget once fresh metrics land so
            // it isn't hours stale between app opens.
            Task { @MainActor in
                await HealthMetricsStore.shared.refreshNow()
                if activeWorkout == nil { updateWidgetSnapshot() }
            }
            NotificationScheduler.shared.refreshStatus()
            // Covers "the app was already running when the month rolled
            // over" — launch alone would miss it.
            generateWrappedIfDue()
            updateWidgetSnapshot()
        } else if phase == .background {
            // Leave the widget with the freshest snapshot we have — otherwise it
            // would serve whatever it last read until the next app open.
            updateWidgetSnapshot()
            // Flush any pending (debounced) backup before iOS suspends us.
            BackupScheduler.shared.exportNow()
        }
    }

    /// Wrapped generation is launch/foreground-driven (idempotent, keyed by
    /// period — cheap when nothing is due). A newly created report gets the
    /// one-shot "ready" notification; the Home card appears either way.
    private func generateWrappedIfDue() {
        let created = WrappedReportService.generateIfDue(in: modelContext)
        if let newest = created.first {
            NotificationScheduler.shared.scheduleWrappedReady(
                reportTitle: WrappedReportService.title(for: newest)
            )
        }
    }

    private func handleActiveWorkoutChange(oldID: UUID?, newID: UUID?) {
        WatchLink.shared.publishState(force: newID != nil)
        if newID == nil {
            readinessStampTask?.cancel()
            liveSurfaceUpdateTask?.cancel()
            WorkoutActivityController.shared.end()
            RestTimerController.shared.skip()
            IntervalRunnerHub.shared.stop()
            LiveMetricsHub.shared.endSession()
        } else {
            LiveMetricsHub.shared.beginSession()
            // Latch onto a paired heart-rate monitor (Garmin broadcast /
            // strap) for the session; no-op when none is remembered.
            BLEHeartRateService.shared.reconnectIfRemembered()
            WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
        }
        updateWidgetSnapshot()
        guard let newID, oldID != newID,
              let workout = workouts.first(where: { $0.id == newID }) else { return }
        if workout.readinessAtStart == nil {
            scheduleReadinessStamp(for: workout, delayMilliseconds: 600)
        }
        if UserDefaults.standard.object(forKey: "liveSyncEnabled") == nil
            || UserDefaults.standard.bool(forKey: "liveSyncEnabled") {
            HealthService.shared.startWatchApp(cardioKind: watchCardioKind(for: workout))
        }
    }

    private func scheduleReadinessStamp(for workout: WorkoutModel, delayMilliseconds: Int) {
        readinessStampTask?.cancel()
        readinessStampTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled,
                  !appState.showingLogger,
                  workout.deletedAt == nil,
                  workout.readinessAtStart == nil else { return }
            workout.readinessAtStart = Int(ReadinessReportFactory.report(
                workouts: workouts,
                exercises: exercises,
                in: modelContext
            ).displayScore * 100)
            try? modelContext.save()
        }
    }

    private func watchCardioKind(for workout: WorkoutModel) -> CardioKind? {
        guard !workout.cardioSessions.isEmpty,
              !workout.exercises.isEmpty,
              workout.exercises.allSatisfy({ we in workout.cardioSessions.contains { $0.workoutExerciseID == we.id } }),
              let modality = workout.cardioSessions.first?.modality else {
            return nil
        }
        return CardioKind.from(modality: modality)
    }

    @MainActor
    private func runLaunchTasksIfNeeded() async {
        guard !didStartLaunchTasks else { return }
        didStartLaunchTasks = true
        let startedAt = Date()

        await launchTasks()

        // The branding beat is a first-impression device; a returning user
        // just wants in. Warm launches drop the minimum hold and dismiss the
        // splash as soon as launch tasks finish.
        let isWarmLaunch = UserDefaults.standard.bool(forKey: "hasCompletedFirstLaunch")
        UserDefaults.standard.set(true, forKey: "hasCompletedFirstLaunch")
        let minimumSplashSeconds = isWarmLaunch ? 0 : 0.65
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed < minimumSplashSeconds {
            try? await Task.sleep(for: .seconds(minimumSplashSeconds - elapsed))
        }

        withAnimation(.easeOut(duration: 0.22)) {
            showBootSplash = false
        }

        if shouldAutoStartRoutine {
            presentLoggerWhenActiveWorkoutIsReady()
        }
    }

    private func launchTasks() async {
        #if DEBUG
        let preserveSleepDemoOverride = ProcessInfo.processInfo.arguments.contains("--preserve-sleep-override-demo")
        // UI automation needs the flagged night before any launch migration or
        // HealthKit authorization work can delay the Home affordance.
        if ProcessInfo.processInfo.arguments.contains("--seed-partial-sleep-demo")
            || ProcessInfo.processInfo.environment["FORGEFIT_PARTIAL_SLEEP_DEMO"] == "1" {
            HealthMetricsStore.shared.seedPartialSleepDemo(resetOverride: !preserveSleepDemoOverride)
        }
        if ProcessInfo.processInfo.arguments.contains("--seed-recovery-demo")
            || ProcessInfo.processInfo.environment["FORGEFIT_RECOVERY_DEMO"] == "1" {
            RecoverySnapshotStore.shared.seedDemo()
        }
        #endif

        // F10: a 7+ day lapse arms Home's welcome-back card — measured BEFORE
        // stamping today as active, and only for users with training history
        // (an install that sat unused isn't "coming back to training").
        let calendar = Calendar.current
        if let lastActive = UserDefaults.standard.object(forKey: "lastActiveDate") as? Date {
            let gap = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: lastActive),
                to: calendar.startOfDay(for: Date())
            ).day ?? 0
            var hasHistory = FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.endedAt != nil && $0.deletedAt == nil }
            )
            hasHistory.fetchLimit = 1
            if gap >= 7, (try? modelContext.fetch(hasHistory))?.isEmpty == false {
                UserDefaults.standard.set(gap, forKey: "welcomeBackPendingGapDays")
            }
        }
        UserDefaults.standard.set(Date(), forKey: "lastActiveDate")

        if let raw = UserDefaults.standard.string(forKey: "weightUnitRaw"), let u = WeightUnit(rawValue: raw) {
            Fmt.unit = u
        }
        if let raw = UserDefaults.standard.string(forKey: "distanceUnitRaw"), let du = DistanceUnit(rawValue: raw) {
            Fmt.distanceUnit = du
        }
        WatchLink.shared.configure(context: modelContext)
        WatchLink.shared.activate()
        WatchLink.shared.onWorkoutStartedFromWatch = { appState.showingLogger = true }
        WatchLink.shared.onWorkoutFinishedFromWatch = { appState.showingLogger = false }
        // Relaunching into an active session (app was killed mid-workout):
        // resume BLE aggregation so a paired heart-rate monitor keeps
        // filling avg/max/time-in-zone. onChange won't fire for a workout
        // that was already active before the first render.
        if activeWorkout != nil {
            LiveMetricsHub.shared.beginSession()
        }
        BLEHeartRateService.shared.reconnectIfRemembered()
        await seedLaunchData()
        #if DEBUG
        // Forced-reset automation can rebuild the visible shell while the
        // launch task is running. Re-assert this in-memory fixture after that
        // reset so the seeded Health state is also the final state Home sees.
        if ProcessInfo.processInfo.arguments.contains("--seed-partial-sleep-demo")
            || ProcessInfo.processInfo.environment["FORGEFIT_PARTIAL_SLEEP_DEMO"] == "1" {
            HealthMetricsStore.shared.seedPartialSleepDemo(resetOverride: !preserveSleepDemoOverride)
        }
        if ProcessInfo.processInfo.arguments.contains("--seed-week-demo") {
            seedCurrentWeekDemo()
        }
        #endif
        await ImportedExerciseBackfill.runIfNeeded(in: modelContext)
        SetTypeRetirementBackfill.run(in: modelContext)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-wrapped-demo") {
            WrappedDemoSeed.run(in: modelContext)
        }
        #endif
        generateWrappedIfDue()
        if let raw = UserDefaults.standard.string(forKey: "initialTab"),
           let tab = AppTab(rawValue: raw) {
            appState.selectedTab = tab
        }
        if shouldAutoStartRoutine,
           activeWorkout == nil,
           let routine = launchRoutineForAutoStart() {
            let launchExercises = (try? modelContext.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? exercises
            let launchSetupNotes = (try? modelContext.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? setupNotes
            _ = WorkoutFactory.start(routine: routine, exercises: launchExercises, setupNotes: launchSetupNotes, in: modelContext)
            presentLoggerWhenActiveWorkoutIsReady()
        }
        await importHealthWorkoutHistory()
        // No-ops when a demo seed is active (see HealthMetricsStore.refresh).
        HealthMetricsStore.shared.refresh()
        NotificationScheduler.shared.activate()
        ReadinessDelivery.shared.configure(container: modelContext.container)
        BackupScheduler.shared.configure(container: modelContext.container)
        BackupScheduler.shared.dailyCheckIfDue()
        updateWidgetSnapshot()
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
    }

    #if DEBUG
    /// UI-automation fixture for Home's Sunday-to-Saturday completion strip.
    /// Seeds only days that have already occurred, so it never creates a
    /// completed workout in the future.
    private func seedCurrentWeekDemo() {
        let calendar = Calendar.current
        let now = Date()
        let week = TrainingWeekSupport.interval(containing: now, calendar: calendar)
        let todayOffset = calendar.dateComponents([.day], from: week.start, to: calendar.startOfDay(for: now)).day ?? 0
        let offsets = [0, 2, 5].filter { $0 <= todayOffset }

        for offset in offsets {
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start),
                  let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) else { continue }
            modelContext.insert(WorkoutModel(
                userID: ForgeFitDemo.userID,
                title: "Week demo \(offset)",
                startedAt: start,
                endedAt: start.addingTimeInterval(3_600),
                totalVolume: 1_000
            ))
        }
        try? modelContext.save()
    }
    #endif

    private func launchRoutineForAutoStart() -> RoutineModel? {
        let launchRoutines = (try? modelContext.fetch(FetchDescriptor<RoutineModel>())) ?? routines
        return launchRoutines
            .sorted { $0.position < $1.position }
            .first { $0.deletedAt == nil && !$0.exercises.isEmpty }
    }

    private var shouldAutoStartRoutine: Bool {
        UserDefaults.standard.bool(forKey: "autoStartRoutine")
            || ProcessInfo.processInfo.arguments.contains("--auto-start-routine")
    }

    private func activeWorkoutForPresentation() -> WorkoutModel? {
        if let activeWorkout { return activeWorkout }
        var descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func presentLoggerWhenActiveWorkoutIsReady() {
        Task { @MainActor in
            for _ in 0..<15 {
                if activeWorkoutForPresentation() != nil {
                    appState.showingLogger = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func updateWidgetSnapshot() {
        let snapshot: ForgeFitWidgetSnapshot
        if let activeWorkout {
            snapshot = activeWorkoutSnapshot(activeWorkout)
        } else {
            let report = ReadinessReportFactory.report(
                workouts: workouts,
                exercises: exercises,
                in: modelContext
            )
            snapshot = ForgeFitWidgetSnapshot(
                mode: .idle,
                readinessScore: Int(report.displayScore * 100),
                readinessAction: report.action.title,
                readinessDetail: report.preWorkoutAdjustment,
                reasonChips: report.reasonChips.prefix(3).map(\.text)
            )
        }

        ForgeFitWidgetSnapshotStore.save(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    private func activeWorkoutSnapshot(_ workout: WorkoutModel) -> ForgeFitWidgetSnapshot {
        let sortedExercises = workout.exercises.sorted { $0.position < $1.position }
        let allSets = sortedExercises.flatMap(\.sets)
        let currentExercise = sortedExercises.first { exercise in
            exercise.sets.contains { $0.completedAt == nil } || exercise.sets.isEmpty
        } ?? sortedExercises.last
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let timer = RestTimerController.shared

        return ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            workoutTitle: workout.title ?? "Workout",
            workoutStartedAt: workout.startedAt,
            currentExerciseName: currentExercise.flatMap { exerciseByID[$0.exerciseID] },
            completedSets: allSets.filter { $0.completedAt != nil }.count,
            totalSets: allSets.count,
            restEndsAt: timer.isRunning && !timer.isMicro ? timer.endsAt : nil,
            heartRate: LiveMetricsHub.shared.liveMetrics?.heartRate
        )
    }

    private func discard(_ workout: WorkoutModel) {
        WorkoutFinisher.discard(workout, in: modelContext)
    }

    private func runPendingStart() {
        appState.pendingWorkoutStart?()
        appState.pendingWorkoutStart = nil
    }

    @MainActor
    private func importHealthWorkoutHistory() async {
        guard HealthService.shared.isAvailable else { return }
        if let lastHealthWorkoutImportAt,
           Date().timeIntervalSince(lastHealthWorkoutImportAt) < 300 {
            return
        }
        lastHealthWorkoutImportAt = Date()
        _ = await HealthWorkoutImporter.shared.importRecent(in: modelContext)
    }

    // MARK: - Launch data seeding

    @MainActor
    private func seedLaunchData() async {
        do {
            let forcedReset = ProcessInfo.processInfo.arguments.contains("--reset-store")
            if forcedReset {
                try AccountResetService.deleteAllLocalModels(in: modelContext)
            }
            // Version-gated: re-materializing the whole library (+ muscle
            // refinement over ~900 bundled seeds) on EVERY cold launch was
            // the single biggest time-to-interactive cost. `fetchCount` is a
            // cheap store-side COUNT.
            let storedVersion = UserDefaults.standard.integer(forKey: LaunchSeedPolicy.defaultsKey)
            let libraryCount = (try? modelContext.fetchCount(FetchDescriptor<ExerciseLibraryModel>())) ?? 0
            let needsSeed = LaunchSeedPolicy.shouldSeed(
                storedVersion: storedVersion,
                libraryCount: libraryCount,
                forcedReset: forcedReset
            )
            if needsSeed {
                try ExerciseSeedRepository.seedGlobalLibrary(in: modelContext)
                ExerciseCatalog.seed(into: modelContext)
                YogaPoseCatalog.seed(into: modelContext)
                // Drop yoga poses trimmed from the catalog (e.g. poses awaiting
                // real artwork) so users only ever see fully-illustrated poses.
                YogaPoseCatalog.pruneUnavailablePoses(into: modelContext)
            }
            // CloudKit can't enforce unique constraints, so re-seed/sync races
            // can leave several rows sharing one id — and sync races arrive on
            // ANY launch, not just seed launches. Dedup stays unconditional:
            // it's the cheap part of the old work (two fetches, no JSON decode,
            // no refinement) and it's the safety net.
            try ExerciseLibraryDeduplicator.removeDuplicates(in: modelContext)
            // The plan-store split migration and CloudKit sync can also leave
            // duplicate RoutineModel rows (same id, different SwiftData rows).
            // Cascade delete rules collapse child exercises/sets automatically.
            try RoutineDeduplicator.removeDuplicates(in: modelContext)
            if shouldSeedStarterContent {
                try seedStarterSetupNote()
                try seedStarterRoutine()
            }
            // Stamp AFTER everything succeeded, so a thrown seed retries next
            // launch instead of being skipped forever.
            if needsSeed {
                UserDefaults.standard.set(LaunchSeedPolicy.currentVersion, forKey: LaunchSeedPolicy.defaultsKey)
            }
        } catch {
            assertionFailure("Launch data seed failed: \(error)")
        }
    }

    private var isAutomationLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--reset-store")
            || UserDefaults.standard.string(forKey: "initialTab") != nil
            || UserDefaults.standard.bool(forKey: "autoStartRoutine")
            || ProcessInfo.processInfo.arguments.contains("--auto-start-routine")
    }

    private var shouldSeedStarterContent: Bool {
        isAutomationLaunch || ProcessInfo.processInfo.arguments.contains("--seed-starter-content")
    }

    private func clearStarterSlate() {
        do {
            for workout in try modelContext.fetch(FetchDescriptor<WorkoutModel>())
            where workout.endedAt == nil || workout.id == ForgeFitDemo.starterRoutineID {
                modelContext.delete(workout)
            }

            let starterRoutineID = ForgeFitDemo.starterRoutineID
            let starterRoutines = try modelContext.fetch(
                FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == starterRoutineID })
            )
            for routine in starterRoutines {
                modelContext.delete(routine)
            }

            let demoUserID = ForgeFitDemo.userID
            let notes = try modelContext.fetch(
                FetchDescriptor<UserExerciseNoteModel>(predicate: #Predicate { $0.userID == demoUserID })
            )
            for note in notes {
                modelContext.delete(note)
            }

            try modelContext.save()
        } catch {
            assertionFailure("Failed to clear onboarding starter slate: \(error)")
        }
    }

    private func handleAccountReset() {
        appState.selectedTab = .home
        appState.showingLogger = false
        appState.pendingWorkoutStart = nil
        cleanedOnboardingSlate = false
        lastHealthWorkoutImportAt = nil
        showOnboarding = true
        themeManager.mode = .dark
        updateWidgetSnapshot()
    }

    private func seedStarterRoutine() throws {
        let routineID = ForgeFitDemo.starterRoutineID
        var descriptor = FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == routineID })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return }

        let firstTarget = RoutineSetModel(
            id: ForgeFitDemo.starterRoutineSetID,
            userID: ForgeFitDemo.userID,
            position: 0,
            targetRepsLow: 8,
            targetRepsHigh: 12,
            targetWeight: 70,
            targetRPE: 8
        )
        let routineExercise = RoutineExerciseModel(
            id: ForgeFitDemo.starterRoutineExerciseID,
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            sets: [firstTarget]
        )
        let routine = RoutineModel(
            id: ForgeFitDemo.starterRoutineID,
            userID: ForgeFitDemo.userID,
            name: "Full Body A",
            notes: "Starter routine",
            position: 0,
            exercises: [routineExercise]
        )

        modelContext.insert(routine)
        try modelContext.save()
    }

    private func seedStarterSetupNote() throws {
        let noteID = ForgeFitDemo.machinePressNoteID
        var descriptor = FetchDescriptor<UserExerciseNoteModel>(predicate: #Predicate { $0.id == noteID })
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return }

        let note = UserExerciseNoteModel(
            id: noteID,
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            note: "Keep shoulder blades pinned before the first rep.",
            seatHeight: "4",
            grip: "Neutral",
            stance: "Feet planted"
        )
        modelContext.insert(note)
        try modelContext.save()
    }
}

/// Watches the live heart-rate stream in a zero-sized view so the Observation
/// dependency registers HERE, not on whatever view embeds it — the embedder
/// stays out of the per-second re-render path while still getting callbacks.
private struct LiveHeartRateObserver: View {
    var hub = LiveMetricsHub.shared
    let onChange: (Int?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: hub.liveMetrics?.heartRate) { _, heartRate in
                onChange(heartRate)
            }
    }
}

private struct BootSplashView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            ScreenBackground()

            VStack(spacing: Space.xl) {
                ZStack {
                    Circle()
                        .fill(theme.accentSoft)
                        .frame(width: 92, height: 92)

                    Circle()
                        .stroke(theme.accent.opacity(0.38), lineWidth: 1)
                        .frame(width: 92, height: 92)

                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(theme.accent)
                }

                VStack(spacing: Space.sm) {
                    Text("ForgeFit")
                        .font(.screenTitle)
                        .foregroundStyle(theme.textPrimary)

                    Text("Loading your training")
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                }

                ProgressView()
                    .tint(theme.accent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, Space.xxl)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ForgeFit is loading")
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
}
