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
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState

    let routines: [RoutineModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    @Query(sort: \RoutineFolderModel.position) private var allFolders: [RoutineFolderModel]

    @State private var collapsed: Set<UUID> = []
    @State private var newRoutine: RoutineModel?
    @State private var renamingFolder: RoutineFolderModel?
    @State private var folderNameDraft = ""
    @State private var sharePayload: ShareImagePayload?
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

    /// The active macrocycle: when no mesocycle is more specifically active,
    /// Home rotates through every mesocycle nested inside it.
    @AppStorage("activeMacroFolderID") private var activeMacroFolderRaw = ""
    /// The active mesocycle: the most specific "what am I actually running
    /// right now" signal. A macrocycle can hold several mesocycles, so these
    /// are independent — Home drills into the mesocycle first, then falls
    /// back to the macrocycle, then to best-guessing from the full list.
    @AppStorage("activeMesoFolderID") private var activeMesoFolderRaw = ""

    private var activeRoutines: [RoutineModel] {
        routines.filter { $0.deletedAt == nil }.sorted { $0.position < $1.position }
    }
    private var folders: [RoutineFolderModel] {
        allFolders.filter { $0.deletedAt == nil }.sorted { $0.position < $1.position }
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
    private func isActiveMacro(_ folder: RoutineFolderModel) -> Bool {
        activeMacroFolderRaw == folder.id.uuidString
    }
    private func isActiveMeso(_ folder: RoutineFolderModel) -> Bool {
        activeMesoFolderRaw == folder.id.uuidString
    }
    /// Setting a mesocycle active also adopts its parent macrocycle (if any)
    /// — drilling into a specific mesocycle means you're "in" that
    /// macrocycle too, so the two stay consistent with each other.
    private func setActiveMeso(_ folder: RoutineFolderModel) {
        activeMesoFolderRaw = folder.id.uuidString
        if let parentID = folder.parentID { activeMacroFolderRaw = parentID.uuidString }
    }
    /// Setting a macrocycle active keeps the current mesocycle active only if
    /// it's actually nested inside this macrocycle — otherwise it no longer
    /// makes sense as "the specific plan within the active macro".
    private func setActiveMacro(_ folder: RoutineFolderModel) {
        activeMacroFolderRaw = folder.id.uuidString
        if let mesoID = UUID(uuidString: activeMesoFolderRaw),
           mesoID != folder.id, !childFolders(of: folder).contains(where: { $0.id == mesoID }) {
            activeMesoFolderRaw = ""
        }
    }

    var body: some View {
        NavigationStack {
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
                    SecondaryButton(title: "New Routine", systemImage: "list.bullet.clipboard") { createRoutine(folderID: nil) }
                    SecondaryButton(title: "Explore", systemImage: "sparkles") { showExploreLibrary = true }
                }

                if activeRoutines.isEmpty && folders.isEmpty {
                    EmptyStateCard(
                        title: "No routines yet",
                        message: "Create a routine, or make a folder and drag routines into it.",
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
            }
            .navigationDestination(for: RoutineModel.self) { routine in
                RoutineDetailView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
            .navigationDestination(item: $newRoutine) { routine in
                RoutineEditorView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
            .toolbar(.hidden, for: .navigationBar)
            .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
                TextField("Folder name", text: $folderNameDraft)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renamingFolder = nil }
            }
            .sheet(isPresented: $showExploreLibrary) {
                RoutineLibraryView(
                    templates: RoutineTemplateCatalog.validTemplates(from: RoutineTemplateCatalog.load(), exercises: exercises),
                    exercises: exercises,
                    onImport: { template in
                        // Only a mesocycle (leaf folder) can directly hold a
                        // routine — a macrocycle-only active state has
                        // nowhere concrete to import into, so it lands
                        // ungrouped instead.
                        _ = RoutineTemplateCatalog.importTemplate(
                            template,
                            folderID: UUID(uuidString: activeMesoFolderRaw),
                            existingRoutines: activeRoutines,
                            in: modelContext
                        )
                        showExploreLibrary = false
                    }
                )
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: [payload.image])
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
        }
        .interactiveBackSwipeEnabled()
    }

    // MARK: - Folder section

    private func folderSection(_ folder: RoutineFolderModel) -> AnyView {
        let isCollapsed = collapsed.contains(folder.id)
        let items = routines(in: folder)
        let children = childFolders(of: folder)
        // A folder is either a macrocycle (has children) or a mesocycle
        // (leaf) — check whichever active slot applies to its role.
        let isActive = children.isEmpty ? isActiveMeso(folder) : isActiveMacro(folder)
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
            // Independent slots: a macrocycle and one of its mesocycles can
            // both be active at once (that's the whole point — a macro can
            // hold several mesocycles, only one of which you're running now).
            if hasChildren {
                if isActive {
                    Button("Clear Active Macrocycle", systemImage: "star.slash") { activeMacroFolderRaw = "" }
                } else {
                    Button("Set as Active Macrocycle", systemImage: "star") { setActiveMacro(folder) }
                }
            } else {
                if isActive {
                    Button("Clear Active Mesocycle", systemImage: "star.slash") { activeMesoFolderRaw = "" }
                } else {
                    Button("Set as Active Mesocycle", systemImage: "star") { setActiveMeso(folder) }
                }
            }
            Divider()
            Button(hasChildren ? "Share Macrocycle" : "Share Mesocycle", systemImage: "square.and.arrow.up") {
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
            Button("Delete Folder", systemImage: "trash", role: .destructive) { deleteFolder(folder) }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(theme.textSecondary).frame(width: 30, height: 30)
        }
    }

    /// Render a training-cycle folder to a single tall image and present the
    /// share sheet. A folder with subfolders shares as a macrocycle (routines
    /// grouped under each mesocycle); otherwise as a mesocycle (its routines).
    private func shareFolder(_ folder: RoutineFolderModel, hasChildren: Bool) {
        let sections: [FolderShareCard.Section]
        if hasChildren {
            sections = childFolders(of: folder).map { sub in
                FolderShareCard.Section(title: sub.name, routines: routines(in: sub))
            }
        } else {
            sections = [FolderShareCard.Section(title: nil, routines: routines(in: folder))]
        }
        if let image = FolderShareRenderer.image(
            name: folder.name,
            isMacro: hasChildren,
            sections: sections,
            exercises: exercises,
            theme: theme
        ) {
            sharePayload = ShareImagePayload(image: image)
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
            onDelete: { delete(routine) },
            onDuplicate: { duplicate(routine) },
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
        newRoutine = routine
    }

    private func createFolder(parentID: UUID? = nil) {
        let folder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "New Folder",
            position: folders.count,
            parentID: parentID
        )
        modelContext.insert(folder)
        // A parent gaining its first subfolder holds only folders from then on
        // — its loose routines move into the new subfolder.
        if let parentID, let parent = folders.first(where: { $0.id == parentID }) {
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
        startRename(folder)
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
        if isActiveMacro(folder) { activeMacroFolderRaw = "" }
        if isActiveMeso(folder) { activeMesoFolderRaw = "" }
        folder.updatedAt = now
        folder.deletedAt = now
        save()
    }

    private func createRoutine(folderID: UUID?) {
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: activeRoutines.isEmpty ? "Full Body A" : "New Routine",
            folderID: folderID,
            position: activeRoutines.count
        )
        modelContext.insert(routine)
        save()
        newRoutine = routine
    }

    private func delete(_ routine: RoutineModel) {
        let now = Date()
        routine.updatedAt = now
        routine.deletedAt = now
        save()
    }

    private func duplicate(_ source: RoutineModel) {
        let copy = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "\(source.name) Copy",
            notes: source.notes,
            folderID: source.folderID,
            position: activeRoutines.count
        )
        copy.exercises = source.exercises
            .sorted { $0.position < $1.position }
            .map { sourceExercise in
                let copiedSets = sourceExercise.sets
                    .sorted { $0.position < $1.position }
                    .map { s in
                        RoutineSetModel(
                            userID: ForgeFitDemo.userID, position: s.position, setType: s.setType,
                            targetRepsLow: s.targetRepsLow, targetRepsHigh: s.targetRepsHigh,
                            targetWeight: s.targetWeight, targetRPE: s.targetRPE,
                            targetRIR: s.targetRIR, targetDurationSeconds: s.targetDurationSeconds
                        )
                    }
                return RoutineExerciseModel(
                    userID: ForgeFitDemo.userID, exerciseID: sourceExercise.exerciseID,
                    position: sourceExercise.position, supersetGroup: sourceExercise.supersetGroup,
                    progressionRuleID: sourceExercise.progressionRuleID, notes: sourceExercise.notes,
                    sets: copiedSets
                )
            }
        modelContext.insert(copy)
        try? modelContext.save()
    }

    private func save() {
        try? modelContext.save()
    }

    // MARK: - Move to folder (accessible alternative to drag & drop)

    /// Folders that can directly hold a routine — leaf folders only, whether
    /// standalone (a mesocycle) or nested under a macrocycle. A folder that
    /// itself has subfolders holds only folders, matching the drag/drop rule
    /// in `handleDrop`.
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
        .preferredColorScheme(.dark)
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
    /// (folder id, display label) for every folder this routine could move
    /// into — the accessible alternative to dragging the card onto a folder.
    var moveDestinations: [(id: UUID, label: String)] = []
    var showsMoveToRoot: Bool = false
    var onMove: (UUID?) -> Void = { _ in }

    private var sortedRoutineExercises: [RoutineExerciseModel] {
        routine.exercises.sorted { $0.position < $1.position }
    }

    private func exerciseName(for re: RoutineExerciseModel) -> String {
        exercises.first { $0.id == re.exerciseID }?.name ?? "Exercise"
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
                            Button("Delete Routine", systemImage: "xmark", role: .destructive, action: onDelete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 30, height: 30)
                        }
                        .accessibilityIdentifier("routine-menu-\(routine.name)")
                    }

                    if sortedRoutineExercises.isEmpty {
                        Text("No exercises yet")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textTertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(sortedRoutineExercises) { re in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(theme.textTertiary)
                                        .frame(width: 4, height: 4)
                                    Text(exerciseName(for: re))
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
}
