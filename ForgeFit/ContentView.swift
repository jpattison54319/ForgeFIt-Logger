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
    @Environment(\.theme) private var theme
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @Query(sort: \UserExerciseNoteModel.updatedAt, order: .reverse) private var setupNotes: [UserExerciseNoteModel]
    @Query(sort: \RoutineModel.position) private var routines: [RoutineModel]
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var workouts: [WorkoutModel]
    @Query(filter: #Predicate<WorkoutModel> { $0.endedAt == nil && $0.deletedAt == nil }, sort: \WorkoutModel.startedAt, order: .reverse) private var activeWorkouts: [WorkoutModel]

    @State private var appState = AppState()
    @State private var restTimer = RestTimerController.shared
    @State private var watchLink = WatchLink.shared
    @State private var intervalHub = IntervalRunnerHub.shared
    @State private var showReplaceWorkoutConfirm = false
    @State private var workoutPendingDiscard: WorkoutModel?
    @State private var cleanedOnboardingSlate = false
    @State private var lastHealthWorkoutImportAt: Date?
    @State private var workoutCountReactionTask: Task<Void, Never>?
    @State private var readinessStampTask: Task<Void, Never>?
    @State private var liveSurfaceUpdateTask: Task<Void, Never>?
    @State private var didStartLaunchTasks = false
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

    /// Count of live completed workouts — changes when one is finished OR
    /// deleted, so downstream state (streak nudge, widget, watch) reacts to
    /// deletions immediately.
    private var completedWorkoutCount: Int {
        workouts.count { $0.endedAt != nil && $0.deletedAt == nil }
    }

    private var routineListVersion: String {
        let latest = routines.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(routines.count)|\(latest)"
    }

    var body: some View {
        ZStack {
            appShell

            if showBootSplash {
                BootSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
            .environment(appState)
            .preferredColorScheme(.dark)
            .tint(theme.accent)
            .fullScreenCover(isPresented: $appState.showingLogger) {
            if let activeWorkout = activeWorkoutForPresentation() {
                ActiveWorkoutLoggerView(
                    workout: activeWorkout,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    history: workouts,
                    onMinimize: { appState.showingLogger = false }
                )
            }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
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
            .onChange(of: showOnboarding) { _, isPresented in handleOnboardingPresentationChange(isPresented) }
            .onChange(of: appState.startRequestID) { _, requestID in handleStartRequestChange(requestID) }
            .onChange(of: routineListVersion) { WatchLink.shared.publishState() }
            .onChange(of: restTimer.endsAt) { _, endsAt in handleRestTimerChange(endsAt) }
            // Interval step transitions repaint the watch + Live Activity.
            .onChange(of: intervalHub.runner?.stepEndsAt) {
                WatchLink.shared.publishState()
                WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
            }
            .onChange(of: watchLink.liveMetrics?.heartRate) { _, heartRate in handleLiveHeartRateChange(heartRate) }
            .onChange(of: activeWorkout?.id) { oldID, newID in
                handleActiveWorkoutChange(oldID: oldID, newID: newID)
            }
            .onChange(of: appState.showingLogger) { _, isPresented in
                if !isPresented, let activeWorkout {
                    scheduleReadinessStamp(for: activeWorkout, delayMilliseconds: 100)
                }
            }
            // Deleting or finishing a workout changes today's training reality —
            // streak, nudge, widget, and watch snapshot must all follow. Deferred
            // and coalesced: the refreshes run full recovery/analytics passes, and
            // doing that synchronously stalls the dismiss/pop animation the user
            // is watching (first delete used to lag and drop its dismissal).
            .onChange(of: completedWorkoutCount) {
                workoutCountReactionTask?.cancel()
                workoutCountReactionTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    refreshStreakNudge()
                    updateWidgetSnapshot()
                    WatchLink.shared.publishState()
                }
            }
            .task { await runLaunchTasksIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: .forgeFitAccountResetDidComplete)) { _ in
                handleAccountReset()
            }
            .onChange(of: scenePhase) { _, phase in handleScenePhaseChange(phase) }
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
        }
    }

    @ViewBuilder
    private var tabScreens: some View {
        switch appState.selectedTab {
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
        scheduleLiveSurfaceUpdate()
    }

    private func handleLiveHeartRateChange(_ heartRate: Int?) {
        // Zone-lock guard: fire audible/haptic cues on leaving/re-entering the
        // target zone. Runs app-wide so it works on any screen.
        HRZoneGuard.shared.evaluate(hr: heartRate)
        scheduleLiveSurfaceUpdate()
    }

    private func scheduleLiveSurfaceUpdate() {
        liveSurfaceUpdateTask?.cancel()
        liveSurfaceUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
            updateWidgetSnapshot()
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
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
            refreshStreakNudge()
            updateWidgetSnapshot()
        } else if phase == .background {
            // Leave the widget with the freshest snapshot we have — otherwise it
            // would serve whatever it last read until the next app open.
            updateWidgetSnapshot()
        }
    }

    /// Keep the streak-protection nudge honest: scheduled only while an
    /// active streak would break today.
    private func refreshStreakNudge() {
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        NotificationScheduler.shared.refreshStreakNudge(
            streak: analytics.currentStreak(),
            trainedToday: analytics.trainedToday()
        )
    }

    private func handleActiveWorkoutChange(oldID: UUID?, newID: UUID?) {
        WatchLink.shared.publishState(force: newID != nil)
        if newID == nil {
            readinessStampTask?.cancel()
            liveSurfaceUpdateTask?.cancel()
            WorkoutActivityController.shared.end()
            RestTimerController.shared.skip()
            IntervalRunnerHub.shared.stop()
            WatchLink.shared.clearLiveMetrics()
        } else {
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
            workout.readinessAtStart = Int(RecoveryEngine(workouts: workouts, exercises: exercises, healthMetrics: HealthMetricsStore.shared.metrics).report().displayScore * 100)
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

        let minimumSplashSeconds = 0.65
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
        await seedLaunchData()
        await ImportedExerciseBackfill.runIfNeeded(in: modelContext)
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
        HealthMetricsStore.shared.refresh()
        NotificationScheduler.shared.activate()
        refreshStreakNudge()
        updateWidgetSnapshot()
        WorkoutActivityController.shared.update(workout: activeWorkout, exercises: exercises)
    }

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
            let report = RecoveryEngine(
                workouts: workouts,
                exercises: exercises,
                healthMetrics: HealthMetricsStore.shared.metrics
            ).report()
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
            heartRate: WatchLink.shared.liveMetrics?.heartRate
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
            if ProcessInfo.processInfo.arguments.contains("--reset-store") {
                try AccountResetService.deleteAllLocalModels(in: modelContext)
            }
            try ExerciseSeedRepository.seedGlobalLibrary(in: modelContext)
            ExerciseCatalog.seed(into: modelContext)
            if shouldSeedStarterContent {
                try seedStarterSetupNote()
                try seedStarterRoutine()
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
                        .font(.system(size: 34, weight: .bold))
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
        .modelContainer(for: ForgeDataSchema.models, inMemory: true)
}
