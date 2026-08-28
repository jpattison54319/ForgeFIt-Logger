import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

@MainActor
struct RoutineEditorReferenceLookup {
    let exerciseByID: [UUID: ExerciseLibraryModel]
    let setupNoteByExerciseID: [UUID: UserExerciseNoteModel]

    static func revision(
        exercises: [ExerciseLibraryModel],
        setupNotes: [UserExerciseNoteModel]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(exercises.count)
        for exercise in exercises {
            hasher.combine(exercise.id)
            hasher.combine(exercise.updatedAt)
            hasher.combine(exercise.deletedAt)
        }
        hasher.combine(setupNotes.count)
        for note in setupNotes {
            hasher.combine(note.id)
            hasher.combine(note.userID)
            hasher.combine(note.exerciseID)
            hasher.combine(note.note)
            hasher.combine(note.updatedAt)
        }
        return hasher.finalize()
    }

    static func make(
        exercises: [ExerciseLibraryModel],
        setupNotes: [UserExerciseNoteModel]
    ) -> Self {
        let exerciseByID = Dictionary(
            exercises.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var noteByExerciseID: [UUID: UserExerciseNoteModel] = [:]
        for note in setupNotes
        where note.userID == ForgeFitDemo.userID
            && ExerciseNotePolicy.authoredText(note.note) != nil {
            if let current = noteByExerciseID[note.exerciseID], current.updatedAt >= note.updatedAt {
                continue
            }
            noteByExerciseID[note.exerciseID] = note
        }
        return Self(
            exerciseByID: exerciseByID,
            setupNoteByExerciseID: noteByExerciseID
        )
    }
}

/// Editing surface for a routine: rename, add/remove exercises, and tune target
/// sets. Kept dark and card-based to match the rest of the app.
struct RoutineEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppState.self) private var appState
    @Bindable var routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    /// Parent-owned history is already fetched for the screen that opens this
    /// editor. Snapshot it once instead of issuing another synchronous
    /// SwiftData fetch underneath the editor's first interaction.
    var history: [WorkoutModel] = []
    /// True when this routine is a just-inserted placeholder (insert-then-edit
    /// keeps the picker's eager saves working). Backing out of a new routine
    /// deletes the placeholder instead of leaving "New Routine" in the library.
    var isNew: Bool = false
    /// Creation surfaces may have attached local presentation state (for
    /// example Home's Quick Start tile). Clean it up only after the new
    /// routine's tombstone commits successfully.
    var onNewRoutineDiscarded: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var editBlock: RoutineBlockModel?
    @State private var entrySnapshot: RoutineSnapshot?
    @State private var showDiscardConfirm = false
    @State private var showInvalidDraftAlert = false
    @State private var replaceTarget: RoutineExerciseModel?
    @State private var detailExerciseID: UUID?
    /// Reference-backed so per-frame finger updates invalidate only the small
    /// reorder overlay, not every editor row and target field.
    @State private var reorderSession: ExerciseReorderSession?
    @State private var keyboardVisible = false
    /// Screen-owned structural-save plumbing — see `save()`.
    @State private var saveCoordinator = DeferredSaveCoordinator()
    /// Child fields keep raw keyboard text here until blur or a durability
    /// boundary. This prevents every digit from mutating a SwiftData model and
    /// invalidating the routine graph while still guaranteeing synchronous
    /// commit before dismissal, backgrounding, or an explicit save.
    @State private var pendingDrafts = PendingDraftCoordinator()
    @State private var referenceLookupMemo = Memo<Int, RoutineEditorReferenceLookup>()
    /// Completed history is immutable for the lifetime of a routine-editing
    /// session. A one-time snapshot prevents every editor save from
    /// republishing a root `@Query` and rebuilding history-derived inputs.
    @State private var historySnapshot: [WorkoutModel] = []
    @State private var bestEstimatedOneRepMaxByExercise: [UUID: Double] = [:]

    private var sortedExercises: [RoutineExerciseModel] { routine.exercises.sorted { $0.position < $1.position } }
    private var orderedItems: [OrderedRoutineItem] { OrderedRoutineItem.ordered(in: routine) }
    private var supersetGroups: [Int] {
        Array(Set(routine.exercises.compactMap(\.supersetGroup))).sorted()
    }
    private var referenceLookup: RoutineEditorReferenceLookup {
        referenceLookupMemo(
            RoutineEditorReferenceLookup.revision(
                exercises: exercises,
                setupNotes: setupNotes
            )
        ) {
            RoutineEditorReferenceLookup.make(
                exercises: exercises,
                setupNotes: setupNotes
            )
        }
    }
    /// Library entries for the routine's current exercises — the picker's
    /// suggestion context (lots of chest work → chest & push suggested first).
    private var exercisesInRoutine: [ExerciseLibraryModel] {
        let exerciseByID = referenceLookup.exerciseByID
        return routine.exercises.compactMap { exerciseByID[$0.exerciseID] }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Always mounted, even while the reorder overlay covers it: the
            // hold-to-reorder gesture starts on a row handle inside this
            // scroll — removing the view mid-gesture would cancel the touch
            // and kill the drag right as it began.
            mainScroll
                .accessibilityHidden(reorderSession != nil)
            if reorderSession != nil {
                reorderOverlay
                    .transition(.opacity)
                    .zIndex(1)
                    .allowsHitTesting(false)
            }
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
                // The scroll used to own the header, so it disappeared from
                // interaction and accessibility with the reorder overlay.
                // Preserve that contract now that the header is persistent.
                .allowsHitTesting(reorderSession == nil)
                .accessibilityHidden(reorderSession != nil)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if keyboardVisible {
                KeyboardAccessoryBar {
                    Spacer()
                    Button("Done") { hideKeyboard() }
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accentForeground)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
            }
        }
        .onKeyboardVisibilityChange($keyboardVisible)
        // This screen owns drafts that can deliberately remain invalid while
        // the user corrects them. A direct interactive pop would bypass
        // `requestDismiss()` and silently throw that text away, so dismissal
        // stays on the visible, validation-aware Back action.
        .onAppear {
            if entrySnapshot == nil {
                if RoutineLegacyBlockMigration.migrateIfNeeded(
                    routine: routine,
                    exercises: exercises,
                    in: modelContext
                ) {
                    save()
                }
                entrySnapshot = RoutineSnapshot(of: routine)
            }
        }
        .task(id: routine.id) {
            await refreshHistoryContext()
        }
        .onChange(of: appState.showingLogger) { wasPresented, isPresented in
            // The estimated-1RM assessment is presented over this still-live
            // editor. Its routine ID does not change, so refresh explicitly
            // when that logger closes instead of leaving the new baseline
            // stale until the editor is reopened.
            guard wasPresented, !isPresented else { return }
            Task { await refreshHistoryContext() }
        }
        .onDisappear {
            flushPendingSave()
            pendingDrafts.clearAll()
        }
        // The 2s save debounce must not lose edits when the app is locked or
        // backgrounded mid-edit.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPendingSave() }
        }
        .confirmationDialog("Keep this new routine?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Keep Routine") {
                saveNow(showValidationError: true, onCommit: dismiss.callAsFunction)
            }
            Button("Discard New Routine", role: .destructive) {
                // A queued debounced save must not fire after the restore and
                // revive the new routine after its tombstone commits.
                saveCoordinator.cancel()
                discardNewRoutine()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits are saved automatically. Discarding removes the new routine.")
        }
        .alert("Check Routine Values", isPresented: $showInvalidDraftAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enter an estimated 1RM percentage from 1 to 100, or a valid range such as 67–72, before leaving this routine.")
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerView(
                excludeYoga: true,
                showsWorkoutBlocks: true,
                context: exercisesInRoutine,
                history: historySnapshot,
                navigationTitle: "Add to Routine",
                onAddConditioningBlock: { addBlock(kind: .conditioning, planJSON: $0) },
                onAddYogaBlock: { addBlock(kind: .yoga, planJSON: $0) }
            ) { added in add(added) }
        }
        .sheet(item: $editBlock) { block in
            if block.kind == .conditioning {
                ConditioningBlockBuilderView(
                    planJSON: block.planJSON,
                    exercises: exercises,
                    workouts: historySnapshot,
                    commit: { update(block, planJSON: $0) }
                )
            } else {
                YogaFlowBuilderView(planJSON: block.planJSON, commit: { json in
                    guard let json else { return false }
                    return update(block, planJSON: json)
                })
            }
        }
        .sheet(item: $replaceTarget) { target in
            // Gym swap: lead with close substitutes for the exercise being
            // replaced; search stays one tap away inside the sheet.
            if let currentExercise = referenceLookup.exerciseByID[target.exerciseID] {
                ExerciseSwapSheet(
                    current: currentExercise,
                    allExercises: exercises.filter { !$0.isYoga },
                    inUseIDs: Set(routine.exercises.map(\.exerciseID)),
                    history: historySnapshot
                ) { picked in
                    replace(target, with: picked)
                }
            } else {
                ExercisePickerView(
                    singleSelection: true,
                    excludeYoga: true,
                    context: exercisesInRoutine,
                    history: historySnapshot,
                    navigationTitle: "Replace Exercise",
                    excludedIDs: Set(routine.exercises.map(\.exerciseID))
                ) { picked in
                    if let first = picked.first { replace(target, with: first) }
                }
            }
        }
        // Binding-based push, deliberately NOT NavigationLink(value:): the
        // editor is itself presented via navigationDestination(isPresented:/
        // item:), and a value push from inside a binding-presented view lands
        // in the stack's path BENEATH it — the detail view opened under the
        // editor. A chained binding-based destination stacks on top.
        .navigationDestination(item: $detailExerciseID) { exerciseID in
            ExerciseDetailView(exerciseID: exerciseID, workouts: historySnapshot, exercises: exercises)
        }
    }

    private var mainScroll: some View {
        let referenceLookup = self.referenceLookup
        let orderedItems = self.orderedItems
        let supersetGroups = self.supersetGroups
        return ScrollView(showsIndicators: false) {
            // Lazy, matching the live logger: a plain VStack used to build
            // every ExerciseEditRow up front regardless of scroll position,
            // so any edit anywhere in the routine (add set, type a target,
            // toggle a superset) re-diffed the entire off-screen list too.
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                RoutineMetadataEditorCard(
                    routine: routine,
                    pendingDrafts: pendingDrafts,
                    onChange: save
                )

                SectionHeader("Workout")

                ForEach(orderedItems) { item in
                    switch item {
                    case .exercise(let re):
                        ExerciseEditRow(
                            routineExercise: re,
                            exercise: referenceLookup.exerciseByID[re.exerciseID],
                            setupNote: referenceLookup.setupNoteByExerciseID[re.exerciseID],
                            pendingDrafts: pendingDrafts,
                            bestEstimatedOneRepMaxKg: bestEstimatedOneRepMaxByExercise[re.exerciseID],
                            availableSupersetGroups: supersetGroups,
                            onShowDetail: { detailExerciseID = $0 },
                            onAssignSuperset: { assignSuperset($0, to: re) },
                            onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: re) },
                            onUngroupSuperset: { ungroupSuperset($0) },
                            onReplace: { replaceTarget = re },
                            onRemove: { remove(re) },
                            onSave: save,
                            onCreateEstimatedOneRepMax: {
                                startEstimatedOneRepMaxAssessment(for: re.exerciseID)
                            },
                            onReorderDragChanged: { fingerY in
                                reorderDragChanged(id: re.id, fingerY: fingerY)
                            },
                            onReorderDragEnded: { reorderDragEnded() },
                            onAccessibilityMoveBy: { offset in accessibilityMoveItem(re.id, by: offset) }
                        )
                    case .block(let block):
                        RoutineBlockCard(
                            block: block,
                            onEdit: { editBlock = block },
                            onRemove: { remove(block) },
                            onReorderDragChanged: { fingerY in
                                reorderDragChanged(id: block.id, fingerY: fingerY)
                            },
                            onReorderDragEnded: reorderDragEnded,
                            onAccessibilityMoveBy: { offset in accessibilityMoveItem(block.id, by: offset) }
                        )
                    }
                }

                SecondaryButton(title: "Add to Routine", systemImage: "plus") { showPicker = true }
                    .accessibilityIdentifier("add-to-routine")
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
            // Keep the last fields scrollable above the number pad without
            // padding — and therefore shrinking — the ScrollView itself.
            .keyboardAdaptiveBottomInset()
        }
        .accessibilityIdentifier("routine-editor-scroll")
        .background(theme.background)
        // The target fields use number pads (no return key) — without
        // these there was no way to dismiss the keyboard at all.
        .scrollDismissesKeyboard(.interactively)
        .onScrollPhaseChange { _, phase in
            if phase == .idle {
                saveCoordinator.resume()
            } else {
                saveCoordinator.pause()
            }
        }
    }

    private func startEstimatedOneRepMaxAssessment(for exerciseID: UUID) {
        guard let exercise = referenceLookup.exerciseByID[exerciseID],
              AdaptiveLoadResolver.supportsPercentagePrescription(exercise) else { return }
        // The assessment does not depend on the routine, but save the visible
        // authoring state before leaving this editor so returning can never
        // reveal older targets.
        guard saveNow(showValidationError: true) else { return }
        appState.requestStart {
            _ = WorkoutFactory.startEstimatedOneRepMaxAssessment(
                exercise: exercise,
                in: modelContext,
                onCommit: { _ in appState.showingLogger = true }
            )
        }
    }

    private func refreshHistoryContext() async {
        // Present/restore the editor first. The history models are a stable
        // session snapshot for pickers; the nested e1RM scan runs separately
        // in a detached context and returns only value data.
        await Task.yield()
        let container = modelContext.container
        async let baselineResult = AdaptiveLoadBaselineWorker(
            modelContainer: container
        ).calculate()
        guard !Task.isCancelled else { return }
        if historySnapshot.isEmpty {
            historySnapshot = history
                .filter { $0.endedAt != nil && $0.deletedAt == nil }
                .sorted { $0.startedAt > $1.startedAt }
        }
        let baselines = try? await baselineResult
        guard !Task.isCancelled else { return }
        bestEstimatedOneRepMaxByExercise = baselines ?? [:]
    }

    /// One continuous gesture from a row's reorder handle. UIKit calls this
    /// once when the stationary hold recognizes, then again for movement.
    private func reorderDragChanged(id: UUID, fingerY: CGFloat) {
        if let reorderSession {
            guard reorderSession.heldID == id else { return }
            reorderSession.fingerGlobalY = fingerY
            return
        }

        hideKeyboard()
        let exerciseNames = referenceLookup.exerciseByID.mapValues(\.name)
        let rows = orderedItems.map { item -> ReorderCollapseOverlay.Row in
            switch item {
            case .exercise(let exercise):
                ReorderCollapseOverlay.Row(
                    id: exercise.id,
                    name: exerciseNames[exercise.exerciseID] ?? "Exercise"
                )
            case .block(let block):
                ReorderCollapseOverlay.Row(id: block.id, name: block.kind.title)
            }
        }
        withAnimation(.snappy(duration: 0.2)) {
            reorderSession = ExerciseReorderSession(
                heldID: id,
                fingerGlobalY: fingerY,
                rows: rows
            )
        }
    }

    private func reorderDragEnded() {
        guard let reorderSession else { return }
        if reorderSession.didMove {
            let exercisesByID = Dictionary(uniqueKeysWithValues: routine.exercises.map { ($0.id, $0) })
            let blocksByID = Dictionary(uniqueKeysWithValues: routine.blocks.map { ($0.id, $0) })
            for (index, row) in reorderSession.rows.enumerated() {
                if let exercise = exercisesByID[row.id] { exercise.position = index }
                if let block = blocksByID[row.id] { block.position = index }
            }
            save()
        }
        withAnimation(.snappy(duration: 0.25)) { self.reorderSession = nil }
    }

    private var header: some View {
        GlassEffectContainer(spacing: Space.sm) {
            ZStack {
                HStack(spacing: Space.sm) {
                    CircleIconButton(
                        systemImage: "chevron.left",
                        label: "Back",
                        action: requestDismiss
                    )
                    .accessibilityIdentifier("routine-editor-back-button")

                    Spacer()

                    Button("Save", action: saveAndDismiss)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accentForeground)
                        .buttonStyle(.glass)
                        .tint(theme.accent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .minimumTouchTarget()
                        .accessibilityIdentifier("routine-editor-save-button")
                }

                Text("Edit Routine")
                    .font(.rowValue)
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, 6)
        .padding(.bottom, Space.sm)
    }

    /// Existing routines autosave, so Back commits and leaves. Offering to
    /// restore the editor-entry snapshot here was unsafe: the debounce and
    /// child editors may already have durably saved those changes, turning
    /// "Discard" into a rollback of previously committed routine data.
    private func requestDismiss() {
        // A focused set/note field may still exist only as a local draft. The
        // snapshot decision must see it; otherwise Back can misclassify an
        // authored new routine as the untouched placeholder and delete it.
        guard pendingDrafts.commitAll() else {
            showInvalidDraftAlert = true
            return
        }
        if isNew,
           let entrySnapshot,
           entrySnapshot != RoutineSnapshot(of: routine) {
            showDiscardConfirm = true
        } else if isNew {
            // Untouched placeholder — silently clean it up.
            discardNewRoutine()
        } else {
            saveNow(onCommit: dismiss.callAsFunction)
        }
    }

    private func saveAndDismiss() {
        saveNow(showValidationError: true, onCommit: dismiss.callAsFunction)
    }

    /// The collapse overlay (see `ReorderCollapseOverlay`): every exercise as
    /// a name-only row gathered around the finger, the held one scaled under
    /// it, hovered rows dimmed, order snapping live — identical to the
    /// live logger's.
    @ViewBuilder
    private var reorderOverlay: some View {
        if let reorderSession {
            ReorderCollapseOverlay(session: reorderSession)
                .accessibilityIdentifier("routine-editor-reorder-overlay")
        }
    }

    /// VoiceOver fallback for the drag: step an exercise or block one slot.
    private func accessibilityMoveItem(_ id: UUID, by offset: Int) {
        var rows = orderedItems
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(rows.count - 1, index + offset))
        guard target != index else { return }
        rows.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        for (i, row) in rows.enumerated() { row.position = i }
        save()
    }

    /// Swap the exercise keeping the set SCHEME (count, types, rep ranges) but
    /// never the numbers: target weight/RPE belong to the exercise they were
    /// programmed for, so they clear on swap and the runner re-sources from
    /// the replacement's own history (blank for a brand-new exercise).
    /// Cardio/strength swaps reset to a fresh default set — duration and
    /// rep-based targets don't translate.
    private func replace(_ target: RoutineExerciseModel, with exercise: ExerciseLibraryModel) {
        let replacedExerciseID = target.exerciseID
        let previous = referenceLookup.exerciseByID[target.exerciseID]
        let wasModality = previous?.modality ?? (target.yogaFlowJSON != nil ? .yoga : .strength)
        let replacement = exercise.isYoga ? YogaPoseCatalog.sessionExercise(in: modelContext) : exercise
        target.exerciseID = replacement.id
        target.updatedAt = Date()
        if exercise.isYoga {
            target.sets.forEach(modelContext.delete)
            target.sets = []
            target.intervalPlanJSON = nil
            let selectedPosePlan = YogaFlowPlan.fromSelectedPoses([exercise])
            if let selectedPosePlan {
                target.yogaFlowJSON = selectedPosePlan.encodedJSON()
            } else if wasModality != .yoga {
                target.yogaFlowJSON = nil
            }
        } else if exercise.modality != wasModality {
            // Targets don't carry across disciplines: rep sets, duration
            // targets, interval plans, and yoga flows are all shaped by the
            // modality they were built for.
            target.sets.forEach(modelContext.delete)
            target.sets = defaultTargetSets(for: exercise)
            target.intervalPlanJSON = nil
            target.yogaFlowJSON = nil
        } else {
            // Same modality: keep the scheme, drop the old exercise's numbers.
            for set in target.sets {
                set.targetWeight = nil
                set.targetRPE = nil
            }
        }
        if var plan = ConditioningPlan.decode(from: routine.conditioningPlanJSON) {
            for sectionIndex in plan.sections.indices {
                for movementIndex in plan.sections[sectionIndex].movements.indices
                    where plan.sections[sectionIndex].movements[movementIndex].exerciseID == replacedExerciseID {
                    plan.sections[sectionIndex].movements[movementIndex].exerciseID = replacement.id
                    plan.sections[sectionIndex].movements[movementIndex].targetLoad = nil
                    plan.sections[sectionIndex].movements[movementIndex].weightMode = replacement.defaultWeightMode
                }
            }
            routine.conditioningPlanJSON = plan.encodedJSON()
        }
        save()
    }

    private func add(_ exercises: [ExerciseLibraryModel]) {
        let additions = exercises.filter { !$0.isYoga }
        guard !additions.isEmpty else { return }
        withAnimation(reduceMotion ? Motion.reduced : Motion.entrance) {
            var nextPosition = orderedItems.count
            for exercise in additions {
                let re = RoutineExerciseModel(
                    userID: ForgeFitDemo.userID,
                    exerciseID: exercise.id,
                    position: nextPosition
                )
                nextPosition += 1
                modelContext.insert(re)
                re.sets = defaultTargetSets(for: exercise)
                routine.exercises.append(re)
            }
        }
        // One graph stamp and one persistence request for a multi-select add.
        save()
    }

    private func addBlock(kind: WorkoutBlockKind, planJSON: String) {
        withAnimation(reduceMotion ? Motion.reduced : Motion.entrance) {
            let block = RoutineBlockModel(
                userID: routine.userID,
                kind: kind,
                position: orderedItems.count,
                planJSON: planJSON
            )
            modelContext.insert(block)
            routine.blocks.append(block)
            save()
        }
    }

    private func update(_ block: RoutineBlockModel, planJSON: String) -> Bool {
        RoutineBlockPlanPersistence.apply(planJSON, to: block, in: modelContext)
    }

    /// The starter target rows an exercise gets when added. Session-based
    /// exercises are open until the athlete explicitly adds a goal/flow;
    /// only strength exercises start with a set row.
    private func defaultTargetSets(for exercise: ExerciseLibraryModel) -> [RoutineSetModel] {
        switch exercise.modality {
        case .yoga, .cardio:
            return []
        case .strength:
            let target = RoutineSetModel(userID: ForgeFitDemo.userID, position: 0)
            modelContext.insert(target)
            return [target]
        }
    }

    private func remove(_ re: RoutineExerciseModel) {
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
            for set in re.sets {
                pendingDrafts.unregister(set.id)
            }
            routine.exercises.removeAll { $0.id == re.id }
            modelContext.delete(re)
            for (index, item) in orderedItems.enumerated() {
                item.position = index
            }
            save()
        }
    }

    private func remove(_ block: RoutineBlockModel) {
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
            routine.blocks.removeAll { $0.id == block.id }
            modelContext.delete(block)
            for (index, item) in orderedItems.enumerated() {
                item.position = index
            }
            save()
        }
    }

    /// The model mutates in memory immediately; persistence is coalesced at
    /// the editor boundary. Rows never own or flush saves as they enter and
    /// leave the lazy stack, so scrolling cannot turn row recycling into
    /// synchronous SwiftData I/O.
    private func save() {
        scheduleSave()
    }

    private func scheduleSave() {
        saveCoordinator.schedule { saveNow() }
    }

    /// Flush a pending debounced save right now; no-op when nothing is queued.
    private func flushPendingSave() {
        guard pendingDrafts.commitAll() else {
            // Do not let a queued task outlive the screen and run after its
            // validation registrations have been cleared. The last valid model
            // value remains intact; correcting the draft schedules a new save.
            saveCoordinator.cancel()
            return
        }
        saveCoordinator.flush()
    }

    @discardableResult
    private func saveNow(
        showValidationError: Bool = false,
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard pendingDrafts.commitAll() else {
            if showValidationError {
                showInvalidDraftAlert = true
            }
            return false
        }
        saveCoordinator.cancel()
        RoutineStructure.normalize(routine)
        markAuthoredGraphUpdated()
        return modelContext.saveUserChanges(onSuccess: onCommit)
    }

    /// `RoutineModel.updatedAt` is also used by organization flows. Stamp the
    /// authored children as the independent content clock used by duplicate
    /// reconciliation, including rename, removal, and whole-routine reorder.
    private func markAuthoredGraphUpdated(at now: Date = .now) {
        routine.updatedAt = now
        for exercise in routine.exercises { exercise.updatedAt = now }
        for block in routine.blocks { block.updatedAt = now }
    }

    /// A brand-new routine the user backs out of is junk — soft-delete it
    /// (matching every other routine delete, so tombstones sync cleanly) and
    /// leave the library exactly as it was before "New Routine" was tapped.
    private func discardNewRoutine() {
        saveCoordinator.cancel()
        let now = Date()
        routine.updatedAt = now
        routine.deletedAt = now
        modelContext.saveUserChanges {
            onNewRoutineDiscarded()
            dismiss()
        }
    }

    private func nextSupersetGroup() -> Int {
        SupersetUI.nextGroup(excluding: supersetGroups)
    }

    private func assignSuperset(_ group: Int?, to re: RoutineExerciseModel) {
        re.supersetGroup = group
        re.updatedAt = Date()
        compactSupersetPositions()
        save()
    }

    private func ungroupSuperset(_ group: Int) {
        for exercise in routine.exercises where exercise.supersetGroup == group {
            exercise.supersetGroup = nil
            exercise.updatedAt = Date()
        }
        compactSupersetPositions()
        save()
    }

    private func compactSupersetPositions() {
        let items = orderedItems
        let groupedExercises = Dictionary(grouping: routine.exercises.compactMap { exercise -> RoutineExerciseModel? in
            exercise.supersetGroup == nil ? nil : exercise
        }, by: { $0.supersetGroup ?? -1 })
        var output: [OrderedRoutineItem] = []
        var seenGroups = Set<Int>()

        for item in items {
            guard case .exercise(let exercise) = item,
                  let group = exercise.supersetGroup else {
                output.append(item)
                continue
            }
            guard seenGroups.insert(group).inserted else { continue }
            output.append(contentsOf: (groupedExercises[group] ?? [])
                .sorted { $0.position < $1.position }
                .map(OrderedRoutineItem.exercise))
        }

        for (index, item) in output.enumerated() {
            item.position = index
            if case .exercise(let exercise) = item { exercise.updatedAt = .now }
        }
    }
}

/// Owns rapid routine-name/note drafts so each keystroke invalidates only this
/// small card, never the editor's exercise list or reorder calculations. The
/// screen coordinator retains the commit closure even if LazyVStack recycles
/// the card, guaranteeing Back/background/save can materialize the latest text.
private struct RoutineMetadataEditorCard: View {
    @Bindable var routine: RoutineModel
    let pendingDrafts: PendingDraftCoordinator
    let onChange: () -> Void

    @State private var nameDraft: String
    @State private var notesDraft: String
    @State private var nameDirty = false
    @State private var notesDirty = false
    private let draftToken: UUID

    init(
        routine: RoutineModel,
        pendingDrafts: PendingDraftCoordinator,
        onChange: @escaping () -> Void
    ) {
        self.routine = routine
        self.pendingDrafts = pendingDrafts
        self.onChange = onChange
        draftToken = routine.id
        _nameDraft = State(initialValue: routine.name)
        _notesDraft = State(initialValue: routine.notes ?? "")
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                FieldLabel("Routine name")
                DarkTextField(
                    text: Binding(
                        get: { nameDraft },
                        set: {
                            nameDraft = $0
                            nameDirty = true
                            onChange()
                        }
                    ),
                    placeholder: "Routine name"
                )
                FieldLabel("Notes")
                DarkTextField(
                    text: Binding(
                        get: { notesDraft },
                        set: {
                            notesDraft = $0
                            notesDirty = true
                            onChange()
                        }
                    ),
                    placeholder: "Add notes",
                    axis: .vertical
                )
            }
        }
        .onAppear {
            syncUntouchedDrafts()
            pendingDrafts.register(draftToken, commit: commitDrafts)
        }
        .onDisappear {
            // Lazy-stack recycling is not a terminal editor boundary. Move the
            // local text into the model before unregistering this card so a
            // fast type-then-scroll gesture cannot lose the metadata edit.
            commitDrafts()
            pendingDrafts.unregister(draftToken)
        }
        .onChange(of: routine.name) { syncUntouchedDrafts() }
        .onChange(of: routine.notes) { syncUntouchedDrafts() }
    }

    private func syncUntouchedDrafts() {
        if !nameDirty { nameDraft = routine.name }
        if !notesDirty { notesDraft = routine.notes ?? "" }
    }

    private func commitDrafts() {
        if nameDirty {
            if routine.name != nameDraft { routine.name = nameDraft }
            nameDirty = false
        }
        if notesDirty {
            let notes = notesDraft.isEmpty ? nil : notesDraft
            if routine.notes != notes { routine.notes = notes }
            notesDirty = false
        }
        syncUntouchedDrafts()
    }
}

// MARK: - Exercise edit row

private struct ExerciseEditRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Bindable var routineExercise: RoutineExerciseModel
    let exercise: ExerciseLibraryModel?
    let setupNote: UserExerciseNoteModel?
    let pendingDrafts: PendingDraftCoordinator
    let bestEstimatedOneRepMaxKg: Double?
    let availableSupersetGroups: [Int]
    let onShowDetail: (UUID) -> Void
    let onAssignSuperset: (Int?) -> Void
    let onCreateSuperset: () -> Void
    let onUngroupSuperset: (Int) -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
    let onSave: () -> Void
    let onCreateEstimatedOneRepMax: () -> Void
    /// Streams the finger's global Y while the reorder handle is held and
    /// dragged — the parent collapses every row around the finger with this
    /// exercise scaled under it (see `ReorderCollapseOverlay`).
    var onReorderDragChanged: (CGFloat) -> Void = { _ in }
    var onReorderDragEnded: () -> Void = {}
    /// VoiceOver fallback for the drag: move this exercise one slot up/down.
    var onAccessibilityMoveBy: (Int) -> Void = { _ in }

    @State private var showIntervalBuilder = false
    @State private var showFlowBuilder = false
    /// The set whose swipe-to-delete tray is open — one at a time, matching
    /// the live logger.
    @State private var openSwipeSetID: UUID?
    @State private var createdPinnedNote: UserExerciseNoteModel?
    @State private var removedPinnedNoteIDs = Set<UUID>()
    @State private var noteEditorRequested = false
    @State private var noteDraft = ""
    @State private var noteDraftDirty = false
    @State private var didInitializeNoteDraft = false
    @State private var noteDraftToken = UUID()
    @FocusState private var noteFocused: Bool
    private var sortedSets: [RoutineSetModel] { routineExercise.sets.sorted { $0.position < $1.position } }
    private var currentProgressionRule: ProgressionRule? { ProgressionRule.decode(from: routineExercise.progressionRuleJSON) }
    private var isCardio: Bool { exercise?.isCardio == true }
    private var isYoga: Bool { exercise?.isYoga == true }
    private var displayUnit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }
    private var supportsPercentagePrescription: Bool {
        AdaptiveLoadResolver.supportsPercentagePrescription(exercise)
    }
    private var hasPercentagePrescription: Bool {
        sortedSets.contains { $0.loadPrescriptionMode == .percentEstimatedOneRepMax }
    }
    private var hasIncompletePercentagePrescription: Bool {
        sortedSets.contains {
            $0.loadPrescriptionMode == .percentEstimatedOneRepMax
                && $0.estimatedOneRepMaxPrescription == nil
        }
    }
    private var pinnedNote: UserExerciseNoteModel? {
        if let createdPinnedNote, !removedPinnedNoteIDs.contains(createdPinnedNote.id) {
            return createdPinnedNote
        }
        guard let setupNote, !removedPinnedNoteIDs.contains(setupNote.id) else { return nil }
        return setupNote
    }
    private var modelNoteText: String {
        ExerciseNotePolicy.authoredText(routineExercise.notes)
            ?? ExerciseNotePolicy.authoredText(pinnedNote?.note)
            ?? ""
    }
    private var showsNoteEditor: Bool {
        noteEditorRequested || ExerciseNotePolicy.authoredText(modelNoteText) != nil
    }

    /// The ⋯ overflow menu for routine-time exercise actions. Progression
    /// stays hidden while its engine is parked, matching the live logger.
    private var overflowMenuSections: [[ScrollSafeMenuItem]] {
        let supersets = SupersetUI.scrollSafeMenuItems(
            currentGroup: routineExercise.supersetGroup,
            availableGroups: availableSupersetGroups,
            onAssign: onAssignSuperset,
            onCreate: onCreateSuperset,
            onUngroup: onUngroupSuperset
        )

        var sections = [supersets]
        if !showsNoteEditor {
            sections.append([ScrollSafeMenuItem(title: "Add Note", systemImage: "note.text") {
                noteEditorRequested = true
                Task { @MainActor in
                    await Task.yield()
                    noteFocused = true
                }
            }])
        }
        if !isCardio && !isYoga {
            sections.append([
                ScrollSafeMenuItem(title: "Add Warm-up Set", systemImage: "flame") { addSet(type: .warmup) },
                ScrollSafeMenuItem(title: "Add Warm-up Ramp", systemImage: "flame.fill") { addWarmupRamp() },
                ScrollSafeMenuItem(title: "Add Working Set", systemImage: "plus") { addSet(type: .working) }
            ])
            if !ProgressionPlanner.isParked {
                sections.append([ScrollSafeMenuItem(
                    title: "Progression",
                    systemImage: "chart.line.uptrend.xyaxis",
                    children: [
                        progressionRuleItem("Double progression (default)", rule: nil),
                        progressionRuleItem("Fixed +\(displayUnit == .lb ? "5 lb" : "2.5 kg") on target", rule: .fixedIncrement(step: displayUnit == .lb ? 5 : 2.5)),
                        progressionRuleItem("Percent +2.5% on target", rule: .percent(step: 2.5)),
                        progressionRuleItem("Off", rule: ProgressionRule.off)
                    ]
                )])
            }
        }
        sections.append([ScrollSafeMenuItem(title: "Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: onReplace)])
        sections.append([ScrollSafeMenuItem(title: "Remove Exercise", systemImage: "trash", isDestructive: true, action: onRemove)])
        return sections
    }

    /// nil rule = the double-progression default (stored as nil JSON).
    private func progressionRuleItem(_ title: String, rule: ProgressionRule?) -> ScrollSafeMenuItem {
        let isSelected = rule == nil
            ? routineExercise.progressionRuleJSON == nil
            : currentProgressionRule == rule
        return ScrollSafeMenuItem(title: title, isChecked: isSelected) {
            routineExercise.progressionRuleJSON = rule?.encodedJSON()
            save()
        }
    }

    private func progressionTagText(_ rule: ProgressionRule) -> String {
        switch rule {
        case .doubleProgression: "Double progression"
        case .fixedIncrement(let step): "Progression: +\(step.formatted()) \(displayUnit.shortSuffix)"
        case .percent(let step): "Progression: +\(step.formatted())%"
        case .off: "Progression off"
        }
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    if let exercise {
                        ExerciseThumbnail(exercise: exercise, size: 34)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if let exercise {
                            Button {
                                onShowDetail(exercise.id)
                            } label: {
                                ExerciseNameLabel(name: exercise.name)
                                    .minimumTouchTarget()
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Exercise").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        }
                        if let group = routineExercise.supersetGroup {
                            SupersetChip(group: group)
                        }
                        if !ProgressionPlanner.isParked,
                           let rule = currentProgressionRule,
                           rule != .doubleProgression {
                            Text(progressionTagText(rule))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    Spacer()
                    ReorderHandle(
                        onDragChanged: onReorderDragChanged,
                        onDragEnded: onReorderDragEnded,
                        onAccessibilityMoveBy: onAccessibilityMoveBy
                    )
                    // ScrollSafeMenu, not Menu — same conversion as the live
                    // logger's ⋯ menu: a scroll starting on the glyph must
                    // scroll, not dead-stop into the menu's touch claim.
                    ScrollSafeMenu(sections: overflowMenuSections) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 44, height: 44)   // HIG minimum touch target
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("routine-exercise-menu-\(exercise?.name ?? "")")
                }

                if showsNoteEditor {
                    pinnedNoteEditor
                }

                if isYoga {
                    yogaTargetEditor
                } else if isCardio {
                    cardioTargetEditor
                    if let exercise {
                        MuscleChips(muscles: CardioKind.infer(name: exercise.name, equipment: exercise.equipment).musclesWorked)
                    }
                } else {
                    if hasPercentagePrescription,
                       hasIncompletePercentagePrescription
                        || bestEstimatedOneRepMaxKg == nil
                        || !supportsPercentagePrescription {
                        adaptiveLoadNotice
                    }
                    strengthSetEditor
                }
            }
        }
    }

    private var strengthSetEditor: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("SET").frame(width: 40, alignment: .leading)
                Text("REPS").frame(maxWidth: .infinity, alignment: .leading)
                Text("LOAD").frame(maxWidth: .infinity, alignment: .leading)
                Text("RPE").frame(width: 48, alignment: .leading)
            }
            .font(.tag).foregroundStyle(theme.textTertiary)

            ForEach(Array(sortedSets.enumerated()), id: \.element.id) { index, set in
                SwipeToDeleteRow(
                    isOpen: openSwipeSetID == set.id,
                    onOpenChange: { open in
                        if open { openSwipeSetID = set.id }
                        else if openSwipeSetID == set.id { openSwipeSetID = nil }
                    },
                    onDelete: { deleteSet(set) }
                ) {
                    SetTargetEditRow(
                        set: set,
                        pendingDrafts: pendingDrafts,
                        workingNumber: workingNumber(upTo: index),
                        exercise: exercise,
                        displayUnit: displayUnit,
                        bestEstimatedOneRepMaxKg: bestEstimatedOneRepMaxKg,
                        supportsPercentagePrescription: supportsPercentagePrescription,
                        supportsResistanceBands: ResistanceBandSupport.isBandExercise(
                            name: exercise?.name,
                            equipment: exercise?.equipment
                        ),
                        onChange: save,
                        onSetType: { changeType(of: set, to: $0, index: index) },
                        onAddDrop: { addDropSet(below: set, index: index) },
                        onDelete: { deleteSet(set) }
                    )
                }
            }

            Button(action: { addSet(type: .working) }) {
                HStack(spacing: 6) { Image(systemName: "plus"); Text("Add Set") }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private var adaptiveLoadNotice: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warmup)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(adaptiveLoadNoticeTitle)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(adaptiveLoadNoticeMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if supportsPercentagePrescription && !hasIncompletePercentagePrescription {
                    Button(action: onCreateEstimatedOneRepMax) {
                        HStack(spacing: 5) {
                            Text("Create Estimate")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accentForeground)
                        .minimumTouchTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Starts a guided three to eight rep estimate workout")
                    .accessibilityIdentifier("create-1rm-estimate")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.sm)
        .background(theme.warmup.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var adaptiveLoadNoticeTitle: String {
        if hasIncompletePercentagePrescription { return "Percentage needed" }
        return supportsPercentagePrescription
            ? "Estimated 1RM needed"
            : "Percentage load unavailable"
    }

    private var adaptiveLoadNoticeMessage: String {
        if hasIncompletePercentagePrescription {
            return "Enter 1–100% or a range for each percentage set. Until then, its workout load stays blank."
        }
        return supportsPercentagePrescription
            ? "You can still start. Percentage loads stay blank until this exercise has a completed estimate."
            : "Percentage planning is available for external strength loads. Choose Fixed load for this exercise."
    }

    private var pinnedNoteEditor: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Label("Pinned to exercise", systemImage: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.stickyInk.opacity(0.6))
                Spacer()
                Button(action: removePinnedNote) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.stickyInk.opacity(0.6))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove exercise note")
            }

            TextField("Write a note…", text: Binding(
                get: { didInitializeNoteDraft ? noteDraft : modelNoteText },
                set: updatePinnedNoteDraft
            ), axis: .vertical)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(theme.stickyInk)
            .tint(theme.stickyInk)
            .focused($noteFocused)
            .lineLimit(1...6)
            .accessibilityLabel("Exercise note")
            .accessibilityIdentifier("routine-exercise-note")
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.stickyFill.opacity(0.88))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(theme.stickyInk.opacity(0.28), lineWidth: 1)
                )
        )
        .onAppear {
            if !didInitializeNoteDraft {
                noteDraft = modelNoteText
                didInitializeNoteDraft = true
            }
            pendingDrafts.register(noteDraftToken, commit: commitPinnedNoteDraft)
        }
        .onChange(of: modelNoteText) { _, newValue in
            guard !noteDraftDirty else { return }
            noteDraft = newValue
        }
        .onChange(of: noteFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused { commitPinnedNoteDraft() }
        }
        .onDisappear {
            commitPinnedNoteDraft()
            pendingDrafts.unregister(noteDraftToken)
        }
    }

    private func updatePinnedNoteDraft(_ text: String) {
        noteDraft = text
        noteDraftDirty = true
        // Schedule only the screen-owned coalesced boundary. The CloudKit-
        // backed note itself stays untouched while the user is typing.
        save()
    }

    private func commitPinnedNoteDraft() {
        guard noteDraftDirty else { return }
        noteDraftDirty = false
        let text = noteDraft
        // A routine-authored note is exercise-level planning intent. Move any
        // legacy routine-only value into the durable pinned-note store on the
        // first committed edit so unpinning it during a workout truly removes
        // it later.
        routineExercise.notes = nil
        guard let authored = ExerciseNotePolicy.authoredText(text) else {
            removePinnedNote()
            return
        }

        if let pinnedNote {
            pinnedNote.note = text
            pinnedNote.updatedAt = .now
        } else {
            let note = UserExerciseNoteModel(
                userID: ForgeFitDemo.userID,
                exerciseID: routineExercise.exerciseID,
                note: authored
            )
            modelContext.insert(note)
            createdPinnedNote = note
        }
        save()
    }

    private func removePinnedNote() {
        noteFocused = false
        noteEditorRequested = false
        noteDraft = ""
        noteDraftDirty = false
        didInitializeNoteDraft = true
        routineExercise.notes = nil
        if let pinnedNote {
            removedPinnedNoteIDs.insert(pinnedNote.id)
            modelContext.delete(pinnedNote)
        }
        createdPinnedNote = nil
        save()
    }

    /// Yoga block target: the attached flow (or the pose's default hold) and
    /// the door into the flow builder. No set rows — yoga is session-shaped.
    private var yogaTargetEditor: some View {
        let plan = YogaFlowPlan.decode(from: routineExercise.yogaFlowJSON)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 8) {
                Image(systemName: (plan?.style ?? .hatha).systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.accentForeground)
                Text("Guided flow")
                    .font(.tag)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }

            Button {
                showFlowBuilder = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: plan?.hasSteps == true ? "figure.yoga" : "plus.circle")
                        .font(.system(size: 12, weight: .bold))
                    Text(yogaGoalLabel(plan))
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.7)
                    Spacer()
                }
                .foregroundStyle(theme.accentForeground)
                .minimumTouchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routine-yoga-flow-builder")
            .sheet(isPresented: $showFlowBuilder) {
                YogaFlowBuilderView(planJSON: routineExercise.yogaFlowJSON, commit: { json in
                    RoutineYogaPlanPersistence.apply(
                        json,
                        to: routineExercise,
                        in: modelContext
                    )
                })
            }

            if let exercise {
                MuscleChips(muscles: exercise.primaryMuscles + exercise.secondaryMuscles)
            }
        }
    }

    private func yogaGoalLabel(_ plan: YogaFlowPlan?) -> String {
        if let plan, plan.hasSteps {
            return "\(plan.structureSummary) · \(plan.style.title)"
        }
        if YogaPoseCatalog.isSessionExercise(exercise) {
            return "Choose poses or a class"
        }
        if let hold = exercise?.defaultHoldSeconds {
            return "Single pose · \(hold)s hold"
        }
        return "Build a flow"
    }

    /// A saved goal has to be readable from the card itself. "Add goal" on a
    /// row that already carries a 30-minute target reads as "nothing saved",
    /// which is exactly how a saved goal gets set twice or abandoned. The row
    /// states which of the two things it does and, when there is one, what the
    /// target actually is.
    private var cardioTargetEditor: some View {
        let row = CardioGoalRowPresentation(planJSON: routineExercise.intervalPlanJSON)
        return Button {
            showIntervalBuilder = true
        } label: {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(row.action)
                            .font(.bodyStrong)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    if let summary = row.summary {
                        Text(summary)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityIdentifier("routine-cardio-goal-summary")
                    }
                }
                Spacer()
            }
            .foregroundStyle(theme.accentForeground)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routine-cardio-goal")
        .accessibilityLabel(row.action)
        .accessibilityValue(row.summary ?? "")
        .sheet(isPresented: $showIntervalBuilder) {
            IntervalPlanBuilderView(routineExercise: routineExercise)
        }
    }

    private func addSet(type: SetType) {
        guard !isCardio, !isYoga else { return }
        let last = sortedSets.last
        let carriedType = type == .working ? (last?.setType.isBlockType == true ? last!.setType : type) : type
        let set = RoutineSetModel(
            userID: ForgeFitDemo.userID, position: routineExercise.sets.count,
            setType: carriedType,
            targetRepsLow: last?.targetRepsLow,
            targetRepsHigh: last?.targetRepsHigh,
            targetWeight: last?.targetWeight,
            loadPrescriptionMode: last?.loadPrescriptionMode ?? .fixed,
            target1RMPercentLow: last?.target1RMPercentLow,
            target1RMPercentHigh: last?.target1RMPercentHigh,
            targetRPE: last?.targetRPE,
            targetDurationSeconds: carriedType == .amrap ? last?.targetDurationSeconds : nil,
            plannedMiniSetCount: carriedType == .myoRep ? (last?.plannedMiniSetCount ?? 1) : nil,
            plannedMiniRepsJSON: carriedType == .cluster ? last?.plannedMiniRepsJSON : nil
        )
        if carriedType == .cluster, set.plannedMiniReps.isEmpty {
            set.plannedMiniReps = [3, 3, 3, 3]
        }
        modelContext.insert(set)
        routineExercise.sets.append(set)
        routineExercise.updatedAt = Date()
        routineExercise.routine?.updatedAt = Date()
        save()
    }

    /// Inserts the user's configured warm-up ramp before the first working
    /// set. Routine targets are stored in kilograms, so weight calculations
    /// round in the exercise's display unit and convert back for persistence.
    /// Assisted and unweighted bodyweight movements keep weights blank because
    /// a percentage of assistance does not represent an easier warm-up.
    private func addWarmupRamp() {
        guard !isCardio, !isYoga else { return }
        let config = WarmupRampConfigStore.load()
        let topSet = sortedSets.first { $0.setType != .warmup }
        let topKilograms: Double?
        if let prescription = topSet?.estimatedOneRepMaxPrescription,
           let exercise,
           let baseline = bestEstimatedOneRepMaxKg,
           let raw = prescription.resolving(estimatedOneRepMaxKg: baseline) {
            topKilograms = AdaptiveLoadResolver.snap(raw.lowKg, for: exercise)
        } else {
            topKilograms = topSet?.targetWeight
        }
        let topDisplay = topKilograms.map(displayUnit.displayValue(fromKilograms:)) ?? 0
        let step: Double = displayUnit == .lb ? 5 : 2.5
        let supportsAutoWeight = exercise?.defaultWeightMode == .external
            || exercise?.defaultWeightMode == .bodyweightAdded

        let newSets = config.stages.enumerated().map { ordinal, stage in
            let displayWeight = config.weight(
                forStageAt: ordinal,
                topWeightInDisplayUnit: topDisplay,
                step: step
            )
            let set = RoutineSetModel(
                userID: ForgeFitDemo.userID,
                setType: .warmup,
                targetRepsLow: stage.reps,
                targetRepsHigh: stage.reps,
                targetWeight: supportsAutoWeight
                    ? displayWeight.map(displayUnit.kilograms(fromDisplayValue:))
                    : nil
            )
            modelContext.insert(set)
            return set
        }

        var allSets = sortedSets
        let insertAt = allSets.firstIndex { $0.setType != .warmup } ?? allSets.count
        allSets.insert(contentsOf: newSets, at: insertAt)
        routineExercise.sets = allSets
        renumber(allSets)
        save()
    }

    private func addDropSet(below set: RoutineSetModel, index: Int) {
        let mode = exercise?.defaultWeightMode ?? .external
        let sourcePrescription = set.estimatedOneRepMaxPrescription
        let drop = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            setType: .drop,
            targetRepsLow: nil,
            targetRepsHigh: nil,
            targetWeight: DropSetLoadPolicy.suggestedModeWeight(
                sourceWeightKg: set.targetWeight,
                mode: mode,
                bodyweightKg: HealthMetricsStore.shared.latestBodyweight,
                displayUnit: displayUnit
            ),
            loadPrescriptionMode: sourcePrescription == nil ? .fixed : .percentEstimatedOneRepMax,
            target1RMPercentLow: sourcePrescription.map { max(1, $0.lowPercent * 0.75) },
            target1RMPercentHigh: sourcePrescription?.highPercent.map { max(1, $0 * 0.75) },
            targetRPE: set.targetRPE
        )
        modelContext.insert(drop)
        routineExercise.sets.append(drop)
        var rows = sortedSets.filter { $0.id != drop.id }
        rows.insert(drop, at: min(index + 1, rows.count))
        renumber(rows)
        save()
    }

    private func changeType(of set: RoutineSetModel, to type: SetType, index: Int) {
        if type == .drop, index > 0, let above = sortedSets[index - 1].targetWeight {
            if set.targetWeight == nil || set.targetWeight == above {
                set.targetWeight = DropSetLoadPolicy.suggestedModeWeight(
                    sourceWeightKg: above,
                    mode: exercise?.defaultWeightMode ?? .external,
                    bodyweightKg: HealthMetricsStore.shared.latestBodyweight,
                    displayUnit: displayUnit
                )
            }
        }
        set.setType = type
        // Seed a sensible plan when flipping into a structured type so the
        // row is immediately editable rather than empty.
        switch type {
        case .myoRep where set.plannedMiniSetCount == nil:
            set.plannedMiniSetCount = 1
        case .cluster where set.plannedMiniReps.isEmpty:
            set.plannedMiniReps = [3, 3, 3, 3]
        case .amrap where set.targetDurationSeconds == nil:
            set.targetDurationSeconds = 60
        default:
            break
        }
        save()
    }

    private func deleteSet(_ set: RoutineSetModel) {
        pendingDrafts.unregister(set.id)
        routineExercise.sets.removeAll { $0.id == set.id }
        modelContext.delete(set)
        renumber(sortedSets)
        save()
    }

    private func workingNumber(upTo index: Int) -> Int {
        sortedSets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
    }

    private func renumber(_ rows: [RoutineSetModel]) {
        for (index, row) in rows.enumerated() { row.position = index }
    }

    /// Every row mutation updates its local authored clock, then asks the
    /// editor-owned coordinator for one debounced graph commit.
    private func save() {
        onSave()
    }
}

/// One editable target-set row. Split into its own view so `@Bindable`
/// projects bindings for the numeric fields.
private struct SetTargetEditRow: View {
    @Environment(\.theme) private var theme
    @Bindable var set: RoutineSetModel
    let pendingDrafts: PendingDraftCoordinator
    let workingNumber: Int
    let exercise: ExerciseLibraryModel?
    let displayUnit: WeightUnit
    let bestEstimatedOneRepMaxKg: Double?
    let supportsPercentagePrescription: Bool
    let supportsResistanceBands: Bool
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    let onAddDrop: () -> Void
    let onDelete: () -> Void

    private var style: SetTypeStyle { SetTypeStyle.of(self.set.setType, theme: theme) }
    private var isDrop: Bool { self.set.setType == .drop }

    var body: some View {
        if set.setType.isBlockType {
            blockPlanner
        } else {
            standardRow
        }
    }

    private var standardRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if isDrop {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(style.color.opacity(0.7))
                        .frame(width: 16)
                }

                typeMenu

                if set.setType == .amrap {
                    amrapTimeField
                    loadField
                } else {
                    OptionalRepsTargetField(
                        low: $set.targetRepsLow,
                        high: $set.targetRepsHigh,
                        pendingDrafts: pendingDrafts,
                        onChange: onChange
                    )
                    loadField
                    OptionalDoubleField(
                        placeholder: "RPE",
                        value: $set.targetRPE,
                        width: 48,
                        pendingDrafts: pendingDrafts,
                        onChange: onChange
                    )
                }
            }
            if let resolutionCaption {
                Text(resolutionCaption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(bestEstimatedOneRepMaxKg == nil ? theme.warmup : theme.textTertiary)
                    .padding(.leading, isDrop ? 64 : 48)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var typeMenu: some View {
        // ScrollSafeMenu, not Menu: the badge sits mid-row on the scroll
        // surface — exactly where a thumb lands to scroll. Same conversion
        // as the live logger's set-row badges.
        ScrollSafeMenu(sections: [
            SetType.selectable.map { type in
                ScrollSafeMenuItem(title: SetTypeStyle.of(type).label, isChecked: set.setType == type) {
                    onSetType(type)
                }
            },
            [ScrollSafeMenuItem(title: "Add Drop Set Below", systemImage: "arrow.down.right", action: onAddDrop)],
            // Accessible fallback — the primary delete is swipe-to-delete,
            // exactly like the live logger.
            [ScrollSafeMenuItem(title: "Delete Set", systemImage: "trash", isDestructive: true, action: onDelete)]
        ]) {
            let hasBadge = !style.badge.isEmpty
            Text(style.numbered ? "\(workingNumber)\(style.badge)" : style.badge)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(hasBadge ? style.color : theme.textPrimary)
                .frame(width: isDrop ? 32 : 40, height: 30)
                .background(hasBadge ? style.color.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .accessibilityLabel("Set type")
    }

    // MARK: - Block plan (myo-reps / cluster)

    /// Planning mirrors performing: the same tinted block card the live
    /// logger uses (`SetBlockView`), with the mini-set bubbles rendered as
    /// dashed placeholders. Myo bubbles stay empty — reps are whatever the
    /// lifter achieves live; cluster bubbles carry their goal reps.
    private var blockPlanner: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: 8) {
                typeMenu
                Spacer()
                if set.setType == .cluster {
                    weightField
                }
            }

            if set.setType == .myoRep {
                HStack(spacing: Space.sm) {
                    Text("Activation")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    weightField
                    // Neutral, like the live activation reps field — the
                    // sage bubbles are reserved for the mini-sets.
                    Text("reps")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: 58, height: 30)
                        .background(theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if let resolutionCaption {
                Text(resolutionCaption)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(bestEstimatedOneRepMaxKg == nil ? theme.warmup : theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WrapLayout(spacing: 7) {
                if set.setType == .myoRep {
                    ForEach(0..<(set.plannedMiniSetCount ?? 0), id: \.self) { index in
                        Button {
                            removePlannedMyoMini()
                        } label: {
                            placeholderBubble(label: "reps")
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityLabel("Planned mini-set \(index + 1)")
                        .accessibilityHint("Tap to remove")
                    }
                } else {
                    ForEach(Array(set.plannedMiniReps.enumerated()), id: \.offset) { index, goal in
                        // ScrollSafeMenu, not Menu — bubbles are prime
                        // scroll-start territory in a long cluster plan.
                        ScrollSafeMenu(sections: [
                            [
                                ScrollSafeMenuItem(title: "+1 rep", systemImage: "plus") { adjustClusterGoal(index, by: 1) },
                                ScrollSafeMenuItem(title: "−1 rep", systemImage: "minus") { adjustClusterGoal(index, by: -1) }
                            ],
                            [ScrollSafeMenuItem(title: "Remove", systemImage: "trash", isDestructive: true) {
                                var plan = set.plannedMiniReps
                                plan.remove(at: index)
                                set.plannedMiniReps = plan
                                onChange()
                            }]
                        ]) {
                            placeholderBubble(label: "\(goal)")
                        }
                        .accessibilityLabel("Mini-set \(index + 1): goal \(goal) reps")
                    }
                }
                addBubble
            }
            .padding(.vertical, 2)
        }
        .padding(Space.sm)
        .background(style.color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(style.color.opacity(0.25), lineWidth: 1)
        )
    }

    private var weightField: some View {
        loadField
            .frame(width: supportsPercentagePrescription || set.loadPrescriptionMode == .percentEstimatedOneRepMax ? 148 : 72)
    }

    private var loadField: some View {
        RoutineLoadPrescriptionField(
            set: set,
            unit: displayUnit,
            supportsPercentage: supportsPercentagePrescription,
            supportsResistanceBands: supportsResistanceBands,
            pendingDrafts: pendingDrafts,
            onChange: onChange
        )
    }

    private var resolutionCaption: String? {
        LoadPrescriptionPresentation.currentLoadLabel(
            for: set,
            exercise: exercise,
            bestEstimatedOneRepMaxKg: bestEstimatedOneRepMaxKg,
            unit: displayUnit
        )
    }

    /// The live logger's mini-set pill, in placeholder form: same sage
    /// capsule, dashed border, no logged value.
    private func placeholderBubble(label: String) -> some View {
        Text(label)
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(style.color)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(style.color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    style.color.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
    }

    private var addBubble: some View {
        Button {
            if set.setType == .myoRep {
                set.plannedMiniSetCount = min(10, (set.plannedMiniSetCount ?? 0) + 1)
            } else {
                var plan = set.plannedMiniReps
                plan.append(plan.last ?? 3)
                set.plannedMiniReps = plan
            }
            onChange()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .overlay(
                    Capsule().strokeBorder(
                        theme.textTertiary.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Add planned mini-set")
    }

    private func removePlannedMyoMini() {
        let current = set.plannedMiniSetCount ?? 0
        set.plannedMiniSetCount = current <= 1 ? nil : current - 1
        onChange()
    }

    private func adjustClusterGoal(_ index: Int, by delta: Int) {
        var plan = set.plannedMiniReps
        guard plan.indices.contains(index) else { return }
        plan[index] = max(1, plan[index] + delta)
        set.plannedMiniReps = plan
        onChange()
    }

    // MARK: - AMRAP plan (as many reps as possible in a fixed time)

    private var amrapTimeField: some View {
        HStack(spacing: 6) {
            OptionalIntField(placeholder: "60", value: Binding(
                get: { set.targetDurationSeconds },
                set: { set.targetDurationSeconds = $0 }
            ), pendingDrafts: pendingDrafts, onChange: onChange)
            Text("sec")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared dark form fields

struct FieldLabel: View {
    @Environment(\.theme) private var theme
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.label).foregroundStyle(theme.textSecondary)
    }
}

struct DarkTextField: View {
    @Environment(\.theme) private var theme
    @Binding var text: String
    var placeholder: String
    var axis: Axis = .horizontal
    var accessibilityIdentifier = ""

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 13).padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct OptionalIntField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Int?
    var width: CGFloat? = nil
    var pendingDrafts: PendingDraftCoordinator? = nil
    var onChange: () -> Void = {}
    @State private var draft = ""
    @State private var draftDirty = false
    @State private var draftToken = UUID()
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(
            get: {
                pendingDrafts != nil && isFocused
                    ? draft
                    : value.map(String.init) ?? ""
            },
            set: { text in
                guard pendingDrafts != nil else {
                    value = Int(text)
                    onChange()
                    return
                }
                draft = text
                draftDirty = true
                onChange()
            }
        ))
        .focused($isFocused)
        .keyboardType(.numberPad)
        .font(.bodyStrong)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            draft = value.map(String.init) ?? ""
            pendingDrafts?.register(draftToken, commit: commitDraft)
        }
        .onChange(of: isFocused) { _, focused in
            if focused, !draftDirty { draft = value.map(String.init) ?? "" }
            if !focused { commitDraft() }
        }
        .onChange(of: value) { _, newValue in
            if !isFocused, !draftDirty { draft = newValue.map(String.init) ?? "" }
        }
        .onDisappear {
            commitDraft()
            pendingDrafts?.unregister(draftToken)
        }
    }

    private func commitDraft() {
        guard pendingDrafts != nil, draftDirty else { return }
        draftDirty = false
        let parsed = Int(draft)
        if value != parsed { value = parsed }
    }
}

/// Decimal twin of `OptionalIntField` on the focus-aware draft pattern —
/// a reformat-per-keystroke binding eats the trailing "." of "2.5"
/// mid-typing (the weight-field rule).
struct OptionalDecimalField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Double?
    var onChange: () -> Void = {}
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .keyboardType(.decimalPad)
            .font(.bodyStrong)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .focused($isFocused)
            .onAppear { draft = Self.text(for: value) }
            .onChange(of: draft) { _, newDraft in
                guard isFocused else { return }
                value = Double(newDraft.replacingOccurrences(of: ",", with: "."))
                onChange()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { draft = Self.text(for: value) }
            }
            .onChange(of: value) { _, newValue in
                guard !isFocused else { return }
                draft = Self.text(for: newValue)
            }
    }

    private static func text(for value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded()
            ? String(Int(value))
            : String(format: "%.2f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

struct OptionalRepsTargetField: View {
    @Environment(\.theme) private var theme
    @Binding var low: Int?
    @Binding var high: Int?
    var pendingDrafts: PendingDraftCoordinator? = nil
    var onChange: () -> Void = {}
    @State private var draft = ""
    @State private var draftDirty = false
    @State private var draftToken = UUID()
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Reps", text: Binding(
            get: { isFocused ? draft : formattedValue },
            set: { text in
                draft = text
                guard pendingDrafts != nil else {
                    apply(text)
                    return
                }
                draftDirty = true
                onChange()
            }
        ))
        .focused($isFocused)
        .keyboardType(.numbersAndPunctuation)
        .font(.bodyStrong)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            draft = formattedValue
            pendingDrafts?.register(draftToken, commit: commitDraft)
        }
        .onChange(of: isFocused) { _, focused in
            if focused, !draftDirty { draft = formattedValue }
            if !focused { commitDraft() }
        }
        .onChange(of: low) { _, _ in
            if !isFocused { draft = formattedValue }
        }
        .onChange(of: high) { _, _ in
            if !isFocused { draft = formattedValue }
        }
        .onDisappear {
            commitDraft()
            pendingDrafts?.unregister(draftToken)
        }
    }

    private var formattedValue: String {
        if let low, let high, high != low { return "\(low)-\(high)" }
        return low.map(String.init) ?? ""
    }

    private func commitDraft() {
        guard pendingDrafts != nil, draftDirty else { return }
        draftDirty = false
        apply(draft)
    }

    private func apply(_ text: String) {
        let normalized = text.replacingOccurrences(of: "–", with: "-")
        let rawParts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let parts = rawParts.map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            low = parts[0].isEmpty ? nil : Int(parts[0])
            high = parts[1].isEmpty ? nil : Int(parts[1])
        } else {
            let value = Int(normalized.trimmingCharacters(in: .whitespaces))
            low = value
            high = value
        }
        onChange()
    }
}

struct OptionalDoubleField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Double?
    var width: CGFloat? = nil
    var pendingDrafts: PendingDraftCoordinator? = nil
    var onChange: () -> Void = {}
    @State private var draft = ""
    @State private var draftDirty = false
    @State private var draftToken = UUID()
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(
            get: {
                pendingDrafts != nil && isFocused ? draft : Self.text(for: value)
            },
            set: { text in
                guard pendingDrafts != nil else {
                    value = Self.parse(text)
                    onChange()
                    return
                }
                draft = text
                draftDirty = true
                onChange()
            }
        ))
        .focused($isFocused)
        .keyboardType(.decimalPad)
        .font(.bodyStrong)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            draft = Self.text(for: value)
            pendingDrafts?.register(draftToken, commit: commitDraft)
        }
        .onChange(of: isFocused) { _, focused in
            if focused, !draftDirty { draft = Self.text(for: value) }
            if !focused { commitDraft() }
        }
        .onChange(of: value) { _, newValue in
            if !isFocused, !draftDirty { draft = Self.text(for: newValue) }
        }
        .onDisappear {
            commitDraft()
            pendingDrafts?.unregister(draftToken)
        }
    }

    private func commitDraft() {
        guard pendingDrafts != nil, draftDirty else { return }
        draftDirty = false
        let parsed = Self.parse(draft)
        if value != parsed { value = parsed }
    }

    private static func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static func text(for value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(0...1))) ?? ""
    }
}

struct OptionalLoadField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Double?
    let unit: WeightUnit
    var width: CGFloat? = nil
    var supportsResistanceBands = false
    var onChange: () -> Void = {}

    /// Raw text while focused; formatted from the model otherwise. A
    /// get-formats/set-parses round trip erases a trailing "." the moment
    /// it's typed ("62." re-renders as "62"), making fractional loads
    /// impossible to enter.
    @State private var draft = ""
    @State private var draftActive = false
    @FocusState private var focused: Bool

    var body: some View {
        // Keep the band picker beside the field instead of laying it over the
        // text. The explicit slot preserves its touch target and leaves the
        // empty "Optional" placeholder readable in narrow conditioning rows.
        HStack(spacing: supportsResistanceBands ? 2 : 0) {
            if supportsResistanceBands {
                ResistanceBandLoadMenu(
                    selectedWeightKilograms: value,
                    unit: unit,
                    onSelect: selectBand
                )
            }

            TextField(placeholder, text: Binding(
                get: { focused && draftActive ? draft : (value.map { Fmt.load($0, unit: unit) } ?? "") },
                set: { text in
                    draft = text
                    draftActive = true
                    value = Fmt.loadKilograms(from: text, unit: unit)
                    onChange()
                }
            ))
            .focused($focused)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { draftActive = false }
            }
            .frame(maxWidth: .infinity)
            .keyboardType(.decimalPad)
            .font(.bodyStrong)
            .multilineTextAlignment(supportsResistanceBands ? .trailing : .center)
            .padding(.trailing, supportsResistanceBands ? 4 : 0)
            .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func selectBand(_ kilograms: Double) {
        focused = false
        draftActive = false
        value = kilograms
        draft = Fmt.load(kilograms, unit: unit)
        onChange()
    }
}
