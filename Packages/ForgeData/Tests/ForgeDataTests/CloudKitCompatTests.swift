import Foundation
import SwiftData
import Testing
@testable import ForgeData

/// CloudKit-backed SwiftData rejects schemas whose attributes lack defaults /
/// optionality or whose relationships are non-optional. This exercises the
/// same validation `cloudKitDatabase: .automatic` triggers at app launch.
@Suite struct CloudKitCompatTests {
    /// Statically validates CloudKit's schema rules — every attribute
    /// optional or defaulted, every relationship optional, no uniqueness
    /// constraints — against the FULL schema, which covers the
    /// compliance-relevant subset by construction: only
    /// `ForgeDataSchema.planModels` (a strict subset) ever attaches to
    /// CloudKit in production; the LOG layer stays local per Guideline
    /// 5.1.3(ii). Keeping LOG models CK-safe too costs nothing and
    /// preserves the discipline should a model ever move layers.
    ///
    /// Deliberately NOT a live `cloudKitDatabase:` container: creating one
    /// kicks off async PushKit registration that aborts the bundle-less
    /// swiftpm test process (`bundleIdentifier != nil`) once any other
    /// store activity runs alongside it.
    @Test func schemaIsCloudKitCompatible() throws {
        let schema = Schema(ForgeDataSchema.models)
        #expect(!schema.entities.isEmpty)
        for entity in schema.entities {
            #expect(entity.uniquenessConstraints.isEmpty,
                    "\(entity.name): CloudKit forbids unique constraints")
            for attribute in entity.attributes {
                #expect(attribute.isOptional || attribute.defaultValue != nil,
                        "\(entity.name).\(attribute.name): CloudKit needs a default value or optionality")
            }
            for relationship in entity.relationships {
                #expect(relationship.isOptional || relationship.isToOneRelationship == false,
                        "\(entity.name).\(relationship.name): CloudKit needs optional to-one relationships")
            }
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

    @Test func progressionSuggestionModelHasCloudKitSafeDefaults() {
        let suggestion = ProgressionSuggestionModel(
            userID: UUID(), exerciseID: UUID(), workoutID: UUID(),
            workoutExerciseID: UUID(), kindRaw: "increase"
        )
        #expect(suggestion.suggestedWeightKg == nil)
        #expect(suggestion.suggestedRepsLow == nil)
        #expect(suggestion.statusRaw == "pending")
        #expect(suggestion.deletedAt == nil)
        let exercise = RoutineExerciseModel(userID: UUID(), exerciseID: UUID())
        #expect(exercise.progressionRuleJSON == nil)
    }

    @Test func dailyCheckinModelHasCloudKitSafeDefaults() {
        let checkin = DailyCheckinModel(userID: UUID(), date: Date(), tags: ["sore", "alcohol"])
        #expect(checkin.tagsRaw == "sore,alcohol")
        #expect(checkin.tags == ["sore", "alcohol"])
        #expect(checkin.deletedAt == nil)
        let empty = DailyCheckinModel(userID: UUID(), date: Date())
        #expect(empty.tags.isEmpty)
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

    @Test func coachingProfileModelHasCloudKitSafeDefaults() {
        let profile = CoachingProfileModel(
            userID: UUID(), focusRaw: "strength", goalRaw: "build-muscle", experienceRaw: "beginner"
        )

        #expect(profile.sessionsPerWeek == 3)
        #expect(profile.sessionMinutes == 60)
        #expect(profile.equipmentJSON == nil)
        #expect(profile.equipment.isEmpty)
        #expect(profile.preferredCardioRaw == nil)
        #expect(profile.focus == .strength)
        #expect(profile.experience == .beginner)

        profile.equipment = ["barbell", "dumbbell"]
        #expect(profile.equipmentJSON != nil)
        #expect(profile.equipment == ["barbell", "dumbbell"])
    }

    @Test func coachedProgramModelHasCloudKitSafeDefaults() {
        let program = CoachedProgramModel(userID: UUID(), startDate: .now)

        #expect(program.folderID == nil)
        #expect(program.catalogProgramID == "")
        #expect(program.isAttachedPlan)
        #expect(program.weeks == 0)
        #expect(program.weeklySessionTarget == 3)
        #expect(!program.isActive)
        #expect(program.lastReviewedWeekAnchor == nil)
        #expect(program.deletedAt == nil)

        let catalogProgram = CoachedProgramModel(userID: UUID(), catalogProgramID: "hybrid-engine", startDate: .now)
        #expect(!catalogProgram.isAttachedPlan)
    }

    @Test func coachingWeekOverrideModelHasCloudKitSafeDefaultsAndTypedAccessors() {
        let override = CoachingWeekOverrideModel(userID: UUID(), weekStart: .now)

        #expect(override.programID == nil)
        #expect(override.kindRaw == "")
        #expect(override.kind == nil)
        #expect(override.exerciseID == nil)
        #expect(override.routineID == nil)
        #expect(override.statusRaw == "")
        #expect(override.status == nil)
        #expect(override.reason == "")

        override.kind = .progressionHold
        #expect(override.kindRaw == "progressionHold")
        override.status = .active
        #expect(override.statusRaw == "active")
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
