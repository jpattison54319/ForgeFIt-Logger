import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

struct ConditioningPresetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let workouts: [WorkoutModel]
    let exercises: [ExerciseLibraryModel]

    // Keep soft-deleted rows available so visibility and restore state are
    // derived from the complete persisted history. The local ID sets below
    // make successful deletes disappear immediately while SwiftData refreshes.
    @Query(sort: \IntervalPresetModel.createdAt, order: .reverse)
    private var records: [IntervalPresetModel]

    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showCreatePreset = false
    @State private var locallyDeletedSavedPresetIDs: Set<UUID> = []
    @State private var locallyHiddenBuiltInIDs: Set<String> = []

    var body: some View {
        let hiddenBuiltInIDs = ConditioningPresetStore.hiddenBuiltInIDs(from: records)
            .union(locallyHiddenBuiltInIDs)
        let includedPresets = ConditioningPreset.allCases
            .filter { !hiddenBuiltInIDs.contains($0.id) }
            .map(ConditioningPresetSelection.builtIn)
        let savedPresets = ConditioningPresetStore.savedPresets(from: records).filter { selection in
            guard case .saved(let id, _, _) = selection else { return false }
            return !locallyDeletedSavedPresetIDs.contains(id)
        }
        let hasRemovedIncludedPresets = !hiddenBuiltInIDs.isEmpty

        NavigationStack {
            Group {
                if includedPresets.isEmpty && savedPresets.isEmpty {
                    ContentUnavailableView {
                        Label("No conditioning presets", systemImage: "square.grid.2x2")
                    } description: {
                        Text("Save a conditioning block as a preset or restore the included presets.")
                    } actions: {
                        if hasRemovedIncludedPresets {
                            Button("Restore Included Presets", systemImage: "arrow.counterclockwise", action: restoreIncludedPresets)
                        }
                    }
                } else {
                    List {
                        if !includedPresets.isEmpty {
                            Section("Included") {
                                ForEach(includedPresets) { preset in
                                    ConditioningPresetManagerRow(
                                        selection: preset,
                                        workouts: workouts,
                                        exercises: exercises,
                                        deleteMessage: "Removes it from the preset menu. Existing blocks stay unchanged.",
                                        onDelete: { delete(preset) }
                                    )
                                }
                            }
                        }

                        if !savedPresets.isEmpty {
                            Section("Saved") {
                                ForEach(savedPresets) { preset in
                                    ConditioningPresetManagerRow(
                                        selection: preset,
                                        workouts: workouts,
                                        exercises: exercises,
                                        deleteMessage: "Removes this saved preset. Existing blocks stay unchanged.",
                                        onDelete: { delete(preset) }
                                    )
                                }
                            }
                        }

                        if hasRemovedIncludedPresets {
                            Section {
                                Button("Restore Included Presets", systemImage: "arrow.counterclockwise", action: restoreIncludedPresets)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("Conditioning Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New preset", systemImage: "plus") {
                        showCreatePreset = true
                    }
                    .accessibilityIdentifier("new-conditioning-preset")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .sheet(isPresented: $showCreatePreset) {
            ConditioningBlockBuilderView(
                planJSON: nil,
                exercises: exercises,
                workouts: workouts,
                navigationTitle: "New Preset",
                allowsMultipleSections: false,
                showsPresetActions: false,
                onSave: { json in
                    guard let section = ConditioningPlan.decode(from: json)?.sections.first else {
                        throw ConditioningPresetStoreError.encodingFailed
                    }
                    try ConditioningPresetStore.save(section, named: section.name, in: modelContext)
                }
            )
        }
        .alert("Couldn't Update Presets", isPresented: $showError) {
        } message: {
            Text(errorMessage)
        }
    }

    private func delete(_ selection: ConditioningPresetSelection) {
        do {
            switch selection {
            case .builtIn(let preset):
                try ConditioningPresetStore.hide(preset, records: records, in: modelContext)
                withAnimation {
                    _ = locallyHiddenBuiltInIDs.insert(preset.id)
                }
            case .saved(let id, _, _):
                guard let record = records.first(where: { $0.id == id }) else { return }
                try ConditioningPresetStore.delete(record, in: modelContext)
                withAnimation {
                    _ = locallyDeletedSavedPresetIDs.insert(id)
                }
            }
        } catch {
            show(error)
        }
    }

    private func restoreIncludedPresets() {
        do {
            try ConditioningPresetStore.restoreIncludedPresets(records: records, in: modelContext)
            withAnimation {
                locallyHiddenBuiltInIDs.removeAll()
            }
        } catch {
            show(error)
        }
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
