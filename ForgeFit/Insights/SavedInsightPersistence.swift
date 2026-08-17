import ForgeData
import Foundation
import SwiftData

/// Stable-ID transactions for every mutation on a saved Insights card. The
/// Insights tab stays alive beside other tabs, so none of its successful
/// actions may save unrelated pending UI work from the environment context.
@MainActor
enum SavedInsightPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    enum PersistenceError: LocalizedError {
        case unavailable

        var errorDescription: String? { "That saved insight is no longer available." }
    }

    @discardableResult
    static func create(
        id: UUID = UUID(),
        userID: UUID,
        name: String,
        recipeJSON: String,
        position: Int,
        in sourceContext: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> SavedInsightModel {
        let transaction = isolatedContext(from: sourceContext)
        let row = SavedInsightModel(
            id: id,
            userID: userID,
            name: name,
            recipeJSON: recipeJSON,
            position: position,
            createdAt: now,
            updatedAt: now
        )
        transaction.insert(row)
        try save(transaction)
        return try resolve(id, in: sourceContext)
    }

    @discardableResult
    static func update(
        id: UUID,
        name: String,
        recipeJSON: String,
        in sourceContext: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> SavedInsightModel {
        let transaction = isolatedContext(from: sourceContext)
        let row = try resolve(id, in: transaction)
        row.name = name
        row.recipeJSON = recipeJSON
        row.updatedAt = now
        try save(transaction)
        return try resolve(id, in: sourceContext)
    }

    static func delete(
        id: UUID,
        in sourceContext: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let transaction = isolatedContext(from: sourceContext)
        let row = try resolve(id, in: transaction)
        row.deletedAt = now
        row.updatedAt = now
        try save(transaction)
        _ = try resolve(id, in: sourceContext)
    }

    static func reorder(
        ids: [UUID],
        in sourceContext: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let transaction = isolatedContext(from: sourceContext)
        let rows = try transaction.fetch(FetchDescriptor<SavedInsightModel>())
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard ids.allSatisfy({ byID[$0] != nil }) else {
            throw PersistenceError.unavailable
        }
        for (position, id) in ids.enumerated() {
            guard let row = byID[id], row.position != position else { continue }
            row.position = position
            row.updatedAt = now
        }
        guard transaction.hasChanges else { return }
        try save(transaction)
        _ = try sourceContext.fetch(FetchDescriptor<SavedInsightModel>())
            .filter { ids.contains($0.id) }
    }

    private static func isolatedContext(from sourceContext: ModelContext) -> ModelContext {
        let context = ModelContext(sourceContext.container)
        context.autosaveEnabled = false
        return context
    }

    private static func resolve(
        _ id: UUID,
        in context: ModelContext
    ) throws -> SavedInsightModel {
        guard let row = try context.fetch(FetchDescriptor<SavedInsightModel>(
            predicate: #Predicate { $0.id == id }
        )).first else {
            throw PersistenceError.unavailable
        }
        return row
    }
}
