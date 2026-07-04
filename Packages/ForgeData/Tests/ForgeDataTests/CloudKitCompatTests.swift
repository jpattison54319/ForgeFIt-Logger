import Foundation
import SwiftData
import Testing
@testable import ForgeData

/// CloudKit-backed SwiftData rejects schemas whose attributes lack defaults /
/// optionality or whose relationships are non-optional. This exercises the
/// same validation `cloudKitDatabase: .automatic` triggers at app launch.
@Suite struct CloudKitCompatTests {
    @Test func schemaIsCloudKitCompatible() throws {
        let schema = Schema(ForgeDataSchema.models)
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .private("iCloud.org.xpetsllc.ForgeFit")
        )
        do {
            _ = try ModelContainer(for: schema, configurations: [config])
        } catch {
            Issue.record("CloudKit-mode container creation failed: \(error)")
        }
    }

    @Test func importedExerciseClassificationFieldsHaveCloudKitSafeDefaults() {
        let exercise = ExerciseLibraryModel(name: "Mystery Press")

        #expect(exercise.needsReview == false)
        #expect(exercise.classificationConfidence == 1.0)
        #expect(exercise.classificationSourceRaw == nil)
        #expect(exercise.importBatchID == nil)
        #expect(exercise.importedRawName == nil)
    }
}
