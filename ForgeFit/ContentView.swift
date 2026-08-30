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
    var selectedTab: AppTab
    var showingLogger = false
    /// Import completion hands the Workout tab an ID instead of a model from
    /// another ModelContext; the tab resolves it after its @Query refreshes.
    var pendingRoutineDetailID: UUID?
    /// Cross-tab calls hand Profile a typed route; the keep-resident tab
    /// consumes it after switching so navigation never races tab mounting.
    var pendingProfileRoute: ProfileRoute?

    /// Guarded workout start: every "start a workout" action funnels through
    /// here so ContentView can warn before discarding an active session.
    var startRequestID = 0
    var pendingWorkoutStart: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        // UI automation can request any app tab, including destinations that
        // are not user-selectable as the persisted default launch tab. Apply
        // that request before the first render so the automation barrier and
        // the eventual seeded screen agree on the same route.
        if let raw = ForgeFitLaunchArguments.value(for: "initialTab", arguments: arguments),
           let requestedTab = AppTab(rawValue: raw) {
            selectedTab = requestedTab
        } else if arguments.contains("--reset-store") {
            // A reset is an explicit automation/debug fixture boundary. Do
            // not carry a tab selected by the previous scenario into the
            // newly seeded account; a caller can still override this with
            // -initialTab when a journey starts deeper in the shell.
            selectedTab = .home
        } else if let raw = defaults.string(forKey: "initialTab"),
                  let requestedTab = AppTab(rawValue: raw) {
            selectedTab = requestedTab
        } else {
            selectedTab = DefaultLaunchTab.load(from: defaults).appTab
        }
    }

    func requestStart(_ action: @escaping () -> Void) {
        pendingWorkoutStart = action
        startRequestID += 1
    }

    func openProfile(_ route: ProfileRoute) {
        pendingProfileRoute = route
        selectedTab = .profile
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

/// XCTest supplies fixture preferences through the UserDefaults argument
/// domain (for example, `-initialTab profile`). That domain is intentionally
/// higher-priority during normal reads, but `UserDefaults.removeObject` can
/// remove those values on the simulator in practice. Keep the launch contract
/// sourced from ProcessInfo so a deterministic reset cannot erase the very
/// fixture parameters that describe the scenario.
enum ForgeFitLaunchArguments {
    static func value(
        for key: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        let flag = key.hasPrefix("-") ? key : "-\(key)"
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                guard arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    static func boolValue(
        for key: String,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool? {
        guard let raw = value(for: key, arguments: arguments) else { return nil }
        switch raw.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: return nil
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

/// Pure scheduling gate for migrations that are safe to run after the first
/// interactive frame but must pause for a live workout or backgrounding.
enum DeferredLaunchMaintenancePolicy {
    static func shouldSchedule(
        isPending: Bool,
        launchTasksFinished: Bool,
        allowsNonWorkoutWork: Bool,
        sceneIsActive: Bool,
        hasScheduledTask: Bool
    ) -> Bool {
        isPending
            && launchTasksFinished
            && allowsNonWorkoutWork
            && sceneIsActive
            && !hasScheduledTask
    }

    /// Catalog-dependent migrations must never mark themselves complete from
    /// an empty or partially upgraded exercise library. A pending launch seed
    /// is therefore a hard dependency: only its successful retry opens the
    /// maintenance lane. When no seed is pending, the already-versioned
    /// catalog remains valid input.
    static func canRunCatalogDependentMaintenance(
        seedWasPending: Bool,
        seedSucceeded: Bool
    ) -> Bool {
        !seedWasPending || seedSucceeded
    }
}

/// Cold-start workout fixtures (and the opt-in auto-start preference) can
/// create an active row before SwiftUI replaces the automation launch barrier.
/// Keep presentation as explicit pending state until the real shell and active
/// scene are both observable; setting a sheet Boolean against the barrier can
/// otherwise leave only the mini logger bar visible.
enum LaunchLoggerPresentationPolicy {
    static func shouldPresent(
        isPending: Bool,
        launchTasksFinished: Bool,
        presentationHostMounted: Bool,
        sceneIsActive: Bool,
        onboardingPresented: Bool,
        hasActiveWorkout: Bool
    ) -> Bool {
        isPending
            && launchTasksFinished
            && presentationHostMounted
            && sceneIsActive
            && !onboardingPresented
            && hasActiveWorkout
    }

    /// A reset can deliver removal of the previous active row after a new
    /// auto-start transaction has already requested presentation. Only the
    /// workout that owns the pending request may cancel it; an untargeted
    /// Watch/deep-link request keeps the conservative legacy behavior.
    static func shouldClearPendingPresentation(
        pendingWorkoutID: UUID?,
        removedWorkoutID: UUID?
    ) -> Bool {
        pendingWorkoutID == nil || pendingWorkoutID == removedWorkoutID
    }
}

/// Resolves the workout that a logger presentation request owns. A targeted
/// request always goes back to durable state by UUID and never falls through to
/// an older `@Query` generation left over from a reset or private-context save.
@MainActor
enum LaunchLoggerWorkoutResolver {
    static func resolve(
        preferredID: UUID?,
        queryCandidate: WorkoutModel?,
        in context: ModelContext
    ) -> WorkoutModel? {
        if let preferredID {
            var preferredDescriptor = FetchDescriptor<WorkoutModel>(
                predicate: #Predicate {
                    $0.id == preferredID && $0.endedAt == nil && $0.deletedAt == nil
                }
            )
            preferredDescriptor.fetchLimit = 1
            return try? context.fetch(preferredDescriptor).first
        }
        if let queryCandidate { return queryCandidate }
        var latestDescriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\WorkoutModel.startedAt, order: .reverse)]
        )
        latestDescriptor.fetchLimit = 1
        return try? context.fetch(latestDescriptor).first
    }
}

private struct ExperimentWorkoutPrompt: Identifiable {
    var id: UUID { workout.id }
    let experiment: ExperimentModel
    let workout: WorkoutModel
    let trackers: [ExperimentTrackerModel]
    let entries: [ExperimentEntryModel]
}

/// Shallow semantic key for completed/deleted workout changes that can affect
/// tracked-microcycle lifecycle. This deliberately lives outside ContentView's
/// query graph: the observer below owns the terminal-history fetch and only
/// wakes the shell when one of the fields used by lifecycle resolution changes.
@MainActor
enum TerminalWorkoutLifecycleRevision {
    static func make(_ workouts: [WorkoutModel]) -> Int {
        var hasher = Hasher()
        hasher.combine(workouts.count)
        for workout in workouts {
            hasher.combine(workout.id)
            hasher.combine(workout.routineID)
            hasher.combine(workout.startedAt)
            hasher.combine(workout.endedAt)
            hasher.combine(workout.updatedAt)
            hasher.combine(workout.deletedAt)
        }
        return hasher.finalize()
    }
}

/// Keeps terminal-history invalidation out of ContentView. The initial value is
/// only recorded because launch already performs the first reconcile; later
/// semantic changes emit one cheap token to the shell.
private struct TerminalWorkoutLifecycleObserver: View, Equatable {
    @Query(
        filter: #Predicate<WorkoutModel> { $0.endedAt != nil || $0.deletedAt != nil },
        sort: \WorkoutModel.updatedAt,
        order: .reverse
    ) private var terminalWorkouts: [WorkoutModel]
    @State private var observedInitialRevision = false
    let onChange: @MainActor () -> Void

    private var revision: Int {
        TerminalWorkoutLifecycleRevision.make(terminalWorkouts)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: revision) {
                guard observedInitialRevision else {
                    observedInitialRevision = true
                    return
                }
                onChange()
            }
    }

    static func == (_: Self, _: Self) -> Bool { true }
}

/// Retains a visited tab's SwiftUI identity while preventing parent query
/// publications from reinstalling new inputs into an invisible tab. Dynamic
/// properties owned by descendants can still publish independently, so each
/// expensive resident screen also receives `isRenderActive` and coalesces its
/// own persistence-driven projections until it is visible again.
private struct ResidentTabSurface<Content: View>: View, Equatable {
    let tab: AppTab
    let selectedTab: AppTab
    let isSuspended: Bool
    let activeRenderID: UUID
    let content: () -> Content

    init(
        tab: AppTab,
        selectedTab: AppTab,
        isSuspended: Bool,
        activeRenderID: UUID,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tab = tab
        self.selectedTab = selectedTab
        self.isSuspended = isSuspended
        self.activeRenderID = activeRenderID
        self.content = content
    }

    private var isActivelyRendering: Bool {
        selectedTab == tab && !isSuspended
    }

    var body: some View { content() }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.tab == rhs.tab else { return false }
        // Hidden/suspended surfaces keep their existing tree and @State even
        // when the root queries publish newer arrays behind them.
        if !lhs.isActivelyRendering, !rhs.isActivelyRendering { return true }
        return lhs.selectedTab == rhs.selectedTab
            && lhs.isSuspended == rhs.isSuspended
            && lhs.activeRenderID == rhs.activeRenderID
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(ForgeFitIntentNavigator.self) private var intentNavigator
    @EnvironmentObject private var themeManager: ThemeManager
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @Query(sort: \UserExerciseNoteModel.updatedAt, order: .reverse) private var setupNotes: [UserExerciseNoteModel]
    @Query(sort: \RoutineModel.position) private var routines: [RoutineModel]
    @Query(sort: \RoutineFolderModel.position) private var routineFolders: [RoutineFolderModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse) private var routineAlternations: [RoutineAlternationModel]
    @Query(filter: #Predicate<WorkoutModel> { $0.endedAt == nil && $0.deletedAt == nil }, sort: \WorkoutModel.startedAt, order: .reverse) private var activeWorkouts: [WorkoutModel]
    @Query(filter: #Predicate<WorkoutModel> { $0.endedAt != nil && $0.deletedAt == nil }, sort: \WorkoutModel.startedAt, order: .reverse) private var completedWorkouts: [WorkoutModel]
    @Query(sort: \DailyCheckinModel.updatedAt, order: .reverse) private var checkins: [DailyCheckinModel]
    @Query(sort: \ExperimentModel.startedAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse) private var microcycleTrackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse) private var microcycleWindows: [MicrocycleWindowModel]
    @Query(sort: \IntervalPresetModel.updatedAt, order: .reverse) private var conditioningPresetRecords: [IntervalPresetModel]
    @Query(sort: \YogaFlowModel.position) private var yogaFlows: [YogaFlowModel]

    @State private var appState = AppState()
    @State private var social = SocialService.make()
    @State private var performanceGate = LiveWorkoutPerformanceGate.shared
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
    /// Non-plan deep links that arrived while onboarding was on screen. Held
    /// FIFO and replayed once onboarding dismisses with launch tasks finished,
    /// so a widget/Live Activity tap never routes behind the cover or into a
    /// half-initialized shell (see `replayPendingDeepLinks`).
    @State private var pendingDeepLinks = PendingDeepLinkQueue()
    @State private var workoutCountReactionTask: Task<Void, Never>?
    @State private var terminalWorkoutLifecycleRevision = 0
    @State private var readinessStampTask: Task<Void, Never>?
    @State private var liveSurfaceUpdateTask: Task<Void, Never>?
    @State private var structuralLiveSurfaceUpdateTask: Task<Void, Never>?
    @State private var planDeduplicationTask: Task<Void, Never>?
    @State private var pendingPlanMaintenance = false
    @State private var pendingPlanMaintenanceVersionStamp = false
    @State private var foregroundMaintenanceTask: Task<Void, Never>?
    @State private var deferredLaunchMaintenanceTask: Task<Void, Never>?
    @State private var pendingDeferredLaunchSeed = false
    @State private var pendingDeferredLaunchMaintenance = false
    @State private var experimentNotificationScheduleTask: Task<Void, Never>?
    @State private var experimentEndTask: Task<Void, Never>?
    @State private var microcycleTransitionTask: Task<Void, Never>?
    @State private var experimentWorkoutPrompt: ExperimentWorkoutPrompt?
    @State private var pendingPlanImport: PendingPlanImport?
    @State private var onboardingPlanImport: PendingPlanImport?
    @State private var planImportErrorMessage: String?
    @State private var onboardingPlanImportErrorMessage: String?
    @State private var externalWorkoutChoiceMessage: String?
    @State private var lastLiveActivityHRPushAt = Date.distantPast
    @State private var didStartLaunchTasks = false
    @State private var didFinishLaunchTasks = false
    @State private var readyShellPresentationHostMounted = false
    @State private var pendingLaunchLoggerPresentation = false
    @State private var pendingLaunchLoggerWorkoutID: UUID?
    @State private var presentedLoggerWorkoutID: UUID?
    // Tabs that have been visited at least once. They stay mounted behind the
    // current tab (keep-resident) so their @State-held Memo caches survive —
    // switching back is instant instead of re-running full-history analytics in
    // `body`. Seeded lazily (only the first tab mounts at launch).
    @State private var mountedTabs: Set<AppTab> = []
    /// A tab-bar tap always means "show this tab's root", including a tap on
    /// the already-selected tab. Kept separate per tab so resetting one stack
    /// does not disturb the other resident tabs or their memoized analytics.
    @State private var tabRootRequestIDs: [AppTab: Int] = [:]
    @State private var tabScrollTopRequestIDs: [AppTab: Int] = [:]
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

    /// CloudKit may temporarily materialize several physical rows for one
    /// logical routine ID. Raw rows stay visible to maintenance/versioning;
    /// every user-facing consumer receives exactly one graph-aware row.
    private var logicalRoutines: [RoutineModel] {
        RoutineDeduplicator.canonicalRoutines(routines)
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
        return "\(liveTrackings.count)|\(latestTracking)|\(microcycleWindows.count)|"
            + "\(liveFolders.count)|\(latestFolder)|\(liveRoutines.count)|\(latestRoutine)|"
            + "\(liveAlternations.count)|\(latestAlternation)|\(terminalWorkoutLifecycleRevision)"
    }

    /// The single source of truth for the app's appearance: combines the
    /// user's chosen mode with the device's live system scheme so `.system`
    /// mode tracks appearance changes without a restart.
    private var resolvedColorScheme: ColorScheme {
        themeManager.mode.resolvedColorScheme(system: systemColorScheme)
    }
    private var activeTheme: AppTheme {
        .active(
            family: themeManager.family,
            mode: themeManager.mode,
            system: systemColorScheme
        )
    }

    /// Count of live completed workouts — changes when one is finished or
    /// deleted, so the widget and watch react immediately.
    private var completedWorkoutCount: Int {
        completedWorkouts.count
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

    private var conditioningPresetRevision: String {
        conditioningPresetRecords.map {
            "\($0.id.uuidString)|\($0.name)|\($0.updatedAt.timeIntervalSince1970)|\($0.deletedAt?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: ";")
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
                social.setLiveWorkoutActive(activeWorkout != nil)
                await social.bootstrap()
                // The sync pipeline: watches every SwiftData save and keeps
                // backup + community converged with the local log (see
                // SyncCoordinator). The forced launch pass publishes history
                // for accounts that opted in before backfill existed and
                // catches up anything done offline last session.
                if syncCoordinator == nil {
                    let coordinator = SyncCoordinator(social: social, container: modelContext.container)
                    coordinator.setLiveWorkoutActive(activeWorkout != nil)
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
                Group {
                    if let activeWorkout = activeWorkoutForPresentation(
                        preferredID: presentedLoggerWorkoutID
                    ) {
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
                // Presentation content can be hosted outside this modifier's
                // environment chain. Pin the resolved selection so every live
                // workout path and its nested sheets receive the active family.
                .environment(\.theme, activeTheme)
                .preferredColorScheme(resolvedColorScheme)
                .tint(activeTheme.accent)
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
            .alert(
                "You have a workout in progress",
                isPresented: $showReplaceWorkoutConfirm
            ) {
                Button("Discard Current & Start New", role: .destructive) {
                    if let activeWorkout = activeWorkoutForPresentation() {
                        discardThenRunPendingStart(activeWorkout)
                    } else {
                        runPendingStart()
                    }
                }
                Button("Keep Current Workout", role: .cancel) {
                    appState.pendingWorkoutStart = nil
                    presentLoggerWhenActiveWorkoutIsReady()
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
            .alert(
                "Choose a workout",
                isPresented: Binding(
                    get: { externalWorkoutChoiceMessage != nil },
                    set: { if !$0 { externalWorkoutChoiceMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(externalWorkoutChoiceMessage ?? "Choose a workout to continue.")
            }
    }

    var body: some View {
        shellLifecycleHandlers
    }

    private var shellLifecycleHandlers: some View {
        shellWorkoutHandlers
            .task { await runLaunchTasksIfNeeded() }
            .task(id: launchLoggerPresentationRevision) {
                await presentPendingLaunchLoggerIfReady()
            }
            // Save-triggered private-context snapshots keep the ~900-row
            // intent/search fingerprint out of ContentView's render path.
            .background(WorkoutIntentCatalogObserver().equatable())
            .background(
                TerminalWorkoutLifecycleObserver {
                    terminalWorkoutLifecycleRevision &+= 1
                }
                .equatable()
            )
            .background(
                LiveRuntimeStateObserver(
                    onRestTimerChange: handleRestTimerChange,
                    onIntervalStepChange: {
                        WatchLink.shared.publishState()
                        WorkoutActivityController.shared.update(
                            workout: activeWorkout,
                            exercises: exercises
                        )
                    },
                    onYogaStateChange: {
                        WatchLink.shared.publishState()
                        WorkoutActivityController.shared.update(
                            workout: activeWorkout,
                            exercises: exercises
                        )
                    }
                )
            )
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
            .onChange(of: intentNavigator.pendingRequest?.id) {
                consumePendingAppIntentNavigation()
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
                if !isPresented {
                    presentedLoggerWorkoutID = nil
                }
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
        let syncHandlers = presentedShell
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
                guard activeWorkout == nil else { return }
                WatchLink.shared.publishState()
            }
            .onChange(of: planRowsVersion) {
                guard hasDuplicatePlanRows else { return }
                schedulePlanDeduplication()
            }

        let preferenceHandlers = syncHandlers
            .onChange(of: exercises.count) { schedulePlanDeduplication() }
            .onChange(of: themeManager.family) { _, _ in
                handleThemePreferenceChange()
            }
            .onChange(of: themeManager.mode) { _, _ in
                handleThemePreferenceChange()
            }

        return preferenceHandlers
            .onChange(of: conditioningPresetRevision) {
                guard didFinishLaunchTasks, activeWorkout == nil else { return }
                reconcileConditioningPresetHistory()
            }
            .onChange(of: todayCheckinTags) { _, _ in handleTodayCheckinChange() }
            // HR observation lives in a zero-sized child view: reading
            // LiveMetricsHub.liveMetrics here would register the Observation
            // dependency on ContentView itself and re-render the whole app
            // shell on every heart-rate tick (~1/s during workouts).
            .background(LiveHeartRateObserver(onChange: handleLiveHeartRateChange))
    }

    /// UI-test fixtures are written during `launchTasks()`, which intentionally
    /// runs after the first frame for normal users. An automation launch must
    /// not expose a partially seeded tab tree: XCUITest can otherwise find a
    /// real-looking shell while its @Query values still describe the pre-reset
    /// store. Keep this barrier DEBUG/automation-only so production retains its
    /// fast first frame, while every deterministic fixture gets one explicit
    /// readiness boundary before it can be driven.
    private var appShell: some View {
        Group {
            if isAutomationLaunch && !automationLaunchIsReady {
                launchPreparationView
            } else {
                readyAppShell
            }
        }
        .onKeyboardVisibilityChange($keyboardVisible)
        .onPreferenceChange(BottomChromeHiddenPreferenceKey.self) {
            screenHidesBottomChrome = $0
        }
    }

    private var launchPreparationView: some View {
        ZStack {
            ScreenBackground()
            VStack(spacing: Space.lg) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing your workspace")
                    .font(.title3.weight(.semibold))
                Text("Your data is being loaded.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(Space.xl)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing your workspace")
    }

    private var readyAppShell: some View {
        ZStack(alignment: .bottom) {
            ScreenBackground()

            tabScreens
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !bottomChromeHidden {
                quickActionsScrim

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
                            onExpand: {
                                presentedLoggerWorkoutID = activeWorkout.id
                                appState.showingLogger = true
                            },
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
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? Motion.reduced : Motion.stateChange, value: bottomChromeHidden)
        .onAppear { readyShellPresentationHostMounted = true }
        .onDisappear { readyShellPresentationHostMounted = false }
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
            routines: logicalRoutines,
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
        // Changes on every root evaluation. The visible tab therefore remains
        // fully reactive; only invisible tab subtrees take the Equatable fast
        // path. A UUID is value-only and avoids maintaining another global
        // revision whose own construction would scan the user history.
        let activeRenderID = UUID()
        ZStack {
            ForEach(AppTab.allCases) { tab in
                if appState.selectedTab == tab || mountedTabs.contains(tab) {
                    ResidentTabSurface(
                        tab: tab,
                        selectedTab: appState.selectedTab,
                        isSuspended: appState.showingLogger,
                        activeRenderID: activeRenderID
                    ) {
                        tabContent(
                            for: tab,
                            isRenderActive: appState.selectedTab == tab
                                && !appState.showingLogger,
                            renderID: activeRenderID
                        )
                            .environment(\.tabRootRequestID, tabRootRequestIDs[tab, default: 0])
                            .environment(\.tabScrollTopRequestID, tabScrollTopRequestIDs[tab, default: 0])
                    }
                        .equatable()
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
    private func tabContent(
        for tab: AppTab,
        isRenderActive: Bool,
        renderID: UUID
    ) -> some View {
        ZStack {
            switch tab {
            case .home:
                HomeView(
                    workouts: completedWorkouts,
                    routines: logicalRoutines,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    isRenderActive: isRenderActive
                )
            case .workout:
                WorkoutHomeView(
                    routines: logicalRoutines,
                    workouts: completedWorkouts,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    isRenderActive: isRenderActive
                )
            case .insights:
                InsightsView(
                    workouts: completedWorkouts,
                    exercises: exercises,
                    isRenderActive: isRenderActive,
                    renderID: renderID
                )
            case .profile:
                ProfileView(
                    workouts: completedWorkouts,
                    exercises: exercises,
                    isRenderActive: isRenderActive,
                    renderID: renderID
                )
            }
        }
    }

    private func selectTab(_ tab: AppTab) {
        tabRootRequestIDs[tab, default: 0] &+= 1
        guard appState.selectedTab != tab else {
            // Reselecting the visible tab is the standard iOS "back to the
            // top" gesture. The root request above has already popped any
            // pushed screen, so the scroll request lands on the tab root the
            // user is about to be looking at.
            tabScrollTopRequestIDs[tab, default: 0] &+= 1
            return
        }
        // Selection mounts (or reveals) an entire keep-resident screen. A
        // root animation transaction made both full-screen trees participate
        // in the tab-bar bounce, including the destination's first mount.
        // The bar owns its small matched-geometry animation locally; screen
        // visibility changes synchronously so navigation never spends a frame
        // compositing two animated dashboards.
        appState.selectedTab = tab
    }

    private func handleOnboardingPresentationChange(_ isPresented: Bool) {
        guard !isPresented else { return }
        // The slate cleanup is still gated exactly as before; the replay runs
        // on every real dismissal regardless, so an automation launch or a
        // missed didOnboard stamp can never strand a held link.
        if !cleanedOnboardingSlate,
           UserDefaults.standard.bool(forKey: "didOnboard"),
           !isAutomationLaunch {
            cleanedOnboardingSlate = true
            clearStarterSlate()
        }
        replayPendingDeepLinks()
    }

    /// Replays deep links held while onboarding was up, in arrival order, into
    /// the now-initialized shell. Guarded twice so neither a dismissal racing
    /// an unfinished launch nor a re-presented cover routes into a
    /// half-initialized stack; `runLaunchTasksIfNeeded` re-invokes this when
    /// launch finishes.
    private func replayPendingDeepLinks() {
        guard DeepLinkDeferralPolicy.canReplay(
            launchTasksFinished: didFinishLaunchTasks,
            onboardingPresented: isOnboardingCoverPresented
        ) else { return }
        let queued = pendingDeepLinks.drain()
        for url in queued {
            handleDeepLink(url)
        }
    }

    private func handleStartRequestChange(_ _: Int) {
        guard appState.pendingWorkoutStart != nil else { return }
        if activeWorkoutForPresentation() == nil {
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

    /// Theme changes are rare user actions. Refresh each external surface once
    /// here rather than making individual views observe preferences or perform
    /// cross-process writes during normal rendering.
    private func handleThemePreferenceChange() {
        WatchLink.shared.publishState(force: true)
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    private func handleCompletedWorkoutCountChange(oldCount: Int, newCount: Int) {
        workoutCountReactionTask?.cancel()
        workoutCountReactionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, activeWorkout == nil else { return }
            updateWidgetSnapshot()
            WatchLink.shared.invalidateRoutineSummaryCache()
            WatchLink.shared.publishState()

            guard newCount > oldCount else { return }
            for _ in 0..<8 where appState.showingLogger {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard !appState.showingLogger,
                  activeWorkout == nil,
                  scenePhase == .active else { return }
            experimentWorkoutPrompt = makeExperimentWorkoutPrompt()
        }
    }

    /// A per-workout tracker belongs to the workout's start instant, matching
    /// the exact `[start, end)` membership used by results and comparisons.
    /// The short recency gate prevents a bulk Health history import from
    /// presenting a stale check-in during launch.
    private func makeExperimentWorkoutPrompt(now: Date = .now) -> ExperimentWorkoutPrompt? {
        let recentCutoff = now.addingTimeInterval(-10 * 60)
        let completedCandidates = completedWorkouts.filter {
            ($0.endedAt ?? Date.distantPast) >= recentCutoff
        }
        guard let workout = completedCandidates.max(by: {
            ($0.endedAt ?? Date.distantPast) < ($1.endedAt ?? Date.distantPast)
        }) else { return nil }

        do {
            _ = try ExperimentLifecycleService.reconcileIsolated(
                from: modelContext,
                now: now
            )
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
    ///   forgefit://start-choice?id= → start an App Intent workout choice
    ///   forgefit://start-next       → tracked microcycle's next routine
    ///   forgefit://routine/<id>     → open a routine detail
    ///   forgefit://exercise/<id>    → open an exercise detail
    private func handleDeepLink(_ url: URL) {
        if url.pathExtension.lowercased() == "forgefitplan" {
            receivePlanFile(url)
            return
        }
        guard url.scheme?.lowercased() == "forgefit" else { return }
        // Onboarding is not ready to receive routes: hold the link and replay
        // it after dismissal (see `replayPendingDeepLinks`). Plan files never
        // reach here — they short-circuit above into their own deferred
        // onboarding import sheet.
        if DeepLinkDeferralPolicy.shouldDefer(url: url, onboardingPresented: isOnboardingCoverPresented) {
            pendingDeepLinks.deferLink(url)
            return
        }
        switch url.host?.lowercased() {
        case "workout":
            if activeWorkoutForPresentation() != nil {
                presentLoggerWhenActiveWorkoutIsReady()
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
               let routine = logicalRoutines.first(where: {
                   $0.id == routineID && $0.isAvailableForWorkoutStart(exercises: exercises)
               }) {
                appState.requestStart {
                    _ = WorkoutFactory.start(
                        routine: routine,
                        exercises: exercises,
                        setupNotes: setupNotes,
                        in: modelContext,
                        onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
                    )
                }
            } else {
                appState.selectedTab = .workout
            }
        case "start-choice":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let choiceID = components.queryItems?.first(where: { $0.name == "id" })?.value else {
                requireExternalWorkoutChoice("That workout link is incomplete. Choose a workout to continue.")
                return
            }
            requestExternalWorkoutStart(choiceID: choiceID)
        case "start-next":
            switch TrackedMicrocycleNextResolver.resolve(
                trackings: microcycleTrackings,
                windows: microcycleWindows,
                routines: logicalRoutines,
                alternations: routineAlternations,
                workouts: completedWorkouts
            ) {
            case .routine(let id, _):
                requestExternalWorkoutStart(
                    choiceID: WorkoutChoiceTarget.routine(id).identifier
                )
            case .chooseWorkout(let message):
                requireExternalWorkoutChoice(message)
            }
        case "choose-workout":
            requireExternalWorkoutChoice("Choose the workout you want to start.")
        case "routine":
            guard let routineID = url.pathComponents.dropFirst().first.flatMap(UUID.init),
                  logicalRoutines.contains(where: {
                      $0.id == routineID && $0.deletedAt == nil && $0.archivedAt == nil
                  }) else {
                appState.selectedTab = .workout
                return
            }
            appState.pendingRoutineDetailID = routineID
            appState.selectedTab = .workout
        case "exercise":
            guard let exerciseID = url.pathComponents.dropFirst().first.flatMap(UUID.init),
                  exercises.contains(where: { $0.id == exerciseID && $0.deletedAt == nil }) else {
                appState.openProfile(.exercises)
                return
            }
            appState.openProfile(.exercise(exerciseID))
        default:   // "readiness" and anything unrecognized
            appState.selectedTab = .home
        }
    }

    private func requireExternalWorkoutChoice(_ message: String) {
        appState.selectedTab = .workout
        externalWorkoutChoiceMessage = message
    }

    private func requestExternalWorkoutStart(choiceID: String) {
        guard let target = WorkoutChoiceTarget(identifier: choiceID) else {
            requireExternalWorkoutChoice("That workout is no longer available. Choose another workout.")
            return
        }

        if target == .next {
            switch TrackedMicrocycleNextResolver.resolve(
                trackings: microcycleTrackings,
                windows: microcycleWindows,
                routines: logicalRoutines,
                alternations: routineAlternations,
                workouts: completedWorkouts
            ) {
            case .routine(let id, _):
                requestExternalWorkoutStart(
                    choiceID: WorkoutChoiceTarget.routine(id).identifier
                )
            case .chooseWorkout(let message):
                requireExternalWorkoutChoice(message)
            }
            return
        }

        let start: (() -> Void)? = switch target {
        case .next:
            nil
        case .empty:
            {
                _ = WorkoutFactory.startEmpty(
                    in: modelContext,
                    onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
                )
            }
        case .routine(let id):
            logicalRoutines.first(where: {
                $0.id == id && $0.isAvailableForWorkoutStart(exercises: exercises)
            }).map { routine in
                {
                    _ = WorkoutFactory.start(
                        routine: routine,
                        exercises: exercises,
                        setupNotes: setupNotes,
                        in: modelContext,
                        applyProgression: false,
                        onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
                    )
                }
            }
        case .cardio(let raw):
            CardioModality(rawValue: raw).map { modality in
                {
                    _ = WorkoutFactory.startCardio(
                        modality,
                        exercises: exercises,
                        in: modelContext,
                        onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
                    )
                }
            }
        case .yogaBuiltIn(let slug):
            YogaFlowCatalog.flow(forSlug: slug).map { seed in
                {
                    _ = WorkoutFactory.startYoga(
                        flow: YogaFlowCatalog.plan(for: seed),
                        named: seed.name,
                        exercises: exercises,
                        in: modelContext,
                        onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
                    )
                }
            }
        case .yogaSaved(let id):
            yogaFlows.first(where: {
                $0.id == id && $0.deletedAt == nil && $0.plan?.hasSteps == true
            }).flatMap { flow in
                flow.plan.map { plan in
                    {
                        _ = WorkoutFactory.startYoga(
                            flow: plan,
                            named: flow.name,
                            exercises: exercises,
                            in: modelContext,
                            onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
                        )
                    }
                }
            }
        case .conditioningBuiltIn(let raw):
            ConditioningPreset(rawValue: raw).flatMap { preset in
                conditioningStart(
                    selection: .builtIn(preset),
                    title: preset.title
                )
            }
        case .conditioningSaved(let id):
            ConditioningPresetStore.savedPresets(from: conditioningPresetRecords)
                .first(where: {
                    guard case .saved(let savedID, _, _) = $0 else { return false }
                    return savedID == id
                })
                .flatMap { conditioningStart(selection: $0, title: $0.title) }
        }

        guard let start else {
            requireExternalWorkoutChoice("That workout is no longer available. Choose another workout.")
            return
        }
        appState.requestStart(start)
    }

    private func conditioningStart(
        selection: ConditioningPresetSelection,
        title: String
    ) -> (() -> Void)? {
        guard let section = selection.resolvedSection(in: exercises),
              !section.movements.isEmpty else { return nil }
        let availableExerciseIDs = Set(exercises.lazy.filter { $0.deletedAt == nil }.map(\.id))
        guard section.movements.allSatisfy({ availableExerciseIDs.contains($0.exerciseID) }) else {
            return nil
        }
        let plan = ConditioningPlan(sections: [section])
        return {
            _ = WorkoutFactory.startConditioning(
                plan: plan,
                named: title,
                in: modelContext,
                onCommit: { _ in presentLoggerWhenActiveWorkoutIsReady() }
            )
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
        let rawURL = UserDefaults.standard.string(
            forKey: ExperimentNotificationRoute.pendingURLDefaultsKey
        )
        guard let rawURL, let url = URL(string: rawURL) else {
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
        if phase == .background, let runner = YogaFlowRunnerHub.shared.runner {
            NotificationScheduler.shared.scheduleYogaCueSchedule(runner.upcomingTransitions())
        } else if phase == .active {
            NotificationScheduler.shared.cancelYogaCueSchedule()
        }
        if phase == .active {
            consumePendingAppIntentNavigation()
            UserDefaults.standard.set(Date(), forKey: "lastActiveDate")
            reconcileLiveRuntimeOwnership()
            BackupScheduler.shared.resumeAfterForeground()
            updateWidgetSnapshot()
            // The wrist is refreshed by no user action on its own: the watch
            // asks on ITS foreground, and the phone answers only while its
            // app is running. Foregrounding here is the moment the phone can
            // answer, so push rather than wait to be asked.
            WatchLink.shared.publishState()

            if LiveWorkoutLifecyclePolicy.shouldRunForegroundMaintenance(
                hasActiveWorkout: activeWorkout != nil
            ) {
                reconcileExperimentLifecycle()
                reconcileMicrocycleLifecycle()
                NotificationScheduler.shared.refreshStatus()
                scheduleForegroundMaintenance()
                scheduleDeferredLaunchMaintenanceIfNeeded()
                scheduleLaunchPlanMaintenanceIfNeeded()
                if pendingPlanMaintenance, planDeduplicationTask == nil {
                    schedulePlanDeduplication()
                }
            } else {
                foregroundMaintenanceTask?.cancel()
                foregroundMaintenanceTask = nil
                deferredLaunchMaintenanceTask?.cancel()
                deferredLaunchMaintenanceTask = nil
                experimentNotificationScheduleTask?.cancel()
                experimentNotificationScheduleTask = nil
            }
        } else if phase == .background {
            experimentEndTask?.cancel()
            experimentEndTask = nil
            experimentNotificationScheduleTask?.cancel()
            experimentNotificationScheduleTask = nil
            microcycleTransitionTask?.cancel()
            microcycleTransitionTask = nil
            planDeduplicationTask?.cancel()
            planDeduplicationTask = nil
            foregroundMaintenanceTask?.cancel()
            foregroundMaintenanceTask = nil
            deferredLaunchMaintenanceTask?.cancel()
            deferredLaunchMaintenanceTask = nil
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
        setLiveWorkoutPerformancePriority(newID != nil)
        if newID != nil {
            workoutCountReactionTask?.cancel()
            workoutCountReactionTask = nil
            planDeduplicationTask?.cancel()
            planDeduplicationTask = nil
            foregroundMaintenanceTask?.cancel()
            foregroundMaintenanceTask = nil
            deferredLaunchMaintenanceTask?.cancel()
            deferredLaunchMaintenanceTask = nil
            experimentEndTask?.cancel()
            experimentEndTask = nil
            experimentNotificationScheduleTask?.cancel()
            experimentNotificationScheduleTask = nil
            microcycleTransitionTask?.cancel()
            microcycleTransitionTask = nil
        } else if scenePhase == .active {
            reconcileConditioningPresetHistory()
            reconcileExperimentLifecycle()
            reconcileMicrocycleLifecycle()
            NotificationScheduler.shared.refreshStatus()
            scheduleForegroundMaintenance()
            scheduleDeferredLaunchMaintenanceIfNeeded()
            if pendingPlanMaintenance || hasDuplicatePlanRows {
                schedulePlanDeduplication()
            }
        }
        WatchLink.shared.publishState(policy: .immediate)
        if newID == nil {
            // Backstop for externally removed workouts. Normal finish/discard
            // paths already send their more specific terminal command.
            if LaunchLoggerPresentationPolicy.shouldClearPendingPresentation(
                pendingWorkoutID: pendingLaunchLoggerWorkoutID,
                removedWorkoutID: oldID
            ) {
                pendingLaunchLoggerPresentation = false
                pendingLaunchLoggerWorkoutID = nil
            }
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
            // strap) for the session; no-op when none is remembered. Skipped
            // entirely while the feature is gated off so CBCentralManager is
            // never constructed and iOS never asks for Bluetooth permission.
            if FeatureFlags.bluetoothHeartRate {
                BLEHeartRateService.shared.reconnectIfRemembered()
            }
            WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
        }
        updateWidgetSnapshot()
        guard let newID, oldID != newID,
              let workout = activeWorkouts.first(where: { $0.id == newID }) else { return }
        if workout.readinessAtStart == nil {
            scheduleReadinessStamp(for: workout, delayMilliseconds: 600)
        }
        if UserDefaults.standard.object(forKey: "liveSyncEnabled") == nil
            || UserDefaults.standard.bool(forKey: "liveSyncEnabled") {
            HealthService.shared.startWatchApp(cardioKind: watchCardioKind(for: workout))
        }
    }

    private func reconcileConditioningPresetHistory() {
        guard activeWorkout == nil else { return }
        do {
            let updatedWorkouts = try ConditioningPresetHistoryReconciler.reconcile(
                records: conditioningPresetRecords,
                workouts: completedWorkouts,
                exercises: exercises,
                context: modelContext
            )
            if updatedWorkouts > 0 {
                BackupScheduler.shared.noteLogDataChanged()
            }
        } catch {
            assertionFailure("Conditioning preset history reconciliation failed: \(error)")
        }
    }

    /// One transition fans out to every app-owned maintenance service. Each
    /// service still owns its cancellation handle so stopping the awaiting
    /// ContentView task can never leave detached work running invisibly.
    private func setLiveWorkoutPerformancePriority(_ isActive: Bool) {
        performanceGate.setLiveWorkoutActive(isActive)
        let revision = performanceGate.transitionRevision
        HealthMetricsStore.shared.setLiveWorkoutActive(isActive)
        ReadinessDelivery.shared.setLiveWorkoutActive(isActive)
        InsightDataCoordinator.shared.setLiveWorkoutActive(isActive)
        DeferredWorkoutEnrichmentCoordinator.shared.setLiveWorkoutActive(isActive)
        ExerciseAIClassifier.setLiveWorkoutActive(isActive)
        social.setLiveWorkoutActive(isActive)
        BackupScheduler.shared.setLiveWorkoutActive(isActive)
        syncCoordinator?.setLiveWorkoutActive(isActive)
        Task {
            await HealthWorkoutImporter.shared.setLiveWorkoutActive(
                isActive,
                revision: revision
            )
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
        let workoutID = workout.id
        readinessStampTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled,
                  !appState.showingLogger,
                  workout.deletedAt == nil,
                  workout.readinessAtStart == nil else { return }
            _ = try? ReadinessSurfacePublisher.persistCachedStart(
                to: workoutID,
                in: modelContext
            )
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
        // SwiftData has committed the fixture by this point, but its @Query
        // change notifications and SwiftUI's dependent view invalidation are
        // delivered on subsequent main-actor turns. Let those turns run before
        // removing the automation barrier, so readiness means "seeded and
        // observable", not merely "the save call returned".
        await Task.yield()
        await Task.yield()
        didFinishLaunchTasks = true
        reconcileConditioningPresetHistory()
        scheduleLaunchPlanMaintenanceIfNeeded()
        // Links queued while onboarding was up and dismissed before launch
        // finished are only safe to route now.
        replayPendingDeepLinks()
        #if DEBUG
        routeAppIntentLaunchFixtureIfNeeded()
        #endif
        consumePendingAppIntentNavigation()

        if scenePhase == .active, activeWorkout == nil {
            scheduleDeferredLaunchMaintenanceIfNeeded()
            scheduleForegroundMaintenance()
        }

        if shouldAutoStartRoutine, !pendingLaunchLoggerPresentation {
            presentLoggerWhenActiveWorkoutIsReady(
                workoutID: activeWorkoutForPresentation()?.id
            )
        }
    }

    #if DEBUG
    /// Acceptance seam for submitting the exact typed navigation request that
    /// production App Intents submit after the reset/seed work is observable.
    private func routeAppIntentLaunchFixtureIfNeeded() {
        guard let rawURL = ForgeFitLaunchArguments.value(for: "appIntentURL"),
              let url = URL(string: rawURL),
              let destination = ForgeFitIntentDestination(internalDeepLink: url) else { return }
        intentNavigator.navigate(to: destination)
    }

    #endif

    /// App Intents foreground the app before `perform()` updates the shared
    /// navigator. Keep requests pending until launch setup is complete, then
    /// feed them through the same validated routes as every other app surface.
    @MainActor
    private func consumePendingAppIntentNavigation() {
        guard didFinishLaunchTasks,
              scenePhase == .active,
              let request = intentNavigator.takePendingRequest() else { return }

        switch request.destination {
        case .chooseWorkout(let message):
            requireExternalWorkoutChoice(message)
        case .resumeWorkout:
            presentLoggerWhenActiveWorkoutIsReady()
        default:
            guard let url = request.destination.internalDeepLink else { return }
            handleDeepLink(url)
        }
    }

    private func launchTasks() async {
        let forcedReset = ProcessInfo.processInfo.arguments.contains("--reset-store")
        #if DEBUG
        let requiresAppIntentWorkoutFixtureSeed = ForgeFitAppIntentWorkoutUITestFixture.isRequested
        #else
        let requiresAppIntentWorkoutFixtureSeed = false
        #endif
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
        // App Store capture: a clean 70-night Health series so readiness,
        // sleep, and the personal health bands compute for real.
        if ProcessInfo.processInfo.arguments.contains("--seed-appstore-demo") {
            HealthMetricsStore.shared.seedAppStoreDemo()
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
        // A forced reset is an account boundary. The keep-resident @Query can
        // still expose a pre-reset active row for one run-loop turn, but that
        // row must not put launch seeding behind the live-workout performance
        // gate or make the new scenario inherit the old logger state.
        if forcedReset || requiresAppIntentWorkoutFixtureSeed {
            setLiveWorkoutPerformancePriority(false)
        } else {
            setLiveWorkoutPerformancePriority(activeWorkout != nil)
        }
        WatchLink.shared.configure(context: modelContext)
        WatchLink.shared.activate()
        WatchLink.shared.onWorkoutStartedFromWatch = {
            presentLoggerWhenActiveWorkoutIsReady()
        }
        WatchLink.shared.onWorkoutFinishedFromWatch = {
            pendingLaunchLoggerPresentation = false
            pendingLaunchLoggerWorkoutID = nil
            presentedLoggerWorkoutID = nil
            appState.showingLogger = false
        }
        // Relaunching into an active session (app was killed mid-workout):
        // resume BLE aggregation so a paired heart-rate monitor keeps
        // filling avg/max/time-in-zone. onChange won't fire for a workout
        // that was already active before the first render.
        if activeWorkout != nil {
            LiveMetricsHub.shared.beginSession()
            if FeatureFlags.bluetoothHeartRate {
                BLEHeartRateService.shared.reconnectIfRemembered()
            }
        }
        if forcedReset || requiresAppIntentWorkoutFixtureSeed || performanceGate.allowsNonWorkoutWork {
            if !(await seedLaunchData()) {
                pendingDeferredLaunchSeed = true
                pendingDeferredLaunchMaintenance = true
            }
        } else {
            pendingDeferredLaunchSeed = true
            pendingDeferredLaunchMaintenance = true
        }
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
        // These repairs can traverse imported exercises, complete workout
        // graphs, and routine sets. Their legacy values remain readable, so a
        // normal launch defers the scans until after the first interactive
        // frame and cancels them whenever a workout starts.
        pendingDeferredLaunchMaintenance = true
        #if DEBUG
        // Review automation expects its seeded classifications to be final
        // before the launch-readiness barrier. Preserve that explicit fixture
        // contract; production launches always use the delayed lane.
        if ProcessInfo.processInfo.arguments.contains(ImportedExerciseReviewUITestFixture.launchArgument),
           performanceGate.allowsNonWorkoutWork {
            await ImportedExerciseBackfill.runCooperativelyIfNeeded(in: modelContext)
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-wrapped-demo") {
            WrappedDemoSeed.run(in: modelContext)
            // The automatic foreground worker coalesces attempts per day in
            // UserDefaults. `--reset-store` deliberately clears SwiftData but
            // not that preference, so a later UI-test launch could seed the
            // demo workouts yet skip recreating the report it just deleted.
            // Materialize the due report as part of this explicit DEBUG
            // fixture; production launches still use the coalesced worker.
            _ = WrappedReportService.generateIfDue(
                in: modelContext,
                weightUnit: Fmt.unit
            )
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
        if let tab = requestedInitialTab {
            appState.selectedTab = tab
        }
        if shouldAutoStartRoutine,
           (forcedReset || activeWorkoutForPresentation() == nil),
           let routine = launchRoutineForAutoStart() {
            let launchExercises = (try? modelContext.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? exercises
            let launchSetupNotes = (try? modelContext.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? setupNotes
            _ = WorkoutFactory.start(
                routine: routine,
                exercises: launchExercises,
                setupNotes: launchSetupNotes,
                in: modelContext,
                onCommit: { workout in
                    presentLoggerWhenActiveWorkoutIsReady(workoutID: workout.id)
                }
            )
        }
        #if DEBUG
        // Account reset rebuilds the shell and clears pending presentations.
        // Reassert this explicit fixture only after the reset/seed boundary,
        // matching the stable auto-start lane above.
        if ProcessInfo.processInfo.arguments.contains(
            QuickIncrementUITestFixture.livePrefillLaunchArgument
        ), let workout = try? QuickIncrementUITestFixture.seedLivePrefillWorkout(
            in: modelContext
        ) {
            presentLoggerWhenActiveWorkoutIsReady(workoutID: workout.id)
        }
        #endif
        // No-ops when a demo seed is active (see HealthMetricsStore.refresh).
        HealthMetricsStore.shared.refresh()
        consumePendingExperimentNotificationRoute()
        if performanceGate.allowsNonWorkoutWork {
            CyclePreferenceMigration.migrate()
            reconcileExperimentLifecycle()
            reconcileMicrocycleLifecycle()
        } else {
            pendingDeferredLaunchMaintenance = true
        }
        ReadinessDelivery.shared.configure(container: modelContext.container)
        BackupScheduler.shared.configure(container: modelContext.container)
        BackupScheduler.shared.dailyCheckIfDue()
        updateWidgetSnapshot()
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
    }

    /// Cold-launch migrations are idempotent but can be expensive. Run them
    /// after the first interactive frame and a short grace period; if the app
    /// restored directly into a workout, wait for its terminal transition.
    private func scheduleDeferredLaunchMaintenanceIfNeeded() {
        guard DeferredLaunchMaintenancePolicy.shouldSchedule(
            isPending: pendingDeferredLaunchMaintenance,
            launchTasksFinished: didFinishLaunchTasks,
            allowsNonWorkoutWork: performanceGate.allowsNonWorkoutWork,
            sceneIsActive: scenePhase == .active,
            hasScheduledTask: deferredLaunchMaintenanceTask != nil
        ) else { return }

        deferredLaunchMaintenanceTask = Task { @MainActor in
            defer { deferredLaunchMaintenanceTask = nil }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            let seedWasPending = pendingDeferredLaunchSeed
            let seedSucceeded = seedWasPending ? await seedLaunchData() : true
            guard DeferredLaunchMaintenancePolicy.canRunCatalogDependentMaintenance(
                seedWasPending: seedWasPending,
                seedSucceeded: seedSucceeded
            ),
            !Task.isCancelled,
            performanceGate.allowsNonWorkoutWork else { return }
            pendingDeferredLaunchSeed = false
            await ImportedExerciseBackfill.runCooperativelyIfNeeded(in: modelContext)
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            await SetTypeRetirementBackfill.runCooperatively(in: modelContext)
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            await WeightModeBackfill.convertIfNeededCooperatively(in: modelContext)
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            CyclePreferenceMigration.migrate()
            guard !Task.isCancelled,
                  performanceGate.allowsNonWorkoutWork else { return }
            reconcileExperimentLifecycle()
            reconcileMicrocycleLifecycle()
            pendingDeferredLaunchMaintenance = false
        }
    }

    /// Scheduled experiment endings are date truth, not notification truth:
    /// iOS may never wake the process at the exact end instant. Materialize
    /// expired rows whenever the app becomes usable, then rebuild the one
    /// active experiment's bounded reminder set.
    private func reconcileExperimentLifecycle() {
        experimentEndTask?.cancel()
        experimentEndTask = nil
        experimentNotificationScheduleTask?.cancel()
        experimentNotificationScheduleTask = nil
        guard performanceGate.allowsNonWorkoutWork else { return }
        do {
            _ = try ExperimentLifecycleService.reconcileIsolated(from: modelContext)
            guard let active = try ExperimentLifecycleService.activeExperiment(in: modelContext) else {
                return
            }
            let trackers = try modelContext.fetch(FetchDescriptor<ExperimentTrackerModel>())
                .filter { $0.experimentID == active.id && $0.deletedAt == nil && $0.archivedAt == nil }
            let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
                experiment: active,
                trackers: trackers
            )
            experimentNotificationScheduleTask = Task { @MainActor in
                guard !Task.isCancelled,
                      performanceGate.allowsNonWorkoutWork else { return }
                _ = await ExperimentNotificationScheduler.schedule(
                    notificationSchedule
                )
                guard !Task.isCancelled else { return }
                experimentNotificationScheduleTask = nil
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
        guard performanceGate.allowsNonWorkoutWork else { return }
        do {
            guard let transition = try MicrocycleTrackingService.reconcileIsolated(
                from: modelContext
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
        let launchRoutines = RoutineDeduplicator.canonicalRoutines(
            (try? modelContext.fetch(FetchDescriptor<RoutineModel>())) ?? routines
        )
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--seed-block-prefill-history"),
           let starter = launchRoutines.first(where: {
               $0.id == ForgeFitDemo.starterRoutineID
                   && $0.deletedAt == nil
                   && !$0.exercises.isEmpty
           }) {
            return starter
        }
        #endif
        return launchRoutines
            .sorted { $0.position < $1.position }
            .first { $0.deletedAt == nil && !$0.exercises.isEmpty }
    }

    private var shouldAutoStartRoutine: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        // `--reset-store` deliberately clears SwiftData but does not clear the
        // defaults domain, so an old manual/automation autorun preference must
        // not leak an active workout into an unrelated deterministic fixture.
        // The explicit launch argument remains authoritative for logger tests.
        if arguments.contains("--auto-start-routine") { return true }
        if arguments.contains("--reset-store") { return false }
        return UserDefaults.standard.bool(forKey: "autoStartRoutine")
    }

    private var requestedInitialTab: AppTab? {
        let arguments = ProcessInfo.processInfo.arguments
        if let raw = ForgeFitLaunchArguments.value(for: "initialTab", arguments: arguments),
           let tab = AppTab(rawValue: raw) {
            return tab
        }
        if arguments.contains("--reset-store") { return nil }
        if let raw = UserDefaults.standard.string(forKey: "initialTab"),
           let tab = AppTab(rawValue: raw) {
            return tab
        }
        return nil
    }

    private func activeWorkoutForPresentation(preferredID: UUID? = nil) -> WorkoutModel? {
        LaunchLoggerWorkoutResolver.resolve(
            preferredID: preferredID,
            queryCandidate: activeWorkout,
            in: modelContext
        )
    }

    private var launchLoggerPresentationRevision: String {
        "\(pendingLaunchLoggerPresentation)|\(didFinishLaunchTasks)|"
            + "\(readyShellPresentationHostMounted)|\(scenePhase == .active)|"
            + "\(isOnboardingCoverPresented)|"
            + "\(pendingLaunchLoggerWorkoutID?.uuidString ?? "any")|"
            + "\(activeWorkout?.id.uuidString ?? "none")"
    }

    @MainActor
    private func presentPendingLaunchLoggerIfReady() async {
        let readyWorkout = activeWorkoutForPresentation(
            preferredID: pendingLaunchLoggerWorkoutID
        )
        guard LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: pendingLaunchLoggerPresentation,
            launchTasksFinished: didFinishLaunchTasks,
            presentationHostMounted: readyShellPresentationHostMounted,
            sceneIsActive: scenePhase == .active,
            onboardingPresented: isOnboardingCoverPresented,
            hasActiveWorkout: readyWorkout != nil
        ) else { return }

        // Let the ready shell and its presentation host commit before asking
        // UIKit to host the cover. A bare yield can resume in the same SwiftUI
        // update transaction on iOS 26: the Boolean then becomes true, but no
        // cover is installed and only the mini logger remains. One short frame-
        // bounded settle keeps launch, Watch, and deep-link starts on the same
        // deterministic path without putting seed work back on the render pass.
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled,
              let readyWorkout = activeWorkoutForPresentation(
                preferredID: pendingLaunchLoggerWorkoutID
              ),
              LaunchLoggerPresentationPolicy.shouldPresent(
                isPending: pendingLaunchLoggerPresentation,
                launchTasksFinished: didFinishLaunchTasks,
                presentationHostMounted: readyShellPresentationHostMounted,
                sceneIsActive: scenePhase == .active,
                onboardingPresented: isOnboardingCoverPresented,
                hasActiveWorkout: true
              ) else { return }
        presentedLoggerWorkoutID = readyWorkout.id
        pendingLaunchLoggerPresentation = false
        pendingLaunchLoggerWorkoutID = nil
        appState.showingLogger = true
    }

    private func presentLoggerWhenActiveWorkoutIsReady(workoutID: UUID? = nil) {
        // One pending bit survives launch-barrier replacement, onboarding,
        // backgrounding, and a private-context workout commit. The keyed task
        // above presents only after every prerequisite is observable.
        pendingLaunchLoggerPresentation = true
        if workoutID != nil || pendingLaunchLoggerWorkoutID == nil {
            pendingLaunchLoggerWorkoutID = workoutID
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
            // block launch to replace it. `publishIdle` keeps a score that is
            // still today's — the pre-dawn background refresh publishes one
            // before Home has ever rendered — and clears only a stale one.
            ReadinessSurfacePublisher.publishIdle()
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

    private func discard(
        _ workout: WorkoutModel,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        PersistentChangeSaveCenter.shared.performReportingFailure({
            WorkoutFinisher.discard(workoutID: workout.id, in: modelContext)
        }, onSuccess: onSuccess)
    }

    private func discardThenRunPendingStart(_ workout: WorkoutModel) {
        // Remove the global pending action before the fallible write. Retry
        // retains this exact closure, while Keep Editing drops it instead of
        // leaving a surprise start queued for a later state change.
        let pendingStart = appState.pendingWorkoutStart
        appState.pendingWorkoutStart = nil
        discard(workout) {
            pendingStart?()
        }
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
    private func seedLaunchData() async -> Bool {
        do {
            let forcedReset = ProcessInfo.processInfo.arguments.contains("--reset-store")
            if forcedReset {
                resetAutomationDefaults()
                try AccountResetService.deleteAllLocalModels(in: modelContext)
            }
            // Version-gated: re-materializing the whole library (+ muscle
            // refinement over ~900 bundled seeds) on EVERY cold launch was
            // the single biggest time-to-interactive cost. `fetchCount` is a
            // cheap store-side COUNT.
            let storedVersion = UserDefaults.standard.integer(forKey: LaunchSeedPolicy.defaultsKey)
            // A failed read is not proof of an empty catalog. Propagate it so
            // this launch neither creates duplicate logical IDs nor stamps a
            // seed version that did not complete; the next launch retries.
            let libraryCount = try modelContext.fetchCount(FetchDescriptor<ExerciseLibraryModel>())
            let needsSeed = LaunchSeedPolicy.shouldSeed(
                storedVersion: storedVersion,
                libraryCount: libraryCount,
                forcedReset: forcedReset
            )
            if needsSeed {
                try await ExerciseSeedRepository.seedGlobalLibraryCooperatively(in: modelContext)
                try await ExerciseCatalog.seedCooperatively(into: modelContext)
                // Seed current yoga poses and drop trimmed rows in one isolated,
                // durable transaction so catalog upgrades never scan the full
                // exercise library on MainActor.
                try await YogaPoseCatalog.seedAndPruneCooperatively(into: modelContext)
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
            if ProcessInfo.processInfo.arguments.contains(
                QuickIncrementUITestFixture.livePrefillLaunchArgument
            ) {
                _ = try QuickIncrementUITestFixture.seedLivePrefillWorkout(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-block-prefill-history") {
                try BlockPrefillUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-conditioning-preset-rename") {
                try ConditioningPresetUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-conditioning-finalization") {
                try ConditioningPresetUITestFixture.seedFinalizing(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-workout-finalization") {
                let workout = try WorkoutFinalizationUITestFixture.seed(in: modelContext)
                if let end = workout.endedAt {
                    let pendingSnapshot = CardioSnapshot()
                    DeferredWorkoutEnrichmentCoordinator.shared.scheduleWorkout(
                        .init(workoutID: workout.id, start: workout.startedAt, end: end),
                        container: modelContext.container,
                        snapshot: {
                            try? await Task.sleep(for: .seconds(10 * 60))
                            return pendingSnapshot
                        }
                    )
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-experiment-demo") {
                try ExperimentDemoSeed.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-routine-reorder") {
                try RoutineReorderUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-data-display-audit") {
                try DataDisplayUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains(ImportedExerciseReviewUITestFixture.launchArgument) {
                try ImportedExerciseReviewUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-microcycle-tracking") {
                try MicrocycleTrackingUITestFixture.seed(in: modelContext)
            }
            if ForgeFitAppIntentWorkoutUITestFixture.isRequested {
                try ForgeFitAppIntentWorkoutUITestFixture.seed(in: modelContext)
            }
            if ProcessInfo.processInfo.arguments.contains(CustomExerciseMediaUITestFixture.launchArgument) {
                try CustomExerciseMediaUITestFixture.seed(in: modelContext)
            }
            try RoutineHierarchyUITestFixture.seedIfRequested(
                arguments: ProcessInfo.processInfo.arguments,
                in: modelContext
            )
            // App Store screenshot/preview capture. Runs after the catalogs so
            // it can resolve bundled routine templates by slug.
            if ProcessInfo.processInfo.arguments.contains("--seed-appstore-demo") {
                if ProcessInfo.processInfo.arguments.contains("--discard-active-workouts") {
                    try AppStoreDemoSeed.discardActiveWorkouts(in: modelContext)
                }
                try AppStoreDemoSeed.seed(in: modelContext)
                if ProcessInfo.processInfo.arguments.contains("--seed-active-workout") {
                    try AppStoreDemoSeed.seedActiveWorkout(in: modelContext)
                }
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
            return true
        } catch {
            #if DEBUG
            if ForgeFitAppIntentWorkoutUITestFixture.isRequested {
                fatalError("App Intent workout acceptance fixture seed failed: \(error)")
            }
            #endif
            assertionFailure("Launch data seed failed: \(error)")
            return false
        }
    }

    /// `--reset-store` is the deterministic UI-test account boundary. SwiftData
    /// is only half of the app's state: pending notification routes, quick
    /// actions, autorun flags, migrations, and display preferences all live in
    /// UserDefaults. Clear the canonical app-owned keys before seeding so one
    /// scenario cannot influence the next. XCTest launch arguments are stored
    /// in UserDefaults' higher-priority argument domain and therefore remain
    /// available to this launch after the persistent values are removed.
    private func resetAutomationDefaults() {
        let defaults = UserDefaults.standard
        let keys = Set(AppPreferenceKeys.allResettable)
        let argumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let commandLineOverrides = keys.reduce(into: [String: Any]()) { result, key in
            if let raw = ForgeFitLaunchArguments.value(for: key) {
                result[key] = automationDefaultValue(raw, for: key)
                return
            }
            // XCTest can materialize `-key value` in the argument domain
            // without leaving it in ProcessInfo.arguments. Preserve only
            // that explicit domain. Looking at `defaults.object(forKey:)`
            // here is unsafe: it also sees stale volatile app state such as
            // a pending notification route and would carry it into the new
            // scenario.
            if let argumentValue = argumentDomain[key] {
                if let raw = argumentValue as? String {
                    result[key] = automationDefaultValue(raw, for: key)
                } else {
                    result[key] = argumentValue
                }
            }
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        // `removeObject` can erase XCTest's argument-domain value on the
        // simulator, so restore only the values explicitly requested by this
        // launch. Unspecified preferences stay at their clean defaults.
        for (key, value) in commandLineOverrides {
            defaults.set(value, forKey: key)
        }
    }

    private func automationDefaultValue(_ raw: String, for key: String) -> Any {
        let booleanKeys: Set<String> = [
            "didOnboard",
            "liveSyncEnabled",
            "healthWriteEnabled",
            WorkoutEffortPolicy.loggingEnabledKey,
            WorkoutEffortPolicy.failureTrainingKey,
            "morningReadinessEnabled",
            "timerSoundEnabled",
            "loudRestAlarmEnabled",
            "paceAnnouncementsEnabled",
            "intervalSoundCues",
            "zoneVoiceCues",
            "paceVoiceCues",
            "yogaVoiceCues",
        ]
        if booleanKeys.contains(key), let value = ForgeFitLaunchArguments.boolValue(for: key) {
            return value
        }
        return raw
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
                    // Morning Run #117 is the explicit after-the-fact
                    // treadmill-edit fixture: time and HR exist, but the
                    // machine distance is intentionally still blank.
                    distanceMeters: isYoga || sessionNumber == 117
                        ? nil
                        : 4_800 + Double((120 - i) / 8) * 40,
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
                        let set = SetModel(
                            userID: userID,
                            position: setIndex,
                            setType: .working,
                            reps: 8 + setIndex,
                            weight: lift.base + progression,
                            rpe: i % 5 == 0 ? nil : 8,
                            completedAt: start.addingTimeInterval(Double(600 + position * 900 + setIndex * 180))
                        )
                        // The detail chart reads persisted derived metrics, not
                        // just the raw weight/reps fields. Keep the deterministic
                        // acceptance history equivalent to a real completed set
                        // so visual chart checks exercise the rendered chart path.
                        set.recomputeDerivedMetrics()
                        return set
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
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if ForgeFitAppIntentWorkoutUITestFixture.isRequested {
            return true
        }
        #endif
        return arguments.contains("--reset-store")
            || requestedInitialTab != nil
            || UserDefaults.standard.bool(forKey: "autoStartRoutine")
            || arguments.contains("--auto-start-routine")
    }

    private var automationLaunchIsReady: Bool {
        didFinishLaunchTasks
    }

    private var shouldSeedStarterContent: Bool {
        isAutomationLaunch || ProcessInfo.processInfo.arguments.contains("--seed-starter-content")
    }

    private func clearStarterSlate() {
        let cancelsStarterRuntime = StarterSlatePolicy.cancelsLiveRuntimeForDeletion(
            activeWorkout: activeWorkout
        )
        PersistentChangeSaveCenter.shared.perform({
            // Keep this terminal cleanup out of the shared main context. A
            // rejected write can then be discarded with this short-lived
            // context instead of leaving phantom deletions for autosave.
            let cleanupContext = ModelContext(modelContext.container)
            cleanupContext.autosaveEnabled = false
            // Deletes only seeded starter content (starter routine, its setup
            // note, and unfinished starter-derived workouts); genuine user
            // work-in-progress survives via `routineID` provenance.
            try StarterSlateCleanup.run(in: cleanupContext)
        }, onSuccess: {
            // Runtime teardown is a consequence of a committed delete, never
            // something that happens while the starter workout remains live.
            if cancelsStarterRuntime {
                WorkoutFinisher.cancelLiveRuntime()
            }
        })
    }

    private func handleAccountReset() {
        setLiveWorkoutPerformancePriority(false)
        foregroundMaintenanceTask?.cancel()
        foregroundMaintenanceTask = nil
        deferredLaunchMaintenanceTask?.cancel()
        deferredLaunchMaintenanceTask = nil
        experimentEndTask?.cancel()
        experimentEndTask = nil
        experimentNotificationScheduleTask?.cancel()
        experimentNotificationScheduleTask = nil
        microcycleTransitionTask?.cancel()
        microcycleTransitionTask = nil
        appState.selectedTab = .home
        appState.showingLogger = false
        pendingLaunchLoggerPresentation = false
        pendingLaunchLoggerWorkoutID = nil
        presentedLoggerWorkoutID = nil
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
        themeManager.reset()
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

/// Rest/interval/yoga state changes are frequent while a logger is visible.
/// Observe them in this zero-sized leaf so starting a rest timer or advancing a
/// step does not re-evaluate ContentView's plan, lifecycle, and tab inputs.
private struct LiveRuntimeStateObserver: View {
    var restTimer = RestTimerController.shared
    var intervalHub = IntervalRunnerHub.shared
    var yogaHub = YogaFlowRunnerHub.shared
    let onRestTimerChange: (Date?) -> Void
    let onIntervalStepChange: () -> Void
    let onYogaStateChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: restTimer.endsAt) { _, endsAt in
                onRestTimerChange(endsAt)
            }
            .onChange(of: intervalHub.runner?.stepEndsAt) {
                onIntervalStepChange()
            }
            .onChange(of: yogaHub.runner?.stepEndsAt) {
                onYogaStateChange()
            }
            .onChange(of: yogaHub.runner?.isPaused) {
                onYogaStateChange()
            }
    }
}

#Preview {
    ContentView()
        .environment(ForgeFitIntentNavigator())
        .environmentObject(ThemeManager())
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
}
