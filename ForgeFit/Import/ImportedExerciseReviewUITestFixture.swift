#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Small, person-free import batch used to replay every review action against
/// stable names and classifications.
@MainActor
enum ImportedExerciseReviewUITestFixture {
    static let launchArgument = "--seed-imported-exercise-review"

    static func seed(in context: ModelContext) throws {
        let batchID = UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let exercises = [
            ExerciseLibraryModel(
                id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000101")!,
                ownerID: ForgeFitDemo.userID,
                name: "Lat Prayer",
                primaryMuscles: ["lats"],
                equipment: "cable",
                category: "strength",
                needsReview: true,
                classificationConfidence: 0.1,
                classificationSourceRaw: ClassificationSource.keyword.rawValue,
                importBatchID: batchID,
                importedRawName: "Lat Prayer",
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            ExerciseLibraryModel(
                id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000102")!,
                ownerID: ForgeFitDemo.userID,
                name: "Lean Back Abduction Machine",
                primaryMuscles: ["abductors"],
                secondaryMuscles: ["glutes"],
                equipment: "machine",
                category: "strength",
                needsReview: true,
                classificationConfidence: 0.2,
                classificationSourceRaw: ClassificationSource.keyword.rawValue,
                importBatchID: batchID,
                importedRawName: "Lean Back Abduction Machine",
                createdAt: createdAt,
                updatedAt: createdAt
            ),
            ExerciseLibraryModel(
                id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000103")!,
                ownerID: ForgeFitDemo.userID,
                name: "Mystery Handle",
                category: "strength",
                needsReview: true,
                classificationConfidence: 0.3,
                classificationSourceRaw: ClassificationSource.fallback.rawValue,
                importBatchID: batchID,
                importedRawName: "Mystery Handle",
                createdAt: createdAt,
                updatedAt: createdAt
            ),
        ]
        exercises.forEach(context.insert)
        try context.save()
    }
}
#endif
