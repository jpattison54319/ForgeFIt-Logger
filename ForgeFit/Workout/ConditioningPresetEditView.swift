import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Included presets are immutable app defaults, so customization produces a
/// saved copy. User-saved presets update their existing synced record.
struct ConditioningPresetEditView: View {
    @Environment(\.modelContext) private var modelContext

    let selection: ConditioningPresetSelection
    let section: ConditioningSection
    let exercises: [ExerciseLibraryModel]
    let workouts: [WorkoutModel]
    var historySnapshot: ExercisePickerHistorySnapshot? = nil
    let onSaved: (ConditioningPresetSelection) -> Void

    private var editingSection: ConditioningSection {
        var value = section
        if case .builtIn = selection {
            value.name = "\(selection.title) Custom"
        }
        return value
    }

    private var navigationTitle: String {
        switch selection {
        case .builtIn: "Customize Preset"
        case .saved: "Edit Preset"
        }
    }

    var body: some View {
        ConditioningBlockBuilderView(
            planJSON: ConditioningPlan(sections: [editingSection]).encodedJSON(),
            exercises: exercises,
            workouts: workouts,
            historySnapshot: historySnapshot,
            navigationTitle: navigationTitle,
            allowsMultipleSections: false,
            showsPresetActions: false,
            onSave: { json in
                try save(json)
            }
        )
    }

    private func save(_ json: String) throws {
        guard let editedSection = ConditioningPlan.decode(from: json)?.sections.first else {
            throw ConditioningPresetStoreError.encodingFailed
        }
        let name = editedSection.name
        let context = ModelContext(modelContext.container)
        context.autosaveEnabled = false
        let workoutIDs = Set(workouts.map(\.id))
        let persistedWorkouts = try context.fetch(FetchDescriptor<WorkoutModel>())
            .filter { workoutIDs.contains($0.id) }

        switch selection {
        case .builtIn(let preset):
            let record = try ConditioningPresetStore.save(
                editedSection,
                named: name,
                in: context,
                saveChanges: false
            )
            let descriptor = FetchDescriptor<IntervalPresetModel>()
            let records = try context.fetch(descriptor)
            try ConditioningPresetStore.hide(
                preset,
                records: records,
                in: context,
                saveChanges: false
            )
            try ConditioningPresetHistoryRenamer.renameMatchingHistory(
                from: section,
                to: record.name,
                presetReferenceID: "saved-\(record.id.uuidString)",
                in: persistedWorkouts,
                context: context,
                saveChanges: false
            )
            try context.save()
            var savedSection = editedSection
            savedSection.name = record.name
            onSaved(.saved(id: record.id, name: record.name, section: savedSection))

        case .saved(let id, _, _):
            let descriptor = FetchDescriptor<IntervalPresetModel>(
                predicate: #Predicate { $0.id == id }
            )
            guard let record = try context.fetch(descriptor).first,
                  record.deletedAt == nil else {
                throw ConditioningPresetStoreError.presetUnavailable
            }
            try ConditioningPresetStore.update(
                record,
                with: editedSection,
                named: name,
                in: context,
                saveChanges: false
            )
            try ConditioningPresetHistoryRenamer.renameMatchingHistory(
                from: section,
                to: record.name,
                presetReferenceID: "saved-\(record.id.uuidString)",
                in: persistedWorkouts,
                context: context,
                saveChanges: false
            )
            try context.save()
            var savedSection = editedSection
            savedSection.name = record.name
            onSaved(.saved(id: id, name: record.name, section: savedSection))
        }
    }
}
