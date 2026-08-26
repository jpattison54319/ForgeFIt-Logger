#if DEBUG
import ForgeData
import Foundation
import SwiftData

/// Deterministic routine history for rendered duration and chart-scale checks.
enum DataDisplayUITestFixture {
    static let routineName = "Data Display Audit"

    static func seed(in context: ModelContext) throws {
        for routine in try context.fetch(FetchDescriptor<RoutineModel>()) {
            context.delete(routine)
        }
        for workout in try context.fetch(FetchDescriptor<WorkoutModel>()) {
            context.delete(workout)
        }

        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: routineName
        )
        context.insert(routine)

        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: .now)
        let history: [(daysAgo: Int, durationSeconds: Int)] = [
            (21, 1_260),
            (14, 1_242),
            (7, 1_314),
        ]
        for item in history {
            let start = calendar.date(byAdding: .day, value: -item.daysAgo, to: day)!
            context.insert(WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: routine.id,
                title: routineName,
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(item.durationSeconds)),
                sourceDevice: "ui-test"
            ))
        }
        try context.save()
    }
}
#endif
