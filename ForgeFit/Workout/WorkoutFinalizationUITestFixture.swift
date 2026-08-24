#if DEBUG
import ForgeData
import Foundation
import SwiftData

@MainActor
enum WorkoutFinalizationUITestFixture {
    static func seed(in context: ModelContext) throws -> WorkoutModel {
        let title = "Finalizing Strength"
        var descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == title }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let end = Date.now.addingTimeInterval(-20)
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: end.addingTimeInterval(-35 * 60),
            endedAt: end,
            sourceDevice: "iphone"
        )
        context.insert(workout)
        try context.save()
        return workout
    }
}
#endif
