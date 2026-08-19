import ForgeData
import Foundation
import SwiftData

/// One exact daily-check-in write, reusable by Home and Recovery detail.
/// Every attempt works in a private context and resolves by stable day/ID, so
/// failed creation cannot linger in a shared context or duplicate on Retry.
@MainActor
struct DailyCheckinCommitAttempt {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    let id: UUID
    let userID: UUID
    let day: Date
    let tags: [String]
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        userID: UUID,
        day: Date,
        tags: [String],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.userID = userID
        self.day = Calendar.current.startOfDay(for: day)
        self.tags = tags
        self.updatedAt = updatedAt
    }

    @discardableResult
    func commit(
        in sourceContext: ModelContext,
        save: SaveOperation = { try $0.save() }
    ) throws -> DailyCheckinModel {
        let transaction = ModelContext(sourceContext.container)
        transaction.autosaveEnabled = false
        let targetDay = day
        let dayEnd = Calendar.current.date(
            byAdding: .day,
            value: 1,
            to: targetDay
        ) ?? targetDay.addingTimeInterval(86_400)
        let targetUserID = userID
        let existing = try transaction.fetch(FetchDescriptor<DailyCheckinModel>(
            predicate: #Predicate {
                $0.userID == targetUserID
                    && $0.date >= targetDay
                    && $0.date < dayEnd
                    && $0.deletedAt == nil
            }
        )).max { $0.updatedAt < $1.updatedAt }

        let checkin: DailyCheckinModel
        if let existing {
            checkin = existing
        } else {
            checkin = DailyCheckinModel(
                id: id,
                userID: userID,
                date: day
            )
            transaction.insert(checkin)
        }
        checkin.tags = tags
        checkin.updatedAt = updatedAt
        try save(transaction)

        let committedID = checkin.id
        var descriptor = FetchDescriptor<DailyCheckinModel>(
            predicate: #Predicate { $0.id == committedID }
        )
        descriptor.fetchLimit = 1
        guard let committed = try sourceContext.fetch(descriptor).first else {
            throw PersistenceError.committedCheckinUnavailable
        }
        return committed
    }

    private enum PersistenceError: LocalizedError {
        case committedCheckinUnavailable

        var errorDescription: String? {
            "Your check-in was saved, but it could not be refreshed on this screen."
        }
    }
}
