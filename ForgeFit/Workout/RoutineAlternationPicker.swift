import ForgeData
import SwiftUI

struct RoutineAlternationPicker: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let routines: [RoutineModel]
    let existingMemberIDs: Set<UUID>
    let claimedRoutineIDs: Set<UUID>
    let folderPathByRoutineID: [UUID: String]
    let onSelect: (RoutineModel) -> Void

    @State private var searchText = ""

    init(
        routines: [RoutineModel],
        existingMemberIDs: Set<UUID>,
        claimedRoutineIDs: Set<UUID>,
        folderPathByRoutineID: [UUID: String],
        onSelect: @escaping (RoutineModel) -> Void
    ) {
        self.routines = routines.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
        self.existingMemberIDs = existingMemberIDs
        self.claimedRoutineIDs = claimedRoutineIDs
        self.folderPathByRoutineID = folderPathByRoutineID
        self.onSelect = onSelect
    }

    private var filteredChoices: [RoutineModel] {
        routines
            .filter {
                $0.deletedAt == nil
                    && $0.archivedAt == nil
                    && !existingMemberIDs.contains($0.id)
                    && (searchText.isEmpty || $0.name.localizedStandardContains(searchText))
            }
    }

    var body: some View {
        let choices = filteredChoices

        List {
            Section("Available Routines") {
                ForEach(choices) { routine in
                    let isClaimed = claimedRoutineIDs.contains(routine.id)
                    Button {
                        onSelect(routine)
                        dismiss()
                    } label: {
                        HStack(spacing: Space.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(routine.name)
                                    .font(.bodyStrong)
                                    .foregroundStyle(isClaimed ? theme.textTertiary : theme.textPrimary)
                                    .lineLimit(2)
                                Text(isClaimed
                                    ? "In another alternating cycle"
                                    : folderPathByRoutineID[routine.id, default: "Ungrouped"])
                                    .font(.caption)
                                    .foregroundStyle(isClaimed ? theme.textTertiary : theme.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: Space.sm)
                            Image(systemName: isClaimed ? "arrow.triangle.2.circlepath" : "plus.circle")
                                .foregroundStyle(isClaimed ? theme.textTertiary : theme.accent)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        .minimumTouchTarget()
                    }
                    .disabled(isClaimed)
                    .accessibilityLabel(isClaimed
                        ? "\(routine.name), in another alternating cycle"
                        : "Add \(routine.name) to cycle")
                    .accessibilityIdentifier("choose-alternate-\(routine.id.uuidString)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("Add Routine")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search routines")
        .overlay {
            if choices.isEmpty {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "No Routines Available",
                        systemImage: "list.bullet.clipboard",
                        description: Text("Every available routine is already in this cycle.")
                    )
                } else {
                    ContentUnavailableView.search
                }
            }
        }
    }
}
