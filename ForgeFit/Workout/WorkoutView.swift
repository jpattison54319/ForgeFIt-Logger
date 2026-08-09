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
    case root
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

    let routines: [RoutineModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    @Query(sort: \RoutineFolderModel.position) private var allFolders: [RoutineFolderModel]
    @Query(sort: \MicrocycleTrackingModel.updatedAt, order: .reverse)
    private var microcycleTrackings: [MicrocycleTrackingModel]
    @Query(sort: \MicrocycleWindowModel.startsAt, order: .reverse)
    private var microcycleWindows: [MicrocycleWindowModel]

    @State private var collapsed: Set<UUID> = []
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
    @State private var showExploreLibrary = false
    /// Accessible alternative to drag-reordering: a List with drag handles
    /// that VoiceOver / Switch Control can operate, matching the reorder mode
    /// already used in the routine editor and the live logger.
    @State private var editingOrder = false
    @State private var trackingFolder: RoutineFolderModel?

    /// A mesocycle can contain several microcycles. Home uses the active
    /// microcycle first, then its broader mesocycle, then the full library.
    @AppStorage(CyclePreferenceMigration.activeMesocycleKey)
    private var activeMesocycleFolderRaw = ""
    @AppStorage(CyclePreferenceMigration.activeMicrocycleKey)
    private var activeMicrocycleFolderRaw = ""

    private var activeRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil && $0.archivedAt == nil }.sorted { $0.position < $1.position }
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
            ScreenScaffold("Workout") {
                SecondaryButton(title: "Start Empty Workout", systemImage: "plus") {
                    appState.requestStart {
                        _ = WorkoutFactory.startEmpty(in: modelContext)
                        appState.showingLogger = true
                    }
                }

                SectionHeader("Routines") {
                    HStack(spacing: Space.lg) {
                        // Accessible alternative to drag-reordering — VoiceOver /
                        // Switch Control have no other way to reorder routines
                        // or folders (drag/drop only ever moved things BETWEEN
                        // folders; nothing reordered position within one).
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

                // Ungrouped routines (also the drop target to pull a routine OUT of a folder)
                VStack(spacing: Space.md) {
                    ForEach(ungrouped) { routine in routineCard(routine) }
                }
                .frame(maxWidth: .infinity, minHeight: ungrouped.isEmpty ? Space.lg : 0, alignment: .top)
                .contentShape(Rectangle())
                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                    handleDrop(providers, into: nil)
                }

                ForEach(topLevelFolders) { folder in folderSection(folder) }

                // Pinned below everything that's live; exists only once
                // something is archived, so it never clutters a fresh library.
                if archiveInventory.rootCount > 0 {
                    archiveRow
                }
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
        }
        .id(tabRootRequestID)
        .onChange(of: appState.pendingRoutineDetailID, initial: true) {
            openPendingImportedRoutineIfAvailable()
        }
        .onChange(of: activeRoutines.map(\.id)) {
            openPendingImportedRoutineIfAvailable()
        }
        .task {
            CyclePreferenceMigration.migrate()
            _ = try? MicrocycleTrackingService.reconcile(in: modelContext)
        }
        .interactiveBackSwipeEnabled()
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
        let items = routines(in: folder)
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
                            Text(children.isEmpty ? "MICROCYCLE" : "MESOCYCLE")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(theme.textTertiary)
                            let count = children.isEmpty ? items.count : children.count
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
                    // Folders drag like routines — drop one onto another to nest.
                    .onDrag {
                        let payload = DragPayload.folder(folder.id)
                        draggedPayload = payload
                        return dragProvider(for: payload)
                    }
                    Spacer()
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
                                        : "Day \(MicrocycleTrackingService.dayNumber(for: trackedWindow)) of \(activeTracking.durationDays) · \(progress.completedCount) of \(progress.requiredCount) workouts")
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
                }

                if !isCollapsed {
                    if items.isEmpty && children.isEmpty && !isTargeted {
                        dropHint("Drop routines or a folder here")
                    } else {
                        ForEach(items) { routine in routineCard(routine) }
                        ForEach(children) { child in folderSection(child) }
                    }
                }

                // Live feedback while a drag hovers this folder: say exactly
                // what a release will do here.
                if let feedback {
                    dropHint(feedback)
                }
            }
            .padding(Space.sm)
            .background(folderBackground(isTargeted: isTargeted, isRejected: isRejected))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .stroke(
                        folderStroke(isTargeted: isTargeted, isRejected: isRejected, isActive: isActive),
                        lineWidth: isTargeted ? 2 : 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isTargeted)
            .onDrop(of: [.plainText], isTargeted: Binding(
                get: { dropFeedback?.target == target },
                set: { hovering in
                    if hovering {
                        dropFeedback = folderDropFeedback(for: folder)
                        // Spring open so the user can see where things will land.
                        withAnimation(.easeOut(duration: 0.2)) { _ = collapsed.remove(folder.id) }
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
                return DropFeedback(target: target, accepts: true, title: "Release to add here", detail: "Accepts routines and child folders")
            }
            return DropFeedback(target: target, accepts: true, title: "Release to nest a folder here", detail: "Routines stay inside child folders")
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
            return DropFeedback(target: target, accepts: true, title: "Release to add routine", detail: "Moves \(routine.name) into \(folder.name)")

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
            return DropFeedback(target: target, accepts: true, title: "Release to nest folder", detail: "Moves \(dragged.name) into \(folder.name)")
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
                        Button("Top Level", systemImage: "arrow.up.to.line") { nest(folder, into: nil) }
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
                    exercises: exercises
                )
                : PlanShareService.microcycleDocument(
                    folder,
                    routines: sharedRoutines,
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

    /// Routes a drop of routines and/or folders onto `folder` (nil = root).
    private func handleDrop(_ providers: [NSItemProvider], into folder: RoutineFolderModel?) -> Bool {
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
                    _ = handleDrop([payload], into: folder)
                    clearDragFeedback()
                }
            }
        }
        return true
    }

    /// Routes a drop of routines and/or folders onto `folder` (nil = root).
    private func handleDrop(_ payloads: [String], into folder: RoutineFolderModel?) -> Bool {
        var handled = false
        for payload in payloads {
            guard let parsed = DragPayload(rawValue: payload) else { continue }
            switch parsed {
            case .folder(let id):
                guard let dragged = folders.first(where: { $0.id == id }) else { continue }
                handled = nest(dragged, into: folder) || handled

            case .routine(let id):
                guard let routine = activeRoutines.first(where: { $0.id == id }) else {
                    continue
                }
                if routine.folderID == folder?.id { continue }
                // Folders that contain subfolders hold folders only.
                if let folder, !childFolders(of: folder).isEmpty { continue }
                routine.folderID = folder?.id
                routine.updatedAt = Date()
                handled = true
            }
        }
        if handled { save() }
        return handled
    }

    private func dropHint(_ text: String) -> some View {
        dropHint(DropFeedback(target: .root, accepts: true, title: text, detail: nil))
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
        return RoutineCard(
            routine: routine,
            exercises: exercises,
            onStart: { start(routine) },
            onEdit: { edit(routine) },
            onDelete: { routinePendingDelete = routine },
            onDuplicate: { duplicate(routine) },
            onArchive: { archive(routine) },
            moveDestinations: destinations.map { ($0.id, destinationLabel($0)) },
            showsMoveToRoot: routine.folderID != nil,
            onMove: { folderID in moveRoutine(routine, toFolder: folderID) }
        )
        .contentShape(Rectangle())
        .onDrag {
            let payload = DragPayload.routine(routine.id)
            draggedPayload = payload
            return dragProvider(for: payload)
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
        return theme.surface.opacity(0.5)
    }

    private func folderStroke(isTargeted: Bool, isRejected: Bool, isActive: Bool) -> Color {
        if isTargeted { return isRejected ? theme.danger : theme.accent }
        return isActive ? theme.accent.opacity(0.45) : theme.separator
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
        folders.filter { childFolders(of: $0).isEmpty }
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
        guard routine.folderID != folderID else { return }
        routine.folderID = folderID
        routine.updatedAt = Date()
        save()
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

/// Drag-handle reordering for routines and top-level folders — the
/// accessible counterpart to the Workout tab's drag & drop, which only ever
/// moves things BETWEEN folders and never reorders position within one.
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
    let onStart: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onArchive: () -> Void
    /// (folder id, display label) for every folder this routine could move
    /// into — the accessible alternative to dragging the card onto a folder.
    var moveDestinations: [(id: UUID, label: String)] = []
    var showsMoveToRoot: Bool = false
    var onMove: (UUID?) -> Void = { _ in }

    private var sortedRoutineExercises: [RoutineExerciseModel] {
        routine.exercises.sorted { $0.position < $1.position }
    }
    private var orderedItems: [OrderedRoutineItem] { OrderedRoutineItem.ordered(in: routine) }

    private func exerciseName(for re: RoutineExerciseModel) -> String {
        exercises.first { $0.id == re.exerciseID }?.name ?? "Exercise"
    }

    private var conditioningSummary: String? {
        let json = routine.blocks.first(where: { $0.kind == .conditioning })?.planJSON
            ?? routine.conditioningPlanJSON
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
        NavigationLink(value: routine) {
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(routine.name)
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Space.sm)
                        Button {
                            onStart()
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
                        .accessibilityIdentifier("start-routine-\(routine.name)")
                        Menu {
                            Button("Edit Routine", systemImage: "pencil", action: onEdit)
                            Button("Duplicate Routine", systemImage: "doc.on.doc", action: onDuplicate)
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

                    if orderedItems.isEmpty {
                        Text("Nothing added yet — add an exercise or block to start")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textTertiary)
                    } else {
                        if routine.blocks.isEmpty, let conditioningSummary {
                            Label(conditioningSummary, systemImage: "stopwatch")
                                .font(.tag)
                                .foregroundStyle(theme.accent)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(orderedItems) { item in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(theme.textTertiary)
                                        .frame(width: 4, height: 4)
                                    Text(itemName(item))
                                        .font(.system(size: 14))
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func itemName(_ item: OrderedRoutineItem) -> String {
        switch item {
        case .exercise(let exercise): exerciseName(for: exercise)
        case .block(let block): block.kind.title
        }
    }
}

/// Typed pushes for Workout-tab screens that aren't model-backed.
enum WorkoutRoute: Hashable {
    case archive
    case microcycle(UUID)
}
