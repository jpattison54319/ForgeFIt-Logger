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
    /// The item currently being dragged. SwiftUI's drop target callback only
    /// tells us whether something is hovering, so we keep the payload here to
    /// make folder hover feedback specific instead of vague.
    @State private var draggedPayload: DragPayload?
    @State private var dropFeedback: DropFeedback?
    @State private var showExploreLibrary = false

    /// The active mesocycle: the folder whose routines Home rotates through.
    @AppStorage("activeFolderID") private var activeFolderRaw = ""

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
    private func isActiveFolder(_ folder: RoutineFolderModel) -> Bool {
        activeFolderRaw == folder.id.uuidString
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
                    Button { createFolder() } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                    }
                    .accessibilityIdentifier("new-folder-button")
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
                        let activeFolderID = UUID(uuidString: activeFolderRaw)
                        _ = RoutineTemplateCatalog.importTemplate(
                            template,
                            folderID: activeFolderID,
                            existingRoutines: activeRoutines,
                            in: modelContext
                        )
                        showExploreLibrary = false
                    }
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
        let isActive = isActiveFolder(folder)
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
            if isActive {
                Button("Clear Active Mesocycle", systemImage: "star.slash") { activeFolderRaw = "" }
            } else {
                Button("Set as Active Mesocycle", systemImage: "star") { activeFolderRaw = folder.id.uuidString }
            }
            Divider()
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
        RoutineCard(
            routine: routine,
            exercises: exercises,
            onStart: { start(routine) },
            onEdit: { edit(routine) },
            onDelete: { delete(routine) },
            onDuplicate: { duplicate(routine) }
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
        if isActiveFolder(folder) { activeFolderRaw = "" }
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
                            Button("Delete Routine", systemImage: "xmark", role: .destructive, action: onDelete)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .frame(width: 30, height: 30)
                        }
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
