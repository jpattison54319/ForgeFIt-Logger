import ForgeData
import SwiftData
import SwiftUI

/// Derives what the archive contains from the raw model arrays. Shared by the
/// Workout tab's entry row (count) and the Archive screen (lists) so the two
/// can never disagree.
struct ArchiveInventory {
    let archivedFolders: [RoutineFolderModel]
    let archivedRoutines: [RoutineModel]
    /// The units the user archived: folders whose parent isn't archived and
    /// routines whose folder isn't archived. Children of an archived folder
    /// stay inside their unit rather than triple-listing in "All".
    let rootFolders: [RoutineFolderModel]
    let rootRoutines: [RoutineModel]

    private let foldersByID: [UUID: RoutineFolderModel]

    init(routines: [RoutineModel], folders: [RoutineFolderModel]) {
        let liveRows = folders.filter { $0.deletedAt == nil }
        // CloudKit can briefly deliver duplicate-id rows; first-wins like the
        // rest of the app.
        var byID: [UUID: RoutineFolderModel] = [:]
        for folder in liveRows where byID[folder.id] == nil { byID[folder.id] = folder }
        foldersByID = byID

        archivedFolders = byID.values.filter { $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
        archivedRoutines = routines.filter { $0.deletedAt == nil && $0.archivedAt != nil }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }

        rootFolders = archivedFolders.filter { folder in
            guard let parentID = folder.parentID, let parent = byID[parentID] else { return true }
            return parent.archivedAt == nil
        }
        rootRoutines = archivedRoutines.filter { routine in
            guard let folderID = routine.folderID, let parent = byID[folderID] else { return true }
            return parent.archivedAt == nil
        }
    }

    var rootCount: Int { rootFolders.count + rootRoutines.count }

    func isMacrocycle(_ folder: RoutineFolderModel) -> Bool {
        foldersByID.values.contains { $0.parentID == folder.id }
    }

    func archivedChildFolders(of folder: RoutineFolderModel) -> [RoutineFolderModel] {
        archivedFolders.filter { $0.parentID == folder.id }
    }

    func archivedRoutineCount(inSubtreeOf folder: RoutineFolderModel) -> Int {
        var folderIDs: Set<UUID> = [folder.id]
        archivedChildFolders(of: folder).forEach { folderIDs.insert($0.id) }
        return archivedRoutines.count { routine in
            routine.folderID.map(folderIDs.contains) ?? false
        }
    }

    func folderName(for id: UUID?) -> String? {
        id.flatMap { foldersByID[$0]?.name }
    }
}

/// The archive: everything hidden-but-kept, filterable by kind, restorable in
/// one tap, or deletable for good.
struct ArchiveView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let routines: [RoutineModel]
    let folders: [RoutineFolderModel]

    @State private var filter: ArchiveFilter = .all
    @State private var routinePendingDelete: RoutineModel?
    @State private var folderPendingDelete: RoutineFolderModel?

    enum ArchiveFilter: String, CaseIterable, Hashable {
        case all = "All"
        case macrocycles = "Macros"
        case mesocycles = "Mesos"
        case routines = "Routines"
    }

    private var inventory: ArchiveInventory {
        ArchiveInventory(routines: routines, folders: folders)
    }

    /// One list, filter-dependent. "All" shows the archived UNITS; the kind
    /// filters flatten so a routine buried in an archived macrocycle is still
    /// findable under Routines.
    private var items: [ArchiveItem] {
        let inventory = inventory
        switch filter {
        case .all:
            return (inventory.rootFolders.map(ArchiveItem.folder) + inventory.rootRoutines.map(ArchiveItem.routine))
                .sorted { $0.archivedAt > $1.archivedAt }
        case .macrocycles:
            return inventory.archivedFolders.filter { inventory.isMacrocycle($0) }.map(ArchiveItem.folder)
        case .mesocycles:
            return inventory.archivedFolders.filter { !inventory.isMacrocycle($0) }.map(ArchiveItem.folder)
        case .routines:
            return inventory.archivedRoutines.map(ArchiveItem.routine)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.lg) {
                header

                SegmentedPills(
                    options: ArchiveFilter.allCases,
                    title: { $0.rawValue },
                    selection: $filter
                )

                Text(countLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)

                if items.isEmpty {
                    EmptyStateCard(
                        title: "Nothing archived",
                        message: "Archive routines and cycles from their ⋯ menus to tuck them away without deleting anything.",
                        systemImage: "archivebox"
                    )
                } else {
                    ForEach(items) { item in
                        itemCard(item)
                    }
                }

                footerCard
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .background(theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveBackSwipeEnabled()
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
                if let folder = folderPendingDelete { delete(folder) }
                folderPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDelete = nil }
        } message: {
            Text("Anything inside stays archived and moves up a level — nothing inside is deleted.")
        }
    }

    private var header: some View {
        HStack {
            CircleIconButton(systemImage: "chevron.left", label: "Back") { dismiss() }
            Spacer()
            Text("Archive").font(.rowValue).foregroundStyle(theme.textPrimary)
            Spacer()
            // Balances the back button so the title stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.top, Space.sm)
    }

    private var countLine: String {
        let count = items.count
        let noun: String
        switch filter {
        case .all: noun = count == 1 ? "archived item" : "archived items"
        case .macrocycles: noun = count == 1 ? "macrocycle" : "macrocycles"
        case .mesocycles: noun = count == 1 ? "mesocycle" : "mesocycles"
        case .routines: noun = count == 1 ? "routine" : "routines"
        }
        return "\(count) \(noun)"
    }

    private var footerCard: some View {
        Card(padding: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: "archivebox")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Text("Archived items are hidden from Workout, Home, the watch, and quick actions. Restore anytime, or delete permanently.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Rows

    private func itemCard(_ item: ArchiveItem) -> some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(alignment: .center, spacing: Space.md) {
                    Image(systemName: icon(for: item))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(theme.accent)
                        .frame(width: 36, height: 36)
                        .background(theme.surfaceElevated)
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Space.sm) {
                            Text(item.name)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            kindBadge(for: item)
                        }
                        Text(subtitle(for: item))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: Space.sm)

                    Button("Restore") { restore(item) }
                        .buttonStyle(.glassProminent)
                        .tint(theme.accent)
                        .controlSize(.small)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("archive-restore-\(item.name)")

                    Menu {
                        Button(deleteMenuTitle(for: item), systemImage: "trash", role: .destructive) {
                            switch item {
                            case .folder(let folder): folderPendingDelete = folder
                            case .routine(let routine): routinePendingDelete = routine
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Archive options for \(item.name)")
                }

                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Archived \(item.archivedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(theme.textTertiary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archive-item-\(item.name)")
    }

    private func kindBadge(for item: ArchiveItem) -> some View {
        Text(kindLabel(for: item))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.surfaceElevated)
            .clipShape(Capsule())
    }

    private func kindLabel(for item: ArchiveItem) -> String {
        switch item {
        case .folder(let folder): inventory.isMacrocycle(folder) ? "MACROCYCLE" : "MESOCYCLE"
        case .routine: "ROUTINE"
        }
    }

    private func icon(for item: ArchiveItem) -> String {
        switch item {
        case .folder(let folder): inventory.isMacrocycle(folder) ? "star.circle" : "folder"
        case .routine: "list.bullet.rectangle"
        }
    }

    private func subtitle(for item: ArchiveItem) -> String {
        let inventory = inventory
        switch item {
        case .folder(let folder):
            let routineCount = inventory.archivedRoutineCount(inSubtreeOf: folder)
            let routinePart = "\(routineCount) \(routineCount == 1 ? "routine" : "routines")"
            if inventory.isMacrocycle(folder) {
                let mesoCount = inventory.archivedChildFolders(of: folder).count
                return "\(mesoCount) \(mesoCount == 1 ? "mesocycle" : "mesocycles") · \(routinePart)"
            }
            if let parent = inventory.folderName(for: folder.parentID) {
                return "\(routinePart) · in \(parent)"
            }
            return routinePart
        case .routine(let routine):
            let count = routine.exercises.count
            let exercisePart = "\(count) \(count == 1 ? "exercise" : "exercises")"
            if let parent = inventory.folderName(for: routine.folderID) {
                return "\(exercisePart) · in \(parent)"
            }
            return exercisePart
        }
    }

    private func deleteMenuTitle(for item: ArchiveItem) -> String {
        switch item {
        case .folder: "Delete Folder"
        case .routine: "Delete Routine"
        }
    }

    // MARK: - Actions

    private func restore(_ item: ArchiveItem) {
        switch item {
        case .folder(let folder): try? RoutineArchiver.restore(folder, in: modelContext)
        case .routine(let routine): try? RoutineArchiver.restore(routine, in: modelContext)
        }
        try? modelContext.save()
    }

    /// Same soft-delete semantics as the Workout tab: a hard delete would
    /// fight CloudKit sync and the deduplicator's tombstone rules.
    private func delete(_ routine: RoutineModel) {
        let now = Date()
        routine.updatedAt = now
        routine.deletedAt = now
        try? modelContext.save()
    }

    private func delete(_ folder: RoutineFolderModel) {
        let now = Date()
        for routine in routines where routine.folderID == folder.id && routine.deletedAt == nil {
            routine.folderID = folder.parentID
            routine.updatedAt = now
        }
        for child in folders where child.parentID == folder.id && child.deletedAt == nil {
            child.parentID = folder.parentID
            child.updatedAt = now
        }
        folder.updatedAt = now
        folder.deletedAt = now
        try? modelContext.save()
    }
}

/// A folder or routine row in the archive, unified for the mixed "All" list.
private enum ArchiveItem: Identifiable {
    case folder(RoutineFolderModel)
    case routine(RoutineModel)

    var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .routine(let routine): routine.id
        }
    }

    var name: String {
        switch self {
        case .folder(let folder): folder.name
        case .routine(let routine): routine.name
        }
    }

    var archivedAt: Date {
        switch self {
        case .folder(let folder): folder.archivedAt ?? .distantPast
        case .routine(let routine): routine.archivedAt ?? .distantPast
        }
    }
}
