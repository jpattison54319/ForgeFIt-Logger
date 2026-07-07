import ForgeCore
import ForgeData
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

    @State private var showFinishConfirm = false
    @State private var reordering = false
    @State private var showAddPicker = false
    @State private var replaceTarget: WorkoutExerciseModel?
    @State private var showPostWorkoutSummary = false
    @State private var detailExercise: ExerciseLibraryModel?
    /// Best prior values per exercise — the bar a set must clear to earn a
    /// record award. Computed once; history doesn't change mid-session.
    @State private var recordBaselines: [UUID: ExerciseRecordBaseline] = [:]
    @State private var widgetSnapshotTask: Task<Void, Never>?
    @State private var previousSetsByExerciseID: [UUID: [SetModel]] = [:]
    @State private var liveStats = WorkoutLiveStats()
    @State private var inputRouter = SetInputRouter()
    @AppStorage("showRPEInLogger") private var showRPEInLogger = false

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
            } else {
                loggerScroll
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
                }
            }
        }
        .environment(inputRouter)
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
        .confirmationDialog("Finish this workout?", isPresented: $showFinishConfirm, titleVisibility: .visible) {
            Button("Review Summary") { showPostWorkoutSummary = true }
            Button("Cancel", role: .cancel) {}
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
        .sheet(isPresented: $showAddPicker) {
            ExercisePickerView(context: exercisesInWorkout, history: history) { added in addExercises(added) }
        }
        .sheet(item: $replaceTarget) { target in
            ExercisePickerView(singleSelection: true, context: exercisesInWorkout, history: history) { picked in
                if let first = picked.first { replace(target, with: first) }
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
                    let ex = exercises.first { $0.id == we.exerciseID }
                    if ex?.isCardio == true {
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
                            onRemove: { removeExercise(we) }
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
                            showRPE: showRPEInLogger,
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
                            onReorder: { withAnimation { reordering = true } }
                        )
                    }
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
                HStack(spacing: Space.md) {
                    if let ex = exercises.first(where: { $0.id == we.exerciseID }) {
                        ExerciseThumbnail(exercise: ex, size: 40)
                        Text(ex.name).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "line.3.horizontal").foregroundStyle(theme.textTertiary)
                }
                .listRowBackground(theme.surface)
                .listRowSeparatorTint(theme.separator)
            }
            .onMove(perform: moveExercises)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .environment(\.editMode, .constant(.active))
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
                } else {
                    CircleIconButton(systemImage: isHistoricalEdit ? "xmark" : "chevron.down") {
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
                        LiveHeartRatePill(heartRate: WatchLink.shared.liveMetrics?.heartRate)
                        RestTimerPill()
                    }
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
                                .frame(width: 40, height: 40)
                        }
                        .glassEffect(.regular.interactive(), in: Circle())
                    }
                    Button {
                        if isHistoricalEdit {
                            saveHistoricalEdit()
                        } else {
                            showFinishConfirm = true
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

    private var isPureCardio: Bool {
        !workout.exercises.isEmpty && workout.exercises.allSatisfy { we in
            exercises.first { $0.id == we.exerciseID }?.isCardio == true
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
            if isPureCardio {
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
                StatColumn(label: "Volume", value: Fmt.volume(liveStats.volume))
                StatColumn(label: "Sets", value: "\(liveStats.completedSets)")
                if !isHistoricalEdit, let hr = WatchLink.shared.liveMetrics?.heartRate {
                    StatColumn(label: "HR", value: "\(hr)", valueColor: theme.danger)
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

    private struct WorkoutLiveStats {
        var volume: Double = 0
        var completedSets: Int = 0
    }

    private struct ReferenceCaches {
        var recordBaselines: [UUID: ExerciseRecordBaseline]
        var previousSetsByExerciseID: [UUID: [SetModel]]
    }

    private func refreshReferenceCaches() async {
        let caches = await buildReferenceCaches()
        guard !Task.isCancelled else { return }
        recordBaselines = caches.recordBaselines
        previousSetsByExerciseID = caches.previousSetsByExerciseID
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

    private func makeLiveStats() -> WorkoutLiveStats {
        let completed = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        return WorkoutLiveStats(
            volume: completed.reduce(0) { $0 + ($1.totalVolume ?? 0) },
            completedSets: completed.count
        )
    }

    private func refreshLiveStats() {
        liveStats = makeLiveStats()
    }

    private func addExercises(_ list: [ExerciseLibraryModel]) {
        for exercise in list {
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

    private func replace(_ target: WorkoutExerciseModel, with exercise: ExerciseLibraryModel) {
        let wasCardio = exercises.first { $0.id == target.exerciseID }?.isCardio == true
        target.exerciseID = exercise.id
        target.updatedAt = Date()
        previousSetsByExerciseID[exercise.id] = []
        recordBaselines[exercise.id] = nil
        if exercise.isCardio {
            for set in target.sets {
                modelContext.delete(set)
            }
            target.sets = []
            let existingSession = workout.cardioSessions.first { $0.workoutExerciseID == target.id }
            if existingSession == nil {
                let kind = CardioKind.infer(name: exercise.name, equipment: exercise.equipment)
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
            if wasCardio {
                deleteCardioSessions(for: target.id)
            }
            if target.sets.isEmpty {
                let set = SetModel(userID: ForgeFitDemo.userID, position: 0, weightMode: exercise.defaultWeightMode)
                modelContext.insert(set)
                target.sets = [set]
            } else {
                for set in target.sets { set.weightMode = exercise.defaultWeightMode }
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
        let fallback = set.setType == .drop ? SetType.working.defaultRestSeconds : set.setType.defaultRestSeconds
        let seconds = workoutExercise.restSeconds ?? fallback
        guard let seconds, seconds > 0 else { return }
        RestTimerController.shared.start(seconds: seconds, label: label ?? SetTypeStyle.of(set.setType).label)
    }

    private func publishWorkoutChange() {
        refreshLiveStats()
        WatchLink.shared.publishState()
        WorkoutActivityController.shared.update(workout: workout, exercises: exercises)
        scheduleWidgetSnapshot()
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
            heartRate: WatchLink.shared.liveMetrics?.heartRate
        ))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    private func finishAndDismiss() {
        // Prefer the watch's live session metrics when it has been streaming.
        WorkoutFinisher.finish(
            workout,
            in: modelContext,
            watchMetrics: WatchLink.shared.liveMetrics
        )
        dismiss()
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
    let onSave: () -> Void
    let onCancel: () -> Void

    /// Detected structural drift between this workout and its source routine,
    /// populated when the user taps Save. Non-nil while the "update routine?"
    /// prompt is in flight.
    @State private var routinePlan: RoutineChangeSync.Plan?
    @State private var routineName: String?
    @State private var showRoutineUpdatePrompt = false

    private var completedSets: [SetModel] {
        workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
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
        let priorVolume = previousComparable.exercises.flatMap(\.sets).reduce(0) { $0 + ($1.totalVolume ?? 0) }
        let delta = volume - priorVolume
        guard abs(delta) > 0.1 else { return "Volume matched last time" }
        return "\(delta >= 0 ? "+" : "")\(Fmt.volumeFull(delta)) vs last time"
    }
    private var totalReps: Int {
        completedSets.reduce(0) { $0 + ($1.reps ?? 0) + $1.miniReps.reduce(0, +) }
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
                                StatColumn(label: "Sets", value: "\(completedSets.count)")
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

                    if !awardEntries.isEmpty {
                        awardsCard
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
        onSave()
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

private struct LiveHeartRatePill: View {
    @Environment(\.theme) private var theme
    let heartRate: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11, weight: .bold))
            Text(heartRate.map { "\($0)" } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("BPM")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.textTertiary)
        }
        .foregroundStyle(heartRate == nil ? theme.textSecondary : theme.danger)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background((heartRate == nil ? theme.surfaceElevated : theme.danger.opacity(0.12)))
        .clipShape(Capsule())
        .accessibilityLabel(heartRate.map { "Live heart rate \($0) beats per minute" } ?? "Live heart rate unavailable")
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

private struct ExerciseLogCard: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Bindable var workout: WorkoutModel
    @Bindable var workoutExercise: WorkoutExerciseModel
    let exercise: ExerciseLibraryModel?
    let pinnedNote: UserExerciseNoteModel?
    let previousSets: [SetModel]
    let recordBaseline: ExerciseRecordBaseline?
    let allowsRestTimers: Bool
    let showRPE: Bool
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
    let onReorder: () -> Void

    @State private var deferredSaveTask: Task<Void, Never>?
    /// Set being plate-calculated (barbell-loaded exercises only).
    @State private var plateSet: SetModel?
    @State private var editedSuggestionSetIDs = Set<UUID>()
    /// The one set row whose swipe-to-delete tray is currently open (only one
    /// at a time, Mail-style).
    @State private var openSwipeSetID: UUID?
    @FocusState private var focusedInput: SetInputFocus?
    /// PR awards per set, computed when set data changes rather than on every
    /// body evaluation — focus changes and menu presentations re-render all
    /// visible rows, and running PersonalRecords per row per render caused
    /// visible stutter opening the set-type menu on long workouts.
    @State private var awardsCache: [UUID: [RecordKind]] = [:]

    private var sortedSets: [SetModel] { workoutExercise.sets.sorted { $0.position < $1.position } }
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
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.md) {
                header

                if workoutExercise.notes != nil {
                    StickyNoteView(workoutExercise: workoutExercise, exerciseID: workoutExercise.exerciseID, pinnedNote: pinnedNote)
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
                        SetBlockView(
                            set: set,
                            workoutExercise: workoutExercise,
                            blockNumber: workingNumber(upTo: index, in: sets),
                            previous: blockTemplate(for: set, index: index, in: sets),
                            showWeight: weightHeader != nil,
                            displayUnit: displayUnit,
                            onChange: recompute,
                            onSetType: { set.setType = $0; recompute() },
                            onDelete: { deleteSet(set) }
                        )
                    } else {
                        SetRow(
                            set: set,
                            workingNumber: workingNumber(upTo: index, in: sets),
	                            awards: awardsCache[set.id] ?? [],
	                            previous: previousText(index: index),
	                            previousSet: previousSet(index: index),
	                            isCardio: isCardio,
	                            showWeight: weightHeader != nil,
	                            showRPE: showRPE,
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
                                onSuggestionEdited: { editedSuggestionSetIDs.insert(set.id) },
	                                onMaterializeSuggestion: { materializeSuggestion(for: set, index: index) },
	                            onCompleted: { if allowsRestTimers { onCompletedSet(set) } },
	                            onMatchPrevious: { matchPrevious(set, from: previousSet(index: index)) },
                                onAdvancePastLastField: { focusNextSet(after: index, in: sets) },
	                            onAddDrop: { addDropSet(below: set, index: index) },
	                            onPlates: isBarbellLoaded ? { plateSet = set } : nil,
	                            onDelete: { deleteSet(set) }
	                        )
	                        if set.setType.countsAsWorkingVolume && set.setType != .drop {
	                            HStack {
	                                Spacer()
	                                Button {
	                                    addDropSet(below: set, index: index)
	                                } label: {
	                                    Label("Drop set", systemImage: "arrow.down.right")
	                                        .font(.tag)
	                                        .padding(.vertical, 10)
	                                        .padding(.horizontal, 4)
	                                        .contentShape(Rectangle())
	                                }
	                                .foregroundStyle(theme.accent)
	                            }
	                            .padding(.trailing, 40)
	                        }
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
                        HStack(spacing: 4) {
                            Text(exercise.name)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onLongPressGesture { onReorder() }
            } else {
                Text("Exercise")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .onLongPressGesture { onReorder() }
            }
		    if let group = workoutExercise.supersetGroup {
		        SupersetChip(group: group)
		    }
	            Spacer()
	            // Explicit gap (rather than relying on the outer HStack's
	            // ambient spacing) so both controls can sit at the HIG's
	            // 44x44 minimum without their hit areas overlapping.
	            HStack(spacing: Space.sm) {
	                Button(action: onReorder) {
	                    Image(systemName: "line.3.horizontal")
	                        .font(.bodyStrong)
	                        .foregroundStyle(theme.textTertiary)
	                        .frame(width: 44, height: 44)
	                }
	                .buttonStyle(.plain)
	                .accessibilityLabel("Reorder exercises")
	                Menu {
                    if let exercise {
                        Button("Exercise Details", systemImage: "info.circle") { onShowExerciseDetail(exercise) }
                        Divider()
                    }
                    if workoutExercise.notes == nil {
                        Button("Add Note", systemImage: "note.text") { workoutExercise.notes = ""; try? modelContext.save() }
                    }
                    Button("Add Warm-up Set", systemImage: "flame") { addSet(type: .warmup) }
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
	            Image(systemName: "checkmark").frame(width: 44)
	            Text("SET").frame(width: 40)
	            Text("PREVIOUS")
	                .lineLimit(1)
	                .frame(maxWidth: .infinity, alignment: .leading)
	            if let weightHeader {
                Button(action: toggleExerciseUnit) {
                    HStack(spacing: 3) {
                        Text(weightHeader)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .frame(width: 60)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .accessibilityLabel("Switch \(exercise?.name ?? "exercise") weight unit")
	            }
	            if isCardio { Text("MIN").frame(width: 60) } else { Text("REPS").frame(width: 46) }
	            if showRPE && !isCardio { Text("RPE").frame(width: 40) }
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
            && set.sourceRoutineSetID != nil
            && !editedSuggestionSetIDs.contains(set.id)
    }

    private func suggestedWeight(for set: SetModel, index: Int) -> Double? {
        previousSet(index: index).flatMap { $0.modeWeight ?? $0.weight } ?? set.modeWeight ?? set.weight
    }

    private func suggestedReps(for set: SetModel, index: Int) -> Int? {
        previousSet(index: index)?.reps ?? set.reps
    }

    private func suggestedDurationSeconds(for set: SetModel, index: Int) -> Int? {
        previousSet(index: index)?.durationSeconds ?? set.durationSeconds
    }

    private func materializeSuggestion(for set: SetModel, index: Int) {
        guard usesSuggestedValues(for: set) else { return }
        editedSuggestionSetIDs.insert(set.id)
        if let previous = previousSet(index: index) {
            set.weight = previous.weight ?? set.weight
            set.reps = previous.reps ?? set.reps
            set.durationSeconds = previous.durationSeconds ?? set.durationSeconds
            set.rpe = previous.rpe ?? set.rpe
            set.rir = previous.rir ?? set.rir
        }
    }

	    private func previousText(index: Int) -> String {
	        guard index < previousSets.count else { return "—" }
	        let prev = previousSets[index]
        let w = Fmt.load(prev.modeWeight ?? prev.weight, unit: displayUnit)
        let r = prev.reps.map(String.init) ?? "—"
        // No unit suffix here: the weight column header already labels the unit,
        // and dropping it keeps the value legible when the RPE column is on.
	        return isCardio ? Fmt.durationShort(prev.durationSeconds) : "\(w) × \(r)"
	    }

	    private func previousSet(index: Int) -> SetModel? {
	        index < previousSets.count ? previousSets[index] : nil
	    }

    private func matchPrevious(_ set: SetModel, from previous: SetModel?) {
        guard let previous else { return }
        set.weight = previous.weight
        set.addedWeight = previous.addedWeight
        set.assistanceWeight = previous.assistanceWeight
        set.reps = previous.reps
        set.durationSeconds = previous.durationSeconds
        set.rpe = previous.rpe
        set.rir = previous.rir
        set.recomputeDerivedMetrics()
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
        try? modelContext.save()
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

/// Mail-style swipe-to-delete for set rows. These rows live in a plain
/// `LazyVStack`, not a `List`, so SwiftUI's `.swipeActions` isn't available —
/// this is the hand-rolled equivalent. Swipe left to reveal a red trash tray
/// (tap it to delete) or keep swiping past the commit threshold to delete
/// outright. The set menu keeps a "Delete Set" item as the accessible path.
///
/// The drag is gated on horizontal-dominant movement with a non-trivial
/// `minimumDistance` so taps, typing, and vertical scrolling are left to the
/// row's controls and the enclosing scroll view.
private struct SwipeToDeleteRow<Content: View>: View {
    @Environment(\.theme) private var theme
    let isOpen: Bool
    let onOpenChange: (Bool) -> Void
    let onDelete: () -> Void
    private let content: Content

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1

    init(
        isOpen: Bool,
        onOpenChange: @escaping (Bool) -> Void,
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isOpen = isOpen
        self.onOpenChange = onOpenChange
        self.onDelete = onDelete
        self.content = content()
    }

    /// Snap-open reveals ~⅓ of the row (min 88pt so the trash is a comfy tap).
    private var revealWidth: CGFloat { min(width, max(88, width / 3)) }
    /// Swiping past 60% of the row commits the delete outright.
    private var commitWidth: CGFloat { width * 0.6 }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: deleteWithAnimation) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: max(0, -offset))
                    .frame(maxHeight: .infinity)
                    .background(theme.danger)
                    .clipped()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete set")
            .allowsHitTesting(offset < -4)

            content
                .background(widthReader)
                .offset(x: offset)
                // Simultaneous, not exclusive: an exclusive DragGesture claims
                // the touch stream even for the vertical drags its onChanged
                // ignores, which starved ScrollView's pan whenever a scroll
                // began on a set row or one of its text fields. The
                // horizontal-dominant guard below still keeps casual scrolls
                // from opening the tray.
                .simultaneousGesture(swipe)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: isOpen) { _, open in
            if !open, offset != 0 {
                withAnimation(.snappy(duration: 0.22)) { offset = 0 }
            }
        }
    }

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { width = max(geo.size.width, 1) }
                .onChange(of: geo.size.width) { _, w in width = max(w, 1) }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Horizontal-dominant, leftward drags only — vertical stays with
                // the scroll view, taps stay with the row's controls.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isOpen ? -revealWidth : 0
                offset = min(0, max(-width, base + value.translation.width))
            }
            .onEnded { value in
                let base: CGFloat = isOpen ? -revealWidth : 0
                let end = base + value.translation.width
                if -end > commitWidth {
                    deleteWithAnimation()
                } else if -end > revealWidth * 0.5 {
                    withAnimation(.snappy(duration: 0.22)) { offset = -revealWidth }
                    onOpenChange(true)
                } else {
                    withAnimation(.snappy(duration: 0.22)) { offset = 0 }
                    onOpenChange(false)
                }
            }
    }

    private func deleteWithAnimation() {
        withAnimation(.snappy(duration: 0.22)) {
            offset = -width
        } completion: {
            onDelete()
        }
    }
}

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
    @Bindable var set: SetModel
    @State private var weightDraft = ""
    @State private var primaryDraft = ""
    @State private var rpeDraft = ""
    @State private var editedDraftFields = Set<SetInputField>()
    let workingNumber: Int
    /// Records this set currently holds — renders the subtle gold strip.
    var awards: [RecordKind] = []
    let previous: String
    let previousSet: SetModel?
    let isCardio: Bool
    let showWeight: Bool
    let showRPE: Bool
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
    var onSuggestionEdited: () -> Void = {}
    var onMaterializeSuggestion: () -> Void = {}
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
        onSuggestionEdited: @escaping () -> Void = {},
        onMaterializeSuggestion: @escaping () -> Void = {},
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
        self.onSuggestionEdited = onSuggestionEdited
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
        guard let rpe = set.rpe else { return false }
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
                    .frame(width: 44, height: 44)
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
                ForEach(SetType.allCases, id: \.self) { type in
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
                    .frame(width: isDrop ? 32 : 40, height: 30)
                    .background(hasBadge ? style.color.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    // 44pt hit target; the visual pill stays 30pt.
                    .frame(height: 44)
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
                ), placeholder: suggestedWeightText, width: 60, field: .weight)
            }

            if isCardio {
                numberField(text: Binding(
                    get: { primaryDraft },
                    set: { editDraft(.primary, value: $0) }
                ), placeholder: suggestedDurationText, width: 60, field: .primary, keyboardType: .numberPad)
            } else {
                numberField(text: Binding(
                    get: { primaryDraft },
                    set: { editDraft(.primary, value: $0) }
                ), placeholder: suggestedRepsText, width: 46, field: .primary, keyboardType: .numberPad)
            }

            if showRPE && !isCardio {
                rpePickerField(width: 40)
            }
        }
    }

    /// RPE below 6 is stored as 5 and shown as "W" — warm-up effort, far from
    /// failure, where finer grading adds noise instead of signal. The option
    /// list + warm-up value live on `RPEQuickPick`.

    private var firstInputField: SetInputField {
        showWeight ? .weight : .primary
    }

    private var weightText: String {
        if usesSuggestedValues, let suggestedWeight {
            return Fmt.load(suggestedWeight, unit: displayUnit)
        }
        return set.modeWeight.map { Fmt.load($0, unit: displayUnit) } ?? ""
    }

    private var primaryText: String {
        if isCardio {
            if usesSuggestedValues, let suggestedDurationSeconds {
                return String(suggestedDurationSeconds / 60)
            }
            return set.durationSeconds.map { String($0 / 60) } ?? ""
        }
        if usesSuggestedValues, let suggestedReps {
            return String(suggestedReps)
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
            set.completedAt = nil
            set.recomputeDerivedMetrics()
            onChange()
        } else {
            completeSet()
        }
    }

    private func completeSet() {
        commitFocusedDraft()
        onMaterializeSuggestion()
        set.completedAt = completionDate ?? Date()
        set.recomputeDerivedMetrics()
        onChange()
        onCompleted()
    }

    private func setRPE(_ value: Double) {
        set.rpe = value
        rpeDraft = formattedRPE(value)
        onChange()
    }

    private func clearRPE() {
        set.rpe = nil
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
        if usesSuggestedValues {
            onMaterializeSuggestion()
        }
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
        if usesSuggestedValues {
            onMaterializeSuggestion()
        }
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
        if usesSuggestedValues {
            onSuggestionEdited()
        }
        guard !sameLoad(set.modeWeight, next) else { return }
        onSuggestionEdited()
        set.setModeWeight(next)
        onChange()
    }

    private func commitPrimaryDraft() {
        if isCardio {
            let next = parsedInt(primaryDraft).map { $0 * 60 }
            if usesSuggestedValues {
                onSuggestionEdited()
            }
            guard set.durationSeconds != next else { return }
            onSuggestionEdited()
            set.durationSeconds = next
        } else {
            let next = parsedInt(primaryDraft)
            if usesSuggestedValues {
                onSuggestionEdited()
            }
            guard set.reps != next else { return }
            onSuggestionEdited()
            set.reps = next
        }
        onChange()
    }

    private func commitRPEDraft() {
        let next = parsedRPE(rpeDraft)
        guard !sameLoad(set.rpe, next) else { return }
        set.rpe = next
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

    private var rpeDisplay: String {
        guard let rpe = set.rpe else { return "—" }
        if rpe < 6 { return "W" }
        return formattedRPE(rpe)
    }

    private var rpeText: String {
        return set.rpe.map(formattedRPE) ?? ""
    }

    private func rpeOptionLabel(_ value: Double) -> String {
        switch value {
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
        .frame(width: width, height: 44)
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
            if set.rpe != nil {
                Divider()
                Button("Clear RPE", role: .destructive, action: clearRPE)
            }
        } label: {
            Text(rpeDisplay)
                .font(.bodyStrong)
                .foregroundStyle(set.rpe == nil ? theme.textTertiary : theme.textPrimary)
                .frame(width: width, height: 44)
                .background(theme.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("RPE")
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
            "RPE"
        }
    }

}

