import ForgeData
import Foundation
import SwiftData

@MainActor
final class IntervalPresetCreationAttempt {
    enum PersistenceError: LocalizedError {
        case committedPresetUnavailable

        var errorDescription: String? {
            "The interval preset was saved, but ForgeFit couldn't reopen it. Try again."
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    let id: UUID
    private let persistenceContext: ModelContext
    private let preset: IntervalPresetModel

    init(
        id: UUID = UUID(),
        name: String,
        planJSON: String,
        in sourceContext: ModelContext
    ) {
        self.id = id
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
        preset = IntervalPresetModel(
            id: id,
            userID: ForgeFitDemo.userID,
            name: name,
            planJSON: planJSON
        )
        persistenceContext.insert(preset)
    }

    func update(name: String, planJSON: String) {
        preset.name = name
        preset.planJSON = planJSON
        preset.updatedAt = .now
    }

    @discardableResult
    func commit(
        into sourceContext: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (IntervalPresetModel) -> Void
    ) -> Bool {
        let presetID = id
        var committedPreset: IntervalPresetModel?
        return (saveCenter ?? .shared).perform({ [persistenceContext] in
            try save(persistenceContext)
            committedPreset = try sourceContext.fetch(
                FetchDescriptor<IntervalPresetModel>(predicate: #Predicate { $0.id == presetID })
            ).first
            guard committedPreset != nil else {
                throw PersistenceError.committedPresetUnavailable
            }
        }, onSuccess: {
            if let committedPreset { onCommit(committedPreset) }
        })
    }
}

@MainActor
enum IntervalPresetPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func softDelete(
        _ presets: [IntervalPresetModel],
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let snapshots = presets.map {
            (preset: $0, deletedAt: $0.deletedAt, updatedAt: $0.updatedAt)
        }
        return (saveCenter ?? .shared).perform({
            for preset in presets {
                preset.deletedAt = now
                preset.updatedAt = now
            }
            do {
                try save(context)
            } catch {
                for snapshot in snapshots {
                    snapshot.preset.deletedAt = snapshot.deletedAt
                    snapshot.preset.updatedAt = snapshot.updatedAt
                }
                throw error
            }
        }, onSuccess: onCommit)
    }
}
