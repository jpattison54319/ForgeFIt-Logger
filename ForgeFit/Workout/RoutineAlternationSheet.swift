import ForgeData
import SwiftData
import SwiftUI

/// Creates or removes one alternating pair with routine and folder context
/// visible at the decision point. Already-paired routines remain visible but
/// unavailable, so the constraint never needs explanatory instructions.
struct RoutineAlternationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let anchor: RoutineModel
    let routines: [RoutineModel]
    let folders: [RoutineFolderModel]
    let alternations: [RoutineAlternationModel]
    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]
    let setupNotes: [UserExerciseNoteModel]

    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var showingRemoveConfirmation = false

    private var state: RoutineAlternationService.State? {
        RoutineAlternationService.state(
            containing: anchor.id,
            alternations: alternations,
            routines: routines,
            workouts: workouts
        )
    }

    private var configuredAlternation: RoutineAlternationModel? {
        RoutineAlternationService.alternation(containing: anchor.id, in: alternations)
    }

    private var choices: [RoutineModel] {
        routines
            .filter {
                $0.id != anchor.id
                    && $0.deletedAt == nil
                    && $0.archivedAt == nil
                    && (searchText.isEmpty || $0.name.localizedStandardContains(searchText))
            }
            .sorted {
                if $0.name != $1.name {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let state {
                    pairedContent(state)
                } else if let configuredAlternation {
                    unavailablePairContent(configuredAlternation)
                } else {
                    pickerContent
                }
            }
            .navigationTitle(configuredAlternation == nil ? "Choose Alternate" : "Alternating Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .navigationDestination(for: RoutineModel.self) { routine in
                RoutineDetailView(routine: routine, exercises: exercises, setupNotes: setupNotes)
            }
        }
        .alert("Couldn't update alternation", isPresented: errorIsPresented) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove alternating routine?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Alternation", role: .destructive, action: removeAlternation)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Both routines stay in your library and remain available to start.")
        }
    }

    private var pickerContent: some View {
        List {
            Section {
                ForEach(choices) { routine in
                    let configured = RoutineAlternationService.alternation(
                        containing: routine.id,
                        in: alternations
                    )
                    let existing = RoutineAlternationService.state(
                        containing: routine.id,
                        alternations: alternations,
                        routines: routines,
                        workouts: workouts
                    )
                    Button {
                        createPair(with: routine)
                    } label: {
                        HStack(spacing: Space.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routine.name)
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.textPrimary)
                                Text(existing.map { "Alternates with \(counterpart(to: routine, in: $0).name)" }
                                    ?? (configured == nil ? folderPath(for: routine) : "Alternate unavailable"))
                                    .font(.caption)
                                    .foregroundStyle(configured == nil ? theme.textSecondary : theme.textTertiary)
                            }
                            Spacer()
                            Image(systemName: configured == nil ? "plus.circle" : "arrow.triangle.2.circlepath")
                                .foregroundStyle(configured == nil ? theme.accent : theme.textTertiary)
                                .accessibilityHidden(true)
                        }
                    }
                    .disabled(configured != nil)
                    .accessibilityIdentifier("choose-alternate-\(routine.id.uuidString)")
                }
            } header: {
                Text("Alternate with \(anchor.name)")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .searchable(text: $searchText, prompt: "Search routines")
        .overlay {
            if choices.isEmpty {
                ContentUnavailableView.search
            }
        }
    }

    private func pairedContent(_ state: RoutineAlternationService.State) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Card {
                    VStack(spacing: Space.md) {
                        pairRow(state.owner, isNext: state.due.id == state.owner.id)
                        Divider().overlay(theme.separator)
                        pairRow(state.partner, isNext: state.due.id == state.partner.id)
                    }
                }

                Button("Remove Alternation", systemImage: "link.badge.minus", role: .destructive) {
                    showingRemoveConfirmation = true
                }
                .font(.bodyStrong)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("remove-routine-alternation")
            }
            .padding(Space.lg)
        }
        .background(theme.background)
    }

    private func unavailablePairContent(_ alternation: RoutineAlternationModel) -> some View {
        let counterpartID = alternation.ownerRoutineID == anchor.id
            ? alternation.partnerRoutineID
            : alternation.ownerRoutineID
        let counterpart = routines.first { $0.id == counterpartID }
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Card {
                    HStack(spacing: Space.md) {
                        Image(systemName: "archivebox")
                            .foregroundStyle(theme.textSecondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(counterpart?.name ?? "Alternate routine")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text(counterpart?.archivedAt == nil ? "Unavailable" : "Archived")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                }

                Text("Restore the routine to resume alternating, or remove the alternation. Your routines are not deleted.")
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)

                Button("Remove Alternation", systemImage: "link.badge.minus", role: .destructive) {
                    showingRemoveConfirmation = true
                }
                .font(.bodyStrong)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("remove-unavailable-routine-alternation")
            }
            .padding(Space.lg)
        }
        .background(theme.background)
    }

    private func pairRow(_ routine: RoutineModel, isNext: Bool) -> some View {
        NavigationLink(value: routine) {
            HStack(spacing: Space.md) {
                Image(systemName: isNext ? "play.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(isNext ? theme.accent : theme.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(routine.name)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text(isNext ? "Next" : folderPath(for: routine))
                        .font(.caption)
                        .foregroundStyle(isNext ? theme.accent : theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .minimumTouchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(routine.name), \(isNext ? "next" : "alternate")")
    }

    private func folderPath(for routine: RoutineModel) -> String {
        guard let folderID = routine.folderID,
              let folder = folders.first(where: { $0.id == folderID }) else { return "Ungrouped" }
        guard let parentID = folder.parentID,
              let parent = folders.first(where: { $0.id == parentID }) else { return folder.name }
        return "\(parent.name) › \(folder.name)"
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func counterpart(
        to routine: RoutineModel,
        in state: RoutineAlternationService.State
    ) -> RoutineModel {
        state.owner.id == routine.id ? state.partner : state.owner
    }

    private func createPair(with partner: RoutineModel) {
        do {
            try RoutineAlternationService.create(owner: anchor, partner: partner, in: modelContext)
            WatchLink.shared.invalidateRoutineSummaryCache()
            WatchLink.shared.publishState(policy: .immediate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeAlternation() {
        do {
            try RoutineAlternationService.removeAll(containing: anchor.id, in: modelContext)
            WatchLink.shared.invalidateRoutineSummaryCache()
            WatchLink.shared.publishState(policy: .immediate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
