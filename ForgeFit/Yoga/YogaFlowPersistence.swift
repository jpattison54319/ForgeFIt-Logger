import ForgeData
import Foundation
import SwiftData

@MainActor
final class YogaFlowCreationAttempt {
    enum PersistenceError: LocalizedError {
        case committedFlowUnavailable

        var errorDescription: String? {
            "The yoga flow was saved, but ForgeFit couldn't reopen it. Try again."
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    let id: UUID
    private let persistenceContext: ModelContext
    private let flow: YogaFlowModel

    init(
        id: UUID = UUID(),
        name: String,
        styleRaw: String,
        planJSON: String,
        position: Int,
        in sourceContext: ModelContext,
        now: Date = .now
    ) {
        self.id = id
        persistenceContext = ModelContext(sourceContext.container)
        persistenceContext.autosaveEnabled = false
        flow = YogaFlowModel(
            id: id,
            userID: ForgeFitDemo.userID,
            name: name,
            styleRaw: styleRaw,
            planJSON: planJSON,
            position: position,
            createdAt: now,
            updatedAt: now
        )
        persistenceContext.insert(flow)
    }

    func update(
        name: String,
        styleRaw: String,
        planJSON: String,
        now: Date = .now
    ) {
        flow.name = name
        flow.styleRaw = styleRaw
        flow.planJSON = planJSON
        flow.updatedAt = now
    }

    /// The pending row lives only in an isolated context. Failed attempts can
    /// be retried exactly, but cannot be committed by an unrelated main-
    /// context save or create a second row when the user taps Save again.
    @discardableResult
    func commit(
        into sourceContext: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (YogaFlowModel) -> Void
    ) -> Bool {
        let flowID = id
        var committedFlow: YogaFlowModel?
        return (saveCenter ?? .shared).perform({ [persistenceContext] in
            try save(persistenceContext)
            committedFlow = try sourceContext.fetch(
                FetchDescriptor<YogaFlowModel>(predicate: #Predicate { $0.id == flowID })
            ).first
            guard committedFlow != nil else {
                throw PersistenceError.committedFlowUnavailable
            }
        }, onSuccess: {
            if let committedFlow { onCommit(committedFlow) }
        })
    }
}

@MainActor
enum YogaFlowPersistence {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    @discardableResult
    static func update(
        _ flow: YogaFlowModel,
        planJSON: String,
        styleRaw: String,
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let previousPlanJSON = flow.planJSON
        let previousStyleRaw = flow.styleRaw
        let previousUpdatedAt = flow.updatedAt

        return (saveCenter ?? .shared).perform({
            flow.planJSON = planJSON
            flow.styleRaw = styleRaw
            flow.updatedAt = now
            do {
                try save(context)
            } catch {
                flow.planJSON = previousPlanJSON
                flow.styleRaw = previousStyleRaw
                flow.updatedAt = previousUpdatedAt
                throw error
            }
        }, onSuccess: onCommit)
    }

    @discardableResult
    static func softDelete(
        _ flows: [YogaFlowModel],
        in context: ModelContext,
        now: Date = .now,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        let snapshots = flows.map { flow in
            (flow: flow, deletedAt: flow.deletedAt, updatedAt: flow.updatedAt)
        }
        return (saveCenter ?? .shared).perform({
            for flow in flows {
                flow.deletedAt = now
                flow.updatedAt = now
            }
            do {
                try save(context)
            } catch {
                for snapshot in snapshots {
                    snapshot.flow.deletedAt = snapshot.deletedAt
                    snapshot.flow.updatedAt = snapshot.updatedAt
                }
                throw error
            }
        }, onSuccess: onCommit)
    }
}
