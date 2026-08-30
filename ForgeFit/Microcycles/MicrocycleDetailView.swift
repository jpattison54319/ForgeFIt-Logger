import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MicrocycleDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let trackingID: UUID

    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var trackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var windows: [MicrocycleWindowModel]
    @Query(sort: \RestDayModel.date, order: .reverse)
    private var restDays: [RestDayModel]
    @Query(sort: \WorkoutModel.startedAt, order: .reverse)
    private var workouts: [WorkoutModel]
    @Query(sort: \RoutineModel.position)
    private var routines: [RoutineModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse)
    private var alternations: [RoutineAlternationModel]
    @Query private var exercises: [ExerciseLibraryModel]
    @Query private var setupNotes: [UserExerciseNoteModel]

    @State private var showingRestSheet = false
    @State private var showingEndConfirmation = false
    @State private var showingRestartConfirmation = false
    @State private var showingEditTracking = false
    @State private var showingHistoryEducation = false
    @State private var opensHistoryAfterEducation = false
    @State private var actionError: String?
    @State private var selectedDay: MicrocycleDaySelection?
    @State private var draggedRestDayID: UUID?
    @State private var previewPlanItemIDs: [UUID] = []

    private var tracking: MicrocycleTrackingModel? {
        trackings.first { $0.id == trackingID && $0.deletedAt == nil }
    }

    private var trackingWindows: [MicrocycleWindowModel] {
        windows.filter { $0.trackingID == trackingID && $0.deletedAt == nil }
    }

    private var currentWindow: MicrocycleWindowModel? {
        guard let tracking else { return nil }
        return MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: trackingWindows
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                if let tracking {
                    if tracking.needsAttention {
                        needsAttentionCard(tracking)
                    } else if let currentWindow {
                        currentCard(tracking: tracking, window: currentWindow)
                    }
                    historySection(tracking: tracking)
                    if tracking.isActive || tracking.needsAttention {
                        Button("Stop Tracking", systemImage: "stop.fill", role: .destructive) {
                            showingEndConfirmation = true
                        }
                        .font(.bodyStrong)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.md)
                        .accessibilityIdentifier("stop-microcycle-tracking")
                    }
                } else {
                    EmptyStateCard(
                        title: "Microcycle unavailable",
                        message: "This tracking history is no longer available.",
                        systemImage: "calendar.badge.exclamationmark"
                    )
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle(tracking?.folderName ?? "Microcycle")
        .toolbar {
            if let tracking, tracking.isActive || tracking.needsAttention {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Microcycle options", systemImage: "ellipsis") {
                        Button("Edit Day Target", systemImage: "calendar") {
                            showingEditTracking = true
                        }
                        if tracking.isActive, currentWindow != nil {
                            Button(action: addDayToCurrentCycle) {
                                Text("Add 1 Day")
                                Text("This cycle only")
                                Image(systemName: "calendar.badge.plus")
                            }
                            if let currentWindow,
                               MicrocycleTrackingService.dayNumber(for: currentWindow) > 1 {
                                Button("Restart at Day 1", systemImage: "arrow.counterclockwise") {
                                    showingRestartConfirmation = true
                                }
                                .accessibilityIdentifier("restart-microcycle-at-day-one")
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("microcycle-options")
                    .confirmationDialog(
                        "Restart this cycle at Day 1?",
                        isPresented: $showingRestartConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Restart Cycle", role: .destructive, action: restartCurrentCycle)
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Today becomes Day 1. Activity from before today stays in your history but no longer counts toward the restarted cycle.")
                    }
                }
            }
        }
        .sheet(isPresented: $showingRestSheet) {
            RestDayLogSheet { date in
                _ = try RestDayService.log(
                    date: date,
                    workouts: workouts,
                    in: modelContext
                )
            }
        }
        .sheet(isPresented: $showingEditTracking) {
            if let tracking {
                MicrocycleTrackingEditView(tracking: tracking) { durationDays in
                    try MicrocycleTrackingService.updateDuration(
                        tracking,
                        durationDays: durationDays,
                        in: modelContext
                    )
                }
            }
        }
        .sheet(item: $selectedDay) { selection in
            if let currentWindow {
                MicrocycleDayDetailSheet(
                    date: selection.date,
                    window: currentWindow,
                    windows: trackingWindows,
                    workouts: workouts,
                    restDays: restDays,
                    exercises: exercises
                )
            }
        }
        .sheet(isPresented: $showingHistoryEducation, onDismiss: finishStopEducation) {
            MicrocycleHistoryEducationSheet(
                onViewHistory: viewHistoryAfterStop,
                onDone: dismissHistoryEducation
            )
            .onAppear(perform: markHistoryEducationShown)
        }
        .navigationDestination(for: MicrocycleHistoryRoute.self) { route in
            switch route {
            case .window(let trackingID, let windowID):
                MicrocycleHistoryWindowDetailView(
                    trackingID: trackingID,
                    windowID: windowID,
                    workouts: workouts,
                    exercises: exercises
                )
            }
        }
        .confirmationDialog(
            "Stop tracking this microcycle?",
            isPresented: $showingEndConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Tracking", role: .destructive, action: endTracking)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Previous windows remain in your history. No workouts are deleted.")
        }
        .alert("Couldn't update microcycle", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
        } message: {
            Text(actionError ?? "")
        }
    }

    private func currentCard(
        tracking: MicrocycleTrackingModel,
        window: MicrocycleWindowModel
    ) -> some View {
        let progress = MicrocycleTrackingService.progress(
            for: window,
            windows: trackingWindows,
            workouts: workouts
        )
        let planProgress = MicrocyclePlanProgress.make(
            window: window,
            routineProgress: progress,
            restDays: restDays
        )
        let displayedItems = displayedPlanItems(planProgress.items)
        let markersByRoutineID = MicrocycleRoutineMarker.markersByRoutineID(
            in: progress.routines.map(\.routine)
        )
        let indexByItemID = Dictionary(
            displayedItems.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let canLogRestToday = !hasRestLoggedToday(for: tracking)
        return Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current window")
                            .font(.headline)
                            .foregroundStyle(theme.textPrimary)
                        Text("Day \(MicrocycleTrackingService.dayNumber(for: window)) of \(MicrocycleTrackingService.windowDurationDays(for: window))")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Text("\(planProgress.completedCount)/\(planProgress.requiredCount)")
                        .font(.headline)
                        .foregroundStyle(planProgress.isComplete ? theme.accent : theme.textPrimary)
                }

                MicrocycleDayStrip(
                    window: window,
                    workouts: workouts,
                    restDays: RestDayService.live(restDays),
                    onSelectDay: selectDay
                )

                VStack(spacing: Space.sm) {
                    ForEach(displayedItems) { item in
                        let itemIndex = indexByItemID[item.id] ?? 0
                        switch item {
                        case .routine(let routine):
                            routineRow(
                                routine,
                                marker: markersByRoutineID[routine.routine.id] ?? "?"
                            )
                            .onDrop(
                                of: [UTType.plainText],
                                delegate: MicrocycleRestReorderDropDelegate(
                                    targetID: item.id,
                                    draggedRestDayID: $draggedRestDayID,
                                    previewItemIDs: $previewPlanItemIDs,
                                    reduceMotion: reduceMotion,
                                    onCommit: movePlannedRestDay
                                )
                            )
                        case .restDay(let restDay):
                            MicrocyclePlannedRestDayRow(
                                restDay: restDay,
                                position: itemIndex + 1,
                                itemCount: planProgress.items.count,
                                canMoveUp: itemIndex > 0,
                                canMoveDown: itemIndex < planProgress.items.count - 1,
                                canLogToday: canLogRestToday,
                                isDragging: draggedRestDayID == restDay.id,
                                onLogToday: { logPlannedRestDay(restDay.id) },
                                onMoveUp: { movePlannedRestDay(restDay.id, to: itemIndex - 1) },
                                onMoveDown: { movePlannedRestDay(restDay.id, to: itemIndex + 1) },
                                onRemove: { removePlannedRestDay(restDay.id) },
                                onDragStarted: {
                                    beginDraggingRestDay(restDay.id, items: displayedItems)
                                }
                            )
                            .onDrop(
                                of: [UTType.plainText],
                                delegate: MicrocycleRestReorderDropDelegate(
                                    targetID: item.id,
                                    draggedRestDayID: $draggedRestDayID,
                                    previewItemIDs: $previewPlanItemIDs,
                                    reduceMotion: reduceMotion,
                                    onCommit: movePlannedRestDay
                                )
                            )
                        }
                    }
                }

                MicrocycleRestActionMenu(
                    canAddPlannedRest: window.plannedRestDays.count
                        < MicrocycleTrackingService.maximumPlannedRestDays,
                    onLogAdHoc: showRestSheet,
                    onAddToRoutine: addPlannedRestDay
                )
            }
        }
    }

    private func routineRow(
        _ item: MicrocycleRoutineProgress,
        marker: String
    ) -> some View {
        let alternatingState = RoutineAlternationService.state(
            containing: item.routine.id,
            alternations: alternations,
            routines: routines,
            workouts: workouts
        )
        let startRoutine = alternatingState?.due
            ?? routines.first(where: { $0.id == item.routine.id })
        let completedName = item.completedRoutineID.flatMap { id in
            routines.first(where: { $0.id == id })?.name
                ?? item.routine.memberName(for: id)
        }
        return HStack(spacing: Space.sm) {
            MicrocycleRoutineStatusMarker(
                marker: marker,
                isCompleted: item.isCompleted
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(startRoutine?.name ?? item.routine.name)
                    .font(.body)
                    .foregroundStyle(item.isCompleted ? theme.textSecondary : theme.textPrimary)
                    .lineLimit(1)
                if let completedAt = item.completedAt {
                    Text("Completed\(completedName.map { " \($0)" } ?? "") \(completedAt.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Routine \(marker), \(startRoutine?.name ?? item.routine.name), \(item.isCompleted ? "completed" : "remaining")")
            .frame(maxWidth: .infinity, alignment: .leading)

            if let startRoutine {
                HStack(spacing: Space.xs) {
                    routineStartButton(
                        startRoutine,
                        isNext: false
                    )
                    if let next = alternatingState?.next(after: startRoutine.id) {
                        routineStartButton(next, isNext: true)
                    }
                }
                .layoutPriority(1)
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private func routineStartButton(
        _ routine: RoutineModel,
        isNext: Bool
    ) -> some View {
        if isNext {
            Button {
                startRoutine(id: routine.id)
            } label: {
                compactAlternateStartLabel("Start \(routine.name)")
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start \(routine.name)")
            .accessibilityIdentifier("microcycle-start-next-\(routine.id.uuidString)")
        } else {
            Button {
                startRoutine(id: routine.id)
            } label: {
                MicrocycleCompactPrimaryActionLabel(title: "Start")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Start \(routine.name)")
            .accessibilityIdentifier("microcycle-start-routine-\(routine.id.uuidString)")
        }
    }

    private func compactAlternateStartLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.bold())
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.85)
            .allowsTightening(true)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .foregroundStyle(theme.textPrimary)
            .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func needsAttentionCard(_ tracking: MicrocycleTrackingModel) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(theme.warmup)
                Text("Restore this microcycle folder or add a routine to continue automatic windows.")
                    .font(.body)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .accessibilityIdentifier("microcycle-needs-attention")
    }

    private func historySection(tracking: MicrocycleTrackingModel) -> some View {
        let past = MicrocycleTrackingService.history(for: tracking, windows: trackingWindows)
            .filter { $0.id != currentWindow?.id }
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text("Previous windows")
                .font(.sectionTitle)
                .foregroundStyle(theme.textPrimary)
            if past.isEmpty {
                Card {
                    Text("Completed windows will appear here.")
                        .font(.body)
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                ForEach(past) { window in
                    if let presentation = MicrocycleHistoryPresentation.windowPresentation(
                        tracking: tracking,
                        window: window,
                        windows: trackingWindows,
                        workouts: workouts
                    ) {
                        NavigationLink(
                            value: MicrocycleHistoryRoute.window(
                                trackingID: tracking.id,
                                windowID: window.id
                            )
                        ) {
                            Card(padding: Space.md) {
                                MicrocycleHistoryWindowRow(window: presentation)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("microcycle-previous-window-\(window.index + 1)")
                    }
                }
            }
        }
    }

    private func showRestSheet() {
        showingRestSheet = true
    }

    private func addPlannedRestDay() {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.addPlannedRestDay(
                to: tracking,
                in: modelContext
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func logPlannedRestDay(_ id: UUID) {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.logPlannedRestDay(
                id: id,
                in: tracking,
                workouts: workouts,
                context: modelContext
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func movePlannedRestDay(_ id: UUID, to targetIndex: Int) {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.movePlannedRestDay(
                id: id,
                to: targetIndex,
                in: tracking,
                context: modelContext
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func removePlannedRestDay(_ id: UUID) {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.removePlannedRestDay(
                id: id,
                from: tracking,
                in: modelContext
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func displayedPlanItems(
        _ items: [MicrocyclePlanProgress.Item]
    ) -> [MicrocyclePlanProgress.Item] {
        guard draggedRestDayID != nil,
              previewPlanItemIDs.count == items.count else { return items }
        let itemsByID = Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let preview = previewPlanItemIDs.compactMap { itemsByID[$0] }
        return preview.count == items.count ? preview : items
    }

    private func beginDraggingRestDay(
        _ id: UUID,
        items: [MicrocyclePlanProgress.Item]
    ) {
        previewPlanItemIDs = items.map(\.id)
        draggedRestDayID = id
    }

    private func hasRestLoggedToday(for tracking: MicrocycleTrackingModel) -> Bool {
        guard let calendar = try? MicrocycleEngine.calendar(
            timeZoneIdentifier: tracking.timeZoneIdentifier
        ) else { return false }
        return RestDayService.live(restDays).contains {
            calendar.isDate($0.date, inSameDayAs: .now)
        }
    }

    private func selectDay(_ date: Date) {
        selectedDay = MicrocycleDaySelection(date: date)
    }

    private func startRoutine(id: UUID) {
        guard let routine = routines.first(where: {
            $0.id == id && $0.deletedAt == nil && $0.archivedAt == nil
        }) else {
            actionError = "This routine is no longer available to start."
            return
        }
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

    private func endTracking() {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.end(tracking, in: modelContext)
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: AppPreferenceKeys.microcycleHistoryEducationShownKey) {
                dismiss()
            } else {
                showingHistoryEducation = true
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func viewHistoryAfterStop() {
        opensHistoryAfterEducation = true
        showingHistoryEducation = false
    }

    private func dismissHistoryEducation() {
        showingHistoryEducation = false
    }

    private func markHistoryEducationShown() {
        UserDefaults.standard.set(
            true,
            forKey: AppPreferenceKeys.microcycleHistoryEducationShownKey
        )
    }

    private func finishStopEducation() {
        dismiss()
        if opensHistoryAfterEducation {
            appState.openProfile(.microcycles)
        }
    }

    private func addDayToCurrentCycle() {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.addDayToCurrentWindow(
                tracking,
                in: modelContext
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func restartCurrentCycle() {
        guard let tracking else { return }
        do {
            try MicrocycleTrackingService.restartCurrentCycle(
                tracking,
                in: modelContext
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

}
