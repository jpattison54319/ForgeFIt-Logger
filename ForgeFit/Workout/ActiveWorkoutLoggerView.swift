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

    static func of(_ type: SetType, theme t: AppTheme = .sage) -> SetTypeStyle {
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

private struct RemovedSessionRuntime {
    let id: UUID
    let wasLive: Bool
}

/// Full-screen active-workout logger with per-set type selection, dynamic
/// columns per exercise, inline reordering, sticky notes, and add/replace/remove.
struct ActiveWorkoutLoggerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var workout: WorkoutModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    /// Caller-supplied history (the historical editor passes its own). Live
    /// sessions leave it empty and the logger snapshots history itself — a
    /// STABLE snapshot, so ContentView's per-save @Query updates never hand
    /// this view a new array identity and force a full subtree diff.
    var injectedHistory: [WorkoutModel] = []
    var mode: WorkoutLoggerMode = .active
    var onMinimize: (() -> Void)? = nil
    /// Called with the just-finished workout after a successful finish, so the
    /// host can publish it to social (if the user has opted in).
    var onFinished: ((WorkoutModel) -> Void)? = nil

    /// Reference-backed so per-frame finger updates invalidate only the small
    /// reorder overlay, not this entire logger and all of its set fields.
    @State private var reorderSession: ExerciseReorderSession?
    @State private var showAddPicker = false
    @State private var replaceTarget: WorkoutExerciseModel?
    @State private var editBlock: WorkoutBlockModel?
    @State private var pendingRemoveBlock: WorkoutBlockModel?
    /// This session's progression suggestions, keyed by workout-exercise id.
    @State private var progressionByWorkoutExercise: [UUID: ProgressionSuggestionModel] = [:]
    @State private var showPostWorkoutSummary = false
    @State private var showEmptyDiscardConfirm = false
    @State private var conditioningFinishMessage: String?
    /// Non-nil while the "unfinished sets" warning is up. Populated at Finish,
    /// never during logging — an in-progress workout is *supposed* to have
    /// unticked sets.
    @State private var incompleteWorkSummary: IncompleteWorkSummary?
    @State private var detailExercise: ExerciseLibraryModel?
    /// Best prior values per exercise — the bar a set must clear to earn a
    /// record award. Computed once; history doesn't change mid-session.
    @State private var recordBaselines: [UUID: ExerciseRecordBaseline] = [:]
    @State private var liveSurfacePublishTask: Task<Void, Never>?
    @State private var previousSetsByExerciseID: [UUID: [SetModel]] = [:]
    /// Logger-local lookup snapshots. Card reconstruction is a hot path during
    /// typing/completion; it must not linearly scan the library and notes for
    /// every visible exercise.
    @State private var exerciseByID: [UUID: ExerciseLibraryModel] = [:]
    @State private var setupNoteByExerciseID: [UUID: UserExerciseNoteModel] = [:]
    /// A deleted/unpinned setup note must win over the immutable array the
    /// logger received at presentation. Otherwise a later cache refresh can
    /// reinsert that stale model before the parent's @Query catches up.
    @State private var removedSetupNoteExerciseIDs = Set<UUID>()
    /// Live-session history snapshot, fetched once on appear ("history doesn't
    /// change mid-session" is this screen's contract). Internal code reads
    /// `history`, which resolves injected (historical edit) over snapshot.
    @State private var snapshotHistory: [WorkoutModel] = []
    private var history: [WorkoutModel] { injectedHistory.isEmpty ? snapshotHistory : injectedHistory }
    @State private var liveStats = WorkoutLiveStats()
    /// Cached modality flags — see `computeModalityFlags()`.
    @State private var isPureCardio = false
    @State private var isPureYoga = false
    @State private var inputRouter = SetInputRouter()
    @State private var quickIncrement = QuickIncrementController()
    @AppStorage(WorkoutEffortPolicy.loggingEnabledKey) private var showRPEInLogger = false
    @AppStorage("effortScaleRaw") private var effortScaleRaw = EffortScale.rpe.rawValue
    @AppStorage(WorkoutEffortPolicy.failureTrainingKey) private var failureTrainingEnabled = false

    private var sortedExercises: [WorkoutExerciseModel] {
        workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .sorted { $0.position < $1.position }
    }
    private var orderedItems: [OrderedWorkoutItem] {
        OrderedWorkoutItem.ordered(in: workout)
    }
    private var supersetGroups: [Int] {
        Array(Set(sortedExercises.compactMap(\.supersetGroup))).sorted()
    }
    /// Library entries for what's already in this workout — the picker's
    /// suggestion context.
    private var exercisesInWorkout: [ExerciseLibraryModel] {
        sortedExercises.compactMap { exerciseByID[$0.exerciseID] }
    }
    /// Includes exercises created from a picker nested inside this logger even
    /// before the presenting view's `@Query` array catches up.
    private var liveExerciseLibrary: [ExerciseLibraryModel] {
        LiveExerciseLibraryCache.librarySnapshot(library: exercises, lookup: exerciseByID)
    }
    private var isHistoricalEdit: Bool { mode == .historicalEdit }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()
            // Always mounted, even while the reorder overlay covers it: the
            // hold-to-reorder gesture starts on a card handle inside this
            // scroll — removing the view mid-gesture would cancel the touch
            // and kill the drag right as it began.
            loggerScroll
                .accessibilityHidden(reorderSession != nil)
            if reorderSession != nil {
                reorderOverlay
                    .transition(.opacity)
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("active-workout-theme-\(theme.family.rawValue)")
        // The header lives in the safe area, so content can never slide
        // underneath it or collide with the stats bar.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                header
                statsBar
                    .padding(.horizontal, Space.lg)
                    .padding(.bottom, Space.sm)
                // The rest countdown gets its own full-width strip below
                // the stats instead of cramming into the top bar.
                if !isHistoricalEdit {
                    LoggerRestTimerHost()
                }
            }
        }
        .overlay { QuickIncrementOverlay() }
        .environment(inputRouter)
        .environment(quickIncrement)
        .coordinateSpace(name: QuickIncrementController.spaceName)
        .onAppear(perform: reconcileEffortVisibility)
        .onChange(of: showRPEInLogger) { _, _ in reconcileEffortVisibility() }
        // One app-owned accessory for every set input, driven by whichever
        // field registered itself with the router on focus. SwiftUI's iOS 26
        // `.keyboard` toolbar emits an invalid-frame runtime warning as it is
        // installed; the safe-area host keeps each action as standalone
        // Liquid Glass without entering that broken layout path.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let actions = inputRouter.active {
                KeyboardAccessoryBar {
                    CircleIconButton(
                        systemImage: "keyboard.chevron.compact.down",
                        label: "Dismiss keyboard",
                        action: actions.onDismiss
                    )
                    Spacer()
                    if let onNext = actions.onNext {
                        Button("Next", action: onNext)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.accentForeground)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                    }
                    Button(actions.completeTitle, action: actions.onComplete)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accentForeground)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
            }
        }
        // Reference caches walk the full workout history — built after the
        // first frame so the cover presents instantly. Rows show "—" for the
        // previous column for a frame or two, then fill in. The snapshot fetch
        // mirrors ContentView's old query shape (all workouts, newest first);
        // plain fetch only — relationship prefetching crashes on these
        // CloudKit-shaped models (see buildReferenceCaches).
        .task(id: workout.id) {
            await Task.yield()
            // SwiftUI can reuse the presented logger view when one workout is
            // saved and another starts in the same app session. Refresh for
            // every workout ID so the new session sees the just-saved history
            // instead of inheriting the prior logger's original snapshot.
            if injectedHistory.isEmpty {
                snapshotHistory = (try? modelContext.fetch(FetchDescriptor<WorkoutModel>(
                    sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
                ))) ?? []
            }
            await refreshReferenceCaches()
        }
        .sheet(isPresented: $showPostWorkoutSummary) {
            PostWorkoutSummaryView(
                workout: workout,
                exercises: liveExerciseLibrary,
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
                discardWorkout()
            }
            Button("Keep Logging", role: .cancel) {}
        } message: {
            Text("Nothing was completed — there's nothing to save to your history or Apple Health.")
        }
        .alert(
            "Conditioning Target Not Complete",
            isPresented: Binding(
                get: { conditioningFinishMessage != nil },
                set: { if !$0 { conditioningFinishMessage = nil } }
            )
        ) {
            Button("Keep Logging", role: .cancel) { conditioningFinishMessage = nil }
        } message: {
            Text(conditioningFinishMessage ?? "Complete the conditioning target before saving.")
        }
        // Unlike the conditioning blocker above, this one is dismissible in
        // both directions: stopping short is a legitimate way to end a
        // session, so the warning informs rather than gates.
        .alert(
            "Unfinished sets",
            isPresented: Binding(
                get: { incompleteWorkSummary != nil },
                set: { if !$0 { incompleteWorkSummary = nil } }
            )
        ) {
            Button("Keep Logging", role: .cancel) { incompleteWorkSummary = nil }
            Button("Finish Anyway") {
                incompleteWorkSummary = nil
                showPostWorkoutSummary = true
            }
        } message: {
            Text(incompleteWorkSummary?.message ?? "")
        }
        .sheet(isPresented: $showAddPicker) {
            ExercisePickerView(
                excludeYoga: true,
                showsWorkoutBlocks: !isHistoricalEdit,
                context: exercisesInWorkout,
                history: history,
                navigationTitle: "Add to Workout",
                onAddConditioningBlock: { addBlock(kind: .conditioning, planJSON: $0) },
                onAddYogaBlock: { addBlock(kind: .yoga, planJSON: $0) }
            ) { added in
                addExercises(added)
            }
        }
        .sheet(item: $editBlock) { block in
            if block.kind == .conditioning {
                ConditioningBlockBuilderView(
                    planJSON: block.planSnapshotJSON,
                    exercises: liveExerciseLibrary,
                    workouts: history,
                    commit: { updateBlock(block, planJSON: $0) }
                )
            } else {
                YogaFlowBuilderView(planJSON: block.planSnapshotJSON, commit: { json in
                    guard let json else { return false }
                    return updateBlock(block, planJSON: json)
                })
            }
        }
        .sheet(item: $replaceTarget) { target in
            // Gym swap: lead with close substitutes for the exercise being
            // replaced (search stays one tap away inside the sheet). The plain
            // picker remains the fallback for rows whose exercise is missing.
            if let currentExercise = exerciseByID[target.exerciseID] {
                ExerciseSwapSheet(
                    current: currentExercise,
                    allExercises: liveExerciseLibrary,
                    inUseIDs: Set(workout.exercises.map(\.exerciseID)),
                    history: history
                ) { picked in
                    replace(target, with: picked)
                }
            } else {
                ExercisePickerView(
                    singleSelection: true,
                    excludeYogaPoses: true,
                    context: exercisesInWorkout,
                    history: history,
                    navigationTitle: "Replace Exercise",
                    excludedIDs: Set(workout.exercises.map(\.exerciseID))
                ) { picked in
                    if let first = picked.first { replace(target, with: first) }
                }
            }
        }
        .sheet(item: $detailExercise) { exercise in
            NavigationStack {
                ExerciseDetailView(
                    exerciseID: exercise.id,
                    workouts: history.isEmpty ? [workout] : history,
                    exercises: liveExerciseLibrary
                )
            }
        }
        .confirmationDialog(
            "Remove this block?",
            isPresented: Binding(
                get: { pendingRemoveBlock != nil },
                set: { if !$0 { pendingRemoveBlock = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Block", role: .destructive) {
                if let block = pendingRemoveBlock { removeBlock(block) }
                pendingRemoveBlock = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoveBlock = nil }
        } message: {
            Text("Its logged segment data will be removed from this workout.")
        }
    }

    private var loggerScroll: some View {
        ScrollView(showsIndicators: false) {
            // Lazy: long workouts only build the cards on screen, and focus /
            // keystroke re-renders don't touch off-screen exercises.
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                if WorkoutNotePolicy.shouldPresentEditor(for: workout) {
                    WorkoutNoteEditor(workout: workout)
                } else {
                    SecondaryButton(title: "Add Workout Note", systemImage: "note.text") {
                        workout.notes = ""
                        workout.updatedAt = .now
                        modelContext.saveUserChanges()
                    }
                    .accessibilityIdentifier("add-workout-note")
                }
                ForEach(orderedItems, id: \.id) { item in
                    switch item {
                    case .exercise(let workoutExercise):
                        exerciseCard(for: workoutExercise)
                    case .block(let block):
                        blockCard(for: block)
                    }
                }
                if orderedItems.isEmpty {
                    emptyLoggerState
                }
                SecondaryButton(title: "Add to Workout", systemImage: "plus", action: presentExercisePicker)
                    .accessibilityIdentifier("add-to-workout")
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

    // MARK: - Hold-to-reorder

    /// The collapse overlay (see `ReorderCollapseOverlay`): every exercise as
    /// a name-only row gathered around the finger, the held one scaled under
    /// it, hovered rows dimmed, order snapping live as slots are crossed.
    @ViewBuilder
    private var reorderOverlay: some View {
        if let reorderSession {
            ReorderCollapseOverlay(session: reorderSession)
                .accessibilityIdentifier("live-workout-reorder-overlay")
        }
    }

    /// One continuous gesture from a card's reorder handle. UIKit calls this
    /// once when the stationary hold recognizes, then again for movement.
    private func reorderDragChanged(itemID: UUID, fingerY: CGFloat) {
        if let reorderSession {
            guard reorderSession.heldID == itemID else { return }
            reorderSession.fingerGlobalY = fingerY
            return
        }

        hideKeyboard()
        let rows = orderedItems.map { item in
            let rowName: String
            switch item {
            case .exercise(let exercise):
                rowName = exerciseByID[exercise.exerciseID]?.name ?? "Exercise"
            case .block(let block):
                rowName = block.kind.title
            }
            return ReorderCollapseOverlay.Row(id: item.id, name: rowName)
        }
        withAnimation(.snappy(duration: 0.2)) {
            reorderSession = ExerciseReorderSession(
                heldID: itemID,
                fingerGlobalY: fingerY,
                rows: rows
            )
        }
    }

    private func reorderDragEnded() {
        guard let reorderSession else { return }
        if reorderSession.didMove {
            let itemsByID = Dictionary(uniqueKeysWithValues: orderedItems.map { ($0.id, $0) })
            for (index, row) in reorderSession.rows.enumerated() {
                itemsByID[row.id]?.position = index
            }
            modelContext.saveUserChanges {
                publishWorkoutChange()
            }
        }
        withAnimation(.snappy(duration: 0.25)) { self.reorderSession = nil }
    }

    /// VoiceOver fallback for the drag: step a row one slot at a time.
    private func accessibilityMoveItem(_ id: UUID, by offset: Int) {
        var rows = orderedItems
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(rows.count - 1, index + offset))
        guard target != index else { return }
        rows.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        for (index, item) in rows.enumerated() { item.position = index }
        modelContext.saveUserChanges {
            publishWorkoutChange()
        }
    }

    @ViewBuilder
    private func exerciseCard(for we: WorkoutExerciseModel) -> some View {
        let ex = exerciseByID[we.exerciseID]
        let isYogaRow = ex?.isYoga == true
            || we.yogaFlowJSON != nil
            || workout.cardioSessions.contains { $0.workoutExerciseID == we.id && $0.isYogaSession }
        if isYogaRow {
            YogaExerciseCard(
                workout: workout,
                workoutExercise: we,
                exercise: ex,
                pinnedNote: setupNoteByExerciseID[we.exerciseID],
                onPinnedNoteChanged: { updateSetupNote($0, for: we.exerciseID) },
                allowsLiveControls: !isHistoricalEdit,
                availableSupersetGroups: supersetGroups,
                onAssignSuperset: { assignSuperset($0, to: we) },
                onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: we) },
                onUngroupSuperset: { ungroupSuperset($0) },
                onShowExerciseDetail: { exercise in detailExercise = exercise },
                onReplace: { replaceTarget = we },
                onRemove: { removeExercise(we) },
                onReorderDragChanged: { fingerY in
                    reorderDragChanged(itemID: we.id, fingerY: fingerY)
                },
                onReorderDragEnded: { reorderDragEnded() },
                onAccessibilityMoveBy: { offset in accessibilityMoveItem(we.id, by: offset) }
            )
        } else if ex?.isCardio == true {
            CardioExerciseCard(
                workout: workout,
                workoutExercise: we,
                exercise: ex,
                pinnedNote: setupNoteByExerciseID[we.exerciseID],
                onPinnedNoteChanged: { updateSetupNote($0, for: we.exerciseID) },
                allowsLiveControls: !isHistoricalEdit,
                availableSupersetGroups: supersetGroups,
                onAssignSuperset: { assignSuperset($0, to: we) },
                onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: we) },
                onUngroupSuperset: { ungroupSuperset($0) },
                onShowExerciseDetail: { exercise in detailExercise = exercise },
                onReplace: { replaceTarget = we },
                onRemove: { removeExercise(we) },
                onReorderDragChanged: { fingerY in
                    reorderDragChanged(itemID: we.id, fingerY: fingerY)
                },
                onReorderDragEnded: { reorderDragEnded() },
                onAccessibilityMoveBy: { offset in accessibilityMoveItem(we.id, by: offset) },
                history: history
            )
        } else {
            ExerciseLogCard(
                workout: workout,
                workoutExercise: we,
                exercise: ex,
                pinnedNote: setupNoteByExerciseID[we.exerciseID],
                onPinnedNoteChanged: { updateSetupNote($0, for: we.exerciseID) },
                previousSets: cachedPreviousSets(for: we),
                recordBaseline: recordBaselines[we.exerciseID],
                allowsRestTimers: !isHistoricalEdit,
                allowsCollapse: !isHistoricalEdit,
                showRPE: showRPEInLogger,
                failureTrainingEnabled: showRPEInLogger && failureTrainingEnabled,
                showsPreviousTapHint: !isHistoricalEdit,
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
                onReorderDragChanged: { fingerY in
                    reorderDragChanged(itemID: we.id, fingerY: fingerY)
                },
                onReorderDragEnded: { reorderDragEnded() },
                onAccessibilityMoveBy: { offset in accessibilityMoveItem(we.id, by: offset) },
                progression: progressionByWorkoutExercise[we.id],
                onRejectProgression: { rejectProgression(for: we) }
            )
            // Keyed by row + *library* exercise so a gym swap tears down card
            // state and the replacement begins with clean drafts.
            .id("\(we.id.uuidString)-\(we.exerciseID.uuidString)")
        }
    }

    @ViewBuilder
    private func blockCard(for block: WorkoutBlockModel) -> some View {
        if block.kind == .conditioning {
            ConditioningBlockCard(
                workout: workout,
                block: block,
                exercises: liveExerciseLibrary,
                allowsLiveControls: !isHistoricalEdit,
                onEdit: { editBlock = block },
                onRemove: { pendingRemoveBlock = block },
                onReorderDragChanged: { fingerY in
                    reorderDragChanged(itemID: block.id, fingerY: fingerY)
                },
                onReorderDragEnded: reorderDragEnded,
                onAccessibilityMoveBy: { accessibilityMoveItem(block.id, by: $0) }
            )
        } else {
            YogaBlockCard(
                workout: workout,
                block: block,
                allowsLiveControls: !isHistoricalEdit,
                onEdit: { editBlock = block },
                onRemove: { pendingRemoveBlock = block },
                onReorderDragChanged: { fingerY in
                    reorderDragChanged(itemID: block.id, fingerY: fingerY)
                },
                onReorderDragEnded: reorderDragEnded,
                onAccessibilityMoveBy: { accessibilityMoveItem(block.id, by: $0) }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        GlassEffectContainer(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
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
                if !isHistoricalEdit {
                    LoggerRestTimerControl()
                        .foregroundStyle(theme.textPrimary)
                }
                Button {
                    if isHistoricalEdit {
                        saveHistoricalEdit()
                    } else if let blocker = WorkoutFinisher.conditioningTargetBlocker(in: workout) {
                        conditioningFinishMessage = blocker
                    } else if !WorkoutFinisher.hasSubstance(workout) {
                        // Nothing logged: the celebratory summary would be
                        // all zeros, and finishing would discard anyway
                        // (WorkoutFinisher's empty-workout guard) — ask
                        // the one honest question instead.
                        showEmptyDiscardConfirm = true
                    } else if let incomplete = pendingIncompleteWork() {
                        // A set skipped by mistake, or an exercise that
                        // scrolled off the bottom and never got started, is
                        // silently dropped at finish. Say so once; finishing
                        // early on purpose stays one tap away.
                        incompleteWorkSummary = incomplete
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
                        .foregroundStyle(theme.accentForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .minimumTouchTarget()
                }
                // Keep the accent identity without the opaque fill of
                // glassProminent, so workout content remains visible through
                // the persistent action as the user requested.
                .buttonStyle(.glass)
                .tint(theme.accent)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("finish-workout-button")
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
        isPureCardio = workout.blocks.isEmpty && !sortedExercises.isEmpty && sortedExercises.allSatisfy { we in
            exerciseByID[we.exerciseID]?.isCardio == true
        }
        // A session that is all yoga gets a calm, session-shaped header —
        // duration, poses, heart rate — instead of volume/sets.
        isPureYoga = !orderedItems.isEmpty && orderedItems.allSatisfy { item in
            switch item {
            case .exercise(let exercise): exerciseByID[exercise.exerciseID]?.isYoga == true
            case .block(let block): block.kind == .yoga
            }
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
                let poses = workout.cardioSessions.compactMap { $0.logicalYogaPosesCompleted }.reduce(0, +)
                let hrs = workout.cardioSessions.compactMap { $0.avgHR }
                StatColumn(label: "Duration", value: Fmt.durationShort(loggedTime > 0 ? loggedTime : elapsed), valueColor: theme.accent, animatesValue: true)
                StatColumn(label: "Poses", value: poses > 0 ? "\(poses)" : "—", animatesValue: true)
                if isHistoricalEdit {
                    StatColumn(label: "Avg HR", value: hrs.isEmpty ? "—" : "\(hrs.reduce(0,+) / hrs.count)", animatesValue: true)
                } else {
                    LiveWorkoutHeartRateStat()
                }
            } else if isPureCardio {
                let totalDist = workout.cardioSessions.compactMap { $0.distanceMeters }.reduce(0, +)
                let loggedTime = workout.cardioSessions.compactMap { $0.durationSeconds }.reduce(0, +)
                let hrs = workout.cardioSessions.compactMap { $0.avgHR }
                StatColumn(label: "Duration", value: Fmt.durationShort(loggedTime > 0 ? loggedTime : elapsed), valueColor: theme.secondaryAccent, animatesValue: true)
                StatColumn(label: "Distance", value: totalDist > 0 ? Fmt.distance(totalDist) : "—", animatesValue: true)
                if isHistoricalEdit {
                    StatColumn(label: "Avg HR", value: hrs.isEmpty ? "—" : "\(hrs.reduce(0,+) / hrs.count)", animatesValue: true)
                } else {
                    LiveWorkoutHeartRateStat()
                }
            } else {
                // Neutral, not accent: the live timer is a data readout, not a
                // control. Reserving sage for interactive elements lets the
                // Finish button and tappable fields actually stand out.
                StatColumn(label: "Duration", value: Fmt.elapsed(elapsed), animatesValue: true)
                // Volume/Sets read `liveStats` inside their OWN body, so a set
                // completion (which mutates liveStats in place) re-renders only
                // these two columns — not statsContent or the exercise list.
                LiveVolumeSetsColumns(liveStats: liveStats)
                if !isHistoricalEdit {
                    LiveWorkoutHeartRateStat()
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
                StatColumn(label: "Volume", value: Fmt.volume(liveStats.volume), animatesValue: true)
                StatColumn(label: "Sets", value: Fmt.sets(liveStats.completedSets), animatesValue: true)
            }
        }
    }

    /// The empty state keeps the add affordance visible where users first look;
    /// the full-width action below remains the primary path.
    private var emptyLoggerState: some View {
        EmptyStateCard(
            title: "Ready to log",
            message: "Add your first exercise to this workout.",
            systemImage: "plus.circle",
            iconActionLabel: "Add first exercise",
            iconActionIdentifier: "empty-workout-add-exercise",
            iconAction: presentExercisePicker
        )
    }

    private func presentExercisePicker() {
        showAddPicker = true
    }

    private struct ReferenceCaches {
        var recordBaselines: [UUID: ExerciseRecordBaseline]
        var previousSetsByExerciseID: [UUID: [SetModel]]
    }

    private func refreshReferenceCaches() async {
        exerciseByID = LiveExerciseLibraryCache.refreshedLookup(
            library: exercises,
            retaining: exerciseByID
        )
        let storedSetupNotes = (try? modelContext.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? []
        setupNoteByExerciseID = Dictionary(
            (setupNotes + storedSetupNotes)
                .filter {
                    $0.userID == ForgeFitDemo.userID
                        && !removedSetupNoteExerciseIDs.contains($0.exerciseID)
                        && ExerciseNotePolicy.authoredText($0.note) != nil
                }
                .map { ($0.exerciseID, $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )
        computeModalityFlags()
        let caches = await buildReferenceCaches()
        guard !Task.isCancelled else { return }
        recordBaselines = caches.recordBaselines
        previousSetsByExerciseID = caches.previousSetsByExerciseID
        refreshProgressionSuggestions()
        refreshLiveStats()
    }

    private func updateSetupNote(_ note: UserExerciseNoteModel?, for exerciseID: UUID) {
        if let note, ExerciseNotePolicy.authoredText(note.note) != nil {
            removedSetupNoteExerciseIDs.remove(exerciseID)
            setupNoteByExerciseID[exerciseID] = note
        } else {
            removedSetupNoteExerciseIDs.insert(exerciseID)
            setupNoteByExerciseID.removeValue(forKey: exerciseID)
        }
    }

    private func setupNote(for exerciseID: UUID) -> UserExerciseNoteModel? {
        guard !removedSetupNoteExerciseIDs.contains(exerciseID) else { return nil }
        if let cached = setupNoteByExerciseID[exerciseID],
           ExerciseNotePolicy.authoredText(cached.note) != nil {
            return cached
        }
        return setupNotes
            .filter {
                $0.userID == ForgeFitDemo.userID
                    && $0.exerciseID == exerciseID
                    && ExerciseNotePolicy.authoredText($0.note) != nil
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func buildReferenceCaches() async -> ReferenceCaches {
        let exerciseIDs = Set(workout.exercises.map(\.exerciseID))
        var baselines: [UUID: ExerciseRecordBaseline] = [:]
        var previousSets = Dictionary(exerciseIDs.map { ($0, [SetModel]()) }, uniquingKeysWith: { first, _ in first })
        guard !exerciseIDs.isEmpty else {
            return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
        }

        // NOTE: relationship prefetching (`relationshipKeyPathsForPrefetching`)
        // was tried here and tripped a SwiftData internal assertion on these
        // CloudKit-shaped models (optional relationships) — the walk relies on
        // the time-budgeted slicing below instead, which caps each main-thread
        // stall regardless of per-workout faulting cost.
        let prior = sortedPriorWorkouts()

        // Time-budgeted slicing: the old fixed stride (yield every 20 workouts)
        // produced 50–200ms main-thread chunks on large histories — long enough
        // to eat the touch-down of the user's first scroll, alternating dead
        // and live gestures with the chunk cadence. A ~6ms budget keeps every
        // slice inside a frame, and the 1ms sleep (unlike a bare yield)
        // guarantees the run loop actually drains pending touch events.
        let sliceBudget: Duration = .milliseconds(6)
        var sliceStart = ContinuousClock.now
        func breatheIfNeeded() async -> Bool {
            guard sliceStart.duration(to: .now) > sliceBudget else { return true }
            try? await Task.sleep(for: .milliseconds(1))
            sliceStart = .now
            return !Task.isCancelled
        }

        let routineMatches = workout.routineID.map { routineID in prior.filter { $0.routineID == routineID } } ?? []
        let routineMatchIDs = Set(routineMatches.map(\.id))
        let fallback = prior.filter { !routineMatchIDs.contains($0.id) }

        let baselinePrior = prior.filter { $0.startedAt < workout.startedAt }
        for past in baselinePrior {
            for we in past.exercises where exerciseIDs.contains(we.exerciseID) {
                var baseline = baselines[we.exerciseID] ?? ExerciseRecordBaseline()
                for set in we.sets { baseline.absorb(set) }
                baselines[we.exerciseID] = baseline
            }
            guard await breatheIfNeeded() else {
                return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
            }
        }

        var unresolvedTypes = Dictionary(
            uniqueKeysWithValues: exerciseIDs.map {
                ($0, Set(SetType.allCases.map(\.rawValue)))
            }
        )
        for past in routineMatches + fallback {
            for we in past.exercises where exerciseIDs.contains(we.exerciseID) {
                let sets = we.sets.filter { $0.completedAt != nil }.sorted { $0.position < $1.position }
                guard !sets.isEmpty,
                      var unresolved = unresolvedTypes[we.exerciseID],
                      !unresolved.isEmpty else { continue }
                for type in SetType.allCases where unresolved.contains(type.rawValue) {
                    let sameType = sets.filter { $0.setType == type }
                    guard !sameType.isEmpty else { continue }
                    previousSets[we.exerciseID, default: []].append(contentsOf: sameType)
                    unresolved.remove(type.rawValue)
                }
                unresolvedTypes[we.exerciseID] = unresolved
            }
            if unresolvedTypes.values.allSatisfy(\.isEmpty) { break }
            guard await breatheIfNeeded() else {
                return ReferenceCaches(recordBaselines: baselines, previousSetsByExerciseID: previousSets)
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
        modelContext.saveUserChanges {
            publishWorkoutChange()
        }
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
        var result: [SetModel] = []
        var unresolved = Set(SetType.allCases.map(\.rawValue))
        for p in routineMatches + fallback {
            for we in p.exercises where we.exerciseID == exerciseID {
                let sets = we.sets.filter { $0.completedAt != nil }.sorted { $0.position < $1.position }
                for type in SetType.allCases where unresolved.contains(type.rawValue) {
                    let sameType = sets.filter { $0.setType == type }
                    guard !sameType.isEmpty else { continue }
                    result.append(contentsOf: sameType)
                    unresolved.remove(type.rawValue)
                }
            }
            if unresolved.isEmpty { break }
        }
        return result
    }

    /// Recompute the live counters in place — mutating the @Observable object
    /// invalidates only `LiveVolumeSetsColumns`, not the whole logger body.
    private func refreshLiveStats() {
        let completed = workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .flatMap(\.sets)
            .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        liveStats.volume = completed.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        liveStats.completedSets = completed.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }
    }

    private func addExercises(_ list: [ExerciseLibraryModel]) {
        withAnimation(reduceMotion ? Motion.reduced : Motion.entrance) {
            insertExercises(list)
        }
    }

    private func insertExercises(_ list: [ExerciseLibraryModel]) {
        let yogaSelections = list.filter(\.isYoga)
        var addedYogaSession = false
        var nextPosition = orderedItems.count
        for exercise in list {
            if exercise.isYoga {
                guard !addedYogaSession else { continue }
                addedYogaSession = true
                addYogaSession(from: yogaSelections)
                continue
            }
            // A newly created exercise is returned by the nested picker before
            // the logger's caller receives its updated @Query array. Register
            // it before adding the row so the first rendered card is complete.
            exerciseByID[exercise.id] = exercise
            // Cardio exercises follow the cardio data model (a linked session),
            // not strength sets.
            let we = WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: exercise.id,
                position: nextPosition,
                sets: exercise.isCardio ? [] : [SetModel(userID: ForgeFitDemo.userID, position: 0, weightMode: exercise.defaultWeightMode)]
            )
            nextPosition += 1
            if let pinned = setupNote(for: exercise.id),
               let note = ExerciseNotePolicy.authoredText(pinned.note) {
                we.notes = note
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
        modelContext.saveUserChanges {
            publishWorkoutChange()
        }
        Task { await refreshReferenceCaches() }
    }

    private func addYogaSession(from selections: [ExerciseLibraryModel]) {
        let sessionExercise = YogaPoseCatalog.sessionExercise(in: modelContext)
        exerciseByID[sessionExercise.id] = sessionExercise
        let plan = YogaFlowPlan.fromSelectedPoses(selections)
        let we = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: sessionExercise.id,
            position: orderedItems.count,
            yogaFlowJSON: plan?.encodedJSON(),
            sets: []
        )
        if let pinned = setupNote(for: sessionExercise.id),
           let note = ExerciseNotePolicy.authoredText(pinned.note) {
            we.notes = note
            we.notePinned = true
        }
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

    private func addBlock(kind: WorkoutBlockKind, planJSON: String) {
        let block = WorkoutBlockModel(
            userID: workout.userID,
            kind: kind,
            position: orderedItems.count,
            planSnapshotJSON: planJSON,
            progressJSON: kind == .conditioning ? ConditioningProgress().encodedJSON() : nil
        )
        let yogaPlan = kind == .yoga ? YogaFlowPlan.decode(from: planJSON) : nil
        let session = CardioSessionModel(
            userID: workout.userID,
            workoutBlockID: block.id,
            modality: kind == .yoga ? CardioSessionModel.yogaModality : CardioSessionModel.conditioningModality,
            startedAt: isHistoricalEdit ? workout.startedAt : .now,
            endedAt: isHistoricalEdit ? workout.endedAt : nil,
            sourceDevice: isHistoricalEdit ? nil : (kind == .yoga ? "iphone-yoga" : "iphone-conditioning"),
            durationSeconds: yogaPlan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil },
            yogaStyleRaw: yogaPlan?.styleRaw
        )
        withAnimation(reduceMotion ? Motion.reduced : Motion.entrance) {
            modelContext.insert(block)
            modelContext.insert(session)
            workout.blocks.append(block)
            workout.cardioSessions.append(session)
        }
        modelContext.saveUserChanges {
            publishWorkoutChange()
        }
        computeModalityFlags()
    }

    private func updateBlock(_ block: WorkoutBlockModel, planJSON: String) -> Bool {
        let session = workout.cardioSessions.first { $0.workoutBlockID == block.id }
        guard session?.liveStartedAt == nil, session?.endedAt == nil else { return false }
        let generatedExercise = workout.exercises.first { $0.generatedByWorkoutBlockID == block.id }
        return WorkoutBlockPlanPersistence.apply(
            planJSON,
            to: block,
            session: session,
            generatedExercise: generatedExercise,
            in: modelContext,
            onCommit: { publishWorkoutChange() }
        )
    }

    private func removeBlock(_ block: WorkoutBlockModel) {
        let generatedExercises = workout.exercises.filter { $0.generatedByWorkoutBlockID == block.id }
        let generatedIDs = Set(generatedExercises.map(\.id))
        let sessions = workout.cardioSessions.filter {
            $0.workoutBlockID == block.id || $0.workoutExerciseID.map(generatedIDs.contains) == true
        }
        let removedRuntime = sessions.map {
            RemovedSessionRuntime(id: $0.id, wasLive: $0.liveStartedAt != nil && $0.endedAt == nil)
        }
        for session in sessions {
            modelContext.delete(session)
        }
        workout.cardioSessions.removeAll { session in
            session.workoutBlockID == block.id || session.workoutExerciseID.map(generatedIDs.contains) == true
        }
        for exercise in generatedExercises { modelContext.delete(exercise) }
        workout.exercises.removeAll { generatedIDs.contains($0.id) }
        workout.blocks.removeAll { $0.id == block.id }
        modelContext.delete(block)
        normalizeOrderedPositions()
        workout.recomputeTotalVolume()
        modelContext.saveUserChanges {
            cancelRemovedSessionRuntime(removedRuntime)
            publishWorkoutChange()
        }
        computeModalityFlags()
        Task { await refreshReferenceCaches() }
    }

    private func normalizeOrderedPositions(excluding excludedID: UUID? = nil) {
        for (index, item) in orderedItems.filter({ $0.id != excludedID }).enumerated() {
            item.position = index
        }
    }

    /// The unfinished-work warning for this Finish tap, or nil when there is
    /// nothing unticked worth interrupting for.
    private func pendingIncompleteWork() -> IncompleteWorkSummary? {
        let names = Dictionary(
            liveExerciseLibrary.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let summary = IncompleteWorkSummary.make(for: workout, exerciseNames: names)
        return summary.isEmpty ? nil : summary
    }

    private func replace(_ target: WorkoutExerciseModel, with exercise: ExerciseLibraryModel) {
        // The card's `.id` includes `exerciseID`, so this swap tears down and
        // recreates the card — the animated transaction turns that into a
        // crossfade between the old and new exercise identity.
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
            performReplace(target, with: exercise)
        }
    }

    private func performReplace(_ target: WorkoutExerciseModel, with exercise: ExerciseLibraryModel) {
        let previousExercise = exerciseByID[target.exerciseID]
        let previousSession = workout.cardioSessions.first { $0.workoutExerciseID == target.id }
        let wasCardio = previousExercise?.isCardio == true
            || (previousSession != nil && previousSession?.isYogaSession == false)
        let wasSessionBased = previousExercise?.isCardio == true
            || previousExercise?.isYoga == true
            || previousSession != nil
        var removedRuntime: [RemovedSessionRuntime] = []
        let replacement = exercise.isYoga ? YogaPoseCatalog.sessionExercise(in: modelContext) : exercise
        // `exercise` may have been created inside the replacement picker's
        // nested sheet. Cache the concrete model before either replacement path
        // publishes its ID to the card tree.
        exerciseByID[replacement.id] = replacement

        if !exercise.isCardio, !exercise.isYoga {
            LiveExerciseReplacement.replaceInPlace(
                target: target,
                replacementExerciseID: replacement.id,
                replacementWeightMode: exercise.defaultWeightMode,
                replacementIsUnilateral: exercise.isUnilateral
            )
        } else {
            target.exerciseID = replacement.id
            target.updatedAt = Date()
        }

        previousSetsByExerciseID[replacement.id] = []
        recordBaselines[replacement.id] = nil
        if let suggestion = progressionByWorkoutExercise[target.id], suggestion.statusRaw == "pending" {
            suggestion.statusRaw = "rejected"
            suggestion.updatedAt = Date()
        }
        if let pinned = setupNote(for: replacement.id),
           let note = ExerciseNotePolicy.authoredText(pinned.note) {
            target.notes = note
            target.notePinned = true
        } else {
            // Exercise notes describe that exercise, so an in-workout swap
            // never carries the old movement's note onto the replacement.
            target.notes = nil
            target.notePinned = false
        }
        if exercise.isYoga {
            target.intervalPlanJSON = nil
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
            if !wasCardio { target.intervalPlanJSON = nil }
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
            target.intervalPlanJSON = nil
            target.yogaFlowJSON = nil
            if wasSessionBased {
                removedRuntime = deleteCardioSessions(for: target.id)
            }
            if target.sets.isEmpty {
                let set = SetModel(userID: ForgeFitDemo.userID, position: 0, weightMode: exercise.defaultWeightMode)
                modelContext.insert(set)
                target.sets = [set]
            }
        }
        workout.recomputeTotalVolume()
        refreshLiveStats()
        modelContext.saveUserChanges {
            cancelRemovedSessionRuntime(removedRuntime)
            publishWorkoutChange()
        }
        Task { await refreshReferenceCaches() }
    }

    private func removeExercise(_ we: WorkoutExerciseModel) {
        var removedRuntime: [RemovedSessionRuntime] = []
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
            removedRuntime = deleteCardioSessions(for: we.id)
            workout.exercises.removeAll { $0.id == we.id }
            modelContext.delete(we)
            normalizeOrderedPositions()
            workout.recomputeTotalVolume()
            refreshLiveStats()
        }
        modelContext.saveUserChanges {
            cancelRemovedSessionRuntime(removedRuntime)
            publishWorkoutChange()
        }
    }

    private func deleteCardioSessions(for workoutExerciseID: UUID) -> [RemovedSessionRuntime] {
        let sessions = workout.cardioSessions.filter { $0.workoutExerciseID == workoutExerciseID }
        let removedRuntime = sessions.map {
            RemovedSessionRuntime(id: $0.id, wasLive: $0.liveStartedAt != nil && $0.endedAt == nil)
        }
        for session in sessions {
            modelContext.delete(session)
        }
        workout.cardioSessions.removeAll { $0.workoutExerciseID == workoutExerciseID }
        return removedRuntime
    }

    private func cancelRemovedSessionRuntime(_ removed: [RemovedSessionRuntime]) {
        guard !removed.isEmpty else { return }
        for session in removed {
            CardioGoalAnnouncer.shared.cancel(sessionID: session.id)
            CardioRouteRecorder.shared.cancel(sessionID: session.id)
            IntervalRunnerHub.shared.stop(for: session.id)
            YogaFlowRunnerHub.shared.stop(for: session.id, clearCheckpoint: true)
        }
        guard removed.contains(where: \.wasLive) else { return }
        HRZoneGuard.shared.deactivate()
        PaceGuard.shared.deactivate()
        PaceAnnouncer.shared.stop()
        NotificationScheduler.shared.cancelCardioCues()
    }

    private func nextSupersetGroup() -> Int {
        SupersetUI.nextGroup(excluding: supersetGroups)
    }

    private func assignSuperset(_ group: Int?, to we: WorkoutExerciseModel) {
        we.supersetGroup = group
        we.updatedAt = Date()
        compactSupersetPositions()
        modelContext.saveUserChanges {
            WatchLink.shared.publishState()
        }
    }

    private func ungroupSuperset(_ group: Int) {
        for exercise in workout.exercises where exercise.supersetGroup == group {
            exercise.supersetGroup = nil
            exercise.updatedAt = Date()
        }
        compactSupersetPositions()
        modelContext.saveUserChanges {
            WatchLink.shared.publishState()
        }
    }

    private func compactSupersetPositions() {
        let rows = orderedItems
        var output: [OrderedWorkoutItem] = []
        var seenGroups = Set<Int>()

        for row in rows {
            guard case .exercise(let exercise) = row,
                  let group = exercise.supersetGroup else {
                output.append(row)
                continue
            }
            guard !seenGroups.contains(group) else { continue }
            seenGroups.insert(group)
            output.append(contentsOf: rows.filter { item in
                guard case .exercise(let candidate) = item else { return false }
                return candidate.supersetGroup == group
            })
        }

        for (index, row) in output.enumerated() {
            row.position = index
            switch row {
            case .exercise(let exercise): exercise.updatedAt = Date()
            case .block(let block): block.updatedAt = Date()
            }
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
        guard let roundIndex = SupersetRoundPolicy.logicalRoundIndex(
            for: set.id,
            in: sets.map(\.supersetProgress)
        ) else { return }
        let groupMembers = sortedExercises.filter { $0.supersetGroup == group }
        let roundComplete = groupMembers.allSatisfy { member in
            let memberSets = member.sets.sorted { $0.position < $1.position }
            return SupersetRoundPolicy.isRoundSatisfied(
                roundIndex,
                in: memberSets.map(\.supersetProgress)
            )
        }
        guard roundComplete else { return }
        startRest(after: set, in: workoutExercise, label: "\(SupersetUI.label(for: group)) rest")
    }

    private func hasPendingDropSet(after set: SetModel, in workoutExercise: WorkoutExerciseModel) -> Bool {
        let sets = workoutExercise.sets.sorted { $0.position < $1.position }
        return SupersetRoundPolicy.hasPendingDrop(
            after: set.id,
            in: sets.map(\.supersetProgress)
        )
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
        // change. One task owns every external surface so a burst of timer/set
        // mutations converges once, no later than the 500 ms contract.
        liveSurfacePublishTask?.cancel()
        liveSurfacePublishTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            WatchLink.shared.publishState(policy: .immediate)
            // A finish inside the debounce window must not re-request the
            // Live Activity that ContentView just ended.
            guard workout.endedAt == nil, workout.deletedAt == nil else { return }
            WorkoutActivityController.shared.update(workout: workout, exercises: liveExerciseLibrary)
            updateWidgetSnapshot()
        }
    }

    /// A visibility setting is a logging contract, not just layout. Clear any
    /// effort entered earlier in this live workout as soon as the user turns
    /// the column off; historical editing is intentionally unaffected.
    private func reconcileEffortVisibility() {
        guard !isHistoricalEdit, !showRPEInLogger else { return }
        guard WorkoutEffortPolicy.removeEffort(from: workout) else { return }
        workout.updatedAt = .now
        modelContext.saveUserChanges {
            publishWorkoutChange()
        }
    }

    private func updateWidgetSnapshot() {
        let sortedExercises = workout.exercises.sorted { $0.position < $1.position }
        let allSets = sortedExercises.flatMap(\.sets)
        let currentExercise = sortedExercises.first { exercise in
            exercise.sets.contains { $0.completedAt == nil } || exercise.sets.isEmpty
        } ?? sortedExercises.last
        let timer = RestTimerController.shared

        ForgeFitWidgetSnapshotStore.save(ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            workoutTitle: workout.title ?? "Workout",
            workoutStartedAt: workout.startedAt,
            currentExerciseName: currentExercise.flatMap { exerciseByID[$0.exerciseID]?.name },
            completedSets: allSets.filter { $0.completedAt != nil }.count,
            totalSets: allSets.count,
            restEndsAt: timer.isRunning && !timer.isMicro ? timer.endsAt : nil,
            heartRate: LiveMetricsHub.shared.liveMetrics?.heartRate
        ))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    private func finishAndDismiss(
        endedAt: Date,
        summaryCommit: WorkoutFinisher.SummaryCommit
    ) -> String? {
        // Live rows debounce some writes to keep scrolling responsive. Flush
        // their in-memory graph before opening the isolated terminal context,
        // otherwise a fast Finish -> Save can make that context reconcile an
        // older workout snapshot. A failed flush retains the pending changes
        // in this context and keeps the workout open for an exact retry.
        do {
            try modelContext.save()
        } catch {
            return error.localizedDescription
        }
        // Prefer live session metrics (watch or BLE monitor) when streaming.
        if let failure = WorkoutFinisher.finish(
            workoutID: workout.id,
            in: modelContext,
            liveMetrics: LiveMetricsHub.shared.liveMetrics,
            endedAt: endedAt,
            summaryCommit: summaryCommit
        ) {
            return failure
        }
        onFinished?(workout)
        dismiss()
        return nil
    }

    private func discardWorkout() {
        PersistentChangeSaveCenter.shared.performReportingFailure({
            WorkoutFinisher.discard(workoutID: workout.id, in: modelContext)
        }, onSuccess: dismiss.callAsFunction)
    }

    private func saveHistoricalEdit() {
        workout.recomputeTotalVolume()
        workout.updatedAt = .now
        modelContext.saveUserChanges {
            BackupScheduler.shared.noteLogDataChanged()
            dismiss()
        }
    }
}

// MARK: - Post-workout summary

/// Staggered one-shot entrance for the leading summary cards: a short fade
/// (plus a 12 pt rise when motion is allowed) with a ≤150 ms cascade. Reduce
/// Motion drops the rise and the stagger, keeping a single quick fade.
private struct SummaryCardReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let revealed: Bool

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed || reduceMotion ? 0 : 12)
            .animation(
                reduceMotion
                    ? Motion.reduced
                    : Motion.entrance.delay(Double(index) * 0.05),
                value: revealed
            )
    }
}

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
    let onSave: (Date, WorkoutFinisher.SummaryCommit) -> String?
    let onCancel: () -> Void

    /// Detected structural drift between this workout and its source routine,
    /// populated when the user taps Save. Non-nil while the "update routine?"
    /// prompt is in flight.
    /// One-shot reveal switches for the summary choreography: cards cascade
    /// in, then the XP bar fills from its pre-award position.
    @State private var cardsRevealed = false
    @State private var xpRevealed = false
    @State private var routinePlan: RoutineChangeSync.Plan?
    @State private var routineName: String?
    @State private var showRoutineUpdatePrompt = false
    @State private var saveError: String?
    /// FF-006 in-flight gate: held from the moment a Save commits until the
    /// sheet dismisses (success) or the finisher surfaces a failure (release
    /// so "Try saving again" works). The routine prompt does not hold it, so
    /// dismissing that dialog can never strand the gate.
    @State private var saveGate = WorkoutFinisher.InFlightGate()
    /// One-shot notification prime, shown at the value moment (a finished
    /// workout) instead of buried in Settings — accepting turns on the
    /// rest-timer alerts, reminders, and Wrapped alerts that
    /// otherwise silently no-op.
    @AppStorage("notificationPrimeShown") private var notificationPrimeShown = false
    @State private var shareImage: UIImage?
    @State private var showShareSheet = false
    @State private var sessionRPE: Int?
    @State private var sessionRPERatedAt: Date?
    @State private var finishRequestedAt = Date.now

    private var completedSets: [SetModel] {
        workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
    }
    private var duration: Int {
        max(0, Int(finishRequestedAt.timeIntervalSince(workout.startedAt)))
    }
    private var volume: Double {
        completedSets.reduce(0) { $0 + ($1.totalVolume ?? 0) }
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
    /// Final records and milestones use one derivation path across the
    /// completion sheet, history, search, and generated share images.
    private var awardEntries: [WorkoutAward] {
        WorkoutAwards.all(
            for: workout,
            history: history,
            exercises: exercises
        )
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
    /// Where the bar stood before this workout's award — the fill animates
    /// from here so the gain reads as earned progress, not theater.
    private var preAwardProgress: XPService.Progress {
        XPService.progress(forTotalXP: currentXP)
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

                    PostWorkoutSummaryStatsCard(
                        workout: workout,
                        exercises: exercises,
                        durationSeconds: duration,
                        awardCount: awardEntries.count
                    )
                    .modifier(SummaryCardReveal(index: 0, revealed: cardsRevealed))

                    SessionRPECard(selection: $sessionRPE)
                        .onChange(of: sessionRPE) { _, value in
                            sessionRPERatedAt = value == nil ? nil : .now
                        }
                        .modifier(SummaryCardReveal(index: 1, revealed: cardsRevealed))

                    if xpAward.amount > 0 {
                        xpCard
                            .modifier(SummaryCardReveal(index: 2, revealed: cardsRevealed))
                    }

                    if let volumeDeltaText {
                        summaryRow("chart.line.uptrend.xyaxis", "Compared with last time", volumeDeltaText)
                            .modifier(SummaryCardReveal(index: 2, revealed: cardsRevealed))
                    }

                    if !trainedMuscleRows.isEmpty || cardioAdaptationText != nil {
                        trainedCard
                            .modifier(SummaryCardReveal(index: 3, revealed: cardsRevealed))
                    }

                    if !awardEntries.isEmpty {
                        WorkoutAwardsCard(awards: awardEntries)
                            .modifier(SummaryCardReveal(index: 3, revealed: cardsRevealed))
                    }

                    if !nextTimeEntries.isEmpty {
                        nextTimeCard
                            .modifier(SummaryCardReveal(index: 3, revealed: cardsRevealed))
                    }

                    if !notificationPrimeShown, NotificationScheduler.shared.authorizationStatus == .notDetermined {
                        notificationPrimeCard
                            .modifier(SummaryCardReveal(index: 3, revealed: cardsRevealed))
                    }
                }
                .padding(Space.lg)
                .onAppear { cardsRevealed = true }
            }
            .background(theme.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                PostWorkoutActionBar(
                    onKeepLogging: onCancel,
                    onShare: shareWorkout,
                    onSave: requestSave,
                    isSaving: saveGate.isActive
                )
            }
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
            routeMaps: [:],
            awards: awardEntries
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
                        .foregroundStyle(theme.accentForeground)
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
                        .foregroundStyle(theme.accentForeground)
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
                        .foregroundStyle(theme.accentForeground)
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
                    Button {
                        notificationPrimeShown = true
                        Task { await NotificationScheduler.shared.requestPermission() }
                    } label: {
                        Text("Enable notifications")
                            .minimumTouchTarget()
                    }
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .tint(theme.accent)
                    Button {
                        notificationPrimeShown = true
                    } label: {
                        Text("Not now")
                            .minimumTouchTarget()
                    }
                        .font(.bodyStrong)
                        .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
            }
        }
    }

    private var xpCard: some View {
        let leveledUp = projectedXPProgress.level > preAwardProgress.level
        let displayedAmount = xpRevealed ? xpAward.amount : 0
        let displayedLevel = xpRevealed ? projectedXPProgress.level : preAwardProgress.level
        // A level-up starts the new level's bar from empty; otherwise the fill
        // continues from where the bar stood before this workout.
        let displayedFraction = xpRevealed
            ? projectedXPProgress.fraction
            : (leveledUp ? 0 : preAwardProgress.fraction)
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .center, spacing: Space.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .frame(width: 38, height: 38)
                        .background(theme.accent)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("+\(displayedAmount) XP")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(theme.textPrimary)
                            .contentTransition(.numericText(value: Double(displayedAmount)))
                        Text("Level \(displayedLevel)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .contentTransition(.numericText(value: Double(displayedLevel)))
                    }
                    Spacer()
                }
                ProgressView(value: displayedFraction)
                    .tint(theme.accent)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
                Text("\(projectedXPProgress.xpIntoLevel) / \(projectedXPProgress.xpNeededForNextLevel) XP to Level \(projectedXPProgress.level + 1)")
                    .font(.tag)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .task {
            guard !xpRevealed else { return }
            try? await Task.sleep(for: .milliseconds(400))
            withAnimation(Motion.reward) { xpRevealed = true }
        }
    }

    // MARK: - Routine update flow

    private var routineUpdatePromptTitle: String {
        if let name = routineName { return "Update “\(name)” with your changes?" }
        return "Update routine with your changes?"
    }

    /// On Save: if this workout was started from a routine and structural
    /// changes were made mid-session, ask before finishing. Otherwise save
    /// straight away. The gate is checked (not held) here — the routine
    /// prompt must not strand it if dismissed without a choice.
    private func requestSave() {
        guard !saveGate.isActive else { return }
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
        // Acquired before the isolated transaction so a rapid second commit
        // cannot re-enter mid-apply.
        guard saveGate.tryBegin() else { return }
        commitSaveUnderGate(updateRoutine: true)
    }

    private func commitSave() {
        guard saveGate.tryBegin() else { return }
        commitSaveUnderGate(updateRoutine: false)
    }

    private func commitSaveUnderGate(updateRoutine: Bool) {
        // The finisher applies these values, progression resolution, and the
        // optional routine reconciliation inside one isolated terminal save.
        // The long-lived context is mirrored only after that save succeeds.
        let summaryCommit = WorkoutFinisher.SummaryCommit(
            wholeSessionRPE: sessionRPE.map(Double.init),
            wholeSessionRPERatedAt: sessionRPERatedAt,
            wholeSessionRPEProtocolVersion: sessionRPE == nil ? nil : "whole-session-cr10-immediate-v1",
            updateRoutine: updateRoutine
        )
        saveError = onSave(finishRequestedAt, summaryCommit)
        if saveError != nil {
            // A surfaced failure re-opens the gate so "Try saving again" works;
            // success keeps it held through dismissal.
            saveGate.end()
        }
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
                    .foregroundStyle(theme.accentForeground)
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

enum SetInputField: Hashable {
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
    @Environment(\.scenePhase) private var scenePhase
    var grid = SetGridMetrics()
    @Bindable var workout: WorkoutModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let exercise: ExerciseLibraryModel?
    let pinnedNote: UserExerciseNoteModel?
    var onPinnedNoteChanged: (UserExerciseNoteModel?) -> Void = { _ in }
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
    /// Streams the finger's global Y while the reorder handle is held and
    /// dragged — the parent collapses every card around the finger with this
    /// exercise scaled under it (see `ReorderCollapseOverlay`).
    var onReorderDragChanged: (CGFloat) -> Void = { _ in }
    var onReorderDragEnded: () -> Void = {}
    /// VoiceOver fallback for the drag: move this exercise one slot up/down.
    var onAccessibilityMoveBy: (Int) -> Void = { _ in }
    /// This exercise's progression suggestion for the session (nil = none
    /// offered — no history, rule off, or not a strength exercise).
    var progression: ProgressionSuggestionModel? = nil
    var onRejectProgression: () -> Void = {}

    @State private var deferredSaveTask: Task<Void, Never>?
    /// Set being plate-calculated (barbell-loaded exercises only).
    @State private var plateSet: SetModel?
    /// Myo-reps use a focused full-screen runner; the enclosing card keeps the
    /// presentation identity so logged progress survives row reconstruction.
    @State private var presentedMyoSet: MyoRepSetPresentation?
    /// A row converted into Myo-reps may already show regular-set reps. Keep
    /// those as an activation suggestion without treating them as performed;
    /// `SetModel.reps` becomes the durable activation receipt only after Log.
    @State private var myoActivationSuggestionOverrides: [UUID: Int] = [:]
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
    @State private var noteFocusRequested = false

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
        .fullScreenCover(item: $presentedMyoSet) { presentation in
            let sets = sortedSets
            if let index = sets.firstIndex(where: { $0.id == presentation.set.id }) {
                if presentation.mode == .editing {
                    MyoRepSetEditorView(
                        set: presentation.set,
                        exerciseName: exercise?.name ?? "Exercise",
                        displayUnit: displayUnit,
                        showsWeight: weightHeader != nil,
                        isUnilateral: exercise?.isUnilateral == true,
                        supportsResistanceBands: supportsResistanceBands,
                        onSave: {
                            editedSuggestionSetIDs.insert(presentation.set.id)
                            recompute(changedSet: presentation.set)
                        }
                    )
                } else {
                    MyoRepActiveSetView(
                        set: presentation.set,
                        workoutExercise: workoutExercise,
                        exerciseName: exercise?.name ?? "Exercise",
                        supportsResistanceBands: supportsResistanceBands,
                        blockNumber: myoRepNumber(upTo: index, in: sets),
                        previous: blockTemplate(for: presentation.set, index: index, in: sets),
                        showsWeight: weightHeader != nil,
                        displayUnit: displayUnit,
                        isUnilateral: exercise?.isUnilateral == true,
                        completionDate: completionDate,
                        usesSuggestedValues: usesSuggestedValues(for: presentation.set),
                        suggestedWeight: suggestedWeight(for: presentation.set, index: index),
                        suggestedReps: suggestedReps(for: presentation.set, index: index),
                        editedFields: editedSuggestionFields[presentation.set.id] ?? [],
                        onChange: { recompute(changedSet: presentation.set) },
                        onCompletionChange: { completed in
                            recompute(changedSet: presentation.set, refreshAllAwards: !completed)
                        },
                        onMaterializeSuggestion: { fields in
                            materializeSuggestion(
                                for: presentation.set,
                                index: index,
                                editedFields: fields
                            )
                        },
                        onCompleted: {
                            if allowsRestTimers { onCompletedSet(presentation.set) }
                        }
                    )
                }
            }
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
            for set in sets { set.completedAt = nil }
        } else if allowsRestTimers,
                  let myoSet = sets.first(where: { $0.setType == .myoRep && $0.completedAt == nil }) {
            collapsed = false
            presentedMyoSet = MyoRepSetPresentation(set: myoSet, mode: .active)
            return
        } else {
            if let set = sets.first(where: {
                $0.completedAt == nil && $0.requiresConcreteRepsBeforeCompletion
            }) {
                collapsed = false
                focusedInput = SetInputFocus(setID: set.id, field: .primary)
                return
            }
            let completedAt = completionDate ?? Date()
            var lastCompletedSet: SetModel?
            for (index, set) in sets.enumerated() where set.completedAt == nil {
                materializeSuggestion(for: set, index: index)
                if set.setType == .cluster {
                    set.reps = set.miniReps.reduce(0, +)
                }
                set.completedAt = completedAt
                HealthMetricsStore.shared.fillBodyweight(set)
                lastCompletedSet = set
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
                    StickyNoteView(
                        workoutExercise: workoutExercise,
                        exerciseID: workoutExercise.exerciseID,
                        pinnedNote: pinnedNote,
                        focusRequested: noteFocusRequested,
                        onFocusHandled: { noteFocusRequested = false },
                        onPinnedNoteChanged: onPinnedNoteChanged
                    )
                }

                // Also gated on the park flag so a workout started before the
                // park can't render a stale strip.
                if let progression, progressionActive, !ProgressionPlanner.isParked {
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
                        .foregroundStyle(theme.accentForeground)
                    }
                }

                columnHeader

                let sets = sortedSets

                ForEach(Array(sets.enumerated()), id: \.element.id) { index, set in
                    if set.setType == .myoRep {
                        SwipeToDeleteRow(
                            isOpen: openSwipeSetID == set.id,
                            onOpenChange: { open in
                                if open { openSwipeSetID = set.id }
                                else if openSwipeSetID == set.id { openSwipeSetID = nil }
                            },
                            onDelete: { deleteSet(set) }
                        ) {
                            let mode: MyoRepSetPresentation.Mode = set.completedAt != nil || !allowsRestTimers
                                ? .editing
                                : .active
                            MyoRepSetLauncherCard(
                                set: set,
                                workoutExercise: workoutExercise,
                                showWeight: weightHeader != nil,
                                displayUnit: displayUnit,
                                isUnilateral: exercise?.isUnilateral == true,
                                actionMode: mode,
                                onLaunch: {
                                    presentedMyoSet = MyoRepSetPresentation(set: set, mode: mode)
                                },
                                onChange: { recompute(changedSet: set) },
                                onSetType: { changeType(of: set, to: $0, index: index) },
                                onDelete: { deleteSet(set) }
                            )
                        }
                    } else if set.setType.isBlockType {
                        // Rest-pause / cluster stay inline; Myo-reps owns a
                        // dedicated continuous-focus runner above.
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
                                supportsResistanceBands: supportsResistanceBands,
                                isUnilateral: exercise?.isUnilateral == true,
                                completionDate: completionDate,
                                usesSuggestedValues: usesSuggestedValues(for: set),
                                suggestedWeight: suggestedWeight(for: set, index: index),
                                suggestedReps: suggestedReps(for: set, index: index),
                                editedFields: editedSuggestionFields[set.id] ?? [],
                                onChange: { recompute(changedSet: set) },
                                onCompletionChange: { completed in
                                    recompute(changedSet: set, refreshAllAwards: !completed)
                                },
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
                                onSetType: { changeType(of: set, to: $0, index: index) },
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
                                supportsResistanceBands: supportsResistanceBands,
                                focusedInput: $focusedInput,
                                openSwipeSetID: $openSwipeSetID,
	                            onChange: { recompute(changedSet: set) },
                                onCompletionChange: { completed in
                                    recompute(changedSet: set, refreshAllAwards: !completed)
                                },
	                            onSetType: { changeType(of: set, to: $0, index: index) },
	                            completionDate: completionDate,
                                usesSuggestedValues: usesSuggestedValues(for: set),
                                suggestedWeight: suggestedWeight(for: set, index: index),
                                repSuggestion: repSuggestion(for: set, index: index),
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
            refreshAwardsCache()
        }
        .onDisappear {
            flushPendingSave()
        }
        // The 2s save debounce must not lose edits when the app is locked or
        // backgrounded inside the window.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPendingSave() }
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
                    .minimumTouchTarget()
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
	                    ReorderHandle(
	                        onDragChanged: onReorderDragChanged,
	                        onDragEnded: onReorderDragEnded,
	                        onAccessibilityMoveBy: onAccessibilityMoveBy
	                    )
	                }
	                // ScrollSafeMenu, not Menu: this was the last SwiftUI Menu on
                // the logger scroll surface — a scroll starting on the ⋯ glyph
                // dead-stopped (same class of bug as the 2026-07-16 set-row
                // menu conversions).
                ScrollSafeMenu(sections: overflowMenuSections) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Exercise options")
                .accessibilityIdentifier("exercise-overflow-menu")
            }
        }
    }

    /// The ⋯ overflow menu, section-for-section identical to the old SwiftUI
    /// Menu (details | actions incl. superset submenu | destructive remove).
    private var overflowMenuSections: [[ScrollSafeMenuItem]] {
        var details: [ScrollSafeMenuItem] = []
        if let exercise {
            details.append(ScrollSafeMenuItem(title: "Exercise Details", systemImage: "info.circle") {
                onShowExerciseDetail(exercise)
            })
        }

        var actions: [ScrollSafeMenuItem] = []
        if workoutExercise.notes == nil {
            actions.append(ScrollSafeMenuItem(title: "Add Note", systemImage: "note.text") {
                workoutExercise.notes = ""
                workoutExercise.updatedAt = .now
                noteFocusRequested = true
                modelContext.saveUserChanges()
            })
        }
        actions.append(ScrollSafeMenuItem(title: "Add Warm-up Set", systemImage: "flame") { addSet(type: .warmup) })
        actions.append(ScrollSafeMenuItem(title: "Add Warm-up Ramp", systemImage: "flame.fill") { addWarmupRamp() })
        actions.append(contentsOf: SupersetUI.scrollSafeMenuItems(
            currentGroup: workoutExercise.supersetGroup,
            availableGroups: availableSupersetGroups,
            onAssign: onAssignSuperset,
            onCreate: onCreateSuperset,
            onUngroup: onUngroupSuperset
        ))
        actions.append(ScrollSafeMenuItem(title: "Replace Exercise", systemImage: "arrow.triangle.2.circlepath") { onReplace() })

        let destructive = [ScrollSafeMenuItem(title: "Remove Exercise", systemImage: "trash", isDestructive: true) { onRemove() }]
        return [details, actions, destructive].filter { !$0.isEmpty }
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
                            .foregroundStyle(theme.accentForeground)
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
                    .minimumTouchTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentForeground)
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

    /// Myo-reps are unnumbered in the inline working-set grid, but their
    /// dedicated runner still needs a human 1-based identity of its own.
    private func myoRepNumber(upTo index: Int, in sets: [SetModel]) -> Int {
        sets.prefix(index + 1).filter { $0.setType == .myoRep }.count
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
        // Percentage prescriptions are resolved once when this workout is
        // created. Their conservative lower bound must beat last-session
        // fallback, otherwise a stronger new e1RM would leave the row showing
        // yesterday's lighter load. A missing baseline intentionally stays
        // blank and is explained by the visible prescription strip.
        if set.loadPrescriptionMode == .percentEstimatedOneRepMax {
            return set.prescribedLoadLowKg
        }
        if progressionLeads(for: set) {
            return set.modeWeight ?? set.weight ?? previousSet(for: set, at: index).flatMap { $0.modeWeight ?? $0.weight }
        }
        return previousSet(for: set, at: index).flatMap { $0.modeWeight ?? $0.weight } ?? set.modeWeight ?? set.weight
    }

    private func suggestedReps(for set: SetModel, index: Int) -> Int? {
        repSuggestion(for: set, index: index).materializedValue
    }

    private func repSuggestion(for set: SetModel, index: Int) -> RepFieldSuggestion {
        RepSuggestionPolicy.resolve(
            set: set,
            previousReps: previousSet(for: set, at: index)?.reps,
            progressionLeads: progressionLeads(for: set),
            structuredOverride: set.setType == .myoRep
                ? myoActivationSuggestionOverrides[set.id]
                : nil
        )
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
        if set.setType == .myoRep {
            myoActivationSuggestionOverrides.removeValue(forKey: set.id)
        }
        editedSuggestionSetIDs.insert(set.id)
    }

    private func progressionStrip(_ suggestion: ProgressionSuggestionModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: progressionIcon(suggestion.kindRaw))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.accentForeground)
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
                    .minimumTouchTarget()
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

    /// Set-type-smart previous lookup: the i-th set OF A TYPE maps to the most
    /// recent history containing that type — warmups remember warmups, working
    /// sets remember working sets, and blocks remember their activation. An
    /// extra set beyond that session's count continues from the type's last
    /// set; a type with no history is an honest blank.
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
        recompute(changedSet: set)
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
        let next = displayUnit.toggled
        // Toggling back to the app-wide unit CLEARS the override — the
        // exercise resumes following Settings. A frozen stamp here is how a
        // kg lifter ends up with lb increments on one exercise after
        // changing their global unit.
        exercise.preferredWeightUnit = next == Fmt.unit ? nil : next
        exercise.updatedAt = Date()
        modelContext.saveUserChanges()
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
                reps: stage.reps
            )
            // Percentage-of-top only makes sense when a bigger number means a
            // harder set (external load, added weight). For assisted work a
            // fraction of the top ASSISTANCE would be a harder set than the
            // working one — leave those blank for the lifter to choose.
            if rampSupportsAutoWeight {
                set.setModeWeight(display.map { $0 / displayPerKilogram })
            }
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
        guard rampSupportsAutoWeight else { return }
        let warmups = sortedSets.filter { $0.setType == .warmup }
        let pending = warmups.filter { $0.modeWeight == nil }
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
            warmup.setModeWeight(display / displayPerKilogram)
            didFill = true
        }
        if didFill { recompute() }
    }

    /// Ramp percentages scale a load the lifter moves — external weight or
    /// weight added to bodyweight. Assistance scales inversely and pure
    /// bodyweight has no number to scale, so those ramps stay weight-blank.
    private var rampSupportsAutoWeight: Bool {
        weightMode == .external || weightMode == .bodyweightAdded
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
            reps: (type == .warmup || carriedType.isBlockType) ? nil : last?.reps
        )
        // Copy-forward through the mode accessor so an assisted/added set's
        // value carries into the right field, not the external `weight`.
        set.setModeWeight(last?.modeWeight)
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
            weightMode: set.weightMode,
            reps: nil
        )
        let bodyweight = set.bodyweightKg ?? HealthMetricsStore.shared.latestBodyweight
        drop.bodyweightKg = bodyweight
        drop.setModeWeight(dropPrefillWeight(from: set, index: index, bodyweightKg: bodyweight))
        modelContext.insert(drop)
        workoutExercise.sets.append(drop)
        var rows = sortedSets.filter { $0.id != drop.id }
        rows.insert(drop, at: min(index + 1, rows.count))
        for (i, s) in rows.enumerated() { s.position = i }
        recompute()
    }

    /// Use the value actually visible on the parent row. Routine-backed rows
    /// often hold an untouched target while showing a different history ghost;
    /// reading only `modeWeight` is what left the reported assisted drop blank.
    private func dropPrefillWeight(
        from set: SetModel,
        index: Int,
        bodyweightKg: Double?
    ) -> Double? {
        DropSetLoadPolicy.suggestedModeWeight(
            sourceWeightKg: visibleModeWeight(for: set, index: index),
            mode: set.weightMode,
            bodyweightKg: bodyweightKg,
            displayUnit: displayUnit
        )
    }

    private func visibleModeWeight(for set: SetModel, index: Int) -> Double? {
        let showsSuggestion = usesSuggestedValues(for: set)
            && !(editedSuggestionFields[set.id] ?? []).contains(.weight)
        return DropSetLoadPolicy.visibleSourceWeight(
            enteredWeightKg: set.modeWeight,
            suggestedWeightKg: suggestedWeight(for: set, index: index),
            isShowingSuggestion: showsSuggestion
        )
    }

    private func changeType(of set: SetModel, to type: SetType, index: Int) {
        let oldType = set.setType
        let editedFields = editedSuggestionFields[set.id] ?? []
        let suggestionBacked = suggestionBacked(for: set)
        let preservesEnteredWeight = set.modeWeight != nil
            && (!suggestionBacked || editedFields.contains(.weight))
        let preservesEnteredReps = set.reps != nil
            && (!suggestionBacked || editedFields.contains(.primary))
        let visibleWeight = preservesEnteredWeight
            ? set.modeWeight
            : suggestedWeight(for: set, index: index)
        let visibleReps = preservesEnteredReps
            ? set.reps
            : suggestedReps(for: set, index: index)
        let previousBlock = type.isBlockType
            ? blockTemplate(for: type, index: index, in: sortedSets)
            : nil

        // Converting a row into a drop uses the row above's visible load and
        // the same mode-aware direction as "Add Drop Set Below". Preserve a
        // genuinely hand-entered load; hidden routine backing values are not
        // explicit edits and must not beat the ghost the user can see.
        if type == .drop, index > 0 {
            let above = sortedSets[index - 1]
            let aboveVisible = visibleModeWeight(for: above, index: index - 1)
            let currentMatchesAbove = set.modeWeight.flatMap { current in
                aboveVisible.map { abs(current - $0) < 0.0001 }
            } ?? false
            if !preservesEnteredWeight || currentMatchesAbove {
                let bodyweight = above.bodyweightKg ?? HealthMetricsStore.shared.latestBodyweight
                set.bodyweightKg = set.bodyweightKg ?? bodyweight
                set.setModeWeight(DropSetLoadPolicy.suggestedModeWeight(
                    sourceWeightKg: aboveVisible,
                    mode: above.weightMode,
                    bodyweightKg: bodyweight,
                    displayUnit: displayUnit
                ))
            }
        }
        set.setType = type
        if type.isBlockType {
            BlockSetPrefillPolicy.apply(
                to: set,
                visibleWeight: visibleWeight,
                visibleReps: visibleReps,
                previousBlock: previousBlock,
                preservesEnteredWeight: preservesEnteredWeight,
                preservesEnteredReps: preservesEnteredReps
            )
        }
        if type == .myoRep, oldType != .myoRep {
            // Prefill policy resolves the correct activation suggestion (same
            // type history, then the row's visible value). Move that value out
            // of the performed field until the lifter explicitly logs it.
            myoActivationSuggestionOverrides[set.id] = set.reps
            set.reps = nil
            set.side2Reps = nil
            set.miniReps = []
            set.side2MiniReps = []
        } else if type != .myoRep {
            myoActivationSuggestionOverrides.removeValue(forKey: set.id)
        }
        recompute(changedSet: set)
    }

    /// Template for a block's activation: the previous block of the same type
    /// in this session, then the same ordinal from its most recent history.
    private func blockTemplate(for set: SetModel, index: Int, in sets: [SetModel]) -> SetModel? {
        blockTemplate(for: set.setType, index: index, in: sets)
    }

    private func blockTemplate(for type: SetType, index: Int, in sets: [SetModel]) -> SetModel? {
        if let prior = sets.prefix(index).last(where: {
            $0.setType == type
                && ($0.modeWeight != nil || $0.reps != nil || !$0.miniReps.isEmpty)
        }) {
            return prior
        }
        let ordinal = sets.prefix(index).count { $0.setType == type }
        let sameType = previousSets.filter { $0.setType == type }
        guard !sameType.isEmpty else { return nil }
        return ordinal < sameType.count ? sameType[ordinal] : sameType.last
    }

    private func deleteSet(_ set: SetModel) {
        if openSwipeSetID == set.id { openSwipeSetID = nil }
        workoutExercise.sets.removeAll { $0.id == set.id }
        modelContext.delete(set)
        for (i, s) in sortedSets.enumerated() { s.position = i }
        recompute()
    }

    private func recompute(changedSet: SetModel? = nil, refreshAllAwards: Bool = true) {
        workoutExercise.updatedAt = Date()
        if let changedSet {
            LiveWorkoutMetrics.refresh(changedSet: changedSet, in: workout)
        } else {
            workout.recomputeTotalVolume()
        }
        if refreshAllAwards || changedSet == nil {
            refreshAwardsCache()
        } else if let changedSet {
            let awards = PersonalRecords.awards(
                for: changedSet,
                baseline: recordBaseline,
                sessionSets: sessionSetsForExercise
            )
            if awardsCache[changedSet.id] != awards {
                awardsCache[changedSet.id] = awards
            }
        }
        onLiveStatsChanged()
        scheduleSave()
    }

    private func scheduleSave() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            // 2s, not 350ms: a save triggers ContentView's all-workouts @Query
            // re-fetch (O(total history) on the main thread), and at +350ms it
            // landed exactly when the lifter's thumb came down to scroll after
            // logging — eating the first pan gesture. 2s parks it in idle time.
            // Durability is unchanged: card-exit, app-background, minimize, and
            // finish all flush pending edits immediately (see onDisappear /
            // scenePhase below; WorkoutFinisher saves on its own).
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveNow()
            deferredSaveTask = nil
        }
    }

    /// Flush a pending debounced save right now; no-op when nothing is queued
    /// (so card recycling during a plain scroll never triggers save/publish).
    private func flushPendingSave() {
        guard deferredSaveTask != nil else { return }
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        saveNow()
    }

    private func saveNow() {
        modelContext.saveUserChanges { onWorkoutChanged() }
    }

    private var supportsResistanceBands: Bool {
        ResistanceBandSupport.isBandExercise(
            name: exercise?.name,
            equipment: exercise?.equipment
        )
    }
}

// MARK: - Swipe-to-delete

// SwipeToDeleteRow moved to Workout/SwipeToDeleteRow.swift — shared with the
// routine editor so set deletion feels identical when planning and performing.

// MARK: - Single set row

// SetModel.modeWeight / setModeWeight moved to ForgeData (Models.swift) so the
// watch sync layer and backfills route weight through the same per-mode field
// as the logger.

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
    let supportsResistanceBands: Bool
    let focusedInput: FocusState<SetInputFocus?>.Binding
    /// The set whose swipe-to-delete tray is open, shared across sibling rows so
    /// only one opens at a time.
    @Binding var openSwipeSetID: UUID?
    let onChange: () -> Void
    var onCompletionChange: (Bool) -> Void = { _ in }
    let onSetType: (SetType) -> Void
    var completionDate: Date? = nil
    var usesSuggestedValues: Bool = false
    var suggestedWeight: Double?
    var repSuggestion = RepFieldSuggestion(
        materializedValue: nil,
        placeholder: "—",
        quickAdjustmentBase: nil
    )
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
        supportsResistanceBands: Bool,
        focusedInput: FocusState<SetInputFocus?>.Binding,
        openSwipeSetID: Binding<UUID?>,
        onChange: @escaping () -> Void,
        onCompletionChange: @escaping (Bool) -> Void = { _ in },
        onSetType: @escaping (SetType) -> Void,
        completionDate: Date? = nil,
        usesSuggestedValues: Bool = false,
        suggestedWeight: Double? = nil,
        repSuggestion: RepFieldSuggestion = RepFieldSuggestion(
            materializedValue: nil,
            placeholder: "—",
            quickAdjustmentBase: nil
        ),
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
        self.supportsResistanceBands = supportsResistanceBands
        self.focusedInput = focusedInput
        self._openSwipeSetID = openSwipeSetID
        self.onChange = onChange
        self.onCompletionChange = onCompletionChange
        self.onSetType = onSetType
        self.completionDate = completionDate
        self.usesSuggestedValues = usesSuggestedValues
        self.suggestedWeight = suggestedWeight
        self.repSuggestion = repSuggestion
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

    private var style: SetTypeStyle { SetTypeStyle.of(self.set.setType, theme: theme) }
    private var isDone: Bool { self.set.completedAt != nil }
    private var isDrop: Bool { self.set.setType == .drop }
    private var suggestedWeightText: String {
        suggestedWeight.map { Fmt.load($0, unit: displayUnit) } ?? "—"
    }
    private var suggestedRepsText: String {
        repSuggestion.placeholder
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
                LiveLoadPrescriptionStrip(set: set, unit: displayUnit)
                    .padding(.top, set.loadPrescriptionMode == .fixed ? 0 : 4)
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
            .animation(.snappy(duration: 0.2), value: isDone)
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
                Button {
                    RestTimerController.shared.skip()
                } label: {
                    Text("Stop")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(style.color)
                        .minimumTouchTarget()
                }
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
                    let persistElapsedDuration = onChange
                    set.durationSeconds = seconds
                    RestTimerController.shared.start(
                        seconds: seconds,
                        label: "AMRAP",
                        ownerID: set.id,
                        soundOnEnd: true,
                        endNotification: (title: "Time's up", body: "Log the reps you got."),
                        onComplete: { [set] ranSeconds in
                            // Stopping early counts the window actually used.
                            set.durationSeconds = ranSeconds
                            persistElapsedDuration()
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
            .accessibilityLabel(isDone ? "Mark set incomplete" : "Mark set complete")
            .accessibilityHint(set.requiresConcreteRepsBeforeCompletion ? "Enter completed reps first" : "")
            .accessibilityIdentifier("complete-set-\(workingNumber)")

            // Drop sets cascade: indent under the parent set like a ladder.
            if isDrop {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(style.color.opacity(0.7))
                    .frame(width: 16)
            }
            ScrollSafeMenu(sections: setTypeMenuSections) {
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
                    .minimumTouchTarget()
            }
            .buttonStyle(.plain)
            .disabled(previousSet == nil)
            .accessibilityHint(previousSet == nil ? "" : "Copies your previous set into this one")

            if showWeight {
                numberField(text: Binding(
                    get: { weightDraft },
                    set: { editDraft(.weight, value: $0) }
                ), placeholder: suggestedWeightText, width: grid.weight, field: .weight)
                .quickIncrementable(
                    options: QuickIncrementController.weightOptions(unit: displayUnit),
                    onBegin: { clearFocus() },
                    base: quickWeightBase,
                    apply: applyQuickWeight
                )
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
                .quickIncrementable(
                    options: QuickIncrementController.repsOptions(),
                    onBegin: { clearFocus() },
                    base: quickRepsBase,
                    apply: applyQuickReps
                )
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
        if isShowingSuggestion(for: .weight) { return "" }
        return set.modeWeight.map { Fmt.load($0, unit: displayUnit) } ?? ""
    }

    private var primaryText: String {
        if isShowingSuggestion(for: .primary) { return "" }
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
            guard completeSet() else { return }
        } else {
            commitFocusedDraft()
        }
        onAdvancePastLastField()
    }

    private func toggleCompletion() {
        if isDone {
            commitFocusedDraft()
            set.completedAt = nil
            onCompletionChange(false)
        } else {
            // The checkmark ends editing for this set. Clearing focus before
            // materialization lets every committed ghost refresh its draft,
            // including the field that had the keyboard open.
            clearFocus()
            _ = completeSet()
        }
    }

    @discardableResult
    private func completeSet() -> Bool {
        // A completion tap can clear focus before SwiftUI delivers the focus
        // change callback. Commit every locally edited draft, not just the
        // field that still appears focused in this exact frame.
        commitAllEditedDrafts()
        guard !set.requiresConcreteRepsBeforeCompletion else {
            focus(.primary)
            return false
        }
        onMaterializeSuggestion(effectiveEditedSuggestionFields)
        LiveSetCompletion.prepare(
            set,
            completedAt: completionDate ?? Date(),
            latestBodyweight: HealthMetricsStore.shared.latestBodyweight
        )
        completionHapticTrigger += 1
        onCompletionChange(true)
        onCompleted()
        return true
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

    private func isShowingSuggestion(for field: SetInputField) -> Bool {
        usesSuggestedValues && !effectiveEditedSuggestionFields.contains(field)
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

    // MARK: - Quick increment (hold-drag fan)

    /// The value the fan increments from is exactly what the lifter can see.
    /// A routine-backed set can contain one stored load while showing a
    /// different previous-session ghost; the hidden stored load must not win.
    private func quickWeightBase() -> Double? {
        let draft = Fmt.loadKilograms(from: weightDraft, unit: displayUnit)
            .map(displayUnit.displayValue(fromKilograms:))
        let entered = set.modeWeight.map(displayUnit.displayValue(fromKilograms:))
        let suggested = (suggestedWeight ?? previousSet?.modeWeight)
            .map(displayUnit.displayValue(fromKilograms:))
        let resolved = QuickIncrementController.displayedBase(
            draftValue: draft,
            isDraftEdited: editedDraftFields.contains(.weight),
            enteredValue: entered,
            suggestedValue: suggested,
            isShowingSuggestion: isShowingSuggestion(for: .weight)
        )
        return resolved ?? (editedDraftFields.contains(.weight) ? nil : 0)
    }

    /// Routes through the same draft/commit path as typing, so ghost
    /// suggestions materialize as entered values.
    private func applyQuickWeight(_ newDisplay: Double) {
        let kilograms = displayUnit.kilograms(fromDisplayValue: newDisplay)
        editDraft(.weight, value: Fmt.load(kilograms, unit: displayUnit))
        commitDraft(for: .weight)
    }

    private func quickRepsBase() -> Double? {
        let resolved = QuickIncrementController.displayedBase(
            draftValue: Int(primaryDraft).map(Double.init),
            isDraftEdited: editedDraftFields.contains(.primary),
            enteredValue: set.reps.map(Double.init),
            suggestedValue: (repSuggestion.quickAdjustmentBase ?? previousSet?.reps).map(Double.init),
            isShowingSuggestion: isShowingSuggestion(for: .primary)
        )
        return resolved ?? (editedDraftFields.contains(.primary) ? nil : 0)
    }

    private func applyQuickReps(_ newValue: Double) {
        editDraft(.primary, value: String(Int(newValue.rounded())))
        commitDraft(for: .primary)
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

        return ZStack(alignment: .leading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    // Ghost suggestions ("135 lb") shrink before clipping at
                    // large Dynamic Type sizes.
                    .minimumScaleFactor(0.8)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity)
            }

            if field == .weight, supportsResistanceBands {
                ResistanceBandLoadMenu(
                    selectedWeightKilograms: effectiveBandWeight,
                    unit: displayUnit,
                    onSelect: applyBandWeight
                )
                .zIndex(1)
            }

            TextField("", text: text)
                .keyboardType(keyboardType)
                .submitLabel(submitLabel(for: field))
                .focused(focusedInput, equals: SetInputFocus(setID: set.id, field: field))
                .multilineTextAlignment(.center)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .textFieldStyle(.plain)
                .padding(.leading, field == .weight && supportsResistanceBands ? 22 : 0)
                .accessibilityLabel(label)
                .accessibilityValue(accessibilityValue(
                    for: field,
                    text: text.wrappedValue,
                    placeholder: placeholder
                ))
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

    private var effectiveBandWeight: Double? {
        isShowingSuggestion(for: .weight) ? suggestedWeight : set.modeWeight
    }

    private func applyBandWeight(_ kilograms: Double) {
        clearFocus()
        weightDraft = Fmt.load(kilograms, unit: displayUnit)
        editedDraftFields.insert(.weight)
        set.setModeWeight(kilograms)
        if usesSuggestedValues {
            suggestionFieldOverrides[.weight] = true
            onSuggestionFieldEdited(.weight, true)
        }
        onChange()
    }

    private func rpePickerField(width: CGFloat) -> some View {
        ScrollSafeMenu(sections: rpeMenuSections) {
            Text(rpeDisplay)
                .font(.bodyStrong)
                .foregroundStyle(effectiveRPE == nil ? theme.textTertiary : theme.textPrimary)
                .frame(width: width, height: grid.fieldHeight)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .accessibilityLabel(effortScale.columnTitle)
        .accessibilityValue(rpeDisplay)
        .accessibilityIdentifier("effort-set-\(workingNumber)")
    }

    private var rpeMenuSections: [[ScrollSafeMenuItem]] {
        var sections = [RPEQuickPick.allOptions.map { option in
            ScrollSafeMenuItem(title: rpeOptionLabel(option), isChecked: rpeOptionIsSelected(option)) {
                setRPE(option.rpeValue)
            }
        }]
        if effectiveRPE != nil {
            sections.append([ScrollSafeMenuItem(
                title: "Clear \(effortScale.columnTitle)", isDestructive: true, action: clearRPE)])
        }
        return sections
    }

    private var setTypeMenuSections: [[ScrollSafeMenuItem]] {
        var actions = [ScrollSafeMenuItem(
            title: "Add Drop Set Below", systemImage: "arrow.down.right", action: onAddDrop)]
        if let onPlates {
            actions.append(ScrollSafeMenuItem(
                title: "Plate Calculator", systemImage: "circle.circle", action: onPlates))
        }
        return [
            SetType.selectable.map { type in
                ScrollSafeMenuItem(title: SetTypeStyle.of(type).label, isChecked: set.setType == type) {
                    onSetType(type)
                }
            },
            actions,
            [ScrollSafeMenuItem(title: "Delete Set", systemImage: "trash", isDestructive: true, action: onDelete)],
        ]
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

    private func accessibilityValue(
        for field: SetInputField,
        text: String,
        placeholder: String
    ) -> String {
        guard text.isEmpty else { return text }
        if field == .primary,
           !isCardio,
           set.loadPrescriptionMode == .percentEstimatedOneRepMax,
           !set.setType.isBlockType,
           set.setType != .amrap,
           let target = set.prescribedRepTarget {
            return "Planned \(target.displayText), not entered"
        }
        return placeholder == "—" ? "Empty" : "Suggested \(placeholder), not entered"
    }

}
