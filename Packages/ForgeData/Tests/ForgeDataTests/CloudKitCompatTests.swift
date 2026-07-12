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

    @Test func perSideSetFieldsHaveCloudKitSafeDefaults() {
        let set = SetModel(userID: UUID())

        #expect(set.side2Reps == nil)
        #expect(set.side2MiniRepsJSON == nil)
        #expect(set.side2MiniReps.isEmpty)
        #expect(!set.hasSide2Data)
    }

    @Test func wrappedReportModelHasCloudKitSafeDefaults() {
        let report = WrappedReportModel(userID: UUID(), reportTypeRaw: "monthly", year: 2026, month: 6)

        #expect(report.viewedAt == nil)
        #expect(!report.isViewed)
        #expect(report.isMonthly)
        #expect(report.payloadJSON == "{}")
        #expect(report.reportVersion == 1)
        #expect(report.deletedAt == nil)
    }

    @Test func intervalPresetModelHasCloudKitSafeDefaults() {
        let preset = IntervalPresetModel(userID: UUID(), name: "My VO2")

        #expect(preset.planJSON == "{}")
        #expect(preset.deletedAt == nil)
    }

    @Test func yogaFieldsHaveCloudKitSafeDefaults() {
        let exercise = ExerciseLibraryModel(name: "Pigeon Pose")
        #expect(exercise.modalityRaw == nil)
        #expect(exercise.defaultHoldSeconds == nil)
        // Legacy fallback: nil modalityRaw resolves from isCardio.
        #expect(exercise.modality == .strength)

        let routineExercise = RoutineExerciseModel(userID: UUID(), exerciseID: UUID())
        #expect(routineExercise.yogaFlowJSON == nil)

        let workoutExercise = WorkoutExerciseModel(userID: UUID(), exerciseID: UUID())
        #expect(workoutExercise.yogaFlowJSON == nil)

        let session = CardioSessionModel(userID: UUID(), modality: "run")
        #expect(session.yogaStyleRaw == nil)
        #expect(session.flexibilityExposureJSON == nil)
        #expect(session.posesCompleted == nil)
        #expect(!session.isYogaSession)

        let flow = YogaFlowModel(userID: UUID(), name: "My Flow")
        #expect(flow.planJSON == "{}")
        #expect(flow.deletedAt == nil)
    }

    @Test func modalityResolutionFallsBackToLegacyIsCardio() {
        let legacyCardio = ExerciseLibraryModel(name: "Treadmill Run", isCardio: true)
        #expect(legacyCardio.modality == .cardio)

        let yoga = ExerciseLibraryModel(name: "Warrior II", modalityRaw: "yoga")
        #expect(yoga.modality == .yoga)
        #expect(yoga.isYoga)
        #expect(!yoga.isCardio)

        // Setting the typed accessor keeps the legacy flag in sync.
        let flipped = ExerciseLibraryModel(name: "Rower")
        flipped.modality = .cardio
        #expect(flipped.isCardio)
        flipped.modality = .yoga
        #expect(!flipped.isCardio)
        #expect(flipped.modalityRaw == "yoga")
    }
}
