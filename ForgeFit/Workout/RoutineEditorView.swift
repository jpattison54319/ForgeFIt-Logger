import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Editing surface for a routine: rename, add/remove exercises, and tune target
/// sets. Kept dark and card-based to match the rest of the app.
struct RoutineEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]
    /// True when this routine is a just-inserted placeholder (insert-then-edit
    /// keeps the picker's eager saves working). Backing out of a new routine
    /// deletes the placeholder instead of leaving "New Routine" in the library.
    var isNew: Bool = false

    @Environment(\.scenePhase) private var scenePhase
    @State private var showPicker = false
    @State private var entrySnapshot: RoutineSnapshot?
    @State private var showDiscardConfirm = false
    @State private var replaceTarget: RoutineExerciseModel?
    @State private var detailExerciseID: UUID?
    /// Reference-backed so per-frame finger updates invalidate only the small
    /// reorder overlay, not every editor row and target field.
    @State private var reorderSession: ExerciseReorderSession?
    /// Debounced structural-save plumbing — see `save()`.
    @State private var deferredSaveTask: Task<Void, Never>?
    @Query(sort: \WorkoutModel.startedAt, order: .reverse) private var allWorkouts: [WorkoutModel]

    private var sortedExercises: [RoutineExerciseModel] { routine.exercises.sorted { $0.position < $1.position } }
    private var supersetGroups: [Int] {
        Array(Set(routine.exercises.compactMap(\.supersetGroup))).sorted()
    }
    /// Library entries for the routine's current exercises — the picker's
    /// suggestion context (lots of chest work → chest & push suggested first).
    private var exercisesInRoutine: [ExerciseLibraryModel] {
        routine.exercises.compactMap { re in exercises.first { $0.id == re.exerciseID } }
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
                    .font(.bodyStrong)
                    .foregroundStyle(theme.accent)
            }
        }
        .interactiveBackSwipeEnabled()
        .onAppear {
            if entrySnapshot == nil { entrySnapshot = RoutineSnapshot(of: routine) }
        }
        .onDisappear { flushPendingSave() }
        // The 2s save debounce must not lose edits when the app is locked or
        // backgrounded mid-edit.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPendingSave() }
        }
        .confirmationDialog("Unsaved changes", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Save Changes") { saveNow(); dismiss() }
            Button("Discard Changes", role: .destructive) {
                // A queued debounced save must not fire after the restore and
                // persist the very edits being thrown away.
                deferredSaveTask?.cancel()
                deferredSaveTask = nil
                if isNew {
                    // The routine never existed before this editor opened —
                    // discarding means it shouldn't exist at all.
                    discardNewRoutine()
                } else {
                    if let entrySnapshot { entrySnapshot.restore(onto: routine, in: modelContext) }
                    dismiss()
                }
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You've made changes to this routine.")
        }
        .sheet(isPresented: $showPicker) {
            ExercisePickerView(excludeYogaPoses: true, context: exercisesInRoutine, history: allWorkouts) { added in added.forEach(add) }
        }
        .sheet(item: $replaceTarget) { target in
            // Gym swap: lead with close substitutes for the exercise being
            // replaced; search stays one tap away inside the sheet.
            if let currentExercise = exercises.first(where: { $0.id == target.exerciseID }) {
                ExerciseSwapSheet(
                    current: currentExercise,
                    allExercises: exercises,
                    inUseIDs: Set(routine.exercises.map(\.exerciseID)),
                    history: allWorkouts
                ) { picked in
                    replace(target, with: picked)
                }
            } else {
                ExercisePickerView(singleSelection: true, excludeYogaPoses: true, context: exercisesInRoutine, history: allWorkouts) { picked in
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
            ExerciseDetailView(exerciseID: exerciseID, workouts: allWorkouts, exercises: exercises)
        }
    }

    private var mainScroll: some View {
        ScrollView(showsIndicators: false) {
            // Lazy, matching the live logger: a plain VStack used to build
            // every ExerciseEditRow up front regardless of scroll position,
            // so any edit anywhere in the routine (add set, type a target,
            // toggle a superset) re-diffed the entire off-screen list too.
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                header

                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        FieldLabel("Routine name")
                        DarkTextField(text: $routine.name, placeholder: "Routine name")
                        FieldLabel("Notes")
                        DarkTextField(text: Binding(
                            get: { routine.notes ?? "" },
                            set: { routine.notes = $0.isEmpty ? nil : $0 }
                        ), placeholder: "Add notes", axis: .vertical)
                    }
                }

                SectionHeader("Exercises")

                ForEach(sortedExercises) { re in
                    ExerciseEditRow(
                        routineExercise: re,
                        exercise: exercises.first { $0.id == re.exerciseID },
                        availableSupersetGroups: supersetGroups,
                        onShowDetail: { detailExerciseID = $0 },
                        onAssignSuperset: { assignSuperset($0, to: re) },
                        onCreateSuperset: { assignSuperset(nextSupersetGroup(), to: re) },
                        onUngroupSuperset: { ungroupSuperset($0) },
                        onReplace: { replaceTarget = re },
                        onRemove: { remove(re) },
                        onReorderDragChanged: { fingerY in reorderDragChanged(re, fingerY: fingerY) },
                        onReorderDragEnded: { reorderDragEnded() },
                        onAccessibilityMoveBy: { offset in accessibilityMoveExercise(re.id, by: offset) }
                    )
                }

                SecondaryButton(title: "Add Exercise", systemImage: "plus") { showPicker = true }
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
    }

    /// One continuous gesture from a row's reorder handle. UIKit calls this
    /// once when the stationary hold recognizes, then again for movement.
    private func reorderDragChanged(_ re: RoutineExerciseModel, fingerY: CGFloat) {
        if let reorderSession {
            guard reorderSession.heldID == re.id else { return }
            reorderSession.fingerGlobalY = fingerY
            return
        }

        hideKeyboard()
        let exerciseNames = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0.name) })
        let rows = sortedExercises.map {
            ReorderCollapseOverlay.Row(
                id: $0.id,
                name: exerciseNames[$0.exerciseID] ?? "Exercise"
            )
        }
        withAnimation(.snappy(duration: 0.2)) {
            reorderSession = ExerciseReorderSession(
                heldID: re.id,
                fingerGlobalY: fingerY,
                rows: rows
            )
        }
    }

    private func reorderDragEnded() {
        guard let reorderSession else { return }
        if reorderSession.didMove {
            let exercisesByID = Dictionary(uniqueKeysWithValues: routine.exercises.map { ($0.id, $0) })
            for (index, row) in reorderSession.rows.enumerated() {
                exercisesByID[row.id]?.position = index
            }
            save()
        }
        withAnimation(.snappy(duration: 0.25)) { self.reorderSession = nil }
    }

    private var header: some View {
        HStack {
            // Back offers to save or discard when the routine changed — it no
            // longer silently saves, so Save actually means something.
            CircleIconButton(systemImage: "chevron.left", label: "Back") {
                if let entrySnapshot, entrySnapshot != RoutineSnapshot(of: routine) {
                    showDiscardConfirm = true
                } else if isNew {
                    // Untouched placeholder — silently clean it up.
                    discardNewRoutine()
                } else {
                    dismiss()
                }
            }
            Spacer()
            Text("Edit Routine").font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            Button("Save") { saveNow(); dismiss() }
                .font(.bodyStrong).foregroundStyle(theme.accent)
        }
        .padding(.top, Space.sm)
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

    /// VoiceOver fallback for the drag: step a row one slot at a time.
    private func accessibilityMoveExercise(_ id: UUID, by offset: Int) {
        var rows = sortedExercises
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
        let previous = exercises.first { $0.id == target.exerciseID }
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
        save()
    }

    private func add(_ exercise: ExerciseLibraryModel) {
        withAnimation(reduceMotion ? Motion.reduced : Motion.entrance) {
            let rowExercise = exercise.isYoga ? YogaPoseCatalog.sessionExercise(in: modelContext) : exercise
            let re = RoutineExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: rowExercise.id,
                position: routine.exercises.count
            )
            modelContext.insert(re)
            re.sets = defaultTargetSets(for: rowExercise)
            if exercise.isYoga {
                re.yogaFlowJSON = YogaFlowPlan.fromSelectedPoses([exercise])?.encodedJSON()
            }
            routine.exercises.append(re)
            save()
        }
    }

    /// The starter target rows an exercise gets when added: one rep set for
    /// lifts, one 30-min duration target for cardio, none for yoga (the
    /// session's duration comes from its flow).
    private func defaultTargetSets(for exercise: ExerciseLibraryModel) -> [RoutineSetModel] {
        switch exercise.modality {
        case .yoga:
            return []
        case .cardio:
            let target = RoutineSetModel(userID: ForgeFitDemo.userID, position: 0, targetDurationSeconds: 1_800)
            modelContext.insert(target)
            return [target]
        case .strength:
            let target = RoutineSetModel(userID: ForgeFitDemo.userID, position: 0)
            modelContext.insert(target)
            return [target]
        }
    }

    private func remove(_ re: RoutineExerciseModel) {
        withAnimation(reduceMotion ? Motion.reduced : Motion.stateChange) {
            modelContext.delete(re)
            for (i, e) in sortedExercises.filter({ $0.id != re.id }).enumerated() { e.position = i }
            save()
        }
    }

    /// Debounced, matching the live logger's save discipline: a synchronous
    /// `modelContext.save()` re-publishes this screen's own root
    /// `allWorkouts` @Query (O(total history) on the main thread), and doing
    /// that on every structural tap or reorder move landed exactly when the
    /// thumb came down to scroll — eating the first pan gesture. The model
    /// mutates in memory immediately (the UI reads models, not the store);
    /// only the store write is deferred. Durability is unchanged: Save
    /// buttons, dismissal, and app-background all flush synchronously.
    private func save() {
        routine.updatedAt = Date()
        scheduleSave()
    }

    private func scheduleSave() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveNow()
            deferredSaveTask = nil
        }
    }

    /// Flush a pending debounced save right now; no-op when nothing is queued.
    private func flushPendingSave() {
        guard deferredSaveTask != nil else { return }
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        saveNow()
    }

    private func saveNow() {
        routine.updatedAt = Date()
        try? modelContext.save()
    }

    /// A brand-new routine the user backs out of is junk — soft-delete it
    /// (matching every other routine delete, so tombstones sync cleanly) and
    /// leave the library exactly as it was before "New Routine" was tapped.
    private func discardNewRoutine() {
        let now = Date()
        routine.updatedAt = now
        routine.deletedAt = now
        _ = modelContext.saveReportingFailure()
        dismiss()
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
        let rows = sortedExercises
        var output: [RoutineExerciseModel] = []
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
}

// MARK: - Exercise edit row

private struct ExerciseEditRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var routineExercise: RoutineExerciseModel
    let exercise: ExerciseLibraryModel?
    let availableSupersetGroups: [Int]
    let onShowDetail: (UUID) -> Void
    let onAssignSuperset: (Int?) -> Void
    let onCreateSuperset: () -> Void
    let onUngroupSuperset: (Int) -> Void
    let onReplace: () -> Void
    let onRemove: () -> Void
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
    /// Debounced-save plumbing for "Add Set", mirroring the live logger's
    /// `ExerciseLogCard` (recompute()/scheduleSave()/saveNow()). A synchronous
    /// `modelContext.save()` on every tap was the lag: a blocking SwiftData
    /// store write (plus its CloudKit change-tracking bookkeeping) landing in
    /// the same run loop turn as the tap, before the new row could paint.
    @State private var deferredSaveTask: Task<Void, Never>?

    private var sortedSets: [RoutineSetModel] { routineExercise.sets.sorted { $0.position < $1.position } }
    private var currentProgressionRule: ProgressionRule? { ProgressionRule.decode(from: routineExercise.progressionRuleJSON) }
    private var isCardio: Bool { exercise?.isCardio == true }
    private var isYoga: Bool { exercise?.isYoga == true }
    private var displayUnit: WeightUnit { exercise?.effectiveWeightUnit ?? Fmt.unit }

    /// The ⋯ overflow menu, section-for-section identical to the old SwiftUI
    /// Menu (supersets | add sets | progression submenu | replace | remove).
    private var overflowMenuSections: [[ScrollSafeMenuItem]] {
        let supersets = SupersetUI.scrollSafeMenuItems(
            currentGroup: routineExercise.supersetGroup,
            availableGroups: availableSupersetGroups,
            onAssign: onAssignSuperset,
            onCreate: onCreateSuperset,
            onUngroup: onUngroupSuperset
        )

        var sections = [supersets]
        if !isCardio && !isYoga {
            sections.append([
                ScrollSafeMenuItem(title: "Add Warm-up Set", systemImage: "flame") { addSet(type: .warmup) },
                ScrollSafeMenuItem(title: "Add Working Set", systemImage: "plus") { addSet(type: .working) }
            ])
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
                    VStack(alignment: .leading, spacing: 4) {
                        if let exercise {
                            Button {
                                onShowDetail(exercise.id)
                            } label: {
                                ExerciseNameLabel(name: exercise.name)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Exercise").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        }
                        if let group = routineExercise.supersetGroup {
                            SupersetChip(group: group)
                        }
                        if let rule = currentProgressionRule, rule != .doubleProgression {
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

                if isYoga {
                    yogaTargetEditor
                } else if isCardio {
                    cardioTargetEditor
                    if let exercise {
                        MuscleChips(muscles: CardioKind.infer(name: exercise.name, equipment: exercise.equipment).musclesWorked)
                    }
                } else {
                    strengthSetEditor
                }
            }
        }
        .onDisappear { flushPendingSave() }
        // Backgrounding mid-edit must not sit on a 2s debounce.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { flushPendingSave() }
        }
    }

    private var strengthSetEditor: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("SET").frame(width: 40, alignment: .leading)
                Text("REPS").frame(maxWidth: .infinity, alignment: .leading)
                Text(displayUnit.suffix.uppercased()).frame(maxWidth: .infinity, alignment: .leading)
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
                        workingNumber: workingNumber(upTo: index),
                        displayUnit: displayUnit,
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

    /// Yoga block target: the attached flow (or the pose's default hold) and
    /// the door into the flow builder. No set rows — yoga is session-shaped.
    private var yogaTargetEditor: some View {
        let plan = YogaFlowPlan.decode(from: routineExercise.yogaFlowJSON)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 8) {
                Image(systemName: (plan?.style ?? .hatha).systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.accent)
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
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routine-yoga-flow-builder")
            .sheet(isPresented: $showFlowBuilder) {
                YogaFlowBuilderView(planJSON: routineExercise.yogaFlowJSON) { json in
                    routineExercise.yogaFlowJSON = json
                    save()
                }
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

    private var cardioTargetEditor: some View {
        let kind = CardioKind.infer(name: exercise?.name ?? "Cardio", equipment: exercise?.equipment)
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: 8) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.secondaryAccent)
                Text("Cardio target")
                    .font(.tag)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
            }

            if let first = sortedSets.first {
                CardioDurationTargetRow(set: first)
            }

            // Pacing goal — a steady zone lock or structured intervals. Both
            // live behind one CTA so zone locking is discoverable without being
            // mislabeled as an "interval".
            Button {
                showIntervalBuilder = true
            } label: {
                let plan = IntervalPlan.decode(from: routineExercise.intervalPlanJSON)
                HStack(spacing: 6) {
                    Image(systemName: cardioGoalIcon(plan))
                        .font(.system(size: 12, weight: .bold))
                    Text(cardioGoalLabel(plan))
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).opacity(0.7)
                    Spacer()
                }
                .foregroundStyle(theme.secondaryAccent)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showIntervalBuilder) {
                IntervalPlanBuilderView(routineExercise: routineExercise)
            }

            Text(kind.metricLabels.joined(separator: " · "))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryAccent)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: ensureCardioTarget)
    }

    /// Icon for the cardio pacing-goal CTA: a target for a steady zone lock,
    /// a bar chart for structured intervals, a plain target when unset.
    private func cardioGoalIcon(_ plan: IntervalPlan?) -> String {
        if plan?.hasSteps == true { return "chart.bar.doc.horizontal" }
        return "target"
    }

    /// Label for the cardio pacing-goal CTA, reflecting whichever shape is set.
    private func cardioGoalLabel(_ plan: IntervalPlan?) -> String {
        if let plan, plan.hasSteps {
            let workCount = plan.steps.count { $0.kind == .work }
            let tail = plan.hasDistanceSteps
                ? "\(IntervalPlan.metricDistance(plan.totalDistanceMeters)) of reps"
                : "\(Fmt.durationShort(plan.totalSeconds)) total"
            return "Intervals: \(workCount)× · \(tail)"
        }
        if let plan, plan.isMeaningful {
            return plan.displaySummary
        }
        return "Add goal, zone lock, or intervals"
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
        // Debounced, not the synchronous save() every other mutation here
        // uses — see `deferredSaveTask` above.
        scheduleSave()
    }

    private func scheduleSave() {
        deferredSaveTask?.cancel()
        deferredSaveTask = Task { @MainActor in
            // 2s, not 350ms, for the live logger's reason: a save re-publishes
            // the editor's root all-workouts @Query (O(total history) on the
            // main thread), and at +350ms it landed exactly when the thumb
            // came down to scroll after an edit — eating the first pan
            // gesture. 2s parks it in idle time; row-exit, app-background,
            // and the Save/dismiss paths all flush immediately.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            saveNow()
            deferredSaveTask = nil
        }
    }

    /// Flush a pending debounced save right now; no-op when nothing is queued
    /// (so row recycling during a plain scroll never triggers save/publish).
    private func flushPendingSave() {
        guard deferredSaveTask != nil else { return }
        deferredSaveTask?.cancel()
        deferredSaveTask = nil
        saveNow()
    }

    private func saveNow() {
        try? modelContext.save()
    }

    private func addDropSet(below set: RoutineSetModel, index: Int) {
        let drop = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            setType: .drop,
            targetRepsLow: nil,
            targetRepsHigh: nil,
            targetWeight: set.targetWeight.map(droppedWeight),
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
                set.targetWeight = droppedWeight(above)
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
        modelContext.delete(set)
        renumber(sortedSets.filter { $0.id != set.id })
        save()
    }

    private func workingNumber(upTo index: Int) -> Int {
        sortedSets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
    }

    private func renumber(_ rows: [RoutineSetModel]) {
        for (index, row) in rows.enumerated() { row.position = index }
    }

    private func droppedWeight(_ weight: Double) -> Double {
        let displayed = displayUnit.displayValue(fromKilograms: weight)
        let step = displayUnit == .lb ? 5.0 : 2.5
        let minimum = displayUnit == .lb ? 5.0 : 2.5
        let dropped = max(minimum, (displayed * 0.75 / step).rounded() * step)
        return displayUnit.kilograms(fromDisplayValue: dropped)
    }

    private func ensureCardioTarget() {
        if sortedSets.isEmpty {
            let set = RoutineSetModel(userID: ForgeFitDemo.userID, position: 0, targetDurationSeconds: 1_800)
            modelContext.insert(set)
            routineExercise.sets = [set]
            save()
        }
    }

    /// Every row mutation routes through the debounce: the model updates in
    /// memory instantly (that's what the UI renders); only the store write —
    /// and its @Query republish — waits for idle time.
    private func save() {
        routineExercise.updatedAt = Date()
        routineExercise.routine?.updatedAt = Date()
        scheduleSave()
    }
}

/// One editable target-set row. Split into its own view so `@Bindable`
/// projects bindings for the numeric fields.
private struct SetTargetEditRow: View {
    @Environment(\.theme) private var theme
    @Bindable var set: RoutineSetModel
    let workingNumber: Int
    let displayUnit: WeightUnit
    let onChange: () -> Void
    let onSetType: (SetType) -> Void
    let onAddDrop: () -> Void
    let onDelete: () -> Void

    private var style: SetTypeStyle { SetTypeStyle.of(self.set.setType) }
    private var isDrop: Bool { self.set.setType == .drop }

    var body: some View {
        if set.setType.isBlockType {
            blockPlanner
        } else {
            standardRow
        }
    }

    private var standardRow: some View {
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
                OptionalLoadField(placeholder: displayUnit.suffix, value: $set.targetWeight, unit: displayUnit, onChange: onChange)
            } else {
                OptionalRepsTargetField(
                    low: $set.targetRepsLow,
                    high: $set.targetRepsHigh,
                    onChange: onChange
                )
                OptionalLoadField(placeholder: displayUnit.suffix, value: $set.targetWeight, unit: displayUnit, onChange: onChange)
                    .accessibilityIdentifier("routine-set-weight-\(set.id.uuidString)")
                OptionalDoubleField(placeholder: "RPE", value: $set.targetRPE, width: 48, onChange: onChange)
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
        OptionalLoadField(placeholder: displayUnit.suffix, value: $set.targetWeight, unit: displayUnit, onChange: onChange)
            .frame(width: 64)
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
            ), onChange: onChange)
            Text("sec")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CardioDurationTargetRow: View {
    @Environment(\.theme) private var theme
    @Bindable var set: RoutineSetModel

    var body: some View {
        HStack(spacing: 8) {
            Text("Goal")
                .font(.rowValue)
                .foregroundStyle(theme.secondaryAccent)
                .frame(width: 52, alignment: .leading)
            OptionalIntField(placeholder: "Minutes", value: Binding(
                get: { set.targetDurationSeconds.map { $0 / 60 } },
                set: { set.targetDurationSeconds = $0.map { $0 * 60 } }
            ))
            .accessibilityIdentifier("cardio-target-minutes")
            Text("min")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            // Duration and distance are peer goals — either, both, or
            // neither. Distance starts the session with a live goal ring,
            // never a pre-filled logged distance.
            OptionalDecimalField(placeholder: "Distance", value: Binding(
                get: { set.targetDistanceMeters.map { Fmt.distanceUnit.distance(fromMeters: $0) } },
                set: { set.targetDistanceMeters = $0.map { Fmt.distanceUnit.meters(fromDistance: $0) } }
            ))
            .accessibilityIdentifier("cardio-target-distance")
            Text(Fmt.distanceUnit.abbreviation)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
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

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 13).padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct OptionalIntField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Int?
    var width: CGFloat? = nil
    var onChange: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value.map(String.init) ?? "" },
            set: { value = Int($0); onChange() }
        ))
        .keyboardType(.numberPad)
        .font(.bodyStrong)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    var onChange: () -> Void = {}
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Reps", text: Binding(
            get: { isFocused ? draft : formattedValue },
            set: { text in
                draft = text
                parse(text)
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
        .onAppear { draft = formattedValue }
        .onChange(of: isFocused) { _, focused in
            if focused {
                draft = formattedValue
            } else {
                draft = formattedValue
            }
        }
        .onChange(of: low) { _, _ in
            if !isFocused { draft = formattedValue }
        }
        .onChange(of: high) { _, _ in
            if !isFocused { draft = formattedValue }
        }
    }

    private var formattedValue: String {
        if let low, let high, high != low { return "\(low)-\(high)" }
        return low.map(String.init) ?? ""
    }

    private func parse(_ text: String) {
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
    var onChange: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: Binding(
            get: { value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "" },
            set: { value = Double($0); onChange() }
        ))
        .keyboardType(.decimalPad)
        .font(.bodyStrong)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct OptionalLoadField: View {
    @Environment(\.theme) private var theme
    let placeholder: String
    @Binding var value: Double?
    let unit: WeightUnit
    var width: CGFloat? = nil
    var onChange: () -> Void = {}

    /// Raw text while focused; formatted from the model otherwise. A
    /// get-formats/set-parses round trip erases a trailing "." the moment
    /// it's typed ("62." re-renders as "62"), making fractional loads
    /// impossible to enter.
    @State private var draft = ""
    @State private var draftActive = false
    @FocusState private var focused: Bool

    var body: some View {
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
        .keyboardType(.decimalPad)
        .font(.bodyStrong)
        .multilineTextAlignment(.center)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
