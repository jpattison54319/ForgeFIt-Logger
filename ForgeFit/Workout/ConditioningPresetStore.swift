import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum ConditioningPresetStore {
    static func savedPresets(from records: [IntervalPresetModel]) -> [ConditioningPresetSelection] {
        records.compactMap { record in
            guard record.deletedAt == nil,
                  let storedPreset = record.storedConditioningPreset,
                  case .section(let section) = storedPreset else { return nil }
            let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return .saved(
                id: record.id,
                name: name.isEmpty ? section.name : name,
                section: section
            )
        }
    }

    static func hiddenBuiltInIDs(from records: [IntervalPresetModel]) -> Set<String> {
        Set(records.compactMap { record in
            guard record.deletedAt == nil,
                  let storedPreset = record.storedConditioningPreset,
                  case .deletedBuiltIn(let id) = storedPreset else { return nil }
            return id
        })
    }

    static func visibleBuiltIns(from records: [IntervalPresetModel]) -> [ConditioningPreset] {
        let hiddenIDs = hiddenBuiltInIDs(from: records)
        return ConditioningPreset.allCases.filter { !hiddenIDs.contains($0.id) }
    }

    @discardableResult
    static func save(
        _ section: ConditioningSection,
        named name: String,
        userID: UUID = ForgeFitDemo.userID,
        in context: ModelContext,
        saveChanges: Bool = true
    ) throws -> IntervalPresetModel {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ConditioningPresetStoreError.emptyName }
        guard !section.movements.isEmpty else { throw ConditioningPresetStoreError.emptySection }

        let recordID = UUID()
        var storedSection = section
        storedSection.name = trimmedName
        storedSection.presetReferenceID = "saved-\(recordID.uuidString)"
        guard let json = StoredConditioningPreset.section(storedSection).encodedJSON() else {
            throw ConditioningPresetStoreError.encodingFailed
        }

        let record = IntervalPresetModel(
            id: recordID,
            userID: userID,
            name: trimmedName,
            planJSON: json
        )
        context.insert(record)
        guard saveChanges else { return record }
        do {
            try context.save()
            return record
        } catch {
            context.delete(record)
            throw error
        }
    }

    static func hide(
        _ preset: ConditioningPreset,
        records: [IntervalPresetModel],
        userID: UUID = ForgeFitDemo.userID,
        in context: ModelContext,
        saveChanges: Bool = true
    ) throws {
        guard !hiddenBuiltInIDs(from: records).contains(preset.id) else { return }
        guard let json = StoredConditioningPreset.deletedBuiltIn(preset.id).encodedJSON() else {
            throw ConditioningPresetStoreError.encodingFailed
        }

        let marker = IntervalPresetModel(userID: userID, name: preset.title, planJSON: json)
        context.insert(marker)
        guard saveChanges else { return }
        do {
            try context.save()
        } catch {
            context.delete(marker)
            throw error
        }
    }

    static func delete(_ record: IntervalPresetModel, in context: ModelContext) throws {
        let previousDeletedAt = record.deletedAt
        let previousUpdatedAt = record.updatedAt
        let now = Date.now
        record.deletedAt = now
        record.updatedAt = now

        do {
            try context.save()
        } catch {
            record.deletedAt = previousDeletedAt
            record.updatedAt = previousUpdatedAt
            throw error
        }
    }

    static func update(
        _ record: IntervalPresetModel,
        with section: ConditioningSection,
        named name: String,
        in context: ModelContext,
        saveChanges: Bool = true
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ConditioningPresetStoreError.emptyName }
        guard !section.movements.isEmpty else { throw ConditioningPresetStoreError.emptySection }

        var storedSection = section
        storedSection.name = trimmedName
        storedSection.presetReferenceID = "saved-\(record.id.uuidString)"
        guard let json = StoredConditioningPreset.section(storedSection).encodedJSON() else {
            throw ConditioningPresetStoreError.encodingFailed
        }

        let previousName = record.name
        let previousJSON = record.planJSON
        let previousUpdatedAt = record.updatedAt
        record.name = trimmedName
        record.planJSON = json
        record.updatedAt = .now

        guard saveChanges else { return }
        do {
            try context.save()
        } catch {
            record.name = previousName
            record.planJSON = previousJSON
            record.updatedAt = previousUpdatedAt
            throw error
        }
    }

    static func restoreIncludedPresets(
        records: [IntervalPresetModel],
        in context: ModelContext
    ) throws {
        let markers = records.filter { record in
            guard record.deletedAt == nil,
                  let storedPreset = record.storedConditioningPreset,
                  case .deletedBuiltIn = storedPreset else { return false }
            return true
        }
        guard !markers.isEmpty else { return }

        let previousUpdatedAt = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0.updatedAt) })
        let now = Date.now
        for marker in markers {
            marker.deletedAt = now
            marker.updatedAt = now
        }

        do {
            try context.save()
        } catch {
            for marker in markers {
                marker.deletedAt = nil
                marker.updatedAt = previousUpdatedAt[marker.id] ?? marker.updatedAt
            }
            throw error
        }
    }
}
