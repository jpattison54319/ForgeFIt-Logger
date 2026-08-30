#if DEBUG
import ForgeData
import Foundation
import SwiftData

@MainActor
enum FeatureDiscoveryUITestFixture {
    static let launchArgument = "--seed-feature-discovery-microcycle"

    static func seedIfRequested(
        arguments: [String],
        discovery: FeatureDiscoveryStore,
        in context: ModelContext,
        now: Date = .now,
        calendar: Calendar = .current
    ) throws {
        guard arguments.contains(launchArgument) else { return }

        let folder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Strength Cycle",
            position: 0
        )
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Full Body",
            folderID: folder.id,
            position: 0
        )
        context.insert(folder)
        context.insert(routine)

        discovery.replaceForTesting(
            enrolledAt: calendar.date(byAdding: .day, value: -10, to: now) ?? now
        )
        for daysAgo in [7, 4, 1] {
            let end = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            context.insert(WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: routine.id,
                title: routine.name,
                startedAt: end.addingTimeInterval(-2_700),
                endedAt: end,
                sourceDevice: "iphone"
            ))
        }
        try context.save()
    }
}
#endif
