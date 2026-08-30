import ForgeData
import SwiftData
import SwiftUI

/// Immutable editor input assembled when the user chooses Manage. Keeping the
/// library/history projections here prevents SwiftUI from rebuilding them as
/// the presented sheet's view value is reconstructed.
@MainActor
struct RoutineAlternationEditorPayload: Identifiable {
    let id = UUID()
    let anchor: RoutineModel
    let configuredAlternation: RoutineAlternationModel?
    let configuredAlternationUpdatedAt: Date?
    let routineByID: [UUID: RoutineModel]
    let folderPathByRoutineID: [UUID: String]
    let claimedRoutineIDs: Set<UUID>
    let initialMemberIDs: [UUID]
    let latestCompletionByMemberID: [UUID: RoutineAlternationDraft.Completion]

    init(
        anchor: RoutineModel,
        routines: [RoutineModel],
        folders: [RoutineFolderModel],
        alternations: [RoutineAlternationModel],
        workouts: [WorkoutModel]
    ) {
        self.anchor = anchor

        let configured = RoutineAlternationService.alternation(
            containing: anchor.id,
            in: alternations
        )
        configuredAlternation = configured
        configuredAlternationUpdatedAt = configured?.updatedAt

        let canonicalRoutines = RoutineDeduplicator.canonicalRoutines(routines)
        routineByID = Dictionary(
            canonicalRoutines.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        folderPathByRoutineID = Self.makeFolderPaths(
            routines: canonicalRoutines,
            folders: folders
        )

        let configuredIDs = configured.map {
            RoutineAlternationService.configuredMemberRoutineIDs(for: $0)
        } ?? [anchor.id]
        initialMemberIDs = configuredIDs.isEmpty ? [anchor.id] : configuredIDs
        let joinedAtByMemberID = configured.map { alternation in
            Dictionary(
                uniqueKeysWithValues: RoutineAlternationService.configuration(for: alternation)
                    .members
                    .map { ($0.routineID, $0.joinedAt) }
            )
        } ?? [:]

        var claimed: Set<UUID> = []
        for alternation in RoutineAlternationService.resolved(alternations)
            where alternation.id != configured?.id {
            claimed.formUnion(
                RoutineAlternationService.configuredMemberRoutineIDs(for: alternation)
            )
        }
        claimedRoutineIDs = claimed
        latestCompletionByMemberID = configured == nil ? [:] : Self.latestCompletions(
            among: Set(initialMemberIDs),
            workouts: workouts,
            joinedAtByMemberID: joinedAtByMemberID
        )
    }

    private static func latestCompletions(
        among memberIDs: Set<UUID>,
        workouts: [WorkoutModel],
        joinedAtByMemberID: [UUID: Date]
    ) -> [UUID: RoutineAlternationDraft.Completion] {
        var result: [UUID: RoutineAlternationDraft.Completion] = [:]
        for workout in workouts {
            guard workout.deletedAt == nil,
                  let routineID = workout.routineID,
                  memberIDs.contains(routineID),
                  let endedAt = workout.endedAt,
                  endedAt >= joinedAtByMemberID[routineID, default: .distantFuture] else {
                continue
            }
            let candidate = RoutineAlternationDraft.Completion(
                endedAt: endedAt,
                workoutID: workout.id
            )
            if let existing = result[routineID] {
                if existing.endedAt > candidate.endedAt { continue }
                if existing.endedAt == candidate.endedAt,
                   existing.workoutID.uuidString >= candidate.workoutID.uuidString {
                    continue
                }
            }
            result[routineID] = candidate
        }
        return result
    }

    private static func makeFolderPaths(
        routines: [RoutineModel],
        folders: [RoutineFolderModel]
    ) -> [UUID: String] {
        let folderByID = Dictionary(
            folders.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return Dictionary(uniqueKeysWithValues: routines.map { routine in
            let path: String
            if let folderID = routine.folderID, let folder = folderByID[folderID] {
                if let parentID = folder.parentID, let parent = folderByID[parentID] {
                    path = "\(parent.name) › \(folder.name)"
                } else {
                    path = folder.name
                }
            } else {
                path = "Ungrouped"
            }
            return (routine.id, path)
        })
    }
}

/// Stages the complete ordered membership of one alternating routine cycle.
/// Library order and folder membership are never changed here.
struct RoutineAlternationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let anchor: RoutineModel

    private let configuredAlternation: RoutineAlternationModel?
    private let configuredAlternationUpdatedAt: Date?
    private let routineByID: [UUID: RoutineModel]
    private let folderPathByRoutineID: [UUID: String]
    private let claimedRoutineIDs: Set<UUID>

    @State private var draft: RoutineAlternationDraft
    @State private var showingRoutinePicker = false
    @State private var showingDiscardConfirmation = false
    @State private var showingStopConfirmation = false
    @State private var showingError = false
    @State private var errorMessage = ""

    init(payload: RoutineAlternationEditorPayload) {
        anchor = payload.anchor
        configuredAlternation = payload.configuredAlternation
        configuredAlternationUpdatedAt = payload.configuredAlternationUpdatedAt
        routineByID = payload.routineByID
        folderPathByRoutineID = payload.folderPathByRoutineID
        claimedRoutineIDs = payload.claimedRoutineIDs
        _draft = State(initialValue: RoutineAlternationDraft(
            memberIDs: payload.initialMemberIDs,
            latestCompletionByMemberID: payload.latestCompletionByMemberID
        ))
    }

    private var hasUnavailableMembers: Bool {
        draft.memberIDs.contains { memberID in
            guard let routine = routineByID[memberID] else { return true }
            return routine.deletedAt != nil || routine.archivedAt != nil
        }
    }

    var body: some View {
        let unavailableMembers = hasUnavailableMembers
        let dueMemberID = draft.dueMemberID

        NavigationStack {
            List {
                Section {
                    ForEach(Array(draft.memberIDs.enumerated()), id: \.element) { index, memberID in
                        let routine = routineByID[memberID]
                        RoutineAlternationMemberRow(
                            routine: routine,
                            fallbackName: "Unavailable Routine",
                            location: memberLocation(for: routine),
                            position: index + 1,
                            memberCount: draft.memberIDs.count,
                            isNext: !unavailableMembers && dueMemberID == memberID,
                            allowsRemoval: configuredAlternation != nil
                                || (memberID != anchor.id && draft.memberIDs.count > 1),
                            removalStopsAlternation: configuredAlternation != nil
                                && draft.memberIDs.count <= 2,
                            onRemove: { draft.remove(memberID) },
                            onStopAlternating: stopAlternating
                        )
                    }
                    .onMove(perform: draft.move)

                    Button {
                        showingRoutinePicker = true
                    } label: {
                        Label("Add Routine", systemImage: "plus.circle.fill")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.accentForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .minimumTouchTarget()
                    }
                    .accessibilityIdentifier("add-alternating-routine")
                    .listRowBackground(theme.background)
                } header: {
                    Text("Order")
                }

                if unavailableMembers {
                    Section {
                        Label(
                            "Restore or remove unavailable routines before saving changes.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityIdentifier("alternation-unavailable-members")
                        .listRowBackground(theme.background)
                    }
                }

                if configuredAlternation != nil {
                    Section {
                        Button(
                            "Stop Alternating",
                            systemImage: "link.badge.minus",
                            role: .destructive
                        ) {
                            showingStopConfirmation = true
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .listRowBackground(theme.background)
                        .accessibilityIdentifier("remove-routine-alternation")
                        .confirmationDialog(
                            "Stop alternating these routines?",
                            isPresented: $showingStopConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Stop Alternating", role: .destructive, action: stopAlternating)
                            Button("Cancel", role: .cancel) { }
                        } message: {
                            Text("The routines stay in your library and remain available to start.")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Alternating Routines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .confirmationDialog(
                            "Discard alternation changes?",
                            isPresented: $showingDiscardConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("Discard Changes", role: .destructive, action: dismiss.callAsFunction)
                            Button("Keep Editing", role: .cancel) { }
                        } message: {
                            Text("The cycle will stay as it was before you opened this screen.")
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes", systemImage: "checkmark", action: save)
                        .labelStyle(.iconOnly)
                        .font(.bodyStrong)
                        .disabled(!draft.canSave || unavailableMembers)
                        .accessibilityIdentifier("save-routine-alternation")
                }
            }
            .navigationDestination(isPresented: $showingRoutinePicker) {
                RoutineAlternationPicker(
                    routines: Array(routineByID.values),
                    existingMemberIDs: Set(draft.memberIDs),
                    claimedRoutineIDs: claimedRoutineIDs,
                    folderPathByRoutineID: folderPathByRoutineID
                ) { routine in
                    draft.add(routine.id)
                }
            }
        }
        .interactiveDismissDisabled(draft.hasChanges)
        .alert("Couldn't update alternation", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .accessibilityIdentifier("routine-alternation-organizer")
    }

    private func memberLocation(for routine: RoutineModel?) -> String {
        guard let routine else { return "Unavailable" }
        if routine.deletedAt != nil { return "Unavailable" }
        if routine.archivedAt != nil {
            return "Archived · \(folderPathByRoutineID[routine.id, default: "Ungrouped"])"
        }
        return folderPathByRoutineID[routine.id, default: "Ungrouped"]
    }

    private func cancel() {
        if draft.hasChanges {
            showingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard draft.canSave else { return }
        if configuredAlternation != nil, !draft.hasChanges {
            dismiss()
            return
        }
        guard !hasUnavailableMembers else {
            presentError("Restore or remove unavailable routines before saving changes.")
            return
        }
        let orderedMembers = draft.memberIDs.compactMap { routineByID[$0] }
        guard orderedMembers.count == draft.memberIDs.count else {
            presentError("Your routine library changed while this screen was open. Close it and try again.")
            return
        }

        do {
            if let configuredAlternation {
                guard configuredAlternationIsCurrent(configuredAlternation) else {
                    presentError("This alternating cycle changed while this screen was open. Close it and try again.")
                    return
                }
                try RoutineAlternationService.update(
                    configuredAlternation,
                    orderedMembers: orderedMembers,
                    in: modelContext,
                    now: .now
                )
            } else {
                try RoutineAlternationService.create(
                    owner: anchor,
                    members: orderedMembers,
                    in: modelContext,
                    now: .now
                )
            }
            publishRoutineChanges()
            dismiss()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func stopAlternating() {
        guard let configuredAlternation else {
            dismiss()
            return
        }
        guard configuredAlternationIsCurrent(configuredAlternation) else {
            presentError("This alternating cycle changed while this screen was open. Close it and try again.")
            return
        }
        do {
            try RoutineAlternationService.remove(configuredAlternation, in: modelContext)
            publishRoutineChanges()
            dismiss()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func configuredAlternationIsCurrent(
        _ alternation: RoutineAlternationModel
    ) -> Bool {
        alternation.deletedAt == nil
            && alternation.updatedAt == configuredAlternationUpdatedAt
            && RoutineAlternationService.configuredMemberRoutineIDs(for: alternation)
                == draft.originalMemberIDs
    }

    private func publishRoutineChanges() {
        WatchLink.shared.invalidateRoutineSummaryCache()
        WatchLink.shared.publishState(policy: .immediate)
    }

    private func presentError(_ message: String) {
        errorMessage = message
        showingError = true
    }

}
