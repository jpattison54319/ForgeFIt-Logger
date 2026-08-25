import ForgeData
import SwiftData
import SwiftUI

struct RoutineOrganizerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let folders: [RoutineFolderModel]
    let routines: [RoutineModel]

    @State private var draft: RoutineOrganizerDraft
    @State private var entries: [RoutineOrganizerDraft.Entry]
    @State private var showingDiscardConfirmation = false

    @AppStorage(CyclePreferenceMigration.activeMesocycleKey)
    private var activeMesocycleFolderRaw = ""
    @AppStorage(CyclePreferenceMigration.activeMicrocycleKey)
    private var activeMicrocycleFolderRaw = ""

    init(
        folders: [RoutineFolderModel],
        routines: [RoutineModel],
        alternationStates: [RoutineAlternationService.State]
    ) {
        self.folders = folders
        self.routines = routines
        let initialDraft = RoutineOrganizerDraft(
            folders: folders,
            routines: routines,
            alternationStates: alternationStates
        )
        _draft = State(initialValue: initialDraft)
        _entries = State(initialValue: initialDraft.entries)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    RoutineOrganizerEntryRow(draft: draft, entry: entry)
                        .moveDisabled(!entry.isMovable)
                }
                .onMove { offsets, destination in
                    entries.move(fromOffsets: offsets, toOffset: destination)
                    guard draft.moveEntries(from: offsets, to: destination) else {
                        entries = draft.entries
                        return
                    }
                    entries = draft.entries
                }
            }
            .listStyle(.plain)
            .listRowSpacing(0)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Organize Routines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                        .font(.bodyStrong)
                        .accessibilityIdentifier("save-routine-organization")
                }
            }
        }
        .onChange(of: draft.snapshot) {
            entries = draft.entries
        }
        .interactiveDismissDisabled(draft.hasChanges)
        .confirmationDialog(
            "Discard organization changes?",
            isPresented: $showingDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive, action: dismiss.callAsFunction)
            Button("Keep Organizing", role: .cancel) { }
        } message: {
            Text("Folder and routine order will stay as it was before you opened Organize.")
        }
        .accessibilityIdentifier("routine-organizer")
    }

    private func cancel() {
        if draft.hasChanges {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard draft.hasChanges else {
            dismiss()
            return
        }
        let committedAt = Date.now
        PersistentChangeSaveCenter.shared.perform({
            try RoutineOrganizerPersistence.commit(
                draft,
                folders: folders,
                routines: routines,
                in: modelContext,
                now: committedAt
            )
        }, onSuccess: {
            // The organizer rows are now durable. Refresh the active
            // microcycle's persisted checklist immediately so Home cannot
            // keep presenting its previous routine order until a later
            // lifecycle observer happens to reconcile it. The primary order
            // stays committed if this derived write fails, while the exact
            // reconciliation remains available through the global Retry.
            PersistentChangeSaveCenter.shared.perform({
                _ = try MicrocycleTrackingService.reconcileIsolated(
                    from: modelContext,
                    now: committedAt
                )
            }, onSuccess: {
                reconcileActiveCycle()
            })
            dismiss()
        })
    }

    private func reconcileActiveCycle() {
        guard let activeMicrocycleID = UUID(uuidString: activeMicrocycleFolderRaw) else { return }
        let previousParentID = draft.originalParentID(of: activeMicrocycleID)
        let parentID = draft.parentID(of: activeMicrocycleID)
        if let parentID {
            activeMesocycleFolderRaw = parentID.uuidString
        } else if previousParentID?.uuidString == activeMesocycleFolderRaw {
            activeMesocycleFolderRaw = ""
        }
    }
}
