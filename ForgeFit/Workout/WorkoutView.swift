import ForgeCore
import ForgeData
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private enum DragPayload: Equatable {
    case routine(UUID)
    case folder(UUID)

    var rawValue: String {
        switch self {
        case .routine(let id): "routine:\(id.uuidString)"
        case .folder(let id): "folder:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        if rawValue.hasPrefix("routine:"),
           let id = UUID(uuidString: String(rawValue.dropFirst("routine:".count))) {
            self = .routine(id)
        } else if rawValue.hasPrefix("folder:"),
                  let id = UUID(uuidString: String(rawValue.dropFirst("folder:".count))) {
            self = .folder(id)
        } else if let id = UUID(uuidString: rawValue) {
            // Accept the original routine payload format so older in-flight
            // drag providers still work while the app is running.
            self = .routine(id)
        } else {
            return nil
        }
    }
}

private enum DropTarget: Equatable {
    case folder(UUID)
}

/// A folder the user asked to create but hasn't named yet — the model is only
/// inserted when the name alert is confirmed, so cancelling leaves no
/// "New Folder" junk behind.
private struct FolderCreation {
    let parentID: UUID?
}

private struct DropFeedback: Equatable {
    let target: DropTarget
    let accepts: Bool
    let title: String
    let detail: String?

    var color: Color { accepts ? AppTheme.sage.accent : AppTheme.sage.danger }
    var systemImage: String { accepts ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill" }
}

/// Hevy-style Workout tab: start an empty session and manage routines organized
/// into folders (create, rename, delete, and drag routines in / out).
struct WorkoutHomeView: View {
    @Environment(\.tabRootRequestID) private var tabRootRequestID
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var performanceGate = LiveWorkoutPerformanceGate.shared

    let routines: [RoutineModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    @Query(sort: \RoutineFolderModel.position) private var allFolders: [RoutineFolderModel]
    @Query(sort: \RoutineAlternationModel.updatedAt, order: .reverse)
    private var alternations: [RoutineAlternationModel]
    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var microcycleTrackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var microcycleWindows: [MicrocycleWindowModel]

    @State private var collapsed: Set<UUID> = []
    /// Routine summaries are intentionally session-only. Every launch starts
    /// compact, while navigation and scrolling within this session retain the
    /// user's open cards without writing a presentation preference.
    @State private var expandedRoutineSummaries: Set<UUID> = []
    @State private var navigationPath = NavigationPath()
    @State private var newRoutine: RoutineModel?
    /// Set only by `createRoutine` — tells the editor this routine is a
    /// just-inserted placeholder, so backing out deletes it instead of
    /// leaving "New Routine" junk in the library.
    @State private var newlyCreatedRoutineID: UUID?
    @State private var renamingFolder: RoutineFolderModel?
    @State private var pendingFolderCreation: FolderCreation?
    @State private var folderNameDraft = ""
    /// Deletion is one tap inside an ellipsis menu — both dialogs guard
    /// against a mis-tap silently removing something the user built.
    @State private var routinePendingDelete: RoutineModel?
    @State private var folderPendingDelete: RoutineFolderModel?
    @State private var sharePayload: ShareImagePayload?
    @State private var shareErrorMessage: String?
    /// The item currently being dragged. SwiftUI's drop target callback only
    /// tells us whether something is hovering, so we keep the payload here to
    /// make folder hover feedback specific instead of vague.
    @State private var draggedPayload: DragPayload?
    @State private var dropFeedback: DropFeedback?
    /// Reference-backed so per-frame finger updates invalidate only the small
    /// collapse overlay, never the model-backed routine library underneath.
    @State private var routineReorderSession: RoutineReorderSession?
    @State private var showExploreLibrary = false
    /// Accessible alternative to direct card dragging: a List with native drag
    /// handles that VoiceOver and Switch Control can operate.
    @State private var editingOrder = false
    @State private var trackingFolder: RoutineFolderModel?
    @State private var editingMicrocycleTracking: MicrocycleTrackingModel?
    @State private var alternationRoutine: RoutineModel?

    /// A mesocycle can contain several microcycles. Home uses the active
    /// microcycle first, then its broader mesocycle, then the full library.
    @AppStorage(CyclePreferenceMigration.activeMesocycleKey)
    private var activeMesocycleFolderRaw = ""
    @AppStorage(CyclePreferenceMigration.activeMicrocycleKey)
    private var activeMicrocycleFolderRaw = ""
    @AppStorage(AppPreferenceKeys.workoutUngroupedCollapsedKey)
    private var ungroupedCollapsed = false

    private var activeRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil && $0.archivedAt == nil }.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private var folders: [RoutineFolderModel] {
        // CloudKit can deliver a pre-split record after launch cleanup. Keep
        // the hierarchy stable immediately while the reactive persistence
        // cleanup removes the extra physical row in the background.
        var byID: [UUID: RoutineFolderModel] = [:]
        for folder in allFolders {
            guard folder.deletedAt == nil, folder.archivedAt == nil else { continue }
            if let incumbent = byID[folder.id], incumbent.updatedAt >= folder.updatedAt {
                continue
            }
            byID[folder.id] = folder
        }
        return byID.values.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private var topLevelFolders: [RoutineFolderModel] {
        folders.filter { $0.parentID == nil }
    }
    private func childFolders(of folder: RoutineFolderModel) -> [RoutineFolderModel] {
        folders.filter { $0.parentID == folder.id }
    }
    private var ungrouped: [RoutineModel] {
        activeRoutines.filter { $0.folderID == nil }
    }
    private func routines(in folder: RoutineFolderModel) -> [RoutineModel] {
        activeRoutines.filter { $0.folderID == folder.id }
    }
    private func alternationState(for routine: RoutineModel) -> RoutineAlternationService.State? {
        RoutineAlternationService.state(
            containing: routine.id,
            alternations: alternations,
            routines: activeRoutines,
            workouts: workouts
        )
    }
    private func reorderItems(_ source: [RoutineModel]) -> [RoutineReorderSession.Item] {
        let sourceIDs = Set(source.map(\.id))
        let states = RoutineAlternationService.states(
            alternations: alternations,
            routines: activeRoutines,
            workouts: workouts
        )
        let pairedStates = states.filter {
            sourceIDs.contains($0.owner.id) && sourceIDs.contains($0.partner.id)
        }
        var statesByOwner: [UUID: RoutineAlternationService.State] = [:]
        for state in pairedStates where statesByOwner[state.owner.id] == nil {
            statesByOwner[state.owner.id] = state
        }
        let suppressedPartners = Set(pairedStates.map(\.partner.id))

        return source.compactMap { routine in
            if suppressedPartners.contains(routine.id) { return nil }
            guard let state = statesByOwner[routine.id] else {
                return RoutineReorderSession.Item(
                    id: routine.id,
                    routineIDs: [routine.id],
                    name: routine.name
                )
            }
            let pairIDs = Set([state.owner.id, state.partner.id])
            let orderedPairIDs = source.filter { pairIDs.contains($0.id) }.map(\.id)
            return RoutineReorderSession.Item(
                id: state.owner.id,
                routineIDs: orderedPairIDs,
                name: "\(state.owner.name) / \(state.partner.name)"
            )
        }
    }

    private func routineRows(in destination: RoutineReorderSession.Destination) -> [RoutineModel] {
        // Deliberately ignore the gesture-local session. The original source
        // card must stay mounted and the full library must not re-layout while
        // the finger is moving; the compact overlay owns all live snapping.
        let ids = reorderItems(routines(at: destination)).map(\.id)
        var routinesByID: [UUID: RoutineModel] = [:]
        for routine in activeRoutines where routinesByID[routine.id] == nil {
            routinesByID[routine.id] = routine
        }
        return ids.compactMap { routinesByID[$0] }
    }

    private func routines(at destination: RoutineReorderSession.Destination) -> [RoutineModel] {
        switch destination {
        case .ungrouped:
            ungrouped
        case .folder(let id):
            activeRoutines.filter { $0.folderID == id }
        }
    }
    private var activeTracking: MicrocycleTrackingModel? {
        MicrocycleTrackingService.activeTracking(microcycleTrackings)
    }

    private func isActiveMesocycle(_ folder: RoutineFolderModel) -> Bool {
        activeMesocycleFolderRaw == folder.id.uuidString
    }
    private func isActiveMicrocycle(_ folder: RoutineFolderModel) -> Bool {
        activeMicrocycleFolderRaw == folder.id.uuidString
    }

    private func setActiveMicrocycle(_ folder: RoutineFolderModel) {
        activeMicrocycleFolderRaw = folder.id.uuidString
        if let parentID = folder.parentID {
            activeMesocycleFolderRaw = parentID.uuidString
        }
    }

    private func setActiveMesocycle(_ folder: RoutineFolderModel) {
        activeMesocycleFolderRaw = folder.id.uuidString
        if let microcycleID = UUID(uuidString: activeMicrocycleFolderRaw),
           !childFolders(of: folder).contains(where: { $0.id == microcycleID }) {
            activeMicrocycleFolderRaw = ""
        }
    }

    private func updateMicrocyclePresentation(
        _ tracking: MicrocycleTrackingModel,
        showsOnHome: Bool? = nil,
        showsFolderHeader: Bool? = nil
    ) {
        try? MicrocycleTrackingService.setPresentation(
            tracking,
            showsOnHome: showsOnHome,
            showsFolderHeader: showsFolderHeader,
            in: modelContext
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .top) {
                // Keep the source handle mounted for the entire continuous
                // gesture. Removing this tree as the overlay appears would
                // cancel the UIKit recognizer at lift-off.
                ScreenScaffold("Workout") {
                SecondaryButton(title: "Start Empty Workout", systemImage: "plus") {
                    appState.requestStart {
                        _ = WorkoutFactory.startEmpty(in: modelContext)
                        appState.showingLogger = true
                    }
                }

                SectionHeader("Routines") {
                    HStack(spacing: Space.lg) {
                        // The native edit list remains the accessibility path
                        // for exact ordering without a spatial drag.
                        if !ungrouped.isEmpty || !folders.isEmpty {
                            Button("Edit Order") { editingOrder = true }
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.accent)
                                .accessibilityIdentifier("edit-routine-order-button")
                        }
                        Button { createFolder() } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                        }
                        .accessibilityIdentifier("new-folder-button")
                    }
                }

                HStack(spacing: Space.sm) {
                    SecondaryButton(title: "New Routine", systemImage: "plus") { createRoutine(folderID: nil) }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("new-routine-button")
                    SecondaryButton(title: "Explore", systemImage: "sparkles") { showExploreLibrary = true }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("explore-routines-button")
                }

                if activeRoutines.isEmpty && folders.isEmpty {
                    EmptyStateCard(
                        title: "No routines yet",
                        message: "Build your first routine or organize plans in folders.",
                        systemImage: "list.bullet.rectangle"
                    )
                }

                let ungroupedRows = routineRows(in: .ungrouped)
                if ungroupedRows.isEmpty {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: Space.lg)
                        .contentShape(Rectangle())
                        .onDrop(of: [.plainText], isTargeted: nil) { providers in
                            handleDrop(providers, into: nil)
                        }
                } else if folders.isEmpty {
                    VStack(spacing: Space.md) {
                        ForEach(ungroupedRows) { routine in
                            routineCard(routine)
                        }
                    }
                    .onDrop(of: [.plainText], isTargeted: nil) { providers in
                        handleDrop(providers, into: nil)
                    }
                } else {
                    UngroupedRoutineSection(
                        isCollapsed: $ungroupedCollapsed,
                        count: ungroupedRows.count,
                        onDrop: { providers in handleDrop(providers, into: nil) }
                    ) {
                        VStack(spacing: Space.md) {
                            ForEach(ungroupedRows) { routine in
                                routineCard(routine)
                            }
                        }
                    }
                }

                ForEach(topLevelFolders) { folder in
                    VStack(alignment: .leading, spacing: 0) {
                        RoutineFolderRootInsertionTarget(
                            title: rootInsertionTitle(before: folder),
                            acceptsDrop: canInsertDraggedFolder(before: folder)
                        ) { providers in
                            handleDrop(
                                providers,
                                into: nil,
                                rootFolderBefore: folder.id
                            )
                        }
                        folderSection(folder)
                    }
                    // The insertion target consumes the existing section gap,
                    // preserving the resting hierarchy's current spacing.
                    .padding(.top, -Space.xl)
                }

                // Pinned below everything that's live; exists only once
                // something is archived, so it never clutters a fresh library.
                if archiveInventory.rootCount > 0 {
                    archiveRow
                }
                }
                .accessibilityHidden(routineReorderSession != nil)

                if let routineReorderSession {
                    RoutineReorderCollapseOverlay(session: routineReorderSession)
                        .transition(.opacity)
                        .zIndex(1)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("routine-library-reorder-overlay")
                }
            }
            // The whole routine canvas represents the root level. Exact
            // folder insertion slots take precedence; a release on remaining
            // canvas moves a routine to Ungrouped or a folder to the root end.
            .onDrop(of: [.plainText], isTargeted: nil) { providers in
                handleDrop(providers, into: nil)
            }
            .navigationDestination(for: RoutineModel.self) { routine in
                RoutineDetailView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
            .navigationDestination(for: WorkoutRoute.self) { route in
                switch route {
                case .archive:
                    ArchiveView(routines: routines, folders: allFolders)
                case .microcycle(let trackingID):
                    MicrocycleDetailView(trackingID: trackingID)
                }
            }
            .navigationDestination(item: $newRoutine) { routine in
                RoutineEditorView(
                    routine: routine,
                    exercises: exercises,
                    setupNotes: setupNotes,
                    isNew: routine.id == newlyCreatedRoutineID
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
                TextField("Folder name", text: $folderNameDraft)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renamingFolder = nil }
            }
            .alert("New folder", isPresented: Binding(get: { pendingFolderCreation != nil }, set: { if !$0 { pendingFolderCreation = nil } })) {
                TextField("Folder name", text: $folderNameDraft)
                Button("Create") { commitCreateFolder() }
                Button("Cancel", role: .cancel) { pendingFolderCreation = nil }
            }
            .confirmationDialog(
                "Delete \"\(routinePendingDelete?.name ?? "routine")\"?",
                isPresented: Binding(get: { routinePendingDelete != nil }, set: { if !$0 { routinePendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Routine", role: .destructive) {
                    if let routine = routinePendingDelete { delete(routine) }
                    routinePendingDelete = nil
                }
                Button("Cancel", role: .cancel) { routinePendingDelete = nil }
            } message: {
                Text("The routine and its planned sets are removed. Logged workouts keep their history.")
            }
            .confirmationDialog(
                "Delete \"\(folderPendingDelete?.name ?? "folder")\"?",
                isPresented: Binding(get: { folderPendingDelete != nil }, set: { if !$0 { folderPendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Folder", role: .destructive) {
                    if let folder = folderPendingDelete { deleteFolder(folder) }
                    folderPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { folderPendingDelete = nil }
            } message: {
                Text("Routines and subfolders inside move up a level — nothing inside is deleted.")
            }
            .sheet(isPresented: $showExploreLibrary) {
                let templates = RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises)
                RoutineLibraryView(
                    programs: RoutineTemplateCatalog.validPrograms(
                        from: RoutineTemplateCatalog.loadPrograms(),
                        templates: templates,
                        exercises: exercises
                    ),
                    templates: templates,
                    exercises: exercises,
                    onImport: { program in
                        // Imported day routines land together as one leaf
                        // microcycle folder.
                        RoutineTemplateCatalog.importProgram(program, templates: templates, in: modelContext)
                        showExploreLibrary = false
                    }
                )
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
            .alert(
                "Couldn't share cycle",
                isPresented: Binding(
                    get: { shareErrorMessage != nil },
                    set: { if !$0 { shareErrorMessage = nil } }
                )
            ) { } message: {
                Text(shareErrorMessage ?? "")
            }
            .sheet(isPresented: $editingOrder) {
                RoutineOrderEditorView(
                    topLevelFolders: topLevelFolders,
                    routineHoldingFolders: routineDestinationFolders,
                    ungrouped: ungrouped,
                    routines: { routines(in: $0) },
                    label: { destinationLabel($0) },
                    onMoveFolders: moveTopLevelFolders,
                    onMoveUngrouped: moveUngroupedRoutines,
                    onMoveRoutines: { folder, from, to in moveRoutines(in: folder, from: from, to: to) }
                )
            }
            .sheet(item: $trackingFolder) { folder in
                MicrocycleSetupView(
                    folder: folder,
                    routines: routines(in: folder)
                ) { startDate, durationDays in
                    _ = try MicrocycleTrackingService.start(
                        folder: folder,
                        routines: routines,
                        folders: folders,
                        startDate: startDate,
                        durationDays: durationDays,
                        in: modelContext
                    )
                    setActiveMicrocycle(folder)
                }
            }
            .sheet(item: $editingMicrocycleTracking) { tracking in
                MicrocycleTrackingEditView(tracking: tracking) { durationDays in
                    try MicrocycleTrackingService.updateDuration(
                        tracking,
                        durationDays: durationDays,
                        in: modelContext
                    )
                }
            }
            .sheet(item: $alternationRoutine) { routine in
                RoutineAlternationSheet(
                    anchor: routine,
                    routines: routines,
                    folders: folders,
                    alternations: alternations,
                    workouts: workouts,
                    exercises: exercises,
                    setupNotes: setupNotes
                )
            }
        }
        .id(tabRootRequestID)
        .onChange(of: appState.pendingRoutineDetailID, initial: true) {
            openPendingImportedRoutineIfAvailable()
        }
        .onChange(of: activeRoutines.map(\.id)) {
            openPendingImportedRoutineIfAvailable()
        }
        .task(id: performanceGate.isLiveWorkoutActive) {
            guard performanceGate.allowsNonWorkoutWork else { return }
            CyclePreferenceMigration.migrate()
            _ = try? MicrocycleTrackingService.reconcile(in: modelContext)
        }
        .interactiveBackSwipeEnabled()
        .bottomChromeHidden(routineReorderSession != nil)
    }

    private func openPendingImportedRoutineIfAvailable() {
        guard let id = appState.pendingRoutineDetailID,
              let routine = activeRoutines.first(where: { $0.id == id }) else { return }
        navigationPath = NavigationPath()
        navigationPath.append(routine)
        appState.pendingRoutineDetailID = nil
    }

    // MARK: - Archive entry point

    private var archiveInventory: ArchiveInventory {
        ArchiveInventory(routines: routines, folders: allFolders)
    }

    private var archiveRow: some View {
        NavigationLink(value: WorkoutRoute.archive) {
            HStack(spacing: Space.md) {
                Image(systemName: "archivebox")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("Archive")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text("\(archiveInventory.rootCount)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(Space.md)
            .background(theme.surface.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout-archive-row")
        .padding(.top, Space.sm)
    }

    // MARK: - Folder section

    private func folderSection(_ folder: RoutineFolderModel) -> AnyView {
        let isCollapsed = collapsed.contains(folder.id)
        let destination = RoutineReorderSession.Destination.folder(folder.id)
        let displayedItems = routineRows(in: destination)
        let children = childFolders(of: folder)
        // Parent folders are mesocycles; leaf folders holding routines are
        // microcycles. Routines themselves are workout sessions.
        let isActive = children.isEmpty
            ? isActiveMicrocycle(folder)
            : isActiveMesocycle(folder)
        let trackedWindow: MicrocycleWindowModel? = {
            guard let activeTracking, activeTracking.folderID == folder.id else { return nil }
            return MicrocycleTrackingService.currentWindow(
                for: activeTracking,
                windows: microcycleWindows
            )
        }()
        let target = DropTarget.folder(folder.id)
        let feedback = feedback(for: target)
        let isTargeted = feedback != nil
        let isRejected = feedback?.accepts == false
        return AnyView(
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: Space.sm) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            if isCollapsed { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
                        }
                    } label: {
                        HStack(spacing: Space.sm) {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                            Image(systemName: isActive ? "star.circle.fill" : "folder.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(isActive ? theme.accent : theme.textSecondary)
                            // The name stands alone — the content count is a
                            // separate quiet detail, never part of the name.
                            Text(folder.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            let count = children.isEmpty ? displayedItems.count : children.count
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(theme.surfaceElevated)
                                    .clipShape(Capsule())
                            }
                            if isActive {
                                Text("ACTIVE")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.accent.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("routine-folder-\(folder.name)")
                    Spacer()
                    RoutineFolderDragHandle(folderName: folder.name) {
                        cancelRoutineReorder()
                        let payload = DragPayload.folder(folder.id)
                        draggedPayload = payload
                        return dragProvider(for: payload)
                    }
                    folderMenu(folder, isActive: isActive, hasChildren: !children.isEmpty)
                }

                if let activeTracking,
                   activeTracking.folderID == folder.id,
                   activeTracking.showsFolderHeader,
                   !isCollapsed,
                   let trackedWindow {
                    let progress = MicrocycleTrackingService.progress(
                        for: trackedWindow,
                        windows: microcycleWindows,
                        workouts: workouts
                    )
                    HStack(spacing: Space.sm) {
                        NavigationLink(value: WorkoutRoute.microcycle(activeTracking.id)) {
                            HStack(spacing: Space.sm) {
                                Image(systemName: activeTracking.needsAttention
                                    ? "exclamationmark.triangle.fill"
                                    : (progress.isComplete ? "checkmark.circle.fill" : "calendar"))
                                    .foregroundStyle(activeTracking.needsAttention
                                        ? theme.warmup
                                        : (progress.isComplete ? theme.accent : theme.textSecondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activeTracking.needsAttention
                                        ? "MICROCYCLE NEEDS ATTENTION"
                                        : "MICROCYCLE PROGRESS")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundStyle(theme.textTertiary)
                                    Text(activeTracking.needsAttention
                                        ? "Add a routine to continue tracking"
                                        : "Day \(MicrocycleTrackingService.dayNumber(for: trackedWindow)) of \(MicrocycleTrackingService.windowDurationDays(for: trackedWindow)) · \(progress.completedCount) of \(progress.requiredCount) workouts")
                                        .font(.subheadline)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            updateMicrocyclePresentation(
                                activeTracking,
                                showsFolderHeader: false
                            )
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundStyle(theme.textTertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove microcycle header")
                        .accessibilityHint("Tracking continues and the header can be added back from this folder's menu.")
                    }
                    .padding(Space.sm)
                    .background(theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityIdentifier("microcycle-folder-progress")
                    .padding(.leading, Space.lg)
                }

                if !isCollapsed {
                    if displayedItems.isEmpty && children.isEmpty && !isTargeted {
                        Button("Add Routine", systemImage: "plus") {
                            createRoutine(folderID: folder.id)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("add-routine-to-empty-folder-\(folder.name)")
                        .padding(.leading, Space.lg)
                    } else {
                        if !displayedItems.isEmpty {
                            VStack(spacing: Space.md) {
                                ForEach(displayedItems) { routine in
                                    routineCard(routine)
                                }
                            }
                            .padding(.leading, Space.lg)
                        }
                        if !children.isEmpty {
                            RoutineHierarchyRail {
                                ForEach(children) { child in
                                    folderSection(child)
                                }
                            }
                        }
                    }
                }

                // Live feedback while a drag hovers this folder: say exactly
                // what a release will do here.
                if let feedback {
                    dropHint(feedback)
                }
            }
            .background(folderBackground(isTargeted: isTargeted, isRejected: isRejected))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(
                        folderStroke(isTargeted: isTargeted, isRejected: isRejected),
                        lineWidth: isTargeted ? 2 : 0
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.plainText], isTargeted: Binding(
                get: { dropFeedback?.target == target },
                set: { hovering in
                    if hovering {
                        let feedback = folderDropFeedback(for: folder)
                        dropFeedback = feedback
                        // Spring open so the user can see where things will land.
                        if reduceMotion {
                            collapsed.remove(folder.id)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                _ = collapsed.remove(folder.id)
                            }
                        }
                    } else if dropFeedback?.target == target {
                        dropFeedback = nil
                    }
                }
            )) { providers in
                handleDrop(providers, into: folder)
            }
                )
    }

    private func folderDropFeedback(for folder: RoutineFolderModel) -> DropFeedback {
        let target = DropTarget.folder(folder.id)
        guard let draggedPayload else {
            if childFolders(of: folder).isEmpty {
                return DropFeedback(
                    target: target,
                    accepts: true,
                    title: "Add to \(folder.name)",
                    detail: "Routines and child folders"
                )
            }
            return DropFeedback(
                target: target,
                accepts: true,
                title: "Move folder into \(folder.name)",
                detail: "This mesocycle contains subfolders only"
            )
        }

        switch draggedPayload {
        case .routine(let id):
            guard let routine = activeRoutines.first(where: { $0.id == id }) else {
                return DropFeedback(target: target, accepts: false, title: "That routine is unavailable", detail: nil)
            }
            if routine.folderID == folder.id {
                return DropFeedback(target: target, accepts: false, title: "Already in this folder", detail: nil)
            }
            if !childFolders(of: folder).isEmpty {
                return DropFeedback(target: target, accepts: false, title: "Can't add routines here", detail: "This folder contains subfolders only")
            }
            return DropFeedback(
                target: target,
                accepts: true,
                title: "Move \(routine.name) into \(folder.name)",
                detail: "Places it at the end"
            )

        case .folder(let id):
            guard let dragged = folders.first(where: { $0.id == id }) else {
                return DropFeedback(target: target, accepts: false, title: "That folder is unavailable", detail: nil)
            }
            if dragged.id == folder.id {
                return DropFeedback(target: target, accepts: false, title: "Can't drop onto itself", detail: nil)
            }
            if !canNest(dragged, into: folder) {
                if folder.parentID != nil {
                    return DropFeedback(target: target, accepts: false, title: "Can't nest inside a subfolder", detail: "Folders can only go one level deep")
                }
                if !childFolders(of: dragged).isEmpty {
                    return DropFeedback(target: target, accepts: false, title: "Move its subfolders first", detail: "Only childless folders can be nested")
                }
                if dragged.parentID == folder.id {
                    return DropFeedback(target: target, accepts: false, title: "Already nested here", detail: nil)
                }
                return DropFeedback(target: target, accepts: false, title: "Can't add folder here", detail: nil)
            }
            let detail = childFolders(of: folder).isEmpty && !routines(in: folder).isEmpty
                ? "Existing routines move into \(dragged.name)"
                : "Adds it as a microcycle"
            return DropFeedback(
                target: target,
                accepts: true,
                title: "Move \(dragged.name) into \(folder.name)",
                detail: detail
            )
        }
    }

    private func folderMenu(_ folder: RoutineFolderModel, isActive: Bool, hasChildren: Bool) -> some View {
        Menu {
            // A mesocycle and one of its microcycles can both be active: one
            // names the broader block, the other the sessions currently due.
            if hasChildren {
                if isActive {
                    Button("Clear Active Mesocycle", systemImage: "star.slash") {
                        activeMesocycleFolderRaw = ""
                    }
                } else {
                    Button("Set as Active Mesocycle", systemImage: "star") {
                        setActiveMesocycle(folder)
                    }
                }
            } else {
                if isActive {
                    Button("Clear Active Microcycle", systemImage: "star.slash") {
                        activeMicrocycleFolderRaw = ""
                    }
                } else {
                    Button("Set as Active Microcycle", systemImage: "star") {
                        setActiveMicrocycle(folder)
                    }
                }
                if let activeTracking, activeTracking.folderID == folder.id {
                    NavigationLink(
                        "View Microcycle",
                        value: WorkoutRoute.microcycle(activeTracking.id)
                    )
                    Button("Edit Day Target", systemImage: "calendar") {
                        editingMicrocycleTracking = activeTracking
                    }
                    if !activeTracking.showsOnHome {
                        Button("Show on Home", systemImage: "house") {
                            updateMicrocyclePresentation(
                                activeTracking,
                                showsOnHome: true
                            )
                        }
                    }
                    if !activeTracking.showsFolderHeader {
                        Button("Show Microcycle Header", systemImage: "rectangle.topthird.inset.filled") {
                            updateMicrocyclePresentation(
                                activeTracking,
                                showsFolderHeader: true
                            )
                        }
                    }
                } else {
                    Button("Set Day Target", systemImage: "calendar.badge.plus") {
                        trackingFolder = folder
                    }
                    .disabled(routines(in: folder).isEmpty)
                }
            }
            Divider()
            Button(hasChildren ? "Share Mesocycle" : "Share Microcycle", systemImage: "square.and.arrow.up") {
                shareFolder(folder, hasChildren: hasChildren)
            }
            Button("Rename", systemImage: "pencil") { startRename(folder) }
            // A folder with subfolders holds only folders — no loose routines.
            if !hasChildren {
                Button("Add Routine", systemImage: "plus") { createRoutine(folderID: folder.id) }
            }
            // One layer deep: only top-level folders can gain subfolders.
            if folder.parentID == nil {
                Button("New Subfolder", systemImage: "folder.badge.plus") { createFolder(parentID: folder.id) }
            }
            // A folder that has children can't itself become a subfolder.
            if !hasChildren {
                Menu {
                    if folder.parentID != nil {
                        Button("Top Level", systemImage: "arrow.up.to.line") {
                            moveFolderToRoot(folder, before: nil)
                        }
                    }
                    ForEach(topLevelFolders.filter { $0.id != folder.id && $0.id != folder.parentID }) { target in
                        Button(target.name, systemImage: "folder") { nest(folder, into: target) }
                    }
                } label: {
                    Label("Move Folder Into…", systemImage: "folder.badge.gearshape")
                }
            }
            Divider()
            Button("Archive", systemImage: "archivebox") {
                archiveFolder(folder)
            }
            Button("Delete Folder", systemImage: "trash", role: .destructive) { folderPendingDelete = folder }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Folder options for \(folder.name)")
    }

    /// Keep the readable image and lossless plan document together. A
    /// mesocycle carries its full visible microcycle subtree.
    private func shareFolder(_ folder: RoutineFolderModel, hasChildren: Bool) {
        do {
            let microcycles = hasChildren ? childFolders(of: folder) : []
            let sharedRoutines = hasChildren
                ? microcycles.flatMap { routines(in: $0) }
                : routines(in: folder)
            let sections = hasChildren
                ? microcycles.map { FolderShareCard.Section(title: $0.name, routines: routines(in: $0)) }
                : [FolderShareCard.Section(title: nil, routines: sharedRoutines)]
            guard let image = FolderShareRenderer.image(
                name: folder.name,
                isMesocycle: hasChildren,
                sections: sections,
                exercises: exercises,
                theme: theme
            ) else {
                throw PlanShareService.ShareError.invalidStructuredPlan(folder.name)
            }
            let document = try hasChildren
                ? PlanShareService.mesocycleDocument(
                    folder,
                    microcycles: microcycles,
                    routines: sharedRoutines,
                    allRoutines: activeRoutines,
                    alternations: alternations,
                    exercises: exercises
                )
                : PlanShareService.microcycleDocument(
                    folder,
                    routines: sharedRoutines,
                    allRoutines: activeRoutines,
                    alternations: alternations,
                    exercises: exercises
                )
            let url = try PlanShareService.write(document)
            sharePayload = ShareImagePayload(image: image, attachments: [url])
        } catch {
            shareErrorMessage = error.localizedDescription
        }
    }

    /// Nest `folder` inside `parent` (nil = top level), enforcing the cycle
    /// structure: one layer deep, and a parent that gains its first subfolder
    /// hands its loose routines down to it.
    @discardableResult
    private func nest(_ folder: RoutineFolderModel, into parent: RoutineFolderModel?) -> Bool {
        // Only childless folders can become subfolders (one layer max).
        guard canNest(folder, into: parent) else { return false }
        let previousParentID = folder.parentID
        if let parent {
            if childFolders(of: parent).isEmpty {
                // Parent is gaining its first subfolder: its routines move into
                // the new subfolder so the parent holds only folders.
                for routine in routines(in: parent) {
                    routine.folderID = folder.id
                    routine.updatedAt = Date()
                }
            }
            parent.updatedAt = Date()
        }
        folder.parentID = parent?.id
        folder.updatedAt = Date()
        if let previousParentID,
           previousParentID != parent?.id,
           let previousParent = folders.first(where: { $0.id == previousParentID }) {
            previousParent.updatedAt = Date()
        }
        if let parent { collapsed.remove(parent.id) }
        save()
        return true
    }

    private func canNest(_ folder: RoutineFolderModel, into parent: RoutineFolderModel?) -> Bool {
        guard childFolders(of: folder).isEmpty else { return false }
        guard let parent else { return folder.parentID != nil }
        return parent.parentID == nil && parent.id != folder.id && folder.parentID != parent.id
    }

    private func rootInsertionTitle(before target: RoutineFolderModel) -> String {
        guard case .folder(let id) = draggedPayload,
              let dragged = folders.first(where: { $0.id == id }) else {
            return "Place folder above \(target.name)"
        }
        if canInsertDraggedFolder(before: target) {
            return "\(dragged.name) above \(target.name)"
        }
        return "Already in this position"
    }

    private func canInsertDraggedFolder(before target: RoutineFolderModel) -> Bool {
        guard case .folder(let id) = draggedPayload,
              let dragged = folders.first(where: { $0.id == id }),
              let destinationIDs = RoutineFolderRootOrdering.destinationIDs(
                moving: id,
                before: target.id,
                currentRootIDs: topLevelFolders.map(\.id)
              ) else {
            return false
        }
        return dragged.parentID != nil || destinationIDs != topLevelFolders.map(\.id)
    }

    private func moveFolderToRoot(_ folder: RoutineFolderModel, before targetID: UUID?) {
        guard RoutineFolderRootOrdering.move(
            folder,
            before: targetID,
            currentRoots: topLevelFolders,
            allFolders: folders
        ) else { return }
        save()
    }

    // MARK: - Hold-to-reorder routines

    private var routineReorderSections: [RoutineReorderSession.Section] {
        [RoutineReorderSession.Section(
            destination: .ungrouped,
            title: "Ungrouped",
            items: reorderItems(ungrouped)
        )] + routineDestinationFolders.map { folder in
            RoutineReorderSession.Section(
                destination: .folder(folder.id),
                title: destinationLabel(folder),
                items: reorderItems(routines(in: folder))
            )
        }
    }

    /// One continuous gesture from the visible handle. Only the reference-
    /// backed session changes per frame; the full card tree stays fixed below.
    private func routineReorderDragChanged(_ routine: RoutineModel, fingerY: CGFloat) {
        if let routineReorderSession {
            guard routineReorderSession.draggedItemID == routine.id else { return }
            routineReorderSession.fingerGlobalY = fingerY
            return
        }

        guard let session = RoutineReorderSession(
            draggedItemID: routine.id,
            fingerGlobalY: fingerY,
            sections: routineReorderSections
        ) else { return }
        dropFeedback = nil
        if reduceMotion {
            routineReorderSession = session
        } else {
            withAnimation(.snappy(duration: 0.2)) {
                routineReorderSession = session
            }
        }
    }

    private func routineReorderDragEnded() {
        guard let routineReorderSession else { return }
        if routineReorderSession.hasChanges,
           RoutineReorderPersistence.apply(routineReorderSession, to: activeRoutines) {
            save()
        }
        if reduceMotion {
            self.routineReorderSession = nil
        } else {
            withAnimation(.snappy(duration: 0.25)) {
                self.routineReorderSession = nil
            }
        }
    }

    /// VoiceOver fallback: move one visible slot at a time, including across a
    /// folder header, and commit that single move immediately.
    private func accessibilityMoveRoutine(_ routine: RoutineModel, by offset: Int) {
        guard let session = RoutineReorderSession(
            draggedItemID: routine.id,
            fingerGlobalY: 0,
            sections: routineReorderSections
        ),
        let index = session.entries.firstIndex(where: { $0.id == .item(routine.id) }) else { return }
        let target = min(max(0, index + offset), session.entries.count - 1)
        guard session.moveHeld(toFlatIndex: target),
              RoutineReorderPersistence.apply(session, to: activeRoutines) else { return }
        save()
    }

    private func cancelRoutineReorder() {
        routineReorderSession = nil
    }

    /// Routes a drop onto `folder`; nil means root, with an optional exact
    /// insertion target for folder payloads.
    private func handleDrop(
        _ providers: [NSItemProvider],
        into folder: RoutineFolderModel?,
        rootFolderBefore targetID: UUID? = nil
    ) -> Bool {
        let usableProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !usableProviders.isEmpty else {
            clearDragFeedback()
            return false
        }

        for provider in usableProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                guard let data, let payload = String(data: data, encoding: .utf8) else {
                    Task { @MainActor in clearDragFeedback() }
                    return
                }
                Task { @MainActor in
                    _ = handleDrop(
                        [payload],
                        into: folder,
                        rootFolderBefore: targetID
                    )
                    clearDragFeedback()
                }
            }
        }
        return true
    }

    /// Routes decoded payloads onto a folder or an exact root insertion slot.
    private func handleDrop(
        _ payloads: [String],
        into folder: RoutineFolderModel?,
        rootFolderBefore targetID: UUID? = nil
    ) -> Bool {
        var handled = false
        for payload in payloads {
            guard let parsed = DragPayload(rawValue: payload) else { continue }
            switch parsed {
            case .folder(let id):
                guard let dragged = folders.first(where: { $0.id == id }) else { continue }
                if let folder {
                    handled = nest(dragged, into: folder) || handled
                } else {
                    handled = RoutineFolderRootOrdering.move(
                        dragged,
                        before: targetID,
                        currentRoots: topLevelFolders,
                        allFolders: folders
                    ) || handled
                }

            case .routine(let id):
                guard let routine = activeRoutines.first(where: { $0.id == id }) else {
                    continue
                }
                // Folders that contain subfolders hold folders only.
                if let folder, !childFolders(of: folder).isEmpty { continue }
                handled = relocateRoutineToEnd(routine, folderID: folder?.id) || handled
            }
        }
        if handled { save() }
        return handled
    }

    private func dropHint(_ feedback: DropFeedback) -> some View {
        HStack(spacing: Space.sm) {
            Image(systemName: feedback.systemImage)
                .font(.system(size: 14, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(feedback.color)
                if let detail = feedback.detail {
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(feedback.color.opacity(0.82))
                }
            }
            Spacer(minLength: 0)
        }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.md)
            .padding(.horizontal, Space.md)
            .background(feedback.color.opacity(feedback.accepts ? 0.16 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(feedback.color.opacity(0.62), style: StrokeStyle(lineWidth: 1, dash: [5]))
            )
    }

    private func routineCard(_ routine: RoutineModel) -> some View {
        let destinations = routineDestinationFolders.filter { $0.id != routine.folderID }
        let state = alternationState(for: routine)
        let hasConfiguredAlternation = RoutineAlternationService.alternation(
            containing: routine.id,
            in: alternations
        ) != nil
        return RoutineCard(
            routine: routine,
            exercises: exercises,
            isSummaryExpanded: expandedRoutineSummaries.contains(routine.id),
            alternationState: state,
            isAlternationOwner: state?.owner.id == routine.id,
            hasConfiguredAlternation: hasConfiguredAlternation,
            onStart: start,
            onEdit: { edit(routine) },
            onManageAlternation: { alternationRoutine = routine },
            onDelete: { routinePendingDelete = routine },
            onDuplicate: { duplicate(routine) },
            onArchive: { archive(routine) },
            moveDestinations: destinations.map { ($0.id, destinationLabel($0)) },
            showsMoveToRoot: routine.folderID != nil,
            onMove: { folderID in moveRoutine(routine, toFolder: folderID) },
            onReorderDragChanged: { fingerY in
                routineReorderDragChanged(routine, fingerY: fingerY)
            },
            onReorderDragEnded: routineReorderDragEnded,
            onAccessibilityMoveBy: { offset in
                accessibilityMoveRoutine(routine, by: offset)
            },
            onToggleSummary: { toggleRoutineSummary(routine.id) }
        )
    }

    private func toggleRoutineSummary(_ routineID: UUID) {
        if expandedRoutineSummaries.contains(routineID) {
            expandedRoutineSummaries.remove(routineID)
        } else {
            expandedRoutineSummaries.insert(routineID)
        }
    }

    private func dragProvider(for payload: DragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(payload.rawValue.data(using: .utf8), nil)
            return nil
        }
        provider.suggestedName = payload.rawValue
        return provider
    }

    private func feedback(for target: DropTarget) -> DropFeedback? {
        dropFeedback?.target == target ? dropFeedback : nil
    }

    private func clearDragFeedback() {
        draggedPayload = nil
        dropFeedback = nil
    }

    private func folderBackground(isTargeted: Bool, isRejected: Bool) -> Color {
        if isTargeted { return isRejected ? theme.danger.opacity(0.12) : theme.accentSoft }
        return .clear
    }

    private func folderStroke(isTargeted: Bool, isRejected: Bool) -> Color {
        if isTargeted { return isRejected ? theme.danger : theme.accent }
        return .clear
    }

    // MARK: - Actions

    private func start(_ routine: RoutineModel) {
        appState.requestStart {
            _ = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: modelContext)
            appState.showingLogger = true
        }
    }

    /// Push the routine editor from the card's ellipsis menu. Reuses the same
    /// editor destination as post-create so there's a single code path.
    private func edit(_ routine: RoutineModel) {
        newlyCreatedRoutineID = nil
        newRoutine = routine
    }

    /// Ask for a name first; the folder model is only inserted on confirm
    /// (`commitCreateFolder`) so cancelling leaves nothing behind.
    private func createFolder(parentID: UUID? = nil) {
        folderNameDraft = ""
        pendingFolderCreation = FolderCreation(parentID: parentID)
    }

    private func commitCreateFolder() {
        guard let request = pendingFolderCreation else { return }
        let trimmed = folderNameDraft.trimmingCharacters(in: .whitespaces)
        let folder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: trimmed.isEmpty ? "New Folder" : trimmed,
            position: folders.count,
            parentID: request.parentID
        )
        modelContext.insert(folder)
        // A parent gaining its first subfolder holds only folders from then on
        // — its loose routines move into the new subfolder.
        if let parentID = request.parentID, let parent = folders.first(where: { $0.id == parentID }) {
            let existingChildren = childFolders(of: parent).filter { $0.id != folder.id }
            if existingChildren.isEmpty {
                for routine in routines(in: parent) {
                    routine.folderID = folder.id
                    routine.updatedAt = Date()
                }
            }
            parent.updatedAt = Date()
            collapsed.remove(parentID)
        }
        save()
        pendingFolderCreation = nil
    }

    private func startRename(_ folder: RoutineFolderModel) {
        folderNameDraft = folder.name
        renamingFolder = folder
    }

    private func commitRename() {
        guard let folder = renamingFolder else { return }
        let trimmed = folderNameDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { folder.name = trimmed; folder.updatedAt = Date(); save() }
        renamingFolder = nil
    }

    private func deleteFolder(_ folder: RoutineFolderModel) {
        // Pull contents out rather than deleting them: routines and subfolders
        // move up to this folder's parent level.
        let now = Date()
        for routine in routines(in: folder) {
            routine.folderID = folder.parentID
            routine.updatedAt = now
        }
        for child in childFolders(of: folder) {
            child.parentID = folder.parentID
            child.updatedAt = now
        }
        if isActiveMesocycle(folder) { activeMesocycleFolderRaw = "" }
        if isActiveMicrocycle(folder) { activeMicrocycleFolderRaw = "" }
        folder.updatedAt = now
        folder.deletedAt = now
        save()
    }

    /// Insert-then-edit: the editor's exercise picker saves eagerly, so it
    /// needs a live inserted model. The editor knows it's new (see
    /// `newlyCreatedRoutineID`) and deletes the placeholder if the user
    /// backs out without saving.
    private func createRoutine(folderID: UUID?) {
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: activeRoutines.isEmpty ? "Full Body A" : "New Routine",
            folderID: folderID,
            position: activeRoutines.count
        )
        modelContext.insert(routine)
        save()
        newlyCreatedRoutineID = routine.id
        newRoutine = routine
    }

    private func delete(_ routine: RoutineModel) {
        let now = Date()
        try? RoutineAlternationService.removeAll(containing: routine.id, in: modelContext, now: now)
        routine.updatedAt = now
        routine.deletedAt = now
        save()
    }

    private func duplicate(_ source: RoutineModel) {
        RoutineDuplicator.duplicate(source, position: activeRoutines.count, in: modelContext)
        save()
    }

    private func save() {
        try? modelContext.save()
    }

    // MARK: - Archive

    /// No confirmation dialog: archiving is fully reversible, and the Archive
    /// row appearing at the bottom of the list is the feedback.
    private func archive(_ routine: RoutineModel) {
        RoutineArchiver.archive(routine)
        save()
    }

    private func archiveFolder(_ folder: RoutineFolderModel) {
        try? RoutineArchiver.archive(folder, in: modelContext)
        clearActivePrefsIfArchived()
        save()
    }

    /// Archiving a mesocycle cascades to its microcycles, so either active
    /// selection can be swept into the archive by one action.
    private func clearActivePrefsIfArchived() {
        if let mesocycle = allFolders.first(where: {
            $0.id.uuidString == activeMesocycleFolderRaw
        }), mesocycle.archivedAt != nil {
            activeMesocycleFolderRaw = ""
        }
        if let microcycle = allFolders.first(where: {
            $0.id.uuidString == activeMicrocycleFolderRaw
        }), microcycle.archivedAt != nil {
            activeMicrocycleFolderRaw = ""
        }
    }

    // MARK: - Move to folder (accessible alternative to drag & drop)

    /// Microcycle folders can directly hold routines. A mesocycle containing
    /// child folders holds only those microcycles, matching the drag/drop rule.
    private var routineDestinationFolders: [RoutineFolderModel] {
        topLevelFolders.flatMap { folder in
            let children = childFolders(of: folder)
            return children.isEmpty ? [folder] : children
        }
    }

    /// "Off-Season / Block 1" for a nested folder, plain name for a top-level
    /// one — enough context to tell same-named folders apart.
    private func destinationLabel(_ folder: RoutineFolderModel) -> String {
        guard let parentID = folder.parentID, let parent = folders.first(where: { $0.id == parentID }) else {
            return folder.name
        }
        return "\(parent.name) / \(folder.name)"
    }

    private func moveRoutine(_ routine: RoutineModel, toFolder folderID: UUID?) {
        if relocateRoutineToEnd(routine, folderID: folderID) { save() }
    }

    @discardableResult
    private func relocateRoutineToEnd(_ routine: RoutineModel, folderID: UUID?) -> Bool {
        guard routine.folderID != folderID else { return false }
        let sourceFolderID = routine.folderID
        let source = activeRoutines.filter { $0.id != routine.id && $0.folderID == sourceFolderID }
        let destination = activeRoutines.filter { $0.id != routine.id && $0.folderID == folderID }
        let now = Date.now

        for (index, sourceRoutine) in source.enumerated() where sourceRoutine.position != index {
            sourceRoutine.position = index
            sourceRoutine.updatedAt = now
        }
        for (index, destinationRoutine) in destination.enumerated() where destinationRoutine.position != index {
            destinationRoutine.position = index
            destinationRoutine.updatedAt = now
        }
        routine.folderID = folderID
        routine.position = destination.count
        routine.updatedAt = now
        return true
    }

    // MARK: - Edit Order (accessible alternative to drag reordering)

    private func moveTopLevelFolders(from offsets: IndexSet, to destination: Int) {
        var rows = topLevelFolders
        rows.move(fromOffsets: offsets, toOffset: destination)
        for (index, folder) in rows.enumerated() { folder.position = index; folder.updatedAt = Date() }
        save()
    }

    private func moveUngroupedRoutines(from offsets: IndexSet, to destination: Int) {
        var rows = ungrouped
        rows.move(fromOffsets: offsets, toOffset: destination)
        for (index, routine) in rows.enumerated() { routine.position = index; routine.updatedAt = Date() }
        save()
    }

    private func moveRoutines(in folder: RoutineFolderModel, from offsets: IndexSet, to destination: Int) {
        var rows = routines(in: folder)
        rows.move(fromOffsets: offsets, toOffset: destination)
        for (index, routine) in rows.enumerated() { routine.position = index; routine.updatedAt = Date() }
        save()
    }
}

/// Native drag-handle reordering for routines and top-level folders — the
/// accessible counterpart to direct spatial card dragging on the Workout tab.
private struct RoutineOrderEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let topLevelFolders: [RoutineFolderModel]
    /// Leaf folders only (no subfolders) — the ones that can hold routines.
    let routineHoldingFolders: [RoutineFolderModel]
    let ungrouped: [RoutineModel]
    let routines: (RoutineFolderModel) -> [RoutineModel]
    let label: (RoutineFolderModel) -> String
    let onMoveFolders: (IndexSet, Int) -> Void
    let onMoveUngrouped: (IndexSet, Int) -> Void
    let onMoveRoutines: (RoutineFolderModel, IndexSet, Int) -> Void

    var body: some View {
        NavigationStack {
            List {
                if !topLevelFolders.isEmpty {
                    Section("Folders") {
                        ForEach(topLevelFolders) { folder in
                            row(icon: "folder.fill", title: folder.name)
                        }
                        .onMove(perform: onMoveFolders)
                    }
                }
                if !ungrouped.isEmpty {
                    Section("Ungrouped Routines") {
                        ForEach(ungrouped) { routine in
                            row(icon: "list.bullet.clipboard", title: routine.name)
                        }
                        .onMove(perform: onMoveUngrouped)
                    }
                }
                ForEach(routineHoldingFolders) { folder in
                    let items = routines(folder)
                    if !items.isEmpty {
                        Section(label(folder)) {
                            ForEach(items) { routine in
                                row(icon: "list.bullet.clipboard", title: routine.name)
                            }
                            .onMove { onMoveRoutines(folder, $0, $1) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(.bodyStrong)
                }
            }
        }
    }

    private func row(icon: String, title: String) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon).foregroundStyle(theme.textSecondary).frame(width: 20)
            Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
            Spacer()
        }
        .listRowBackground(theme.surface)
        .listRowSeparatorTint(theme.separator)
    }
}

/// A single routine card with title, exercise summary, and a blue Start button.
/// The whole card is tappable to open the routine detail; the Start button
/// and ellipsis menu are discrete tap targets that don't trigger navigation.
private struct RoutineCard: View {
    @Environment(\.theme) private var theme
    let routine: RoutineModel
    let exercises: [ExerciseLibraryModel]
    let isSummaryExpanded: Bool
    let alternationState: RoutineAlternationService.State?
    let isAlternationOwner: Bool
    let hasConfiguredAlternation: Bool
    let onStart: (RoutineModel) -> Void
    let onEdit: () -> Void
    let onManageAlternation: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onArchive: () -> Void
    /// (folder id, display label) for every folder this routine could move
    /// into — the accessible alternative to dragging the card onto a folder.
    var moveDestinations: [(id: UUID, label: String)] = []
    var showsMoveToRoot: Bool = false
    var onMove: (UUID?) -> Void = { _ in }
    var onReorderDragChanged: (CGFloat) -> Void = { _ in }
    var onReorderDragEnded: () -> Void = {}
    var onAccessibilityMoveBy: (Int) -> Void = { _ in }
    var onToggleSummary: () -> Void = {}

    private var displayRoutine: RoutineModel {
        isAlternationOwner ? (alternationState?.due ?? routine) : routine
    }
    private var pairedRoutine: RoutineModel? {
        guard let alternationState else { return nil }
        return alternationState.owner.id == routine.id
            ? alternationState.partner
            : alternationState.owner
    }
    private var otherStartRoutine: RoutineModel? {
        isAlternationOwner ? alternationState?.other : nil
    }
    private var orderedItems: [OrderedRoutineItem] { OrderedRoutineItem.ordered(in: displayRoutine) }
    private var hasExerciseDisclosure: Bool {
        orderedItems.filter {
            if case .exercise = $0 { return true }
            return false
        }.count >= 3
    }
    private var cardBottomPadding: CGFloat {
        guard hasExerciseDisclosure, otherStartRoutine == nil else { return Space.lg }
        return isSummaryExpanded ? Space.xs : 0
    }

    private var conditioningSummary: String? {
        let json = displayRoutine.blocks.first(where: { $0.kind == .conditioning })?.planJSON
            ?? displayRoutine.conditioningPlanJSON
        guard let plan = ConditioningPlan.decode(from: json),
              let first = plan.sections.first else { return nil }
        switch first.format {
        case .amrap:
            return "\(max(1, (first.durationSeconds ?? 1_200) / 60)) min AMRAP"
        case .emom:
            return "EMOM \(first.rounds ?? 20)"
        case .forTime:
            return "For Time"
        default:
            return first.format.title
        }
    }

    var body: some View {
        NavigationLink(value: displayRoutine) {
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(displayRoutine.name)
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Button {
                            onStart(displayRoutine)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                Text("Start")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(theme.accent)
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                        // An empty routine has nothing to start — starting it
                        // would just open a blank freestyle session.
                        .disabled(orderedItems.isEmpty)
                        .accessibilityLabel("Start \(displayRoutine.name)")
                        .accessibilityIdentifier("start-routine-\(displayRoutine.name)")
                        ReorderHandle(
                            onDragChanged: onReorderDragChanged,
                            onDragEnded: onReorderDragEnded,
                            onAccessibilityMoveBy: onAccessibilityMoveBy,
                            accessibilityLabelText: "Reorder \(routine.name)",
                            accessibilityHintText: "Hold, then drag to reorder this routine or move it between folders",
                            accessibilityIdentifierText: "reorder-routine-\(routine.name)"
                        )
                        Menu {
                            Button("Edit \(routine.name)", systemImage: "pencil", action: onEdit)
                            Button("Duplicate \(routine.name)", systemImage: "doc.on.doc", action: onDuplicate)
                            Button(
                                hasConfiguredAlternation ? "Manage Alternating Routine" : "Add Alternating Routine",
                                systemImage: "arrow.triangle.2.circlepath",
                                action: onManageAlternation
                            )
                            // Accessible alternative to drag-and-drop nesting —
                            // VoiceOver / Switch Control users have no other
                            // way to move a routine between folders.
                            if showsMoveToRoot || !moveDestinations.isEmpty {
                                Menu {
                                    if showsMoveToRoot {
                                        Button("Ungrouped", systemImage: "tray") { onMove(nil) }
                                    }
                                    ForEach(moveDestinations, id: \.id) { destination in
                                        Button(destination.label, systemImage: "folder") { onMove(destination.id) }
                                    }
                                } label: {
                                    Label("Move to Folder…", systemImage: "folder.badge.gearshape")
                                }
                            }
                            Divider()
                            Button("Archive", systemImage: "archivebox", action: onArchive)
                            Button("Delete Routine", systemImage: "xmark", role: .destructive, action: onDelete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Routine options for \(routine.name)")
                        .accessibilityIdentifier("routine-menu-\(routine.name)")
                    }

                    if let pairedRoutine {
                        Label(
                            isAlternationOwner
                                ? "Next · alternates with \(otherStartRoutine?.name ?? pairedRoutine.name)"
                                : ((alternationState?.due.id == routine.id ? "Next · " : "") + "Alternates with \(pairedRoutine.name)"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .accessibilityIdentifier("alternating-routine-\(routine.id.uuidString)")
                    }

                    if orderedItems.isEmpty {
                        Text("Nothing added yet — add an exercise or block to start")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textTertiary)
                    } else {
                        if displayRoutine.blocks.isEmpty, let conditioningSummary {
                            Label(conditioningSummary, systemImage: "stopwatch")
                                .font(.tag)
                                .foregroundStyle(theme.accent)
                        }
                        RoutineExerciseSummaryDisclosure(
                            routineName: displayRoutine.name,
                            items: orderedItems,
                            exercises: exercises,
                            isExpanded: isSummaryExpanded,
                            onToggle: onToggleSummary
                        )
                    }

                    if let otherStartRoutine {
                        Button("Start \(otherStartRoutine.name) instead") {
                            onStart(otherStartRoutine)
                        }
                        .font(.system(size: 14, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .disabled(OrderedRoutineItem.ordered(in: otherStartRoutine).isEmpty)
                        .accessibilityIdentifier("start-alternate-\(otherStartRoutine.name)")
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.lg)
                .padding(.bottom, cardBottomPadding)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("routine-card-\(routine.name)")
    }

}

/// Typed pushes for Workout-tab screens that aren't model-backed.
enum WorkoutRoute: Hashable {
    case archive
    case microcycle(UUID)
}
