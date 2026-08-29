import ForgeCore
import ForgeData
import Foundation

struct MicrocyclePlanProgress {
    struct PlannedRestDay: Equatable, Identifiable {
        let snapshot: MicrocyclePlannedRestDaySnapshot
        let completedAt: Date?

        var id: UUID { snapshot.id }
        var isCompleted: Bool { completedAt != nil }
    }

    enum Item: Identifiable {
        case routine(MicrocycleRoutineProgress)
        case restDay(PlannedRestDay)

        var id: UUID {
            switch self {
            case .routine(let routine): routine.id
            case .restDay(let restDay): restDay.id
            }
        }

        var isCompleted: Bool {
            switch self {
            case .routine(let routine): routine.isCompleted
            case .restDay(let restDay): restDay.isCompleted
            }
        }
    }

    let items: [Item]

    var completedCount: Int { items.count(where: \.isCompleted) }
    var requiredCount: Int { items.count }
    var isComplete: Bool { requiredCount > 0 && completedCount == requiredCount }

    static func make(
        window: MicrocycleWindowModel,
        routineProgress: MicrocycleProgress,
        restDays: [RestDayModel]
    ) -> MicrocyclePlanProgress {
        let routinesByID = Dictionary(
            routineProgress.routines.map { ($0.routine.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let liveRestDaysByID = Dictionary(
            restDays
            .filter {
                $0.deletedAt == nil
                    && window.startsAt <= $0.date
                    && $0.date < window.endsAt
            }
            .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let items = window.orderedPlanItems.compactMap { item -> Item? in
            switch item {
            case .routine(let routine):
                return routinesByID[routine.id].map(Item.routine)
            case .restDay(let restDay):
                let completedAt = restDay.completedRestDayID
                    .flatMap { liveRestDaysByID[$0]?.date }
                return .restDay(.init(snapshot: restDay, completedAt: completedAt))
            }
        }
        return .init(items: items)
    }
}
