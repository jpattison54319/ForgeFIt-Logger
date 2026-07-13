import ForgeCore
import ForgeData
import Observation
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - Set-type presentation

/// Visual style for each set type: a short badge, a color, and a menu label.
struct SetTypeStyle {
    let badge: String
    let color: Color
    let label: String
    /// Whether this type consumes a numbered working-set slot.
    let numbered: Bool

    static func of(_ type: SetType) -> SetTypeStyle {
        let t = AppTheme.sage
        switch type {
        case .warmup: return SetTypeStyle(badge: "W", color: t.warmup, label: "Warm-up", numbered: false)
        case .working: return SetTypeStyle(badge: "", color: t.textPrimary, label: "Working", numbered: true)
        case .drop: return SetTypeStyle(badge: "D", color: t.accent, label: "Drop set", numbered: false)
        case .restPause: return SetTypeStyle(badge: "R", color: t.secondaryAccent, label: "Rest-pause", numbered: false)
        case .backoff: return SetTypeStyle(badge: "B", color: t.secondaryAccent, label: "Back-off", numbered: true)
        case .amrap: return SetTypeStyle(badge: "A", color: t.warmup, label: "AMRAP", numbered: true)
        case .myoRep: return SetTypeStyle(badge: "M", color: t.accent, label: "Myo-reps", numbered: false)
        case .cluster: return SetTypeStyle(badge: "C", color: t.secondaryAccent, label: "Cluster", numbered: false)
        }
    }
}

enum WorkoutLoggerMode {
    case active
    case historicalEdit
}

/// Full-screen active-workout logger with per-set type selection, dynamic
/// columns per exercise, inline reordering, sticky notes, and add/replace/remove.
struct ActiveWorkoutLoggerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    var history: [WorkoutModel] = []
    var mode: WorkoutLoggerMode = .active
    var onMinimize: (() -> Void)? = nil
    /// Called with the just-finished workout after a successful finish, so the
    /// host can publish it to social (if the user has opted in).
    var onFinished: ((WorkoutModel) -> Void)? = nil

    @State private var reordering = false
    @State private var showAddPicker = false
    @State private var replaceTarget: WorkoutExerciseModel?
    /// This session's progression suggestions, keyed by workout-exercise id.
    @State private var progressionByWorkoutExercise: [UUID: ProgressionSuggestionModel] = [:]
    @State private var showPostWorkoutSummary = false
    @State private var showEmptyDiscardConfirm = false
    @State private var detailExercise: ExerciseLibraryModel?
    /// Best prior values per exercise — the bar a set must clear to earn a
    /// record award. Computed once; history doesn't change mid-session.
    @State private var recordBaselines: [UUID: ExerciseRecordBaseline] = [:]
    @State private var widgetSnapshotTask: Task<Void, Never>?
    @State private var liveSurfacePublishTask: Task<Void, Never>?
    @State private var previousSetsByExerciseID: [UUID: [SetModel]] = [:]
    @State private var liveStats = WorkoutLiveStats()
    /// Cached modality flags — see `computeModalityFlags()`.
    @State private var isPureCardio = false
    @State private var isPureYoga = false
    @State private var inputRouter = SetInputRouter()
    @AppStorage(WorkoutEffortPolicy.loggingEnabledKey) private var showRPEInLogger = false
    @AppStorage("effortScaleRaw") private var effortScaleRaw = EffortScale.rpe.rawValue
    @AppStorage(WorkoutEffortPolicy.failureTrainingKey) private var failureTrainingEnabled = false

    private var sortedExercises: [WorkoutExerciseModel] {
        workout.exercises.sorted { $0.position < $1.position }
    }
    private var supersetGroups: [Int] {
        Array(Set(workout.exercises.compactMap(\.supersetGroup))).sorted()
    }
    /// Library entries for what's already in this workout — the picker's
    /// suggestion context.
    private var exercisesInWorkout: [ExerciseLibraryModel] {
        workout.exercises.compactMap { we in exercises.first { $0.id == we.exerciseID } }
    }
    private var isHistoricalEdit: Bool { mode == .historicalEdit }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()
            if reordering {
                reorderList
                    .transition(.opacity)
            } else {
                loggerScroll
                    .transition(.opacity)
            }
        }
        // The header lives in the safe area, so content can never slide
        // underneath it or collide with the stats bar.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                if !reordering {
                    statsBar
                        .padding(.horizontal, Space.lg)
                        .padding(.bottom, Space.sm)
                    // The rest countdown gets its own full-width strip below
                    // the stats instead of cramming into the top bar.
                    if !isHistoricalEdit {
                        RestTimerBar()
                            .padding(.horizontal, Space.lg)
                            .padding(.bottom, Space.sm)
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: RestTimerController.shared.isRunning)
        }
        .environment(inputRouter)
        .onAppear(perform: reconcileEffortVisibility)
        .onChange(of: showRPEInLogger) { _, _ in reconcileEffortVisibility() }
        // One keyboard toolbar for every set input in the logger, driven by
        // whichever field registered itself with the router on focus. A
        // single root-level toolbar can't hit the per-field UIKit
        // toolbar-reuse bug that used to blank the accessory buttons.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if let actions = inputRouter.active {
                    Button {
                        actions.onDismiss()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Dismiss keyboard")
                    Spacer()
                    if let onNext = actions.onNext {
                        Button("Next", action: onNext)
                            .font(.bodyStrong)
                            .tint(theme.accent)
                    }
                    Button(actions.completeTitle, action: actions.onComplete)
                        .font(.bodyStrong)
                        .tint(theme.accent)
                }
            }
        }
        // Reference caches walk the full workout history — built after the
        // first frame so the cover presents instantly. Rows show "—" for the
        // previous column for a frame or two, then fill in.
        .task {
            await Task.yield()
            await refreshReferenceCaches()
        }
        .sheet(isPresented: $showPostWorkoutSummary) {
            PostWorkoutSummaryView(
                workout: workout,
                exercises: exercises,
                history: history,
                onSave: finishAndDismiss,
                onCancel: { showPostWorkoutSummary = false }
            )
        }
        .confirmationDialog(
            "Discard empty workout?",
            isPresented: $showEmptyDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard Workout", role: .destructive) {
                WorkoutFinisher.discard(workout, in: modelContext)
                dismiss()
            }
            Button("Keep Logging", role: .cancel) {}
        } message: {
            Text("Nothing was completed — there's nothing to save to your history or Apple Health.")
        }
        .sheet(isPresented: $showAddPicker) {
            ExercisePickerView(excludeYogaPoses: true, context: exercisesInWorkout, history: history) { added in addExercises(added) }
        }
        .sheet(item: $replaceTarget) { target in
            // Gym swap: lead with close substitutes for the exercise being
            // replaced (search stays one tap away inside the sheet). The plain
            // picker remains the fallback for rows whose exercise is missing.
            if let currentExercise = exercises.first(where: { $0.id == target.exerciseID }) {
                ExerciseSwapSheet(
                    current: currentExercise,
                    allExercises: exercises,
                    inUseIDs: Set(workout.exercises.map(\.exerciseID)),
                    history: history
                ) { picked in
                    replace(target, with: picked)
                }
            } else {
                ExercisePickerView(singleSelection: true, excludeYogaPoses: true, context: exercisesInWorkout, history: history) { picked in
                    if let first = picked.first { replace(target, with: first) }
                }
            }
        }
        .sheet(item: $detailExercise) { exercise in
            NavigationStack {
                ExerciseDetailView(
                    exerciseID: exercise.id,
                    workouts: history.isEmpty ? [workout] : history,
                    exercises: exercises
                )
            }
        }
    }

    private var loggerScroll: some View {
        ScrollView(showsIndicators: false) {
            // Lazy: long workouts only build the cards on screen, and focus /
            // keystroke re-renders don't touch off-screen exercises.
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                ForEach(sortedExercises, id: \.id) { we in
                    exerciseCard(for: we)
                }
                if workout.exercises.isEmpty {
                    emptyLoggerState
                }
                SecondaryButton(title: "Add Exercise", systemImage: "plus") { showAddPicker = true }
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.sm)
            .padding(.bottom, 40)
            // Tapping any non-interactive spot (card chrome, labels, empty
            // space) drops the keyboard — controls layered above win their
            // own taps first, so buttons/fields are unaffected.
            .onTapGesture { hideKeyboard() }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Reorder mode

    private var reorderList: some View {
        List {
            ForEach(sortedExercises) { we in
                // The native move control lifts this entire row and opens an
                // insertion gap as it travels. Rendering the real logger card
                // here keeps the exercise visibly attached to the user's
                // thumb instead of swapping it for an ambiguous compact row.
                exerciseCard(for: we, isReorderPreview: true)
                    .allowsHitTesting(false)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(
                        EdgeInsets(
                            top: Space.sm,
                            leading: Space.lg,
                            bottom: Space.sm,
                            trailing: Space.sm
                        )
                    )
            }
            .onMove(perform: moveExercises)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .environment(\.editMode, .constant(.active))
        .accessibilityIdentifier("live-workout-reorder-list")
    }

    @ViewBuilder
    private func exerciseCard(
        for we: WorkoutExerciseModel,
        isReorderPreview: Bool = false
    ) -> some View {
        let ex = exercises.first { $0.id == we.exerciseID }
        let isYogaRow = ex?.isYoga == true
            || we.yogaFlowJSON != nil
            || workout.cardioSessions.contains { $0.workoutExerciseID == we.id && $0.isYogaSession }
        if isYogaRow {
            YogaExerciseCard(
                workout: workout,
                workoutExercise: we,
                exercise: ex,
                allowsLiveControls: !isHistoricalEdit,
                availableSupersetGroups: supersetGroups,
                onAssignSuperset: { assignSuperset($0, to: we) },
                onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: we) },
                onUngroupSuperset: { ungroupSuperset($0) },
                onShowExerciseDetail: { exercise in detailExercise = exercise },
                onReplace: { replaceTarget = we },
                onRemove: { removeExercise(we) }
            )
        } else if ex?.isCardio == true {
            CardioExerciseCard(
                workout: workout,
                workoutExercise: we,
                exercise: ex,
                allowsLiveControls: !isHistoricalEdit,
                availableSupersetGroups: supersetGroups,
                onAssignSuperset: { assignSuperset($0, to: we) },
                onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: we) },
                onUngroupSuperset: { ungroupSuperset($0) },
                onShowExerciseDetail: { exercise in detailExercise = exercise },
                onReplace: { replaceTarget = we },
                onRemove: { removeExercise(we) },
                history: history
            )
        } else {
            ExerciseLogCard(
                workout: workout,
                workoutExercise: we,
                exercise: ex,
                pinnedNote: setupNotes.first { $0.exerciseID == we.exerciseID && $0.userID == ForgeFitDemo.userID },
                previousSets: cachedPreviousSets(for: we),
                recordBaseline: recordBaselines[we.exerciseID],
                allowsRestTimers: !isHistoricalEdit,
                allowsCollapse: !isHistoricalEdit,
                showRPE: showRPEInLogger,
                failureTrainingEnabled: showRPEInLogger && failureTrainingEnabled,
                showsPreviousTapHint: !isHistoricalEdit,
                showsReorderHandle: !isReorderPreview,
                effortScale: EffortScale(rawValue: effortScaleRaw) ?? .rpe,
                completionDate: isHistoricalEdit ? (workout.endedAt ?? workout.startedAt) : nil,
                availableSupersetGroups: supersetGroups,
                onAssignSuperset: { assignSuperset($0, to: we) },
                onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: we) },
                onUngroupSuperset: { ungroupSuperset($0) },
                onCompletedSet: { set in handleCompletedSet(set, in: we) },
                onLiveStatsChanged: refreshLiveStats,
                onWorkoutChanged: publishWorkoutChange,
                onShowExerciseDetail: { exercise in detailExercise = exercise },
                onReplace: { replaceTarget = we },
                onRemove: { removeExercise(we) },
                onReorder: { withAnimation(.snappy(duration: 0.22)) { reordering = true } },
                progression: progressionByWorkoutExercise[we.id],
                onRejectProgression: { rejectProgression(for: we) }
            )
            // Keyed by row + *library* exercise so a gym swap tears down card
            // state and the replacement begins with clean drafts.
            .id("\(we.id.uuidString)-\(we.exerciseID.uuidString)")
        }
    }

    // MARK: - Header

    private var header: some View {
        GlassEffectContainer(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                if reordering {
                    Text("Reorder")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("Done") { withAnimation { reordering = false } }
                        .font(.bodyStrong)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("live-reorder-done")
                } else {
                    CircleIconButton(systemImage: isHistoricalEdit ? "xmark" : "chevron.down", label: isHistoricalEdit ? "Close editor" : "Minimize workout") {
                        if isHistoricalEdit {
                            saveHistoricalEdit()
                        } else if let onMinimize {
                            onMinimize()
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier(isHistoricalEdit ? "close-workout-editor" : "minimize-workout")
                    Text(isHistoricalEdit ? "Edit Workout" : "Log Workout")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if !isHistoricalEdit && !RestTimerController.shared.isRunning {
                        // Start a rest manually at any point.
                        RestDurationMenu(
                            options: [30, 60, 90, 120, 180, 300],
                            allowsOff: false,
                            selected: nil,
                            onPick: { seconds in
                                if let seconds { RestTimerController.shared.start(seconds: seconds, label: "Rest") }
                            }
                        ) {
                            Image(systemName: "timer")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                                .frame(width: 44, height: 44)   // HIG minimum touch target
                        }
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Start rest timer")
                    }
                    Button {
                        if isHistoricalEdit {
                            saveHistoricalEdit()
                        } else if !WorkoutFinisher.hasSubstance(workout) {
                            // Nothing logged: the celebratory summary would be
                            // all zeros, and finishing would discard anyway
                            // (WorkoutFinisher's empty-workout guard) — ask
                            // the one honest question instead.
                            showEmptyDiscardConfirm = true
                        } else {
                            // Straight to the summary — it IS the confirmation
                            // (Save Workout / Keep Logging live there). The old
                            // intermediate "Finish this workout?" dialog made
                            // every workout a double-confirm.
                            showPostWorkoutSummary = true
                        }
                    } label: {
                        Text(isHistoricalEdit ? "Save" : "Finish")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("finish-workout-button")
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, 6)
        .padding(.bottom, Space.sm)
    }

    /// Cached, not computed: `statsContent` re-evaluates every second inside
    /// its TimelineView, and each purity check was an O(library) scan per
    /// tick. A workout only changes modality via add/remove/replace — all of
    /// which run `refreshReferenceCaches()`, which recomputes these.
    private func computeModalityFlags() {
        isPureCardio = !workout.exercises.isEmpty && workout.exercises.allSatisfy { we in
            exercises.first { $0.id == we.exerciseID }?.isCardio == true
        }
        // A session that is all yoga gets a calm, session-shaped header —
        // duration, poses, heart rate — instead of volume/sets.
        isPureYoga = !workout.exercises.isEmpty && workout.exercises.allSatisfy { we in
            exercises.first { $0.id == we.exerciseID }?.isYoga == true
        }
    }

    @ViewBuilder
    private var statsBar: some View {
        if isHistoricalEdit {
            statsContent(elapsed: historicalDuration)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statsContent(elapsed: max(0, Int(context.date.timeIntervalSince(workout.startedAt))))
            }
        }
    }

    private var historicalDuration: Int {
        guard let endedAt = workout.endedAt else { return 0 }
        return max(0, Int(endedAt.timeIntervalSince(workout.startedAt)))
    }

    private func statsContent(elapsed: Int) -> some View {
        HStack {
            if isPureYoga {
                let loggedTime = workout.cardioSessions.compactMap { $0.durationSeconds }.reduce(0, +)
                let poses = workout.cardioSessions.compactMap { $0.posesCompleted }.reduce(0, +)
                let hrs = workout.cardioSessions.compactMap { $0.avgHR }
                StatColumn(label: "Duration", value: Fmt.durationShort(loggedTime > 0 ? loggedTime : elapsed), valueColor: theme.accent)
                StatColumn(label: "Poses", value: poses > 0 ? "\(poses)" : "—")
                StatColumn(label: "Avg HR", value: hrs.isEmpty ? "—" : "\(hrs.reduce(0,+) / hrs.count)")
                if !isHistoricalEdit {
                    LiveHeartRateStat()
                }
            } else if isPureCardio {
                let totalDist = workout.cardioSessions.compactMap { $0.distanceMeters }.reduce(0, +)
                let loggedTime = workout.cardioSessions.compactMap { $0.durationSeconds }.reduce(0, +)
                let hrs = workout.cardioSessions.compactMap { $0.avgHR }
                StatColumn(label: "Duration", value: Fmt.durationShort(loggedTime > 0 ? loggedTime : elapsed), valueColor: theme.secondaryAccent)
                StatColumn(label: "Distance", value: totalDist > 0 ? Fmt.distance(totalDist) : "—")
                StatColumn(label: "Avg HR", value: hrs.isEmpty ? "—" : "\(hrs.reduce(0,+) / hrs.count)")
            } else {
                // Neutral, not accent: the live timer is a data readout, not a
                // control. Reserving sage for interactive elements lets the
                // Finish button and tappable fields actually stand out.
                StatColumn(label: "Duration", value: Fmt.elapsed(elapsed))
                // Volume/Sets read `liveStats` inside their OWN body, so a set
                // completion (which mutates liveStats in place) re-renders only
                // these two columns — not statsContent or the exercise list.
                LiveVolumeSetsColumns(liveStats: liveStats)
                if !isHistoricalEdit {
                    LiveHeartRateStat()
                }
            }
        }
        .padding(.vertical, Space.md)
        .padding(.horizontal, Space.md)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
        .glassEffect(.regular.tint(theme.surfaceElevated.opacity(0.28)), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: - Data + mutations

    /// Live volume/sets counters. An @Observable reference (mutated in place by
    /// `refreshLiveStats`) so only the columns that read it re-render on a set
    /// completion, not the whole logger. See `LiveVolumeSetsColumns`.
    @Observable final class WorkoutLiveStats {
        var volume: Double = 0
        /// Effective sets (`VolumeMath.effectiveSetCount`) — fractional.
        var completedSets: Double = 0
    }

    /// Isolated reader of `liveStats`: keeping the `.volume`/`.completedSets`
    /// reads out of the root body is what stops every set completion from
    /// re-rendering all visible exercise cards.
    private struct LiveVolumeSetsColumns: View {
        let liveStats: WorkoutLiveStats

        var body: some View {
            Group {
                StatColumn(label: "Volume", value: Fmt.volume(liveStats.volume))
                StatColumn(label: "Sets", value: Fmt.sets(liveStats.completedSets))
            }
        }
    }

    /// Reads `LiveMetricsHub` inside its OWN body so the Observation
    /// dependency registers here — a heart-rate tick (~every second while
    /// streaming) re-renders this one column instead of the entire logger.
    /// With no live source but a paired BLE monitor, a dimmed placeholder
    /// reminds the user their monitor isn't broadcasting yet.
    private struct LiveHeartRateStat: View {
        @Environment(\.theme) private var theme

        var body: some View {
            if let hr = LiveMetricsHub.shared.liveMetrics?.heartRate {
                StatColumn(label: "HR", value: "\(hr)", valueColor: theme.danger)
            } else if BLEHeartRateService.shared.hasRememberedMonitor {
                StatColumn(label: "HR", value: "—", valueColor: theme.textTertiary)
                    .accessibilityLabel("Heart rate waiting — start broadcast on your monitor")
            }
        }
    }

    /// Guided empty state (F5): one-tap picks so the first exercise never
    /// requires a search — recents first, focus-matched staples otherwise.
    private var emptyLoggerState: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            EmptyStateCard(
                title: "Ready to log",
                message: "Add your first exercise — quick picks below, or search the full library.",
                systemImage: "plus.circle"
            )
            ForEach(suggestedStarterExercises, id: \.id) { exercise in
                Button {
                    addExercises([exercise])
                } label: {
                    HStack(spacing: Space.md) {
                        Text(exercise.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                    .padding(Space.md)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private var suggestedStarterExercises: [ExerciseLibraryModel] {
        var picks: [ExerciseLibraryModel] = []
        let completed = history
            .filter { $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
        for past in completed {
            for we in past.exercises {
                guard picks.count < 4 else { return picks }
                if let exercise = exercises.first(where: { $0.id == we.exerciseID }),
                   !exercise.isYoga,
                   !picks.contains(where: { $0.id == exercise.id }) {
                    picks.append(exercise)
                }
            }
        }
        for slug in TrainingFocus.stored.starterExerciseSlugs where picks.count < 4 {
            let id = ExerciseCatalog.deterministicID(for: slug)
            if let exercise = exercises.first(where: { $0.id == id }),
               !picks.contains(where: { $0.id == exercise.id }) {
                picks.append(exercise)
            }
        }
        return picks
    }

    private struct ReferenceCaches {
        var recordBaselines: [UUID: ExerciseRecordBaseline]
        var previousSetsByExerciseID: [UUID: [SetModel]]
    }

    private func refreshReferenceCaches() async {
        computeModalityFlags()
        let caches = await buildReferenceCaches()
        guard !Task.isCancelled else { return }
        recordBaselines = caches.recordBaselines
        previousSetsByExerciseID = caches.previousSetsByExerciseID
        refreshProgressionSuggestions()
        refreshLiveStats()
    }

    private func buildReferenceCaches() async -> ReferenceCaches {
        let exerciseIDs = Set(workout.exercises.map(\.exerciseID))
        var baselines: [UUID: ExerciseRecordBaseline] = [:]
        var previousSets = Dictionary(exerciseIDs.map { ($0, [SetModel]()) }, uniquingKeysWith: { first, _ in first })
        guard !exerciseIDs.isEmpty else {
            return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
        }

        let prior = sortedPriorWorkouts()
        let routineMatches = workout.routineID.map { routineID in prior.filter { $0.routineID == routineID } } ?? []
        let routineMatchIDs = Set(routineMatches.map(\.id))
        let fallback = prior.filter { !routineMatchIDs.contains($0.id) }

        let baselinePrior = prior.filter { $0.startedAt < workout.startedAt }
        for (index, past) in baselinePrior.enumerated() {
            for we in past.exercises where exerciseIDs.contains(we.exerciseID) {
                var baseline = baselines[we.exerciseID] ?? ExerciseRecordBaseline()
                for set in we.sets { baseline.absorb(set) }
                baselines[we.exerciseID] = baseline
            }
            if index.isMultiple(of: 20) {
                await Task.yield()
                if Task.isCancelled {
                    return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
                }
            }
        }

        var unresolved = exerciseIDs
        for (index, past) in (routineMatches + fallback).enumerated() {
            for we in past.exercises where unresolved.contains(we.exerciseID) {
                let sets = we.sets.filter { $0.completedAt != nil }.sorted { $0.position < $1.position }
                if !sets.isEmpty {
                    previousSets[we.exerciseID] = sets
                    unresolved.remove(we.exerciseID)
                }
            }
            if unresolved.isEmpty { break }
            if index.isMultiple(of: 20) {
                await Task.yield()
                if Task.isCancelled {
                    return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
                }
            }
        }

        return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
    }

    private func refreshProgressionSuggestions() {
        let workoutID = workout.id
        let all = (try? modelContext.fetch(FetchDescriptor<ProgressionSuggestionModel>(
            predicate: #Predicate { $0.workoutID == workoutID && $0.deletedAt == nil }
        ))) ?? []
        progressionByWorkoutExercise = Dictionary(all.map { ($0.workoutExerciseID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Banner ✕: record the rejection and clear the engine-advanced values so
    /// the ghost placeholders fall back to last session's numbers.
    private func rejectProgression(for workoutExercise: WorkoutExerciseModel) {
        guard let suggestion = progressionByWorkoutExercise[workoutExercise.id],
              suggestion.statusRaw == "pending" else { return }
        suggestion.statusRaw = "rejected"
        suggestion.updatedAt = Date()
        for set in workoutExercise.sets
        where set.completedAt == nil && !set.setType.isBlockType && set.setType != .warmup {
            if set.weightMode == .external { set.weight = nil }
            set.reps = nil
            set.recomputeDerivedMetrics()
        }
        try? modelContext.save()
        publishWorkoutChange()
    }

    private func sortedPriorWorkouts() -> [WorkoutModel] {
        history
            .filter { $0.id != workout.id && $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func cachedPreviousSets(for workoutExercise: WorkoutExerciseModel) -> [SetModel] {
        if let cached = previousSetsByExerciseID[workoutExercise.exerciseID] {
            return cached
        }
        // Before the deferred cache build lands, render "—" instead of
        // re-walking the whole history per card on the very first frame.
        guard !previousSetsByExerciseID.isEmpty else { return [] }
        return previousSets(for: workoutExercise.exerciseID)
    }

    private func previousSets(for exerciseID: UUID) -> [SetModel] {
        let prior = history
            .filter { $0.id != workout.id && $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }
        let routineMatches = workout.routineID.map { routineID in prior.filter { $0.routineID == routineID } } ?? []
        let fallback = prior.filter { priorWorkout in !routineMatches.contains { $0.id == priorWorkout.id } }
        return previousSets(for: exerciseID, routineMatches: routineMatches, fallback: fallback)
    }

    private func previousSets(
        for exerciseID: UUID,
        routineMatches: [WorkoutModel],
        fallback: [WorkoutModel]
    ) -> [SetModel] {
        for p in routineMatches + fallback {
            if let we = p.exercises.first(where: { $0.exerciseID == exerciseID }) {
                let sets = we.sets.filter { $0.completedAt != nil }.sorted { $0.position < $1.position }
                if !sets.isEmpty { return sets }
            }
        }
        return []
    }

    /// Recompute the live counters in place — mutating the @Observable object
    /// invalidates only `LiveVolumeSetsColumns`, not the whole logger body.
    private func refreshLiveStats() {
        let completed = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        liveStats.volume = completed.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        liveStats.completedSets = completed.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }
    }

    private func addExercises(_ list: [ExerciseLibraryModel]) {
        let yogaSelections = list.filter(\.isYoga)
        var addedYogaSession = false
        for exercise in list {
            if exercise.isYoga {
                guard !addedYogaSession else { continue }
                addedYogaSession = true
                addYogaSession(from: yogaSelections)
                continue
            }
            // Cardio exercises follow the cardio data model (a linked session),
            // not strength sets.
            let we = WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: exercise.id,
                position: workout.exercises.count,
                sets: exercise.isCardio ? [] : [SetModel(userID: ForgeFitDemo.userID, position: 0, weightMode: exercise.defaultWeightMode)]
            )
            if !exercise.isCardio, let pinned = setupNotes.first(where: { $0.exerciseID == exercise.id && $0.userID == ForgeFitDemo.userID }) {
                we.notes = pinned.note
                we.notePinned = true
            }
            modelContext.insert(we)
            workout.exercises.append(we)
            previousSetsByExerciseID[exercise.id] = []
            if exercise.isCardio {
                let kind = CardioKind.infer(name: exercise.name, equipment: exercise.equipment)
                let session = CardioSessionModel(
                    userID: ForgeFitDemo.userID,
                    workoutExerciseID: we.id,
                    modality: kind.rawValue,
                    startedAt: isHistoricalEdit ? workout.startedAt : Date(),
                    endedAt: isHistoricalEdit ? workout.endedAt : nil,
                    durationSeconds: isHistoricalEdit && historicalDuration > 0 ? historicalDuration : nil
                )
                modelContext.insert(session)
                workout.cardioSessions.append(session)
            }
        }
        refreshLiveStats()
        try? modelContext.save()
        publishWorkoutChange()
        Task { await refreshReferenceCaches() }
    }

    private func addYogaSession(from selections: [ExerciseLibraryModel]) {
        let sessionExercise = YogaPoseCatalog.sessionExercise(in: modelContext)
        let plan = YogaFlowPlan.fromSelectedPoses(selections)
        let we = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: sessionExercise.id,
            position: workout.exercises.count,
            yogaFlowJSON: plan?.encodedJSON(),
            sets: []
        )
        modelContext.insert(we)
        workout.exercises.append(we)
        previousSetsByExerciseID[sessionExercise.id] = []
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: we.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: isHistoricalEdit ? workout.startedAt : Date(),
            endedAt: isHistoricalEdit ? workout.endedAt : nil,
            sourceDevice: isHistoricalEdit ? nil : "iphone-yoga",
            durationSeconds: plan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil },
            yogaStyleRaw: plan?.styleRaw
        )
        modelContext.insert(session)
        workout.cardioSessions.append(session)
    }

    private func replace(_ target: WorkoutExerciseModel, with exercise: ExerciseLibraryModel) {
        let previousExercise = exercises.first { $0.id == target.exerciseID }
        let wasSessionBased = previousExercise?.isCardio == true
            || previousExercise?.isYoga == true
            || workout.cardioSessions.contains { $0.workoutExerciseID == target.id }
        let replacement = exercise.isYoga ? YogaPoseCatalog.sessionExercise(in: modelContext) : exercise
        target.exerciseID = replacement.id
        target.updatedAt = Date()
        previousSetsByExerciseID[replacement.id] = []
        recordBaselines[replacement.id] = nil
        if exercise.isYoga {
            let plan = YogaFlowPlan.fromSelectedPoses([exercise]) ?? YogaFlowPlan.decode(from: target.yogaFlowJSON)
            target.yogaFlowJSON = plan?.encodedJSON()
            for set in target.sets {
                modelContext.delete(set)
            }
            target.sets = []
            let existingSession = workout.cardioSessions.first { $0.workoutExerciseID == target.id }
            if let existingSession {
                existingSession.modality = CardioSessionModel.yogaModality
                existingSession.sourceDevice = isHistoricalEdit ? nil : "iphone-yoga"
                existingSession.durationSeconds = isHistoricalEdit && historicalDuration > 0
                    ? historicalDuration
                    : plan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil }
                existingSession.yogaStyleRaw = plan?.styleRaw
            } else {
                let session = CardioSessionModel(
                    userID: ForgeFitDemo.userID,
                    workoutExerciseID: target.id,
                    modality: CardioSessionModel.yogaModality,
                    startedAt: isHistoricalEdit ? workout.startedAt : Date(),
                    endedAt: isHistoricalEdit ? workout.endedAt : nil,
                    sourceDevice: isHistoricalEdit ? nil : "iphone-yoga",
                    durationSeconds: isHistoricalEdit && historicalDuration > 0
                        ? historicalDuration
                        : plan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil },
                    yogaStyleRaw: plan?.styleRaw
                )
                modelContext.insert(session)
                workout.cardioSessions.append(session)
            }
        } else if exercise.isCardio {
            target.yogaFlowJSON = nil
            for set in target.sets {
                modelContext.delete(set)
            }
            target.sets = []
            let existingSession = workout.cardioSessions.first { $0.workoutExerciseID == target.id }
            let kind = CardioKind.infer(name: exercise.name, equipment: exercise.equipment)
            if let existingSession {
                existingSession.modality = kind.rawValue
                existingSession.sourceDevice = isHistoricalEdit ? nil : "iphone-cardio-\(kind.rawValue)"
                existingSession.durationSeconds = isHistoricalEdit && historicalDuration > 0 ? historicalDuration : nil
                existingSession.yogaStyleRaw = nil
            } else {
                let session = CardioSessionModel(
                    userID: ForgeFitDemo.userID,
                    workoutExerciseID: target.id,
                    modality: kind.rawValue,
                    startedAt: isHistoricalEdit ? workout.startedAt : Date(),
                    endedAt: isHistoricalEdit ? workout.endedAt : nil,
                    sourceDevice: isHistoricalEdit ? nil : "iphone-cardio-\(kind.rawValue)",
                    durationSeconds: isHistoricalEdit && historicalDuration > 0 ? historicalDuration : nil
                )
                modelContext.insert(session)
                workout.cardioSessions.append(session)
            }
        } else {
            target.yogaFlowJSON = nil
            if wasSessionBased {
                deleteCardioSessions(for: target.id)
            }
            if target.sets.isEmpty {
                let set = SetModel(userID: ForgeFitDemo.userID, position: 0, weightMode: exercise.defaultWeightMode)
                modelContext.insert(set)
                target.sets = [set]
            } else {
                // The gym-swap contract: set count and set types carry over,
                // but values belong to the exercise they were entered for.
                // Uncompleted sets restart clean so PREVIOUS/ghosts/RPE
                // re-source from the replacement's own history (empty when it
                // has none — a carried myo-rep block the new exercise has
                // never done just starts blank). Completed sets are facts and
                // stay exactly as logged.
                // A swap invalidates the old exercise's suggestion — the new
                // exercise earns its own next session.
                if let suggestion = progressionByWorkoutExercise[target.id], suggestion.statusRaw == "pending" {
                    suggestion.statusRaw = "rejected"
                    suggestion.updatedAt = Date()
                }
                for set in target.sets where set.completedAt == nil {
                    set.weightMode = exercise.defaultWeightMode
                    set.isUnilateral = exercise.isUnilateral
                    set.weight = nil
                    set.reps = nil
                    set.rpe = nil
                    set.rir = nil
                    set.durationSeconds = nil
                    set.holdSeconds = nil
                    set.partialReps = nil
                    set.addedWeight = nil
                    set.assistanceWeight = nil
                    set.implementWeight = nil
                    set.side2Reps = nil
                    set.miniRepsJSON = nil
                    set.machineSettingsJSON = nil
                    set.recomputeDerivedMetrics()
                }
            }
        }
        try? modelContext.save()
        publishWorkoutChange()
        Task { await refreshReferenceCaches() }
    }

    private func removeExercise(_ we: WorkoutExerciseModel) {
        deleteCardioSessions(for: we.id)
        modelContext.delete(we)
        for (i, e) in sortedExercises.filter({ $0.id != we.id }).enumerated() { e.position = i }
        workout.recomputeTotalVolume()
        refreshLiveStats()
        try? modelContext.save()
        publishWorkoutChange()
    }

    private func deleteCardioSessions(for workoutExerciseID: UUID) {
        for session in workout.cardioSessions.filter({ $0.workoutExerciseID == workoutExerciseID }) {
            modelContext.delete(session)
        }
        workout.cardioSessions.removeAll { $0.workoutExerciseID == workoutExerciseID }
    }

    private func moveExercises(from offsets: IndexSet, to destination: Int) {
        var rows = sortedExercises
        rows.move(fromOffsets: offsets, toOffset: destination)
        for (i, e) in rows.enumerated() { e.position = i }
        try? modelContext.save()
    }

    private func nextSupersetGroup() -> Int {
        var candidate = 0
        let used = Set(supersetGroups)
        while used.contains(candidate) { candidate += 1 }
        return candidate
    }

    private func assignSuperset(_ group: Int?, to we: WorkoutExerciseModel) {
        we.supersetGroup = group
        we.updatedAt = Date()
        compactSupersetPositions()
        try? modelContext.save()
        WatchLink.shared.publishState()
    }

    private func ungroupSuperset(_ group: Int) {
        for exercise in workout.exercises where exercise.supersetGroup == group {
            exercise.supersetGroup = nil
            exercise.updatedAt = Date()
        }
        compactSupersetPositions()
        try? modelContext.save()
        WatchLink.shared.publishState()
    }

    private func compactSupersetPositions() {
        let rows = sortedExercises
        var output: [WorkoutExerciseModel] = []
        var seenGroups = Set<Int>()

        for row in rows {
            guard let group = row.supersetGroup else {
                output.append(row)
                continue
            }
            guard !seenGroups.contains(group) else { continue }
            seenGroups.insert(group)
            output.append(contentsOf: rows.filter { $0.supersetGroup == group })
        }

        for (index, row) in output.enumerated() {
            row.position = index
            row.updatedAt = Date()
        }
    }

    private func handleCompletedSet(_ set: SetModel, in workoutExercise: WorkoutExerciseModel) {
        HealthMetricsStore.shared.fillBodyweight(set)
        guard !hasPendingDropSet(after: set, in: workoutExercise) else { return }

        guard let group = workoutExercise.supersetGroup else {
            startRest(after: set, in: workoutExercise)
            return
        }

        let sets = workoutExercise.sets.sorted { $0.position < $1.position }
        guard let roundIndex = supersetRoundIndex(for: set, in: sets) else { return }
        let groupMembers = sortedExercises.filter { $0.supersetGroup == group }
        let roundComplete = groupMembers.allSatisfy { member in
            let memberSets = member.sets.sorted { $0.position < $1.position }
            guard roundIndex < memberSets.count else { return true }
            return setAndDropChainComplete(at: roundIndex, in: memberSets)
        }
        guard roundComplete else { return }
        startRest(after: set, in: workoutExercise, label: "\(SupersetUI.label(for: group)) rest")
    }

    private func hasPendingDropSet(after set: SetModel, in workoutExercise: WorkoutExerciseModel) -> Bool {
        let sets = workoutExercise.sets.sorted { $0.position < $1.position }
        guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return false }
        let next = index + 1
        guard next < sets.count, sets[next].setType == .drop else { return false }
        return sets[next].completedAt == nil
    }

    private func supersetRoundIndex(for set: SetModel, in sets: [SetModel]) -> Int? {
        guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return nil }
        guard set.setType == .drop else { return index }
        return sets[..<index].lastIndex { $0.setType != .drop }
    }

    private func setAndDropChainComplete(at index: Int, in sets: [SetModel]) -> Bool {
        guard index < sets.count, sets[index].completedAt != nil else { return false }
        var next = index + 1
        while next < sets.count, sets[next].setType == .drop {
            guard sets[next].completedAt != nil else { return false }
            next += 1
        }
        return true
    }

    private func startRest(after set: SetModel, in workoutExercise: WorkoutExerciseModel, label: String? = nil) {
        // Honor the exercise-level Rest Timer the user actually sees. When it
        // hasn't been overridden, fall back to the same default the Rest Timer
        // row displays (the working default) — not the completed set's own
        // per-type default. Otherwise finishing a warmup set fires 1m while the
        // row still reads 2m, and the value only "sticks" once the user re-picks
        // it from the menu (which writes restSeconds explicitly).
        let seconds = workoutExercise.restSeconds ?? SetType.working.defaultRestSeconds
        guard let seconds, seconds > 0 else { return }
        RestTimerController.shared.start(seconds: seconds, label: label ?? SetTypeStyle.of(set.setType).label)
    }

    private func publishWorkoutChange() {
        // Local UI reacts immediately; the external surfaces don't need to.
        refreshLiveStats()
        // Watch snapshots and Live Activity content are both rebuilt by
        // walking the full workout — running them synchronously on every
        // keystroke-level change puts avoidable work on the interaction
        // path. Coalesce bursts into one publish shortly after the last
        // change (same pattern as the widget snapshot below, shorter window
        // since the wrist should feel close to live).
        liveSurfacePublishTask?.cancel()
        liveSurfacePublishTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            WatchLink.shared.publishState()
            // A finish inside the debounce window must not re-request the
            // Live Activity that ContentView just ended.
            guard workout.endedAt == nil, workout.deletedAt == nil else { return }
            WorkoutActivityController.shared.update(workout: workout, exercises: exercises)
        }
        scheduleWidgetSnapshot()
    }

    /// A visibility setting is a logging contract, not just layout. Clear any
    /// effort entered earlier in this live workout as soon as the user turns
    /// the column off; historical editing is intentionally unaffected.
    private func reconcileEffortVisibility() {
        guard !isHistoricalEdit, !showRPEInLogger else { return }
        guard WorkoutEffortPolicy.removeEffort(from: workout) else { return }
        workout.updatedAt = .now
        try? modelContext.save()
        publishWorkoutChange()
    }

    /// Widget writes hit disk + WidgetCenter; coalesce bursts of set edits
    /// into one write shortly after the last change.
    private func scheduleWidgetSnapshot() {
        widgetSnapshotTask?.cancel()
        widgetSnapshotTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            updateWidgetSnapshot()
        }
    }

    private func updateWidgetSnapshot() {
        let sortedExercises = workout.exercises.sorted { $0.position < $1.position }
        let allSets = sortedExercises.flatMap(\.sets)
        let currentExercise = sortedExercises.first { exercise in
            exercise.sets.contains { $0.completedAt == nil } || exercise.sets.isEmpty
        } ?? sortedExercises.last
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let timer = RestTimerController.shared

        ForgeFitWidgetSnapshotStore.save(ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            workoutTitle: workout.title ?? "Workout",
            workoutStartedAt: workout.startedAt,
            currentExerciseName: currentExercise.flatMap { exerciseByID[$0.exerciseID] },
            completedSets: allSets.filter { $0.completedAt != nil }.count,
            totalSets: allSets.count,
            restEndsAt: timer.isRunning && !timer.isMicro ? timer.endsAt : nil,
            heartRate: LiveMetricsHub.shared.liveMetrics?.heartRate
        ))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    private func finishAndDismiss() -> String? {
        // Prefer live session metrics (watch or BLE monitor) when streaming.
        if let failure = WorkoutFinisher.finish(
            workout,
            in: modelContext,
            liveMetrics: LiveMetricsHub.shared.liveMetrics
        ) {
            return failure
        }
        onFinished?(workout)
        dismiss()
        return nil
    }

    private func saveHistoricalEdit() {
        workout.recomputeTotalVolume()
        try? modelContext.save()
        dismiss()
    }
}

// MARK: - Post-workout summary

private struct PostWorkoutSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Query(filter: #Predicate<UserProgressModel> { $0.deletedAt == nil }) private var progressRows: [UserProgressModel]
    let workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let history: [WorkoutModel]
    /// Runs the finish pipeline; returns an error message when the terminal
    /// save failed (the workout is still live) so the sheet can alert instead
    /// of silently doing nothing.
    let onSave: () -> String?
    let onCancel: () -> Void

    /// Detected structural drift between this workout and its source routine,
    /// populated when the user taps Save. Non-nil while the "update routine?"
    /// prompt is in flight.
    @State private var routinePlan: RoutineChangeSync.Plan?
    @State private var routineName: String?
    @State private var showRoutineUpdatePrompt = false
    @State private var saveError: String?
    /// One-shot notification prime, shown at the value moment (a finished
    /// workout) instead of buried in Settings — accepting turns on the
    /// rest-timer alerts, reminders, and Wrapped alerts that
    /// otherwise silently no-op.
    @AppStorage("notificationPrimeShown") private var notificationPrimeShown = false
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false

    private var completedSets: [SetModel] {
        workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
    }
    private var effectiveSetTotal: Double {
        completedSets.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }
    }
    private var duration: Int {
        max(0, Int(Date().timeIntervalSince(workout.startedAt)))
    }
    private var volume: Double {
        completedSets.reduce(0) { $0 + ($1.totalVolume ?? 0) }
    }
    private var cardioDistance: Double? {
        let value = workout.cardioSessions.compactMap(\.distanceMeters).reduce(0, +)
        return value > 0 ? value : nil
    }
    private var previousComparable: WorkoutModel? {
        history
            .filter { $0.id != workout.id && $0.endedAt != nil && $0.deletedAt == nil }
            .filter { prior in
                if let routineID = workout.routineID { return prior.routineID == routineID }
                return prior.title == workout.title
            }
            .sorted { $0.startedAt > $1.startedAt }
            .first
    }
    private var volumeDeltaText: String? {
        guard let previousComparable else { return nil }
        let priorVolume = HistoricalSetPresentation.workoutVolume(from: previousComparable.exercises.flatMap(\.sets))
        let delta = volume - priorVolume
        guard abs(delta) > 0.1 else { return "Volume matched last time" }
        return "\(delta >= 0 ? "+" : "")\(Fmt.volumeFull(delta)) vs last time"
    }
    private var totalReps: Int {
        completedSets.reduce(0) {
            $0 + ($1.reps ?? 0) + $1.miniReps.reduce(0, +)
                + ($1.side2Reps ?? 0) + $1.side2MiniReps.reduce(0, +)
        }
    }
    private var bestLift: Double? {
        completedSets.compactMap(\.effectiveLoad).filter { $0 > 0 }.max()
    }

    private struct AwardEntry: Identifiable {
        let id: String
        let exerciseName: String
        let kind: RecordKind
        let valueText: String
    }
    /// Final records of the session: per exercise, the best set per kind that
    /// beat the historical baseline. Same engine as the in-logger trophies.
    private var awardEntries: [AwardEntry] {
        let baselines = PersonalRecords.baselines(history: history, before: workout)
        return workout.exercises.sorted { $0.position < $1.position }.flatMap { we -> [AwardEntry] in
            let exercise = exercises.first { $0.id == we.exerciseID }
            let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
            return PersonalRecords.summaryAwards(for: we, baseline: baselines[we.exerciseID]).map { kind, set in
                AwardEntry(
                    id: "\(we.id)-\(kind.rawValue)",
                    exerciseName: exercise?.name ?? "Exercise",
                    kind: kind,
                    valueText: kind.valueText(for: set, unit: unit)
                )
            }
        }
    }
    private var xpAward: XPService.Award {
        XPService.previewAward(for: workout, requireEnded: false)
    }
    private var currentXP: Int {
        progressRows.first { $0.userID == workout.userID }?.totalXP ?? 0
    }
    private var projectedXPProgress: XPService.Progress {
        XPService.progress(forTotalXP: currentXP + xpAward.amount)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workout complete")
                            .font(.screenTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(workout.title ?? "Workout")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Card {
                        VStack(spacing: Space.lg) {
                            HStack {
                                StatColumn(label: "Time", value: Fmt.durationShort(duration))
                                if let cardioDistance {
                                    StatColumn(label: "Distance", value: Fmt.distance(cardioDistance), valueColor: theme.secondaryAccent)
                                } else {
                                    StatColumn(label: "Volume", value: Fmt.volume(volume))
                                }
                                StatColumn(label: "Sets", value: Fmt.sets(effectiveSetTotal))
                            }
                            if !completedSets.isEmpty {
                                HStack {
                                    StatColumn(label: "Reps", value: "\(totalReps)")
                                    StatColumn(label: "Best Lift", value: bestLift.map { Fmt.loadUnit($0) } ?? "—")
                                    StatColumn(label: "Awards", value: "\(awardEntries.count)", valueColor: awardEntries.isEmpty ? theme.textPrimary : theme.warmup)
                                }
                            }
                        }
                    }

                    if xpAward.amount > 0 {
                        xpCard
                    }

                    if let volumeDeltaText {
                        summaryRow("chart.line.uptrend.xyaxis", "Compared with last time", volumeDeltaText)
                    }

                    if !trainedMuscleRows.isEmpty || cardioAdaptationText != nil {
                        trainedCard
                    }

                    if !awardEntries.isEmpty {
                        awardsCard
                    }

                    if !nextTimeEntries.isEmpty {
                        nextTimeCard
                    }

                    if !notificationPrimeShown, NotificationScheduler.shared.authorizationStatus == .notDetermined {
                        notificationPrimeCard
                    }

                    SecondaryButton(title: "Share Workout", systemImage: "square.and.arrow.up") {
                        shareWorkout()
                    }
                    PrimaryButton(title: "Save Workout", systemImage: "checkmark") {
                        requestSave()
                    }
                    .accessibilityIdentifier("save-workout-button")
                    SecondaryButton(title: "Keep Logging") {
                        onCancel()
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .interactiveDismissDisabled()
        .sheet(isPresented: $showShareSheet) {
            if let shareImage {
                ShareSheet(items: [shareImage])
            }
        }
        .alert(
            "Couldn't Save Workout",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text("\(saveError ?? "") Your workout is still active — nothing was lost. Try saving again.")
        }
        .confirmationDialog(
            routineUpdatePromptTitle,
            isPresented: $showRoutineUpdatePrompt,
            titleVisibility: .visible
        ) {
            Button("Update Routine") { applyRoutineChangesAndSave() }
            Button("Keep Routine As-Is", role: .cancel) { commitSave() }
        } message: {
            if let summary = routinePlan?.summary, !summary.isEmpty {
                Text("\(summary)\n\nYour performed weight and reps stay on this workout only — only structure is applied to the routine.")
            }
        }
    }

    /// The share moment belongs at the finish, not buried in history — same
    /// branded card, rendered without route maps for instant presentation.
    private func shareWorkout() {
        shareImage = WorkoutShareRenderer.image(
            for: workout,
            exercises: exercises,
            theme: theme,
            hrSamples: [],
            recoveryPoints: [],
            routeMaps: [:]
        )
        showShareSheet = shareImage != nil
    }

    /// "What this trained": fractional working sets per muscle (secondaries
    /// count half) plus an honest adaptation read from measured cardio zones.
    private var trainedMuscleRows: [(muscle: String, sets: Double)] {
        Array(TrainingAnalytics(workouts: [workout], exercises: exercises).muscleVolume(for: workout).prefix(4))
    }

    private var cardioAdaptationText: String? {
        var zones = [0, 0, 0, 0, 0]
        for session in workout.cardioSessions where !session.isYogaSession {
            for (index, seconds) in session.hrZoneSeconds.enumerated() where index < 5 {
                zones[index] += seconds
            }
        }
        let total = zones.reduce(0, +)
        guard total > 60 else { return nil }
        let hardShare = (zones[3] + zones[4]) * 100 / total
        let tempoShare = zones[2] * 100 / total
        if hardShare >= 30 { return "High-intensity zones — trains VO₂max and top-end speed" }
        if tempoShare >= 40 { return "Tempo effort — builds your threshold" }
        return "Mostly easy zones — aerobic base building"
    }

    private var trainedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("What this trained").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                }
                ForEach(trainedMuscleRows, id: \.muscle) { row in
                    HStack {
                        Text(row.muscle.capitalized)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(row.sets.formatted(.number.precision(.fractionLength(0...1)))) sets")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                }
                if let cardioAdaptationText {
                    Text(cardioAdaptationText)
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Next-session preview per strength exercise, computed from what was
    /// just logged — the real targets materialize at the next routine start.
    private var nextTimeEntries: [(name: String, text: String)] {
        var routineExerciseByID: [UUID: RoutineExerciseModel] = [:]
        if let routineID = workout.routineID {
            let routines = (try? modelContext.fetch(FetchDescriptor<RoutineModel>(
                predicate: #Predicate { $0.id == routineID && $0.deletedAt == nil }
            ))) ?? []
            if let routine = routines.first {
                routineExerciseByID = Dictionary(routine.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            }
        }
        var entries: [(String, String)] = []
        for workoutExercise in workout.exercises.sorted(by: { $0.position < $1.position }) {
            guard let exercise = exercises.first(where: { $0.id == workoutExercise.exerciseID }),
                  !exercise.isCardio, !exercise.isYoga else { continue }
            let completed = workoutExercise.sets
                .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume && !$0.setType.isBlockType }
            guard !completed.isEmpty else { continue }
            let routineExercise = workoutExercise.sourceRoutineExerciseID.flatMap { routineExerciseByID[$0] }
            let rule = ProgressionRule.decode(from: routineExercise?.progressionRuleJSON) ?? .doubleProgression
            if case .off = rule { continue }
            let targets = routineExercise?.sets ?? []
            let input = ProgressionInput(
                lastSessionSets: completed.map { .init(weightKg: $0.modeWeight ?? $0.weight, reps: $0.reps) },
                targetRepsLow: targets.compactMap(\.targetRepsLow).min(),
                targetRepsHigh: targets.compactMap(\.targetRepsHigh).max(),
                rule: rule,
                increment: ProgressionPlanner.increment(for: exercise),
                isBodyweight: exercise.defaultWeightMode == .bodyweight
            )
            if let suggestion = ProgressionEngine.suggest(input) {
                entries.append((exercise.name, suggestion.rationale))
            }
        }
        return entries
    }

    private var nextTimeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.accent)
                    Text("Next time").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                }
                ForEach(nextTimeEntries, id: \.name) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Text(entry.text)
                            .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var notificationPrimeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.md) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 38, height: 38)
                        .background(theme.accentSoft)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the momentum").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Text("Rest-timer alerts with your phone locked, plus a reminder on your training days.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                }
                HStack(spacing: Space.md) {
                    Button("Enable notifications") {
                        notificationPrimeShown = true
                        Task { await NotificationScheduler.shared.requestPermission() }
                    }
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    Button("Not now") { notificationPrimeShown = true }
                        .font(.bodyStrong)
                        .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
            }
        }
    }

    private var xpCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .center, spacing: Space.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(theme.accent)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("+\(xpAward.amount) XP")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                        Text("Level \(projectedXPProgress.level)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                }
                ProgressView(value: projectedXPProgress.fraction)
                    .tint(theme.accent)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
                Text("\(projectedXPProgress.xpIntoLevel) / \(projectedXPProgress.xpNeededForNextLevel) XP to Level \(projectedXPProgress.level + 1)")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }

    /// Every record earned this session, grouped visually by exercise.
    private var awardsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Label("Awards", systemImage: "trophy.fill")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.warmup)
                ForEach(awardEntries) { entry in
                    HStack(spacing: Space.md) {
                        Image(systemName: entry.kind.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.warmup)
                            .frame(width: 28, height: 28)
                            .background(theme.warmup.opacity(0.15))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.exerciseName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(entry.kind.label)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text(entry.valueText)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.warmup)
                    }
                }
            }
        }
    }

    // MARK: - Routine update flow

    private var routineUpdatePromptTitle: String {
        if let name = routineName { return "Update “\(name)” with your changes?" }
        return "Update routine with your changes?"
    }

    /// On Save: if this workout was started from a routine and structural
    /// changes were made mid-session, ask before finishing. Otherwise save
    /// straight away.
    private func requestSave() {
        guard let routineID = workout.routineID,
              let routine = fetchRoutine(id: routineID) else {
            commitSave()
            return
        }
        let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
        if plan.hasChanges {
            routinePlan = plan
            routineName = routine.name
            showRoutineUpdatePrompt = true
        } else {
            commitSave()
        }
    }

    private func applyRoutineChangesAndSave() {
        if let plan = routinePlan,
           let routineID = workout.routineID,
           let routine = fetchRoutine(id: routineID) {
            RoutineChangeSync.apply(plan, to: routine, from: workout, in: modelContext)
            try? modelContext.save()
        }
        commitSave()
    }

    private func commitSave() {
        // Resolve what the lifter did with each suggestion (accepted at the
        // suggested weight, edited to another, or untouched) before finishing.
        ProgressionPlanner.resolveStatuses(for: workout, in: modelContext)
        saveError = onSave()
    }

    private func fetchRoutine(id: UUID) -> RoutineModel? {
        let descriptor = FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    private func summaryRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        Card {
            HStack(spacing: Space.md) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 34, height: 34)
                    .background(theme.surfaceElevated)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(detail).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }
}

// MARK: - Exercise card

private enum SetInputField: Hashable {
    case weight
    case primary
    case rpe
}

private struct SetInputFocus: Hashable {
    let setID: UUID
    let field: SetInputField
}

/// Which scale the effort column speaks (T4-7). Storage stays canonical
/// RPE on `set.rpe` either way — RIR is the same fact viewed from the other
/// end (RIR = 10 − RPE), so history, ghosts, analytics, and the coach all
/// keep working regardless of the user's preferred scale. Explicit RIR
/// picks also stamp `set.rir` so the load model reads the native value.
enum EffortScale: String {
    case rpe, rir

    var columnTitle: String { self == .rpe ? "RPE" : "RIR" }
}

/// RPE quick-pick options surfaced in the live-workout row menu.
/// `warmup` writes RPE 5 (rendered as "W" in the row) so warm-up sets can be
/// logged in one tap alongside the 6–10 half-step ladder.
enum RPEQuickPick: Hashable {
    case warmup
    case value(Double)

    /// RPE persisted under the warm-up option; anything below 6 shows as "W".
    static let warmupRPE: Double = 5.0

    /// Warm-up first, then 6→10 in 0.5 increments — the order shown in the
    /// row menu.
    static let allOptions: [RPEQuickPick] = [
        .warmup,
        .value(6), .value(6.5), .value(7), .value(7.5),
        .value(8), .value(8.5), .value(9), .value(9.5), .value(10)
    ]

    /// The RPE to persist when this option is tapped.
    var rpeValue: Double {
        switch self {
        case .warmup: Self.warmupRPE
        case .value(let v): v
        }
    }

    /// Numeric value for non-warm-up options; nil for warm-up (used to split
    /// the ladder back out from the full option list).
    var numericValue: Double? {
        switch self {
        case .warmup: nil
        case .value(let v): v
        }
    }

    /// Compact label for the pill: "W" for warm-up, bare number otherwise.
    var label: String {
        switch self {
        case .warmup: "W"
        case .value(let v): v.formatted(.number.precision(.fractionLength(0...1)))
        }
    }
}

/// Dynamic-Type-aware column widths for the set-entry grid, shared by the
/// header row and every `SetRow` so the columns always line up. Anchored to
/// `.body` — the same curve as the `.bodyStrong` text the fields hold.
private struct SetGridMetrics: DynamicProperty {
    @ScaledMetric(relativeTo: .body) var check: CGFloat = 44
    @ScaledMetric(relativeTo: .body) var setBadge: CGFloat = 40
    @ScaledMetric(relativeTo: .body) var weight: CGFloat = 60
    @ScaledMetric(relativeTo: .body) var reps: CGFloat = 46
    @ScaledMetric(relativeTo: .body) var rpe: CGFloat = 40
    @ScaledMetric(relativeTo: .body) var fieldHeight: CGFloat = 44
}

private struct ExerciseLogCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    var grid = SetGridMetrics()
    @Bindable var workout: WorkoutModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let exercise: ExerciseLibraryModel?
    let pinnedNote: UserExerciseNoteModel?
    let previousSets: [SetModel]
    let recordBaseline: ExerciseRecordBaseline?
    let allowsRestTimers: Bool
    /// Whether the exercise may fold into the one-line summary. Active
    /// workouts only — the historical editor always shows every set.
    var allowsCollapse: Bool = false
    let showRPE: Bool
    let failureTrainingEnabled: Bool
    let showsPreviousTapHint: Bool
    /// The normal logger card owns the deliberate entry gesture. Reorder
    /// previews hide it because List supplies the drag control for the row.
    var showsReorderHandle: Bool = true
    let effortScale: EffortScale
    let completionDate: Date?
    let availableSupersetGroups: [Int]
    let onAssignSuperset: (Int?) -> Void
    let onCreateSuperset: () -> Void
    let onUngroupSuperset: (Int) -> Void
    let onCompletedSet: (SetModel) -> Void
    let onLiveStatsChanged: () -> Void
    let onWorkoutChanged: () -> Void
    let onShowExerciseDetail: (ExerciseLibraryModel) -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    /// Enters reorder mode after a deliberate handle hold, or immediately
    /// from the overflow menu's explicit "Reorder Exercises" command.
    let onReorder: () -> Void
    /// This exercise's progression suggestion for the session (nil = none
    /// offered — no history, rule off, or not a strength exercise).
    var progression: ProgressionSuggestionModel? = nil
    var onRejectProgression: () -> Void = {}

    @State private var deferredSaveTask: Task<Void, Never>?
    /// Set being plate-calculated (barbell-loaded exercises only).
    @State private var plateSet: SetModel?
    @State private var editedSuggestionSetIDs = Set<UUID>()
    /// Per-set fields the user explicitly typed into (suggestion-backed rows
    /// only). Lives here, not in SetRow @State, so LazyVStack row recycling
    /// can't forget which fields hold real entries vs placeholder suggestions.
    @State private var editedSuggestionFields: [UUID: Set<SetInputField>] = [:]
    /// The one set row whose swipe-to-delete tray is currently open (only one
    /// at a time, Mail-style).
    @State private var openSwipeSetID: UUID?
    @FocusState private var focusedInput: SetInputFocus?
    /// PR awards per set, computed when set data changes rather than on every
    /// body evaluation — focus changes and menu presentations re-render all
    /// visible rows, and running PersonalRecords per row per render caused
    /// visible stutter opening the set-type menu on long workouts.
    @State private var awardsCache: [UUID: [RecordKind]] = [:]
    /// User-controlled fold state. Completing the last set no longer folds the
    /// card out from under the user — it stays open and green so the final set
    /// is visibly logged; the user folds it with the header chevron when ready.
    /// `onAppear` still re-folds an already-completed exercise on revisit so the
    /// list stays tidy and the fold survives LazyVStack row recycling.
    @State private var collapsed = false
    @State private var reorderHandlePressed = false

    private var sortedSets: [SetModel] { workoutExercise.sets.sorted { $0.position < $1.position } }
    private var completedSetIDs: Set<UUID> {
        Set(sortedSets.lazy.filter { $0.completedAt != nil }.map(\.id))
    }
    private var allSetsCompleted: Bool {
        !workoutExercise.sets.isEmpty && workoutExercise.sets.allSatisfy { $0.completedAt != nil }
    }
    private var isCollapsed: Bool { allowsCollapse && collapsed }
    private var isCardio: Bool { exercise?.isCardio == true }
    private var weightMode: WeightMode { exercise?.defaultWeightMode ?? .external }
    private var displayUnit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }
    private var isBarbellLoaded: Bool { ExerciseCatalog.isBarbellLoaded(exercise?.equipment) }
    private var restSeconds: Int { workoutExercise.restSeconds ?? SetType.working.defaultRestSeconds ?? 120 }

    private var weightHeader: String? {
        guard !isCardio else { return nil }
        let unit = displayUnit.suffix.uppercased()
        switch weightMode {
        case .external: return unit
        case .bodyweightAdded: return "+\(unit)"
        case .bodyweightAssisted: return "-\(unit)"
        case .bodyweight: return nil
        }
    }

    private var sessionSetsForExercise: [SetModel] {
        workout.exercises
            .filter { $0.exerciseID == workoutExercise.exerciseID }
            .flatMap(\.sets)
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedCard
            } else {
                expandedCard
            }
        }
        .animation(.snappy(duration: 0.28), value: isCollapsed)
        .onAppear {
            if allowsCollapse && allSetsCompleted { collapsed = true }
        }
        .onChange(of: completedSetIDs) { oldIDs, newIDs in
            guard allowsRestTimers else { return }
            let newlyCompleted = newIDs.subtracting(oldIDs)
            guard !newlyCompleted.isEmpty else { return }

            var didMaterialize = false
            for (index, set) in sortedSets.enumerated()
            where newlyCompleted.contains(set.id)
                && !set.setType.isBlockType
                && !editedSuggestionSetIDs.contains(set.id) {
                materializeSuggestion(for: set, index: index, allowsCompletedSet: true)
                didMaterialize = true
            }
            if didMaterialize { recompute() }
        }
        .onChange(of: firstWorkingSetWeight) { _, _ in
            // A ramp added before the working weight was known parks its
            // warm-ups with blank weights; fill them the moment that weight
            // exists (typed, matched, or materialized from a suggestion).
            fillPendingWarmupRamp()
        }
    }

    /// One-line receipt shown once every set is checked off: name, set count,
    /// and completed load. The checkmark toggles every set without expanding;
    /// the remainder of the row reopens the full grid for review or editing.
    private var collapsedCard: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.sm) {
                Button(action: toggleAllSetsCompletion) {
                    Image(systemName: allSetsCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.sectionTitle)
                        .foregroundStyle(allSetsCompleted ? theme.success : theme.textTertiary)
                        .frame(width: grid.check, height: grid.fieldHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(allSetsCompleted ? "Mark all sets incomplete" : "Complete all sets")
                .accessibilityValue(completionProgressLabel)
                .accessibilityIdentifier("toggle-condensed-exercise-completion")

                Button {
                    withAnimation(.snappy(duration: 0.28)) { collapsed = false }
                } label: {
                    HStack(spacing: Space.sm) {
                        Text(exercise?.name ?? "Exercise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        if let group = workoutExercise.supersetGroup {
                            SupersetChip(group: group)
                        }
                        Spacer(minLength: Space.sm)
                        Text(completedSummary)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: grid.fieldHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(exercise?.name ?? "exercise") — \(completedSummary)")
                .accessibilityHint("Reopens the completed sets for review or editing")
                .accessibilityIdentifier("completed-exercise-summary")
            }
        }
    }

    private var completionProgressLabel: String {
        "\(sortedSets.count { $0.completedAt != nil }) of \(sortedSets.count) sets completed"
    }

    private func toggleAllSetsCompletion() {
        let sets = sortedSets
        guard !sets.isEmpty else { return }
        if allSetsCompleted {
            withAnimation(.snappy(duration: 0.28)) {
                for set in sets { set.completedAt = nil }
            }
        } else {
            let completedAt = completionDate ?? Date()
            var lastCompletedSet: SetModel?
            withAnimation(.snappy(duration: 0.28)) {
                for (index, set) in sets.enumerated() where set.completedAt == nil {
                    materializeSuggestion(for: set, index: index)
                    if set.setType == .cluster {
                        set.reps = set.miniReps.reduce(0, +)
                    }
                    set.completedAt = completedAt
                    HealthMetricsStore.shared.fillBodyweight(set)
                    lastCompletedSet = set
                }
            }
            if allowsRestTimers, let lastCompletedSet {
                onCompletedSet(lastCompletedSet)
            }
        }
        for set in sets { set.recomputeDerivedMetrics() }
        recompute()
    }

    /// "4 sets · 3,420 lb" — the same per-set volume the live stats bar sums,
    /// scoped to this exercise. Cardio rows total duration instead; loadless
    /// (bodyweight) work falls back to total reps.
    private var completedSummary: String {
        let sets = sortedSets
        let completed = sets.filter { $0.completedAt != nil }
        let count = completed.count == sets.count
            ? "\(sets.count) \(sets.count == 1 ? "set" : "sets")"
            : "\(completed.count)/\(sets.count) sets"
        if isCardio {
            let seconds = completed.compactMap(\.durationSeconds).reduce(0, +)
            return seconds > 0 ? "\(count) · \(Fmt.durationShort(seconds))" : count
        }
        let volume = completed.compactMap(\.totalVolume).reduce(0, +)
        if volume > 0 { return "\(count) · \(Fmt.volume(volume, unit: displayUnit))" }
        let reps = completed.compactMap(\.reps).reduce(0, +)
        return reps > 0 ? "\(count) · \(reps) reps" : count
    }

    private var expandedCard: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header

                if workoutExercise.notes != nil {
                    StickyNoteView(workoutExercise: workoutExercise, exerciseID: workoutExercise.exerciseID, pinnedNote: pinnedNote)
                }

                if let progression, progressionActive {
                    progressionStrip(progression)
                }

                if allowsRestTimers {
                    // User-adjustable rest between straight sets — the countdown
                    // starts automatically when a set is checked off.
                    RestDurationMenu(
                        options: [30, 45, 60, 90, 120, 150, 180, 240, 300],
                        allowsOff: true,
                        selected: workoutExercise.restSeconds ?? SetType.working.defaultRestSeconds,
                        onPick: { picked in
                            workoutExercise.restSeconds = picked
                            recompute()
                        }
                    ) {
                        HStack(spacing: 6) {
                            Image(systemName: "timer").font(.system(size: 14, weight: .semibold))
                            Text("Rest Timer: \(restSeconds == 0 ? "Off" : Fmt.restTimer(restSeconds))")
                                .font(.system(size: 15, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(theme.accent)
                    }
                }

                columnHeader

                let sets = sortedSets

                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    if set.setType.isBlockType {
                        // Myo-reps / rest-pause / cluster log as a nested block,
                        // not a flat row.
                        SwipeToDeleteRow(
                            isOpen: openSwipeSetID == set.id,
                            onOpenChange: { open in
                                if open { openSwipeSetID = set.id }
                                else if openSwipeSetID == set.id { openSwipeSetID = nil }
                            },
                            onDelete: { deleteSet(set) }
                        ) {
                            SetBlockView(
                                set: set,
                                workoutExercise: workoutExercise,
                                blockNumber: workingNumber(upTo: index, in: sets),
                                previous: blockTemplate(for: set, index: index, in: sets),
                                showWeight: weightHeader != nil,
                                displayUnit: displayUnit,
                                isUnilateral: exercise?.isUnilateral == true,
                                completionDate: completionDate,
                                onChange: recompute,
                                onSetType: { set.setType = $0; recompute() },
                                onCompleted: { if allowsRestTimers { onCompletedSet(set) } },
                                onDelete: { deleteSet(set) }
                            )
                        }
                    } else {
                        SetRow(
                            set: set,
                            workingNumber: workingNumber(upTo: index, in: sets),
	                            awards: awardsCache[set.id] ?? [],
	                            previous: previousText(for: set, at: index),
	                            previousSet: previousSet(for: set, at: index),
	                            isCardio: isCardio,
	                            showWeight: weightHeader != nil,
	                            showRPE: showRPE,
	                            defaultsToFailure: failureTrainingEnabled && set.setType != .warmup,
	                            effortScale: effortScale,
	                            displayUnit: displayUnit,
                                focusedInput: $focusedInput,
                                openSwipeSetID: $openSwipeSetID,
	                            onChange: recompute,
	                            onSetType: { changeType(of: set, to: $0, index: index) },
	                            completionDate: completionDate,
                                usesSuggestedValues: usesSuggestedValues(for: set),
                                suggestedWeight: suggestedWeight(for: set, index: index),
                                suggestedReps: suggestedReps(for: set, index: index),
                                suggestedDurationSeconds: suggestedDurationSeconds(for: set, index: index),
                                suggestedRPE: suggestedRPE(for: set, index: index),
                                editedFields: editedSuggestionFields[set.id] ?? [],
                                onSuggestionFieldEdited: { field, isEdited in
                                    var fields = editedSuggestionFields[set.id] ?? []
                                    if isEdited { fields.insert(field) } else { fields.remove(field) }
                                    editedSuggestionFields[set.id] = fields
                                },
                                onMaterializeSuggestion: { editedFields in
                                    materializeSuggestion(
                                        for: set,
                                        index: index,
                                        editedFields: editedFields
                                    )
                                },
	                            onCompleted: { if allowsRestTimers { onCompletedSet(set) } },
	                            onMatchPrevious: { matchPrevious(set, from: previousSet(for: set, at: index)) },
                                onAdvancePastLastField: { focusNextSet(after: index, in: sets) },
	                            onAddDrop: { addDropSet(below: set, index: index) },
	                            onPlates: isBarbellLoaded ? { plateSet = set } : nil,
	                            onDelete: { deleteSet(set) }
	                        )
	                        // Drop sets are added on demand from the set-type menu
	                        // ("Add Drop Set Below") or preplanned in the routine
	                        // editor — no persistent per-row affordance cluttering
	                        // every working set.
	                    }
	                }

                Button(action: { addSet(type: .working) }) {
                    HStack(spacing: 6) { Image(systemName: "plus"); Text("Add Set") }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier("add-set-button")
                .sheet(item: $plateSet) { set in
                    PlateCalculatorView(
                        displayUnit: displayUnit,
                        initialTargetKg: set.weight
                    ) { achievedKg in
                        set.weight = achievedKg
                        recompute()
                    }
                }
            }
        }
        .onAppear {
            prefillPinnedNote()
            refreshAwardsCache()
        }
        .onDisappear {
            deferredSaveTask?.cancel()
            saveNow()
        }
    }

    private var header: some View {
        HStack {
            if let exercise {
                Button {
                    onShowExerciseDetail(exercise)
                } label: {
                    HStack(spacing: Space.md) {
                        ExerciseThumbnail(exercise: exercise, size: 38)
                        ExerciseNameLabel(name: exercise.name, font: .system(size: 18, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text("Exercise")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
            }
		    if let group = workoutExercise.supersetGroup {
		        SupersetChip(group: group)
		    }
	            Spacer()
	            // Explicit gap (rather than relying on the outer HStack's
	            // ambient spacing) so both controls can sit at the HIG's
	            // 44x44 minimum without their hit areas overlapping.
	            HStack(spacing: Space.sm) {
	                if allowsCollapse && allSetsCompleted {
	                    // Positive close-out: every set is logged. Springs in on
	                    // the final completion (inside completeSet's animation) so
	                    // finishing reads as "saved ✓" without folding the card.
	                    Image(systemName: "checkmark.circle.fill")
	                        .font(.bodyStrong)
	                        .foregroundStyle(theme.success)
	                        .frame(height: 44)
	                        .transition(.scale.combined(with: .opacity))
	                        .accessibilityLabel("Exercise complete")
	                }
	                if allowsCollapse {
	                    Button {
	                        withAnimation(.snappy(duration: 0.28)) { collapsed = true }
	                    } label: {
	                        Image(systemName: "chevron.up")
	                            .font(.bodyStrong)
	                            .foregroundStyle(theme.textTertiary)
	                            .frame(width: 44, height: 44)
	                            .contentShape(Rectangle())
	                    }
	                    .buttonStyle(.plain)
	                    .accessibilityLabel(allSetsCompleted ? "Exercise complete, collapse" : "Collapse exercise")
	                    .accessibilityIdentifier("collapse-completed-exercise")
	                }
	                if showsReorderHandle {
	                    Image(systemName: "line.3.horizontal")
	                        .font(.bodyStrong)
	                        .foregroundStyle(theme.textTertiary)
	                        .frame(width: 44, height: 44)
	                        .contentShape(Rectangle())
	                        .scaleEffect(reorderHandlePressed ? 0.88 : 1)
	                        .onLongPressGesture(
	                            minimumDuration: 0.45,
	                            maximumDistance: 12,
	                            pressing: { isPressing in
	                                withAnimation(.easeOut(duration: 0.12)) {
	                                    reorderHandlePressed = isPressing
	                                }
	                            },
	                            perform: onReorder
	                        )
	                        .accessibilityLabel("Reorder exercises")
	                        .accessibilityHint("Touch and hold to open the reorder screen")
	                        .accessibilityAddTraits(.isButton)
	                        .accessibilityAction { onReorder() }
	                        .accessibilityIdentifier("hold-to-reorder-exercises")
	                }
	                Menu {
                    if let exercise {
                        Button("Exercise Details", systemImage: "info.circle") { onShowExerciseDetail(exercise) }
                        Divider()
                    }
                    if workoutExercise.notes == nil {
                        Button("Add Note", systemImage: "note.text") { workoutExercise.notes = ""; try? modelContext.save() }
                    }
                    Button("Add Warm-up Set", systemImage: "flame") { addSet(type: .warmup) }
                    Button("Add Warm-up Ramp", systemImage: "flame.fill") { addWarmupRamp() }
                    SupersetMenuItems(
                        currentGroup: workoutExercise.supersetGroup,
                        availableGroups: availableSupersetGroups,
                        onAssign: onAssignSuperset,
                        onCreate: onCreateSuperset,
                        onUngroup: onUngroupSuperset
                    )
                    Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: onReplace)
                    Button("Reorder Exercises", systemImage: "arrow.up.arrow.down", action: onReorder)
                    Divider()
                    Button("Remove Exercise", systemImage: "trash", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                }
            }
        }
    }

    private var columnHeader: some View {
	        HStack(spacing: 6) {
	            Image(systemName: "checkmark").frame(width: grid.check)
	            Text("SET").frame(width: grid.setBadge)
	            HStack(spacing: 3) {
                    Text("PREVIOUS")
                    if showsPreviousTapHint {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .accessibilityHidden(true)
                    }
                }
	                .lineLimit(1)
	                .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(showsPreviousTapHint ? "Previous, tap a value to autofill" : "Previous")
                    .accessibilityIdentifier("previous-autofill-hint")
	            if let weightHeader {
                Button(action: toggleExerciseUnit) {
                    HStack(spacing: 3) {
                        Text(weightHeader)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .frame(width: grid.weight)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .accessibilityLabel("Switch \(exercise?.name ?? "exercise") weight unit")
	            }
	            if isCardio { Text("MIN").frame(width: grid.weight) } else { Text("REPS").frame(width: grid.reps) }
	            if showRPE && !isCardio { Text(effortScale.columnTitle).frame(width: grid.rpe) }
	        }
        // Rows carry 6pt horizontal padding (their done-state background);
        // mirror it here so every column lines up with its header.
        .padding(.horizontal, 6)
        .font(.tag)
        .foregroundStyle(theme.textTertiary)
    }

    /// 1-based number among numbered (working-type) sets only.
    private func workingNumber(upTo index: Int, in sets: [SetModel]) -> Int {
        sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
    }

	    /// Records this set holds right now, judged against history plus the
	    /// sets of the same exercise completed earlier this session.
	    private func refreshAwardsCache() {
	        let sessionSets = sessionSetsForExercise
	        var fresh: [UUID: [RecordKind]] = [:]
	        for set in workoutExercise.sets where set.completedAt != nil {
	            fresh[set.id] = PersonalRecords.awards(for: set, baseline: recordBaseline, sessionSets: sessionSets)
	        }
	        if fresh != awardsCache { awardsCache = fresh }
	    }

    private func usesSuggestedValues(for set: SetModel) -> Bool {
        set.completedAt == nil
            && suggestionBacked(for: set)
    }

    private func suggestionBacked(for set: SetModel) -> Bool {
        set.sourceRoutineSetID != nil
            && !editedSuggestionSetIDs.contains(set.id)
    }

    /// A live (pending) progression suggestion flips ghost precedence: the
    /// engine-advanced values stored on the set lead, and last session is the
    /// fallback — otherwise the new target could never show through.
    private var progressionActive: Bool { progression?.statusRaw == "pending" }

    private func progressionLeads(for set: SetModel) -> Bool {
        progressionActive && !set.setType.isBlockType && set.setType != .warmup
    }

    private func suggestedWeight(for set: SetModel, index: Int) -> Double? {
        if progressionLeads(for: set) {
            return set.modeWeight ?? set.weight ?? previousSet(for: set, at: index).flatMap { $0.modeWeight ?? $0.weight }
        }
        return previousSet(for: set, at: index).flatMap { $0.modeWeight ?? $0.weight } ?? set.modeWeight ?? set.weight
    }

    private func suggestedReps(for set: SetModel, index: Int) -> Int? {
        if progressionLeads(for: set) {
            return set.reps ?? previousSet(for: set, at: index)?.reps
        }
        return previousSet(for: set, at: index)?.reps ?? set.reps
    }

    private func suggestedDurationSeconds(for set: SetModel, index: Int) -> Int? {
        previousSet(for: set, at: index)?.durationSeconds ?? set.durationSeconds
    }

    private func suggestedRPE(for set: SetModel, index: Int) -> Double? {
        previousSet(for: set, at: index)?.rpe ?? set.rpe
    }

    /// Runs at completion: commits exactly what the row's placeholders were
    /// displaying (typed fields win; untouched fields take the suggestion —
    /// see SetSuggestionPolicy). Marking the set edited afterwards is what
    /// makes uncompleting preserve the committed values as real entries
    /// instead of reverting them to placeholders.
    private func materializeSuggestion(
        for set: SetModel,
        index: Int,
        editedFields: Set<SetInputField>? = nil,
        allowsCompletedSet: Bool = false
    ) {
        let edited = editedFields ?? editedSuggestionFields[set.id] ?? []
        var policyFields = Set<SetSuggestionPolicy.Field>()
        if edited.contains(.weight) { policyFields.insert(.weight) }
        if edited.contains(.primary) { policyFields.insert(.primary) }
        let previous = previousSet(for: set, at: index)
        SetSuggestionPolicy.materialize(
            set: set,
            suggestions: SetSuggestionPolicy.SuggestedValues(
                weight: suggestedWeight(for: set, index: index),
                reps: suggestedReps(for: set, index: index),
                durationSeconds: suggestedDurationSeconds(for: set, index: index),
                rpe: suggestedRPE(for: set, index: index),
                rir: previous?.rir ?? set.rir
            ),
            suggestionBacked: suggestionBacked(for: set),
            editedFields: policyFields,
            effortLoggingEnabled: showRPE,
            failureTrainingEnabled: failureTrainingEnabled,
            allowsCompletedSet: allowsCompletedSet
        )
        editedSuggestionSetIDs.insert(set.id)
    }

    private func progressionStrip(_ suggestion: ProgressionSuggestionModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: progressionIcon(suggestion.kindRaw))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.accent)
            Text(suggestion.rationale)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(action: onRejectProgression) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss suggestion and keep last session's values")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func progressionIcon(_ kind: String) -> String {
        switch kind {
        case ProgressionSuggestion.Kind.increase.rawValue: "arrow.up.right"
        case ProgressionSuggestion.Kind.addReps.rawValue: "plus"
        default: "equal"
        }
    }

	    private func previousText(for set: SetModel, at index: Int) -> String {
        guard let prev = previousSet(for: set, at: index) else { return "—" }
        let w = Fmt.load(prev.modeWeight ?? prev.weight, unit: displayUnit)
        let r = prev.reps.map(String.init) ?? "—"
        // No unit suffix here: the weight column header already labels the unit,
        // and dropping it keeps the value legible when the RPE column is on.
        return isCardio ? Fmt.durationShort(prev.durationSeconds) : "\(w) × \(r)"
    }

    /// Set-type-smart previous lookup: the i-th set OF A TYPE maps to last
    /// session's i-th completed set of the SAME type — warmups remember
    /// warmups, working sets remember working sets, drops match drops — so
    /// changing a row's type swaps its PREVIOUS and ghosts to that type's
    /// history instantly. An extra set beyond last session's count continues
    /// from the type's last set; a type with no history is an honest blank.
    private func previousSet(for set: SetModel, at index: Int) -> SetModel? {
        let ordinal = sortedSets.prefix(index).filter { $0.setType == set.setType }.count
        let sameType = previousSets.filter { $0.setType == set.setType }
        guard !sameType.isEmpty else { return nil }
        return ordinal < sameType.count ? sameType[ordinal] : sameType.last
    }

    private func matchPrevious(_ set: SetModel, from previous: SetModel?) {
        guard let previous else { return }
        set.weight = previous.weight
        set.addedWeight = previous.addedWeight
        set.assistanceWeight = previous.assistanceWeight
        set.reps = previous.reps
        set.durationSeconds = previous.durationSeconds
        if showRPE {
            set.rpe = previous.rpe
            set.rir = previous.rir
        } else {
            set.rpe = nil
            set.rir = nil
        }
        set.recomputeDerivedMetrics()
        // An explicit "copy my previous set" is a manual materialization —
        // the values are real entries now, not placeholder suggestions.
        editedSuggestionSetIDs.insert(set.id)
        recompute()
    }

    private func firstInputField(for set: SetModel) -> SetInputField? {
        guard !set.setType.isBlockType else { return nil }
        return weightHeader == nil ? .primary : .weight
    }

    private func focusNextSet(after index: Int, in sets: [SetModel]) {
        for next in sets.dropFirst(index + 1) where next.completedAt == nil {
            if let field = firstInputField(for: next) {
                focusedInput = SetInputFocus(setID: next.id, field: field)
                return
            }
        }
        focusedInput = nil
        hideKeyboard()
    }

    private func toggleExerciseUnit() {
        guard let exercise else { return }
        exercise.preferredWeightUnit = displayUnit.toggled
        exercise.updatedAt = Date()
        try? modelContext.save()
    }

    private func prefillPinnedNote() {
        if workoutExercise.notes == nil, let pinnedNote {
            workoutExercise.notes = pinnedNote.note
            workoutExercise.notePinned = true
            try? modelContext.save()
        }
    }

    /// Warm-up ramp: the user's configured ramp (default 40/60/80% × 10/6/3,
    /// editable in Settings › Training). Each warm-up's weight is that
    /// percentage of the first working set's target — engine-advanced or
    /// last-session weight — snapped to clean display-unit steps; reps come
    /// straight from the config. When there's nothing to ramp toward yet, the
    /// rows are still created with their reps and blank weights, and
    /// `fillPendingWarmupRamp` fills the weights once a working weight exists.
    private func addWarmupRamp() {
        let config = WarmupRampConfigStore.load()
        let displayPerKilogram = displayUnit == .lb ? 2.2046226218 : 1.0
        let step: Double = displayUnit == .lb ? 5 : 2.5
        let topKg = sortedSets.firstIndex(where: { $0.setType != .warmup })
            .flatMap { suggestedWeight(for: sortedSets[$0], index: $0) }
        let topDisplay = (topKg ?? 0) * displayPerKilogram
        let newSets: [SetModel] = config.stages.enumerated().map { ordinal, stage in
            let display = config.weight(forStageAt: ordinal, topWeightInDisplayUnit: topDisplay, step: step)
            let set = SetModel(
                userID: ForgeFitDemo.userID,
                position: 0,
                setType: .warmup,
                weightMode: weightMode,
                reps: stage.reps,
                weight: display.map { $0 / displayPerKilogram }
            )
            modelContext.insert(set)
            return set
        }
        var all = sortedSets
        let insertAt = all.firstIndex { $0.setType != .warmup } ?? all.count
        all.insert(contentsOf: newSets, at: insertAt)
        for (index, set) in all.enumerated() { set.position = index }
        workoutExercise.sets = all
        // recompute() already schedules a debounced save — the extra
        // synchronous save() that used to run here duplicated the write.
        recompute()
    }

    /// The first working set's entered weight (kg) — the trigger for filling a
    /// ramp that was added before the working weight was known.
    private var firstWorkingSetWeight: Double? {
        sortedSets.first { $0.setType != .warmup }?.weight
    }

    /// Fills the weights of ramp warm-ups still parked at blank once the first
    /// working set's weight exists, reusing each warm-up's configured percentage
    /// by its position among the warm-ups. Fill-once: a warm-up that already has
    /// a weight (auto-filled earlier or hand-typed) is left untouched.
    private func fillPendingWarmupRamp() {
        let warmups = sortedSets.filter { $0.setType == .warmup }
        let pending = warmups.filter { $0.weight == nil }
        guard !pending.isEmpty,
              let workingIndex = sortedSets.firstIndex(where: { $0.setType != .warmup }),
              let topKg = suggestedWeight(for: sortedSets[workingIndex], index: workingIndex),
              topKg > 0 else { return }
        let config = WarmupRampConfigStore.load()
        let displayPerKilogram = displayUnit == .lb ? 2.2046226218 : 1.0
        let step: Double = displayUnit == .lb ? 5 : 2.5
        let topDisplay = topKg * displayPerKilogram
        var didFill = false
        for warmup in pending {
            guard let ordinal = warmups.firstIndex(where: { $0.id == warmup.id }),
                  let display = config.weight(forStageAt: ordinal, topWeightInDisplayUnit: topDisplay, step: step)
            else { continue }
            warmup.weight = display / displayPerKilogram
            didFill = true
        }
        if didFill { recompute() }
    }

    private func addSet(type: SetType) {
        let last = sortedSets.last
        // Intelligent copy-forward: repeat the last set's structure. If the
        // last set was a block (myo-reps etc.), the new set keeps that type and
        // offers its full template via "Match previous".
        let carriedType = type == .working ? (last?.setType.isBlockType == true ? last!.setType : type) : type
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            position: workoutExercise.sets.count,
            setType: carriedType,
            weightMode: weightMode,
            reps: (type == .warmup || carriedType.isBlockType) ? nil : last?.reps,
            weight: last?.weight
        )
        modelContext.insert(set)
        workoutExercise.sets.append(set)
        // Route through the same debounced save every other row mutation
        // uses (recompute() -> scheduleSave()) instead of a synchronous
        // modelContext.save() here. A synchronous store write on every
        // "Add Set" tap was the visible lag: it blocks the main thread for
        // the SwiftData persist (and its CloudKit change-tracking bookkeeping)
        // in the same run loop turn as the tap, before the new row can paint.
        recompute()
    }

    /// Appends a drop-set row right below `set` with the weight pre-filled at
    /// a 25% reduction — the cascading ladder.
    private func addDropSet(below set: SetModel, index: Int) {
        let drop = SetModel(
            userID: ForgeFitDemo.userID,
            setType: .drop,
            weightMode: weightMode,
            reps: nil,
            weight: set.weight.map(droppedWeight)
        )
        modelContext.insert(drop)
        workoutExercise.sets.append(drop)
        var rows = sortedSets.filter { $0.id != drop.id }
        rows.insert(drop, at: min(index + 1, rows.count))
        for (i, s) in rows.enumerated() { s.position = i }
        recompute()
    }

    /// 25% drop, rounded to the nearest 5 — a sensible pre-fill the user can edit.
    private func droppedWeight(_ weight: Double) -> Double {
        let displayed = displayUnit.displayValue(fromKilograms: weight)
        let step = displayUnit == .lb ? 5.0 : 2.5
        let minimum = displayUnit == .lb ? 5.0 : 2.5
        let dropped = max(minimum, (displayed * 0.75 / step).rounded() * step)
        return displayUnit.kilograms(fromDisplayValue: dropped)
    }

    private func changeType(of set: SetModel, to type: SetType, index: Int) {
        // Converting a row into a drop pre-fills the cascading weight cut from
        // the row above it.
        if type == .drop, index > 0, let above = sortedSets[index - 1].weight {
            if set.weight == nil || set.weight == above {
                set.weight = droppedWeight(above)
            }
        }
        set.setType = type
        recompute()
    }

    /// Template for a block's "Match previous": the same-index set from the
    /// last session, or the previous block of the same type in this session.
    private func blockTemplate(for set: SetModel, index: Int, in sets: [SetModel]) -> SetModel? {
        if index < previousSets.count, previousSets[index].setType == set.setType {
            return previousSets[index]
        }
        if let prior = sets.prefix(index).last(where: { $0.setType == set.setType && ($0.reps != nil || !$0.miniReps.isEmpty) }) {
            return prior
        }
        return previousSets.last { $0.setType == set.setType }
    }

    private func deleteSet(_ set: SetModel) {
        if openSwipeSetID == set.id { openSwipeSetID = nil }
        modelContext.delete(set)
        for (i, s) in sortedSets.filter({ $0.id != set.id }).enumerated() { s.position = i }
        recompute()
    }

    private func recompute() {
        workoutExercise.updatedAt = Date()
        refreshAwardsCache()
        let completedSets = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil }
        workout.totalVolume = completedSets.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        workout.updatedAt = Date()
        onLiveStatsChanged()
        scheduleSave()
    }

    private func scheduleSave() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        try? modelContext.save()
        onWorkoutChanged()
    }
}

// MARK: - Swipe-to-delete

// SwipeToDeleteRow moved to Workout/SwipeToDeleteRow.swift — shared with the
// routine editor so set deletion feels identical when planning and performing.

// MARK: - Single set row

/// The weight column means different things per mode: external load, weight
/// added to bodyweight, or assistance subtracted from bodyweight. Routing
/// reads/writes through one accessor keeps the input, "previous", and volume
/// math (VolumeMath.effectiveLoad) on the same field.
extension SetModel {
    var modeWeight: Double? {
        switch weightMode {
        case .external: weight
        case .bodyweightAdded: addedWeight
        case .bodyweightAssisted: assistanceWeight
        case .bodyweight: nil
        }
    }

    func setModeWeight(_ value: Double?) {
        switch weightMode {
        case .external: weight = value
        case .bodyweightAdded: addedWeight = value
        case .bodyweightAssisted: assistanceWeight = value
        case .bodyweight: break
        }
        recomputeDerivedMetrics()
    }
}

private struct SetRow: View {
    @Environment(\.theme) private var theme
    @Environment(SetInputRouter.self) private var inputRouter: SetInputRouter?
    var grid = SetGridMetrics()
    @Bindable var set: SetModel
    @State private var weightDraft = ""
    @State private var primaryDraft = ""
    @State private var rpeDraft = ""
    @State private var editedDraftFields = Set<SetInputField>()
    /// Immediate local truth for suggestion-backed fields. Parent `@State`
    /// re-renders on the next update cycle; completion can happen in the same
    /// tap that commits a draft, so these overrides close that timing gap.
    @State private var suggestionFieldOverrides: [SetInputField: Bool] = [:]
    /// Bumped on each locally-completed set so the confirmation haptic fires
    /// only for taps on this device — never for watch-mirrored completions,
    /// and never when un-checking. PRs escalate separately via `.success`.
    @State private var completionHapticTrigger = 0
    let workingNumber: Int
    /// Records this set currently holds — renders the subtle gold strip.
    var awards: [RecordKind] = []
    let previous: String
    let previousSet: SetModel?
    let isCardio: Bool
    let showWeight: Bool
    let showRPE: Bool
    let defaultsToFailure: Bool
    let effortScale: EffortScale
    let displayUnit: WeightUnit
    let focusedInput: FocusState<SetInputFocus?>.Binding
    /// The set whose swipe-to-delete tray is open, shared across sibling rows so
    /// only one opens at a time.
    @Binding var openSwipeSetID: UUID?
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    var completionDate: Date? = nil
    var usesSuggestedValues: Bool = false
    var suggestedWeight: Double?
    var suggestedReps: Int?
    var suggestedDurationSeconds: Int?
    var suggestedRPE: Double?
    /// Fields the user explicitly typed into (suggestion-backed rows only) —
    /// those display their real stored values; untouched fields stay empty so
    /// the grayed placeholder suggestion shows through.
    var editedFields: Set<SetInputField>
    var onSuggestionFieldEdited: (SetInputField, Bool) -> Void = { _, _ in }
    var onMaterializeSuggestion: (Set<SetInputField>) -> Void = { _ in }
    var onCompleted: () -> Void = {}
    var onMatchPrevious: () -> Void = {}
    var onAdvancePastLastField: () -> Void = {}
    var onAddDrop: () -> Void = {}
    /// Non-nil for barbell-loaded exercises: opens the plate calculator.
    var onPlates: (() -> Void)? = nil
    let onDelete: () -> Void

    init(
        set: SetModel,
        workingNumber: Int,
        awards: [RecordKind] = [],
        previous: String,
        previousSet: SetModel?,
        isCardio: Bool,
        showWeight: Bool,
        showRPE: Bool,
        defaultsToFailure: Bool,
        effortScale: EffortScale = .rpe,
        displayUnit: WeightUnit,
        focusedInput: FocusState<SetInputFocus?>.Binding,
        openSwipeSetID: Binding<UUID?>,
        onChange: @escaping () -> Void,
        onSetType: @escaping (SetType) -> Void,
        completionDate: Date? = nil,
        usesSuggestedValues: Bool = false,
        suggestedWeight: Double? = nil,
        suggestedReps: Int? = nil,
        suggestedDurationSeconds: Int? = nil,
        suggestedRPE: Double? = nil,
        editedFields: Set<SetInputField>,
        onSuggestionFieldEdited: @escaping (SetInputField, Bool) -> Void = { _, _ in },
        onMaterializeSuggestion: @escaping (Set<SetInputField>) -> Void = { _ in },
        onCompleted: @escaping () -> Void = {},
        onMatchPrevious: @escaping () -> Void = {},
        onAdvancePastLastField: @escaping () -> Void = {},
        onAddDrop: @escaping () -> Void = {},
        onPlates: (() -> Void)? = nil,
        onDelete: @escaping () -> Void
    ) {
        self.set = set
        self.workingNumber = workingNumber
        self.awards = awards
        self.previous = previous
        self.previousSet = previousSet
        self.isCardio = isCardio
        self.showWeight = showWeight
        self.showRPE = showRPE
        self.defaultsToFailure = defaultsToFailure
        self.effortScale = effortScale
        self.displayUnit = displayUnit
        self.focusedInput = focusedInput
        self._openSwipeSetID = openSwipeSetID
        self.onChange = onChange
        self.onSetType = onSetType
        self.completionDate = completionDate
        self.usesSuggestedValues = usesSuggestedValues
        self.suggestedWeight = suggestedWeight
        self.suggestedReps = suggestedReps
        self.suggestedDurationSeconds = suggestedDurationSeconds
        self.suggestedRPE = suggestedRPE
        self.editedFields = editedFields
        self.onSuggestionFieldEdited = onSuggestionFieldEdited
        self.onMaterializeSuggestion = onMaterializeSuggestion
        self.onCompleted = onCompleted
        self.onMatchPrevious = onMatchPrevious
        self.onAdvancePastLastField = onAdvancePastLastField
        self.onAddDrop = onAddDrop
        self.onPlates = onPlates
        self.onDelete = onDelete
    }

    private var style: SetTypeStyle { SetTypeStyle.of(self.set.setType) }
    private var isDone: Bool { self.set.completedAt != nil }
    private var isDrop: Bool { self.set.setType == .drop }
    private var suggestedWeightText: String {
        suggestedWeight.map { Fmt.load($0, unit: displayUnit) } ?? "—"
    }
    private var suggestedRepsText: String {
        suggestedReps.map(String.init) ?? "—"
    }
    private var suggestedDurationText: String {
        suggestedDurationSeconds.map { String($0 / 60) } ?? "—"
    }

    private var showsAwards: Bool { isDone && !awards.isEmpty }

    var body: some View {
        SwipeToDeleteRow(
            isOpen: openSwipeSetID == set.id,
            onOpenChange: { open in
                if open { openSwipeSetID = set.id }
                else if openSwipeSetID == set.id { openSwipeSetID = nil }
            },
            onDelete: onDelete
        ) {
            VStack(alignment: .leading, spacing: 0) {
                row
                if set.setType == .amrap && !isDone {
                    amrapStrip
                }
                if showsAwards {
                    awardStrip
                        .transition(.opacity.combined(with: .scale(0.85, anchor: .topLeading)))
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .background(isDone ? theme.success.opacity(0.12) : Color.clear)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .animation(.spring(duration: 0.35), value: showsAwards)
        .sensoryFeedback(.impact(weight: .medium), trigger: completionHapticTrigger)
        .sensoryFeedback(.success, trigger: showsAwards) { _, isRecord in isRecord }
        .onAppear {
            syncDraftsFromValues()
        }
        .onChange(of: currentField) { oldField, newField in
            if let oldField {
                commitDraft(for: oldField)
                inputRouter?.unregister(token: accessoryToken(for: oldField))
            }
            if let newField {
                seedDraft(for: newField)
                registerAccessory(for: newField)
            }
        }
        .onChange(of: weightText) { _, _ in
            syncDraft(.weight)
        }
        .onChange(of: primaryText) { _, _ in
            syncDraft(.primary)
        }
        .onChange(of: rpeText) { _, _ in
            syncDraft(.rpe)
        }
        .onDisappear {
            commitFocusedDraft()
            if let currentField {
                inputRouter?.unregister(token: accessoryToken(for: currentField))
            }
        }
    }

    private func accessoryToken(for field: SetInputField) -> String {
        "\(set.id.uuidString)-\(field)"
    }

    /// Hand this field's actions to the logger's shared keyboard toolbar.
    private func registerAccessory(for field: SetInputField) {
        let nextAction: (() -> Void)? = nextInputField(after: field).map { next in { focus(next) } }
        inputRouter?.register(
            token: accessoryToken(for: field),
            onNext: nextAction,
            onComplete: completeFromKeyboard,
            onDismiss: clearFocus
        )
    }

    // MARK: - AMRAP time window

    /// True AMRAP is as many reps as possible in a FIXED TIME: pick the
    /// window, start the countdown (audible + haptic at zero, wrist buzz via
    /// the watch's rest pipeline), then log the reps achieved. The window
    /// used is saved on the set — progression is more reps in the same time.
    private var amrapSeconds: Int {
        self.set.durationSeconds ?? suggestedDurationSeconds ?? 60
    }

    private var amrapTimerIsMine: Bool {
        let timer = RestTimerController.shared
        return timer.isRunning && !timer.isMicro && timer.ownerID == set.id
    }

    private var amrapStrip: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "stopwatch.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(style.color)

            if amrapTimerIsMine {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text("\(RestTimerController.shared.remaining(at: context.date))s")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(style.color)
                        .contentTransition(.numericText(countsDown: true))
                }
                Text("go — as many reps as possible")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button("Stop") { RestTimerController.shared.skip() }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(style.color)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop AMRAP timer early")
            } else {
                RestDurationMenu(
                    options: [30, 45, 60, 90, 120, 180, 300],
                    allowsOff: false,
                    selected: amrapSeconds,
                    onPick: { picked in
                        if let picked {
                            set.durationSeconds = picked
                            onChange()
                        }
                    }
                ) {
                    HStack(spacing: 3) {
                        Text("\(amrapSeconds)s")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
                }
                .accessibilityLabel("AMRAP time window: \(amrapSeconds) seconds")

                Button {
                    let seconds = amrapSeconds
                    set.durationSeconds = seconds
                    RestTimerController.shared.start(
                        seconds: seconds,
                        label: "AMRAP",
                        ownerID: set.id,
                        soundOnEnd: true,
                        endNotification: (title: "Time's up", body: "Log the reps you got."),
                        onComplete: { [weak set] ranSeconds in
                            // Stopping early counts the window actually used.
                            set?.durationSeconds = ranSeconds
                        }
                    )
                    onChange()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Text("Start").font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(style.color)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(style.color.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Start AMRAP timer")

                Text("max reps in the window")
                    .font(.tag)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(.leading, 50)
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    /// A quiet one-line record callout under the set — gold, no popup.
    private var awardStrip: some View {
        HStack(spacing: 5) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 10, weight: .bold))
            Text(awards.map(\.label).joined(separator: "  ·  "))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(theme.warmup)
        .padding(.leading, 50)
        .padding(.bottom, 2)
    }

    private var currentField: SetInputField? {
        guard focusedInput.wrappedValue?.setID == set.id else { return nil }
        return focusedInput.wrappedValue?.field
    }

    private func rpeOptionIsSelected(_ option: RPEQuickPick) -> Bool {
        guard let rpe = effectiveRPE else { return false }
        return option == .warmup ? rpe < 6 : abs(rpe - option.rpeValue) < 0.0001
    }

    private var row: some View {
        HStack(spacing: 6) {
            Button {
                toggleCompletion()
            } label: {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.sectionTitle)
                    .foregroundStyle(isDone ? theme.success : theme.textTertiary)
                    .frame(width: grid.check, height: grid.fieldHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("complete-set-\(workingNumber)")

            // Drop sets cascade: indent under the parent set like a ladder.
            if isDrop {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(style.color.opacity(0.7))
                    .frame(width: 16)
            }
            Menu {
                ForEach(SetType.selectable, id: \.self) { type in
                    Button {
                        onSetType(type)
                    } label: {
                        Label(SetTypeStyle.of(type).label, systemImage: set.setType == type ? "checkmark" : "")
                    }
                }
                Divider()
                Button("Add Drop Set Below", systemImage: "arrow.down.right", action: onAddDrop)
                if let onPlates {
                    Button("Plate Calculator", systemImage: "circle.circle", action: onPlates)
                }
                Divider()
                Button("Delete Set", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                // Numbered specialty sets (back-off, AMRAP) keep their number
                // but carry the type letter and color: "3B", "4A".
                let hasBadge = !style.badge.isEmpty
                Text(style.numbered ? "\(workingNumber)\(style.badge)" : style.badge)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(hasBadge ? style.color : theme.textPrimary)
                    .frame(width: isDrop ? grid.setBadge * 0.8 : grid.setBadge, height: 30)
                    .background(hasBadge ? style.color.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    // 44pt hit target; the visual pill stays 30pt.
                    .frame(height: grid.fieldHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("set-type-menu")

            Button(action: matchPreviousAndRefreshDraft) {
                Text(previous)
                    .font(.system(size: 14))
                    .foregroundStyle(previousSet == nil ? theme.textTertiary : theme.accent)
                    .lineLimit(1)
                    // Scale down before truncating so the whole "135 × 10"
                    // stays readable even when the RPE column is showing.
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(previousSet == nil)
            .accessibilityHint(previousSet == nil ? "" : "Copies your previous set into this one")

            if showWeight {
                numberField(text: Binding(
                    get: { weightDraft },
                    set: { editDraft(.weight, value: $0) }
                ), placeholder: suggestedWeightText, width: grid.weight, field: .weight)
            }

            if isCardio {
                numberField(text: Binding(
                    get: { primaryDraft },
                    set: { editDraft(.primary, value: $0) }
                ), placeholder: suggestedDurationText, width: grid.weight, field: .primary, keyboardType: .numberPad)
            } else {
                numberField(text: Binding(
                    get: { primaryDraft },
                    set: { editDraft(.primary, value: $0) }
                ), placeholder: suggestedRepsText, width: grid.reps, field: .primary, keyboardType: .numberPad)
            }

            if showRPE && !isCardio {
                rpePickerField(width: grid.rpe)
            }
        }
    }

    /// RPE below 6 is stored as 5 and shown as "W" — warm-up effort, far from
    /// failure, where finer grading adds noise instead of signal. The option
    /// list + warm-up value live on `RPEQuickPick`.

    private var firstInputField: SetInputField {
        showWeight ? .weight : .primary
    }

    /// On suggestion-backed rows, an untouched field renders EMPTY: the
    /// suggested previous value shows through as the grayed placeholder
    /// instead of masquerading as an entered value. The moment the user
    /// commits a value into a field, that field renders its real text.
    private var weightText: String {
        if usesSuggestedValues && !editedFields.contains(.weight) { return "" }
        return set.modeWeight.map { Fmt.load($0, unit: displayUnit) } ?? ""
    }

    private var primaryText: String {
        if usesSuggestedValues && !editedFields.contains(.primary) { return "" }
        if isCardio {
            return set.durationSeconds.map { String($0 / 60) } ?? ""
        }
        return set.reps.map(String.init) ?? ""
    }

    private func focus(_ field: SetInputField?) {
        let previousField = currentField
        if let previousField, previousField != field {
            commitDraft(for: previousField)
        }
        if let field {
            seedDraft(for: field)
            focusedInput.wrappedValue = SetInputFocus(setID: set.id, field: field)
        } else {
            focusedInput.wrappedValue = nil
            hideKeyboard()
        }
    }

    private func clearFocus() {
        commitFocusedDraft()
        focusedInput.wrappedValue = nil
        hideKeyboard()
    }

    private func nextInputField(after field: SetInputField?) -> SetInputField? {
        switch field {
        case nil:
            firstInputField
        case .weight:
            .primary
        case .primary:
            nil
        case .rpe:
            nil
        }
    }

    private func completeFromKeyboard() {
        if !isDone {
            completeSet()
        } else {
            commitFocusedDraft()
        }
        onAdvancePastLastField()
    }

    private func toggleCompletion() {
        commitFocusedDraft()
        if isDone {
            // Animated at the source: this may be what un-folds a collapsed
            // exercise card, and the transaction must include the sibling
            // cards below so they slide instead of snapping.
            withAnimation(.snappy(duration: 0.28)) {
                set.completedAt = nil
            }
            set.recomputeDerivedMetrics()
            onChange()
        } else {
            completeSet()
        }
    }

    private func completeSet() {
        // A completion tap can clear focus before SwiftUI delivers the focus
        // change callback. Commit every locally edited draft, not just the
        // field that still appears focused in this exact frame.
        commitAllEditedDrafts()
        onMaterializeSuggestion(effectiveEditedSuggestionFields)
        // Animated at the source: completing the exercise's last set folds
        // the card into its one-line summary (see ExerciseLogCard), and the
        // sibling cards below must join the same transaction.
        withAnimation(.snappy(duration: 0.28)) {
            set.completedAt = completionDate ?? Date()
        }
        set.recomputeDerivedMetrics()
        completionHapticTrigger += 1
        onChange()
        onCompleted()
    }

    private func setRPE(_ value: Double) {
        // Writes only the RPE — the completion-time policy's
        // `set.rpe ?? previous.rpe` precedence means a pick is never
        // overwritten, and the other fields stay in placeholder state.
        set.rpe = value
        // An explicit pick in RIR mode also stamps the native RIR value so
        // the load model reads it directly (it prefers rir over rpe).
        if effortScale == .rir, value >= 6 {
            set.rir = Int((10 - value).rounded())
        } else {
            set.rir = nil
        }
        rpeDraft = formattedRPE(value)
        onChange()
    }

    private func clearRPE() {
        set.rpe = nil
        set.rir = nil
        rpeDraft = ""
        onChange()
    }

    private func matchPreviousAndRefreshDraft() {
        onMatchPrevious()
        if let currentField {
            seedDraft(for: currentField)
        }
    }

    private func seedDraft(for field: SetInputField) {
        // Suggestion-backed fields stay logically empty on focus — the user
        // types straight over the placeholder, no erasing.
        syncDraft(field, force: true)
        editedDraftFields.remove(field)
    }

    private func syncDraftsFromValues() {
        syncDraft(.weight, force: true)
        syncDraft(.primary, force: true)
        syncDraft(.rpe, force: true)
    }

    private func syncDraft(_ field: SetInputField, force: Bool = false) {
        guard force || (currentField != field && !editedDraftFields.contains(field)) else { return }
        switch field {
        case .weight:
            weightDraft = weightText
        case .primary:
            primaryDraft = primaryText
        case .rpe:
            rpeDraft = rpeText
        }
    }

    private func editDraft(_ field: SetInputField, value: String) {
        switch field {
        case .weight:
            weightDraft = value
        case .primary:
            primaryDraft = value
        case .rpe:
            rpeDraft = value
        }
        editedDraftFields.insert(field)
    }

    private func commitFocusedDraft() {
        if let currentField {
            commitDraft(for: currentField)
        }
    }

    private func commitAllEditedDrafts() {
        for field in [SetInputField.weight, .primary, .rpe]
        where editedDraftFields.contains(field) {
            commitDraft(for: field)
        }
    }

    private var effectiveEditedSuggestionFields: Set<SetInputField> {
        var result = editedFields
        for (field, isEdited) in suggestionFieldOverrides {
            if isEdited { result.insert(field) } else { result.remove(field) }
        }
        return result
    }

    private func recordSuggestionField(_ field: SetInputField, isEdited: Bool) {
        suggestionFieldOverrides[field] = isEdited
        onSuggestionFieldEdited(field, isEdited)
    }

    private func commitDraft(for field: SetInputField) {
        guard editedDraftFields.contains(field) else { return }
        defer { editedDraftFields.remove(field) }
        switch field {
        case .weight:
            commitWeightDraft()
        case .primary:
            commitPrimaryDraft()
        case .rpe:
            commitRPEDraft()
        }
    }

    private func commitWeightDraft() {
        let next = Fmt.loadKilograms(from: weightDraft, unit: displayUnit)
        // Clearing a field back to empty returns it to suggestion state —
        // display and commit-on-complete stay consistent either way.
        if usesSuggestedValues { recordSuggestionField(.weight, isEdited: next != nil) }
        guard !sameLoad(set.modeWeight, next) else { return }
        set.setModeWeight(next)
        onChange()
    }

    private func commitPrimaryDraft() {
        if isCardio {
            let next = parsedInt(primaryDraft).map { $0 * 60 }
            if usesSuggestedValues { recordSuggestionField(.primary, isEdited: next != nil) }
            guard set.durationSeconds != next else { return }
            set.durationSeconds = next
        } else {
            let next = parsedInt(primaryDraft)
            if usesSuggestedValues { recordSuggestionField(.primary, isEdited: next != nil) }
            guard set.reps != next else { return }
            set.reps = next
        }
        onChange()
    }

    private func commitRPEDraft() {
        let next = parsedRPE(rpeDraft)
        let nextRIR = effortScale == .rir ? next.flatMap { $0 >= 6 ? Int((10 - $0).rounded()) : nil } : nil
        guard !sameLoad(set.rpe, next) || set.rir != nextRIR else { return }
        set.rpe = next
        set.rir = nextRIR
        onChange()
    }

    private func parsedInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private func sameLoad(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(lhs), .some(rhs)):
            return abs(lhs - rhs) < 0.0001
        default:
            return false
        }
    }

    private func parsedRPE(_ raw: String) -> Double? {
        let trimmed = raw
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed) else { return nil }
        return min(10, max(0, value))
    }

    private func submitLabel(for field: SetInputField) -> SubmitLabel {
        nextInputField(after: field) == nil ? .done : .next
    }

    /// What the RPE chip reflects: the logged value, else the previous
    /// session's suggestion — the same rule the weight/reps fields already
    /// follow, so a suggested row reads fully prefilled instead of showing
    /// "—" until a tap materializes it.
    private var effectiveRPE: Double? {
        if let rpe = set.rpe { return rpe }
        if defaultsToFailure { return 10 }
        return usesSuggestedValues ? suggestedRPE : nil
    }

    private var rpeDisplay: String {
        guard let rpe = effectiveRPE else { return "—" }
        if rpe < 6 { return "W" }
        // RIR is the same stored fact read from the other end of the scale.
        return formattedRPE(effortScale == .rir ? 10 - rpe : rpe)
    }

    private var rpeText: String {
        return set.rpe.map(formattedRPE) ?? ""
    }

    private func rpeOptionLabel(_ value: Double) -> String {
        if effortScale == .rir {
            let rir = formattedRPE(10 - value)
            return switch value {
            case 10: "0 · nothing left"
            case 9, 9.5: "\(rir) · reps in reserve"
            case 8, 8.5: "\(rir) · reps in reserve"
            case 7, 7.5: "\(rir) · reps in reserve"
            default: "\(rir) · easy"
            }
        }
        return switch value {
        case 10: "10 · nothing left"
        case 9, 9.5: "\(value.formatted(.number.precision(.fractionLength(0...1)))) · ~1 rep left"
        case 8, 8.5: "\(value.formatted(.number.precision(.fractionLength(0...1)))) · ~2 reps left"
        case 7, 7.5: "\(value.formatted(.number.precision(.fractionLength(0...1)))) · ~3 reps left"
        default: "\(value.formatted(.number.precision(.fractionLength(0...1)))) · 4+ reps left"
        }
    }

    private func formattedRPE(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func numberField(
        text: Binding<String>,
        placeholder: String = "—",
        width: CGFloat,
        field: SetInputField,
        keyboardType: UIKeyboardType = .decimalPad
    ) -> some View {
        let label = accessibilityLabel(for: field)

        return ZStack {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    // Ghost suggestions ("135 lb") shrink before clipping at
                    // large Dynamic Type sizes.
                    .minimumScaleFactor(0.8)
                    .allowsHitTesting(false)
            }

            TextField("", text: text)
                .keyboardType(keyboardType)
                .submitLabel(submitLabel(for: field))
                .focused(focusedInput, equals: SetInputFocus(setID: set.id, field: field))
                .multilineTextAlignment(.center)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .textFieldStyle(.plain)
                .accessibilityLabel(label)
                .onSubmit {
                    if let next = nextInputField(after: field) {
                        focus(next)
                    } else {
                        completeFromKeyboard()
                    }
                }
        }
        .frame(width: width, height: grid.fieldHeight)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func rpePickerField(width: CGFloat) -> some View {
        Menu {
            ForEach(RPEQuickPick.allOptions, id: \.self) { option in
                Button {
                    setRPE(option.rpeValue)
                } label: {
                    Label(rpeOptionLabel(option), systemImage: rpeOptionIsSelected(option) ? "checkmark" : "")
                }
            }
            if effectiveRPE != nil {
                Divider()
                Button("Clear \(effortScale.columnTitle)", role: .destructive, action: clearRPE)
            }
        } label: {
            Text(rpeDisplay)
                .font(.bodyStrong)
                .foregroundStyle(effectiveRPE == nil ? theme.textTertiary : theme.textPrimary)
                .frame(width: width, height: grid.fieldHeight)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(effortScale.columnTitle)
        .accessibilityValue(rpeDisplay)
        .accessibilityIdentifier("effort-set-\(workingNumber)")
    }

    private func rpeOptionLabel(_ option: RPEQuickPick) -> String {
        switch option {
        case .warmup:
            "W · warm-up"
        case .value(let value):
            rpeOptionLabel(value)
        }
    }

    private func accessibilityLabel(for field: SetInputField) -> String {
        switch field {
        case .weight:
            "Weight"
        case .primary:
            isCardio ? "Duration" : "Reps"
        case .rpe:
            effortScale.columnTitle
        }
    }

}
