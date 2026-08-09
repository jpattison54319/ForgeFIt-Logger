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
    /// Import completion hands the Workout tab an ID instead of a model from
    /// another ModelContext; the tab resolves it after its @Query refreshes.
    var pendingRoutineDetailID: UUID?

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

/// Expensive history/Health maintenance is useful on an idle foreground, but
/// it must never compete with the live logger for the first interactive frames
/// after an app switch.
enum LiveWorkoutLifecyclePolicy {
    static func shouldRunForegroundMaintenance(hasActiveWorkout: Bool) -> Bool {
        !hasActiveWorkout
    }
}

private struct ExperimentWorkoutPrompt: Identifiable {
    var id: UUID { workout.id }
    let experiment: ExperimentModel
    let workout: WorkoutModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var themeManager: ThemeManager
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @Query(sort: \UserExerciseNoteModel.updatedAt, order: .reverse) private var setupNotes: [UserExerciseNoteModel]
    @Query(sort: \RoutineModel.position) private var routines: [RoutineModel]
    @Query(sort: \RoutineFolderModel.position) private var routineFolders: [RoutineFolderModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse) private var routineAlternations: [RoutineAlternationModel]
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var workouts: [WorkoutModel]
    @Query(filter: #Predicate<WorkoutModel> { $0.endedAt == nil && $0.deletedAt == nil }, sort: \WorkoutModel.startedAt, order: .reverse) private var activeWorkouts: [WorkoutModel]
    @Query(sort: \DailyCheckinModel.updatedAt, order: .reverse) private var checkins: [DailyCheckinModel]
    @Query(sort: \ExperimentModel.startedAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse) private var microcycleTrackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse) private var microcycleWindows: [MicrocycleWindowModel]

    @State private var appState = AppState()
    @State private var social = SocialService.make()
    @State private var restTimer = RestTimerController.shared
    @State private var intervalHub = IntervalRunnerHub.shared
    @State private var yogaHub = YogaFlowRunnerHub.shared
    @State private var showReplaceWorkoutConfirm = false
    @State private var workoutPendingDiscard: WorkoutModel?
    /// Mirrors the quick-action fan's open state (via `onExpandedChange`) so
    /// the shell can show the tap-outside scrim behind it.
    @State private var quickActionsExpanded = false
    /// Bumped by a scrim tap to ask the fan to collapse itself.
    @State private var quickActionsCollapseSignal = 0
    /// Bumped when the editor dismisses (and on account reset) so the bubble
    /// re-reads its store — the dotted preference key defeats UserDefaults
    /// KVO, so @AppStorage-style live observation can't do this.
    @State private var quickActionsReloadToken = 0
    @State private var showQuickActionsEditor = false
    @State private var showLogWeightSheet = false
    @State private var cleanedOnboardingSlate = false
    @State private var workoutCountReactionTask: Task<Void, Never>?
    @State private var readinessStampTask: Task<Void, Never>?
    @State private var liveSurfaceUpdateTask: Task<Void, Never>?
    @State private var structuralLiveSurfaceUpdateTask: Task<Void, Never>?
    @State private var planDeduplicationTask: Task<Void, Never>?
    @State private var pendingPlanMaintenance = false
    @State private var pendingPlanMaintenanceVersionStamp = false
    @State private var foregroundMaintenanceTask: Task<Void, Never>?
    @State private var experimentEndTask: Task<Void, Never>?
    @State private var microcycleTransitionTask: Task<Void, Never>?
    @State private var experimentWorkoutPrompt: ExperimentWorkoutPrompt?
    @State private var pendingPlanImport: PendingPlanImport?
    @State private var onboardingPlanImport: PendingPlanImport?
    @State private var planImportErrorMessage: String?
    @State private var onboardingPlanImportErrorMessage: String?
    @State private var lastLiveActivityHRPushAt = Date.distantPast
    @State private var didStartLaunchTasks = false
    @State private var didFinishLaunchTasks = false
    // Tabs that have been visited at least once. They stay mounted behind the
    // current tab (keep-resident) so their @State-held Memo caches survive —
    // switching back is instant instead of re-running full-history analytics in
    // `body`. Seeded lazily (only the first tab mounts at launch).
    @State private var mountedTabs: Set<AppTab> = []
    /// A tab-bar tap always means "show this tab's root", including a tap on
    /// the already-selected tab. Kept separate per tab so resetting one stack
    /// does not disturb the other resident tabs or their memoized analytics.
    @State private var tabRootRequestIDs: [AppTab: Int] = [:]
    /// True while the software keyboard is up — hides the floating tab bar /
    /// quick-action bubble so keyboard avoidance can't lift them into view.
    @State private var keyboardVisible = false
    /// A visible tab can temporarily yield the shared bottom chrome for a
    /// full-screen interaction such as direct routine reordering.
    @State private var screenHidesBottomChrome = false
    /// Local-log → cloud pipeline (backup + community). Built once the shell
    /// appears; see `SyncCoordinator`.
    @State private var syncCoordinator: SyncCoordinator?
    @State private var needsForcedLaunchSync = true
    // First launch only; UI-test launch hooks skip it.
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "didOnboard")
        && UserDefaults.standard.string(forKey: "initialTab") == nil
        && !UserDefaults.standard.bool(forKey: "autoStartRoutine")
        && !ProcessInfo.processInfo.arguments.contains("--auto-start-routine")
        && !ProcessInfo.processInfo.arguments.contains("--reset-store")

    private var activeWorkout: WorkoutModel? {
        activeWorkouts.first
    }

    private var experimentScheduleRevision: [String] {
        experiments.filter {
            $0.deletedAt == nil && $0.stateRaw == ExperimentLifecycleService.activeState
        }.map {
            "\($0.id.uuidString)|\($0.plannedEndAt.timeIntervalSinceReferenceDate)"
        }
    }

    private var microcycleEvaluationRevision: String {
        let liveTrackings = microcycleTrackings.filter { $0.deletedAt == nil }
        let latestTracking = liveTrackings.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let liveFolders = routineFolders.filter { $0.deletedAt == nil }
        let latestFolder = liveFolders.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let liveRoutines = routines.filter { $0.deletedAt == nil }
        let latestRoutine = liveRoutines.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let liveAlternations = routineAlternations.filter { $0.deletedAt == nil }
        let latestAlternation = liveAlternations.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let terminalWorkouts = workouts.filter { $0.endedAt != nil || $0.deletedAt != nil }
        let latestWorkout = terminalWorkouts.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        return "\(liveTrackings.count)|\(latestTracking)|\(microcycleWindows.count)|"
            + "\(liveFolders.count)|\(latestFolder)|\(liveRoutines.count)|\(latestRoutine)|"
            + "\(liveAlternations.count)|\(latestAlternation)|\(terminalWorkouts.count)|\(latestWorkout)"
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
        let latestAlternation = routineAlternations.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(routines.count)|\(latest)|\(routineAlternations.count)|\(latestAlternation)"
    }

    /// CloudKit imports can land after launch seeding has already performed
    /// its cleanup. Count + unique-count detects duplicate-id arrivals, while
    /// latest-update also catches a same-count remote replacement.
    private var planRowsVersion: String {
        let latestRoutine = routines.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let latestFolder = routineFolders.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let latestAlternation = routineAlternations.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(routines.count)|\(Set(routines.map(\.id)).count)|\(latestRoutine)|"
            + "\(routineFolders.count)|\(Set(routineFolders.map(\.id)).count)|\(latestFolder)|"
            + "\(routineAlternations.count)|\(latestAlternation)"
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
        appShell
            .environment(appState)
            .environment(social)
            .environment(\.theme, activeTheme)
            .preferredColorScheme(resolvedColorScheme)
            .tint(activeTheme.accent)
            .task {
                await social.bootstrap()
                // The sync pipeline: watches every SwiftData save and keeps
                // backup + community converged with the local log (see
                // SyncCoordinator). The forced launch pass publishes history
                // for accounts that opted in before backfill existed and
                // catches up anything done offline last session.
                if syncCoordinator == nil {
                    let coordinator = SyncCoordinator(social: social, container: modelContext.container)
                    coordinator.start()
                    syncCoordinator = coordinator
                }
                // Reconcile is a full local/remote history pass for opted-in
                // users. The foreground-maintenance lane owns it after the
                // first interaction window instead of startup owning it.
                if didFinishLaunchTasks, scenePhase == .active, activeWorkout == nil {
                    scheduleForegroundMaintenance()
                }
            }
            .fullScreenCover(isPresented: $appState.showingLogger) {
            if let activeWorkout = activeWorkoutForPresentation() {
                // No `injectedHistory:` — the logger snapshots history itself,
                // so the per-save re-fetch of `workouts` never hands the
                // logger a new array identity mid-session.
                if activeWorkout.conditioningPlanSnapshotJSON != nil && activeWorkout.blocks.isEmpty {
                    ConditioningWorkoutView(
                        workout: activeWorkout,
                        exercises: exercises,
                        onMinimize: { appState.showingLogger = false },
                        onFinished: { _ in
                            appState.showingLogger = false
                            Task { await syncCoordinator?.flushNow() }
                        }
                    )
                } else {
                    ActiveWorkoutLoggerView(
                        workout: activeWorkout,
                        exercises: exercises,
                        setupNotes: setupNotes,
                        onMinimize: { appState.showingLogger = false },
                        // The finish save already queued the share via the change
                        // feed; skipping the debounce makes it appear immediately.
                        onFinished: { _ in Task { await syncCoordinator?.flushNow() } }
                    )
                    .environment(social)
                }
            }
            }
            .fullScreenCover(isPresented: Binding(
                get: { isOnboardingCoverPresented },
                set: { showOnboarding = $0 }
            )) {
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
                    .sheet(item: $onboardingPlanImport) { pending in
                        PlanImportView(pending: pending, onSaved: handlePlanImportSaved)
                            .environment(\.theme, activeTheme)
                            .preferredColorScheme(resolvedColorScheme)
                    }
                    .alert(
                        "Couldn't open plan",
                        isPresented: Binding(
                            get: { onboardingPlanImportErrorMessage != nil },
                            set: { if !$0 { onboardingPlanImportErrorMessage = nil } }
                        )
                    ) { } message: {
                        Text(onboardingPlanImportErrorMessage ?? "")
                    }
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
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ExperimentNotificationRoute.openRequested
                )
            ) { _ in
                consumePendingExperimentNotificationRoute()
            }
            // Launch tasks perform the initial reconcile once. This handler is
            // only for a real schedule mutation; `initial: true` previously
            // duplicated synchronous SwiftData fetches during first render.
            .onChange(of: experimentScheduleRevision) {
                reconcileExperimentLifecycle()
            }
            .onChange(of: microcycleEvaluationRevision) {
                reconcileMicrocycleLifecycle()
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
            .onChange(of: completedWorkoutCount) { oldCount, newCount in
                handleCompletedWorkoutCountChange(oldCount: oldCount, newCount: newCount)
            }
            // Quick-action presentations live on this handler layer, not on
            // `presentedShell`'s already-at-budget modifier expression. Theme
            // is pinned explicitly, mirroring the onboarding cover.
            .sheet(isPresented: $showLogWeightSheet) {
                LogWeightSheet()
                    .environment(\.theme, activeTheme)
                    .preferredColorScheme(resolvedColorScheme)
            }
            .sheet(item: $experimentWorkoutPrompt) { prompt in
                ExperimentLogUpdateSheet(
                    experiment: prompt.experiment,
                    trackers: prompt.trackers,
                    entries: prompt.entries,
                    workoutID: prompt.workout.id,
                    initialDate: prompt.workout.startedAt
                )
                .environment(\.theme, activeTheme)
                .preferredColorScheme(resolvedColorScheme)
            }
            .sheet(item: $pendingPlanImport) { pending in
                PlanImportView(pending: pending, onSaved: handlePlanImportSaved)
                    .environment(\.theme, activeTheme)
                    .preferredColorScheme(resolvedColorScheme)
            }
            .alert(
                "Couldn't open plan",
                isPresented: Binding(
                    get: { planImportErrorMessage != nil },
                    set: { if !$0 { planImportErrorMessage = nil } }
                )
            ) { } message: {
                Text(planImportErrorMessage ?? "")
            }
            .fullScreenCover(
                isPresented: $showQuickActionsEditor,
                onDismiss: { quickActionsReloadToken += 1 }
            ) {
                quickActionsEditorCover
            }
    }

    private var quickActionsEditorCover: some View {
        NavigationStack {
            QuickActionsEditorView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showQuickActionsEditor = false }
                            .font(.bodyStrong)
                            .accessibilityIdentifier("quick-actions-editor-done")
                    }
                }
        }
        .environment(appState)
        .environment(\.theme, activeTheme)
        .preferredColorScheme(resolvedColorScheme)
    }

    private var shellRealtimeHandlers: some View {
        presentedShell
            // Fresh opt-in flips status to .active — publish the user's
            // existing history right then, not on the next launch.
            .onChange(of: social.status) { _, status in
                guard status == .active else { return }
                Task { await syncCoordinator?.syncNow(force: true) }
            }
            .onChange(of: showOnboarding) { _, isPresented in handleOnboardingPresentationChange(isPresented) }
            .onChange(of: appState.startRequestID) { _, requestID in handleStartRequestChange(requestID) }
            .onChange(of: routineListVersion) {
                WatchLink.shared.invalidateRoutineSummaryCache()
                WatchLink.shared.publishState()
            }
            .onChange(of: planRowsVersion) {
                guard hasDuplicatePlanRows else { return }
                schedulePlanDeduplication()
            }
            .onChange(of: exercises.count) { schedulePlanDeduplication() }
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

            quickActionsScrim
                .opacity(bottomChromeHidden ? 0 : 1)
                .allowsHitTesting(!bottomChromeHidden)

            VStack(spacing: Space.sm) {
                // The quick-action bubble and the mini bar never coexist: an
                // active workout owns the band above the tab bar, and most
                // bubble actions are workout starts anyway. The two hand over
                // (workout start/finish) with a keyed swap animation so one
                // floating element doesn't hard-cut into the other.
                if activeWorkout == nil {
                    quickActionsBubbleRow
                        .transition(Motion.scaleIn(0.8, anchor: .bottomTrailing, reduceMotion: reduceMotion))
                }
                if let activeWorkout {
                    MiniWorkoutBar(
                        workout: activeWorkout,
                        exercises: exercises,
                        onExpand: { appState.showingLogger = true },
                        onDiscard: { workoutPendingDiscard = activeWorkout }
                    )
                    .padding(.horizontal, Space.lg)
                    .transition(Motion.riseIn(reduceMotion: reduceMotion))
                }
                ForgeTabBar(selection: $appState.selectedTab, onSelect: selectTab)
            }
            .animation(reduceMotion ? Motion.reduced : Motion.entrance, value: activeWorkout == nil)
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
            // Belt to the exemption's suspenders: on a pushed editor
            // (RoutineEditorView) SwiftUI's automatic keyboard avoidance was
            // lifting this whole layer — tab bar + quick-action bubble — into a
            // black gap above the keyboard anyway. Behind the keyboard it's
            // unusable, so hide it outright while editing; it can't be raised
            // into view if it isn't drawn.
            .opacity(bottomChromeHidden ? 0 : 1)
            .allowsHitTesting(!bottomChromeHidden)
            .animation(reduceMotion ? Motion.reduced : Motion.stateChange, value: bottomChromeHidden)
        }
        .onKeyboardVisibilityChange($keyboardVisible)
        .onPreferenceChange(BottomChromeHiddenPreferenceKey.self) {
            screenHidesBottomChrome = $0
        }
    }

    private var bottomChromeHidden: Bool {
        keyboardVisible || screenHidesBottomChrome
    }

    /// Dimmed tap-catcher behind the open quick-action fan: above the tab
    /// screens, below the bar stack, so a background tap collapses the fan
    /// while the tab bar stays undimmed and usable.
    @ViewBuilder
    private var quickActionsScrim: some View {
        if quickActionsExpanded {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { quickActionsCollapseSignal += 1 }
                .transition(.opacity)
                .accessibilityLabel("Dismiss quick actions")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("quick-actions-scrim")
        }
    }

    /// Bottom-trailing slot for the bubble, one row above the tab bar. The
    /// transparent remainder of the row has no background or content shape,
    /// so taps left of the trigger fall through to the tab screens.
    private var quickActionsBubbleRow: some View {
        QuickActionsBubble(
            routines: routines,
            exercises: exercises,
            setupNotes: setupNotes,
            collapseSignal: quickActionsCollapseSignal,
            reloadToken: quickActionsReloadToken,
            onExpandedChange: { expanded in
                // Scrim keeps pace with the fan: eased in alongside the fan's
                // ~0.5 s bouncy birth, dropped fast to match its quick
                // retraction springs.
                withAnimation(expanded ? Motion.entrance : Motion.tap) { quickActionsExpanded = expanded }
            },
            onOpenEditor: {
                showQuickActionsEditor = true
            },
            onLogBodyweight: { showLogWeightSheet = true }
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, Space.xl)
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
                        .environment(\.tabRootRequestID, tabRootRequestIDs[tab, default: 0])
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

    private func selectTab(_ tab: AppTab) {
        tabRootRequestIDs[tab, default: 0] &+= 1
        guard appState.selectedTab != tab else { return }
        withAnimation(.bouncy(duration: 0.42, extraBounce: 0.06)) {
            appState.selectedTab = tab
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
        // The watch publish is NOT repeated here: RestTimerController's
        // onStateChange hook (wired in WatchLink.configure) already pushes a
        // forced publish on every start/adjust/skip/end. Publishing here too
        // doubled the SwiftData-fetch + WCSession-serialize cost on the main
        // thread at exactly the moments a lifter starts scrolling.
        // Structural external surfaces may trail local feedback by 500 ms.
        // Coalescing keeps ActivityKit, widget writes, and timeline reloads out
        // of the completion gesture's run-loop turn.
        scheduleStructuralLiveSurfaceUpdate()
    }

    private func scheduleStructuralLiveSurfaceUpdate() {
        structuralLiveSurfaceUpdateTask?.cancel()
        structuralLiveSurfaceUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            structuralLiveSurfaceUpdateTask = nil
            publishStructuralLiveSurfacesNow()
        }
    }

    private func publishStructuralLiveSurfacesNow() {
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
        updateWidgetSnapshot()
    }

    private func flushStructuralLiveSurfaceUpdate() {
        structuralLiveSurfaceUpdateTask?.cancel()
        structuralLiveSurfaceUpdateTask = nil
        publishStructuralLiveSurfacesNow()
    }

    private func handleTodayCheckinChange() {
        guard activeWorkout == nil else { return }
        updateWidgetSnapshot()
        WatchLink.shared.publishState(force: true)
        ReadinessDelivery.shared.refreshMorningNotification()
    }

    private func handleCompletedWorkoutCountChange(oldCount: Int, newCount: Int) {
        workoutCountReactionTask?.cancel()
        workoutCountReactionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            updateWidgetSnapshot()
            WatchLink.shared.invalidateRoutineSummaryCache()
            WatchLink.shared.publishState()

            guard newCount > oldCount else { return }
            for _ in 0..<8 where appState.showingLogger {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard !appState.showingLogger, scenePhase == .active else { return }
            experimentWorkoutPrompt = makeExperimentWorkoutPrompt()
        }
    }

    /// A per-workout tracker belongs to the workout's start instant, matching
    /// the exact `[start, end)` membership used by results and comparisons.
    /// The short recency gate prevents a bulk Health history import from
    /// presenting a stale check-in during launch.
    private func makeExperimentWorkoutPrompt(now: Date = .now) -> ExperimentWorkoutPrompt? {
        let recentCutoff = now.addingTimeInterval(-10 * 60)
        let completedCandidates = workouts.filter {
            $0.deletedAt == nil
                && $0.endedAt != nil
                && ($0.endedAt ?? Date.distantPast) >= recentCutoff
        }
        guard let workout = completedCandidates.max(by: {
            ($0.endedAt ?? Date.distantPast) < ($1.endedAt ?? Date.distantPast)
        }) else { return nil }

        do {
            _ = try ExperimentLifecycleService.reconcile(in: modelContext, now: now)
            let experiment = try modelContext.fetch(
                FetchDescriptor<ExperimentModel>(
                    sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
                )
            )
            .first {
                $0.deletedAt == nil
                    && workout.startedAt >= $0.startedAt
                    && workout.startedAt < ($0.endedAt ?? $0.plannedEndAt)
            }
            guard let experiment else { return nil }

            let trackers = try modelContext.fetch(FetchDescriptor<ExperimentTrackerModel>())
                .filter {
                    $0.experimentID == experiment.id
                        && $0.deletedAt == nil
                        && $0.cadence == .perWorkout
                }
                .sorted { $0.position < $1.position }
            guard !trackers.isEmpty else { return nil }

            let entries = try modelContext.fetch(FetchDescriptor<ExperimentEntryModel>())
                .filter {
                    $0.experimentID == experiment.id && $0.deletedAt == nil
                }
            let alreadyLoggedTrackerIDs = Set(entries.compactMap { entry -> UUID? in
                entry.workoutID == workout.id ? entry.trackerID : nil
            })
            let pendingTrackers = trackers.filter { !alreadyLoggedTrackerIDs.contains($0.id) }
                .filter {
                    workout.startedAt >= $0.createdAt
                        && workout.startedAt < ($0.archivedAt ?? experiment.endedAt
                            ?? experiment.plannedEndAt)
                }
            guard !pendingTrackers.isEmpty else { return nil }
            return ExperimentWorkoutPrompt(
                experiment: experiment,
                workout: workout,
                trackers: pendingTrackers,
                entries: entries
            )
        } catch {
            return nil
        }
    }

    /// CloudKit may deliver several related rows in a short burst. Debounce the
    /// cleanup so one pass handles the batch; a resulting query change is safe
    /// because the follow-up pass is idempotent and performs no save.
    private var hasDuplicatePlanRows: Bool {
        routines.count != Set(routines.map(\.id)).count
            || routineFolders.count != Set(routineFolders.map(\.id)).count
    }

    private func scheduleLaunchPlanMaintenanceIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(
            forKey: PlanMaintenancePolicy.defaultsKey
        )
        guard PlanMaintenancePolicy.needsLaunchAudit(
            storedVersion: storedVersion
        ) else { return }
        schedulePlanDeduplication(stampLaunchAudit: true)
    }

    private func schedulePlanDeduplication(stampLaunchAudit: Bool = false) {
        pendingPlanMaintenance = true
        pendingPlanMaintenanceVersionStamp = pendingPlanMaintenanceVersionStamp
            || stampLaunchAudit
        planDeduplicationTask?.cancel()
        planDeduplicationTask = nil
        guard scenePhase == .active, activeWorkout == nil else { return }

        let worker = PlanMaintenanceWorker(modelContainer: modelContext.container)
        planDeduplicationTask = Task { @MainActor in
            // Debounce CloudKit batches. The scan itself runs on the worker's
            // private context, so this delay is coalescing rather than an
            // attempt to hide main-thread work later in the launch.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  scenePhase == .active,
                  activeWorkout == nil else { return }
            do {
                _ = try await worker.removeDuplicates()
                guard !Task.isCancelled else { return }
                pendingPlanMaintenance = false
                if pendingPlanMaintenanceVersionStamp {
                    UserDefaults.standard.set(
                        PlanMaintenancePolicy.currentVersion,
                        forKey: PlanMaintenancePolicy.defaultsKey
                    )
                    pendingPlanMaintenanceVersionStamp = false
                }
            } catch is CancellationError {
                return
            } catch {
                assertionFailure("Plan deduplication after CloudKit change failed: \(error)")
            }
            planDeduplicationTask = nil
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
        if url.pathExtension.lowercased() == "forgefitplan" {
            receivePlanFile(url)
            return
        }
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
        case "experiment":
            guard let experimentID = url.pathComponents.dropFirst()
                .first
                .flatMap(UUID.init) else {
                appState.selectedTab = .insights
                return
            }
            UserDefaults.standard.set(
                experimentID.uuidString,
                forKey: ExperimentNotificationRoute.pendingExperimentIDDefaultsKey
            )
            appState.selectedTab = .insights
            NotificationCenter.default.post(
                name: ExperimentNotificationRoute.routeReady,
                object: nil
            )
        case "u":   // forgefit://u/<handle> — visit a friend's profile
            if FeatureFlags.social, let handle = SocialLinks.handle(from: url) {
                social.pendingFollowHandle = handle
                appState.selectedTab = .profile
            }
        case "start":
            let routineID = url.pathComponents.dropFirst().first.flatMap(UUID.init)
            if let routineID,
               let routine = routines.first(where: { $0.id == routineID && $0.deletedAt == nil && $0.archivedAt == nil && !$0.exercises.isEmpty }) {
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

    private func receivePlanFile(_ url: URL) {
        guard url.pathExtension.lowercased() == "forgefitplan" else { return }
        do {
            let plan = try PlanImportService.load(from: url)
            if isOnboardingCoverPresented {
                onboardingPlanImport = plan
            } else {
                pendingPlanImport = plan
            }
        } catch {
            if isOnboardingCoverPresented {
                onboardingPlanImportErrorMessage = error.localizedDescription
            } else {
                planImportErrorMessage = error.localizedDescription
            }
        }
    }

    private func handlePlanImportSaved(_ result: PlanImportService.ImportResult) {
        appState.pendingRoutineDetailID = result.routineIDs.first
        appState.selectedTab = .workout
        pendingPlanImport = nil
        onboardingPlanImport = nil
    }

    private var isOnboardingCoverPresented: Bool {
        #if DEBUG
        showOnboarding && !ProcessInfo.processInfo.arguments.contains("--skip-onboarding")
        #else
        showOnboarding
        #endif
    }

    private func consumePendingExperimentNotificationRoute() {
        guard let rawURL = UserDefaults.standard.string(
            forKey: ExperimentNotificationRoute.pendingURLDefaultsKey
        ), let url = URL(string: rawURL) else {
            return
        }
        UserDefaults.standard.removeObject(
            forKey: ExperimentNotificationRoute.pendingURLDefaultsKey
        )
        handleDeepLink(url)
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
            reconcileLiveRuntimeOwnership()
            reconcileExperimentLifecycle()
            reconcileMicrocycleLifecycle()
            BackupScheduler.shared.resumeAfterForeground()
            NotificationScheduler.shared.refreshStatus()
            updateWidgetSnapshot()

            if LiveWorkoutLifecyclePolicy.shouldRunForegroundMaintenance(
                hasActiveWorkout: activeWorkout != nil
            ) {
                scheduleForegroundMaintenance()
                scheduleLaunchPlanMaintenanceIfNeeded()
                if pendingPlanMaintenance, planDeduplicationTask == nil {
                    schedulePlanDeduplication()
                }
            } else {
                foregroundMaintenanceTask?.cancel()
                foregroundMaintenanceTask = nil
            }
        } else if phase == .background {
            experimentEndTask?.cancel()
            experimentEndTask = nil
            microcycleTransitionTask?.cancel()
            microcycleTransitionTask = nil
            planDeduplicationTask?.cancel()
            planDeduplicationTask = nil
            foregroundMaintenanceTask?.cancel()
            foregroundMaintenanceTask = nil
            // Leave the widget with the freshest snapshot we have — otherwise it
            // would serve whatever it last read until the next app open.
            flushStructuralLiveSurfaceUpdate()
            WatchLink.shared.publishState(policy: .immediate)
            // Training data is already durable in SwiftData. A full-history
            // iCloud projection here can be suspended mid-snapshot and resume
            // over the logger's first foreground frames, so keep it deferred
            // until the app is idle and no workout is live.
            BackupScheduler.shared.pauseForBackground()
        }
    }

    /// Let the foreground draw and accept input before starting maintenance.
    /// The work is deliberately serialized so Health/store passes do not all
    /// converge on the main actor in the same frame.
    private func scheduleForegroundMaintenance() {
        guard didFinishLaunchTasks else { return }
        foregroundMaintenanceTask?.cancel()
        foregroundMaintenanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled, activeWorkout == nil else { return }

            await HealthMetricsStore.shared.refreshIfStaleNow()
            guard !Task.isCancelled, activeWorkout == nil else { return }

            await importHealthWorkoutHistory()
            guard !Task.isCancelled, activeWorkout == nil else { return }

            let forceSocialSync = needsForcedLaunchSync
            await syncCoordinator?.syncNow(force: forceSocialSync)
            if syncCoordinator != nil {
                needsForcedLaunchSync = false
            }
            guard !Task.isCancelled, activeWorkout == nil else { return }

            // Check due-state before loading report inputs (the service lazily
            // builds only when a report is actually missing or refreshable).
            await generateWrappedIfDue()
            updateWidgetSnapshot()
            foregroundMaintenanceTask = nil
        }
    }

    /// Wrapped generation is launch/foreground-driven (idempotent, keyed by
    /// period — cheap when nothing is due). A newly created report gets the
    /// one-shot "ready" notification; the Home card appears either way.
    private func generateWrappedIfDue() async {
        let worker = WrappedReportWorker(modelContainer: modelContext.container)
        let created = await worker.generateIfDue(
            healthMetrics: HealthMetricsStore.shared.metrics,
            weightUnit: Fmt.unit
        )
        if let newest = created.first {
            NotificationScheduler.shared.scheduleWrappedReady(
                reportTitle: newest.title
            )
        }
    }

    private func handleActiveWorkoutChange(oldID: UUID?, newID: UUID?) {
        structuralLiveSurfaceUpdateTask?.cancel()
        structuralLiveSurfaceUpdateTask = nil
        BackupScheduler.shared.setLiveWorkoutActive(newID != nil)
        if newID != nil {
            planDeduplicationTask?.cancel()
            planDeduplicationTask = nil
            foregroundMaintenanceTask?.cancel()
            foregroundMaintenanceTask = nil
        } else if scenePhase == .active {
            reconcileMicrocycleLifecycle()
            scheduleForegroundMaintenance()
            if pendingPlanMaintenance || hasDuplicatePlanRows {
                schedulePlanDeduplication()
            }
        }
        WatchLink.shared.publishState(policy: .immediate)
        if newID == nil {
            // Backstop for externally removed workouts. Normal finish/discard
            // paths already send their more specific terminal command.
            WatchLink.shared.sendCommand(.workoutFinished)
            readinessStampTask?.cancel()
            liveSurfaceUpdateTask?.cancel()
            WorkoutFinisher.cancelLiveRuntime()
        } else {
            CardioRouteRecorder.shared.cancelIfOrphaned(
                validSessionIDs: activeLiveCardioSessionIDs()
            )
            // A workout can start from the watch or a deep link while the
            // quick-action fan is open; the bubble unmounts with the fan, so
            // it can never report the collapse — clear the scrim here.
            quickActionsExpanded = false
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

    private func reconcileLiveRuntimeOwnership() {
        guard activeWorkout != nil else {
            WorkoutFinisher.cancelLiveRuntime()
            return
        }
        CardioRouteRecorder.shared.cancelIfOrphaned(
            validSessionIDs: activeLiveCardioSessionIDs()
        )
    }

    private func activeLiveCardioSessionIDs() -> Set<UUID> {
        guard let activeWorkout else { return [] }
        return Set(activeWorkout.cardioSessions.compactMap { session in
            guard session.deletedAt == nil,
                  session.endedAt == nil,
                  session.liveStartedAt != nil else { return nil }
            return session.id
        })
    }

    private func scheduleReadinessStamp(for workout: WorkoutModel, delayMilliseconds: Int) {
        readinessStampTask?.cancel()
        readinessStampTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled,
                  !appState.showingLogger,
                  workout.deletedAt == nil,
                  workout.readinessAtStart == nil else { return }
            if ReadinessSurfacePublisher.applyCachedStart(to: workout) {
                try? modelContext.save()
            }
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

        await launchTasks()
        didFinishLaunchTasks = true
        scheduleLaunchPlanMaintenanceIfNeeded()

        if scenePhase == .active, activeWorkout == nil {
            scheduleForegroundMaintenance()
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
        // Cold-launch dashboard automation: freeze the pre-refresh state, then
        // stage the snapshot store so the same-day-cache and first-open-of-day
        // paths render deterministically.
        if ProcessInfo.processInfo.arguments.contains("--suppress-health-refresh") {
            HealthMetricsStore.shared.suppressRefreshForTesting()
        }
        if ProcessInfo.processInfo.arguments.contains("--seed-home-dashboard-cache") {
            RecoverySnapshotStore.shared.seedTodayDashboardDemo()
        }
        if ProcessInfo.processInfo.arguments.contains("--seed-yesterday-dashboard-cache") {
            RecoverySnapshotStore.shared.removeAllForTesting()
            RecoverySnapshotStore.shared.seedYesterdayDashboardDemo()
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
            BLEHeartRateService.shared.reconnectIfRemembered()
        }
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
        WeightModeBackfill.convertIfNeeded(in: modelContext)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-wrapped-demo") {
            WrappedDemoSeed.run(in: modelContext)
        }
        // Hearts demo: plant friends' hearts on existing share-eligible
        // workouts. Seeded at launch rather than on publish so the row is
        // visible immediately in the simulator (and to screenshot
        // automation) without having to finish a live workout first.
        if ProcessInfo.processInfo.arguments.contains("--seed-social-hearts") {
            let eligible = ((try? modelContext.fetch(
                FetchDescriptor<WorkoutModel>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
            )) ?? []).filter(SocialBackfill.isEligible)
            await social.seedDemoHearts(workoutIDs: eligible.prefix(12).map(\.id))
        }
        #endif
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
        // No-ops when a demo seed is active (see HealthMetricsStore.refresh).
        HealthMetricsStore.shared.refresh()
        consumePendingExperimentNotificationRoute()
        CyclePreferenceMigration.migrate()
        reconcileExperimentLifecycle()
        reconcileMicrocycleLifecycle()
        ReadinessDelivery.shared.configure(container: modelContext.container)
        BackupScheduler.shared.configure(container: modelContext.container)
        BackupScheduler.shared.setLiveWorkoutActive(activeWorkout != nil)
        BackupScheduler.shared.dailyCheckIfDue()
        updateWidgetSnapshot()
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
    }

    /// Scheduled experiment endings are date truth, not notification truth:
    /// iOS may never wake the process at the exact end instant. Materialize
    /// expired rows whenever the app becomes usable, then rebuild the one
    /// active experiment's bounded reminder set.
    private func reconcileExperimentLifecycle() {
        experimentEndTask?.cancel()
        experimentEndTask = nil
        do {
            _ = try ExperimentLifecycleService.reconcile(in: modelContext)
            guard let active = try ExperimentLifecycleService.activeExperiment(in: modelContext) else {
                return
            }
            let trackers = try modelContext.fetch(FetchDescriptor<ExperimentTrackerModel>())
                .filter { $0.experimentID == active.id && $0.deletedAt == nil && $0.archivedAt == nil }
            let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
                experiment: active,
                trackers: trackers
            )
            Task {
                _ = await ExperimentNotificationScheduler.schedule(
                    notificationSchedule
                )
            }
            let experimentID = active.id
            let wait = active.plannedEndAt.timeIntervalSinceNow
            guard wait > 0 else { return }
            experimentEndTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let stillActive = try? ExperimentLifecycleService.activeExperiment(
                    in: modelContext,
                    now: .now
                )
                guard stillActive?.id == experimentID
                        || stillActive == nil else {
                    return
                }
                experimentEndTask = nil
                reconcileExperimentLifecycle()
            }
        } catch {
            // A lifecycle refresh must never block launch or foreground. The
            // active/results surfaces retry through their own model queries.
        }
    }

    /// Fixed windows are calendar truth. Reconcile on launch, foreground, and
    /// relevant plan/workout changes, then wake once at the next boundary.
    private func reconcileMicrocycleLifecycle() {
        microcycleTransitionTask?.cancel()
        microcycleTransitionTask = nil
        do {
            _ = try MicrocycleTrackingService.reconcile(in: modelContext)
            guard let transition = try MicrocycleTrackingService.nextTransitionDate(
                in: modelContext
            ) else { return }
            let wait = transition.timeIntervalSinceNow
            guard wait > 0 else { return }
            microcycleTransitionTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(wait))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                microcycleTransitionTask = nil
                reconcileMicrocycleLifecycle()
            }
        } catch {
            // Tracking is derived from durable folders and workouts. Surfaces
            // retry through their queries if a launch-time fetch is unavailable.
        }
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
        if let activeWorkout {
            ReadinessSurfacePublisher.publish(activeWorkoutSnapshot(activeWorkout))
        } else if let dashboard = ReadinessSurfacePublisher.currentDashboard() {
            ReadinessSurfacePublisher.publish(
                ReadinessSurfacePublisher.idleSnapshot(from: dashboard)
            )
        } else {
            // Never carry yesterday's readiness into a new day, and never
            // block launch to replace it. Home publishes today's completed
            // background result when it becomes available.
            ReadinessSurfacePublisher.publish(ForgeFitWidgetSnapshot(mode: .idle))
        }
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
        _ = await HealthWorkoutImporter.shared.importRecentIfDue(
            in: modelContext.container
        )
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
            // CloudKit duplicate cleanup is intentionally not performed here.
            // It scans the full ~900-row plan store on a private worker after
            // launch, and later re-runs only when query counts reveal a remote
            // row arrival. MainActor launch seeding never pays that audit cost.
            if shouldSeedStarterContent {
                try seedStarterSetupNote()
                try seedStarterRoutine()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--seed-quick-increment-history") {
                try QuickIncrementUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-block-prefill-history") {
                try BlockPrefillUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-experiment-demo") {
                try ExperimentDemoSeed.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-routine-reorder") {
                try RoutineReorderUITestFixture.seed(in: modelContext)
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--seed-history") {
                try seedHistoryFixtures()
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

    /// `--seed-history`: a deterministic 14-month training history — 120
    /// sessions of push/pull/legs rotation with progressing loads (so PRs
    /// exist), runs with heart rate, yoga, sparse RPE, notes, and a few
    /// import-flagged sessions — so UI tests and simulator walkthroughs of
    /// the History screen have real volume to search, filter, and paginate.
    /// Idempotent per store; test-launch plumbing, never a user path.
    private func seedHistoryFixtures() throws {
        let probeTitle = "Push Day #120"
        var probe = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.title == probeTitle })
        probe.fetchLimit = 1
        guard try modelContext.fetch(probe).isEmpty else { return }

        let userID = ForgeFitDemo.userID
        let now = Date()
        struct Lift {
            let exerciseID: UUID
            let base: Double
        }
        let splits: [(title: String, lifts: [Lift])] = [
            ("Push Day", [
                Lift(exerciseID: GlobalExerciseLibrary.machineChestPressID, base: 60),
                Lift(exerciseID: GlobalExerciseLibrary.overheadCableTricepsExtensionID, base: 25),
            ]),
            ("Pull Day", [
                Lift(exerciseID: GlobalExerciseLibrary.chestSupportedTBarRowID, base: 50),
                Lift(exerciseID: GlobalExerciseLibrary.bayesianCableCurlID, base: 15),
            ]),
            ("Leg Day", [
                Lift(exerciseID: GlobalExerciseLibrary.smithMachineSquatID, base: 80),
                Lift(exerciseID: GlobalExerciseLibrary.romanianDeadliftID, base: 70),
            ]),
        ]

        for i in 0..<120 {
            let sessionNumber = 120 - i
            let start = now.addingTimeInterval(-Double(i) * 3.5 * 86_400 - 5 * 3_600)
            let workout: WorkoutModel

            if i % 4 == 3 {
                let isYoga = i % 12 == 11
                // Live-logged cardio always carries an exercise row with the
                // session linked to it; the fixture mirrors that so history
                // editing renders the cardio card. Treadmill = no GPS, no
                // distance — the "add the machine's distance later" case.
                let cardioRow = isYoga ? nil : WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: GlobalExerciseLibrary.treadmillRunID,
                    position: 0
                )
                let session = CardioSessionModel(
                    userID: userID,
                    workoutExerciseID: cardioRow?.id,
                    modality: isYoga ? CardioSessionModel.yogaModality : CardioKind.run.rawValue,
                    startedAt: start,
                    endedAt: start.addingTimeInterval(2_100),
                    durationSeconds: 1_800 + (i % 4) * 300,
                    avgHR: isYoga ? nil : 148 + (i % 20),
                    yogaStyleRaw: isYoga ? "vinyasa" : nil
                )
                workout = WorkoutModel(
                    userID: userID,
                    title: isYoga ? "Yoga Flow #\(sessionNumber)" : "Morning Run #\(sessionNumber)",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(2_100),
                    exercises: cardioRow.map { [$0] } ?? [],
                    cardioSessions: [session]
                )
            } else {
                let split = splits[i % 4]
                // Loads rise toward the present, so chronologically each bump
                // is a fresh PR and the PR filter has hits in every era.
                let progression = Double((120 - i) / 8) * 2.5
                let workoutExercises = split.lifts.enumerated().map { position, lift in
                    let sets = (0..<3).map { setIndex in
                        SetModel(
                            userID: userID,
                            position: setIndex,
                            setType: .working,
                            reps: 8 + setIndex,
                            weight: lift.base + progression,
                            rpe: i % 5 == 0 ? nil : 8,
                            completedAt: start.addingTimeInterval(Double(600 + position * 900 + setIndex * 180))
                        )
                    }
                    return WorkoutExerciseModel(userID: userID, exerciseID: lift.exerciseID, position: position, sets: sets)
                }
                workout = WorkoutModel(
                    userID: userID,
                    title: "\(split.title) #\(sessionNumber)",
                    startedAt: start,
                    endedAt: start.addingTimeInterval(3_900),
                    exercises: workoutExercises
                )
                workout.recomputeTotalVolume()
            }
            if i % 9 == 0 { workout.notes = "Felt strong today — belt on top sets." }
            if i % 10 == 7 { workout.externalSource = "hevy" }
            modelContext.insert(workout)
        }
        try modelContext.save()
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
            WorkoutFinisher.cancelLiveRuntime()
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
        microcycleTransitionTask?.cancel()
        microcycleTransitionTask = nil
        appState.selectedTab = .home
        appState.showingLogger = false
        appState.pendingRoutineDetailID = nil
        pendingPlanImport = nil
        onboardingPlanImport = nil
        planImportErrorMessage = nil
        onboardingPlanImportErrorMessage = nil
        appState.pendingWorkoutStart = nil
        quickActionsReloadToken += 1
        InsightDataCoordinator.shared.invalidate()
        cleanedOnboardingSlate = false
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

#Preview {
    ContentView()
        .environmentObject(ThemeManager())
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
}
