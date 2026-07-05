import ForgeCore
@testable import ForgeData
import Foundation
import Testing

struct SetModelDerivedMetricTests {

    @Test func invalidRawEnumsFallBackToSafeDefaults() {
        let exercise = ExerciseLibraryModel(
            name: "Mystery Lift",
            primaryMuscles: ["chest"],
            secondaryMuscles: ["triceps"],
            equipment: "machine",
            defaultWeightMode: .bodyweightAdded
        )
        exercise.defaultWeightModeRaw = "future-weight-mode"

        let routineSet = RoutineSetModel(userID: UUID(), setType: .drop)
        routineSet.setTypeRaw = "future-set-type"

        let set = SetModel(userID: UUID(), setType: .restPause, weightMode: .bodyweight)
        set.setTypeRaw = "future-set-type"
        set.weightModeRaw = "future-weight-mode"

        #expect(exercise.defaultWeightMode == .external)
        #expect(routineSet.setType == SetType.working)
        #expect(set.setType == SetType.working)
        #expect(set.weightMode == WeightMode.external)
    }

    @Test func exerciseDomainProjectionCarriesAnalyticsFields() {
        let exerciseID = UUID()
        let mappedID = UUID()
        let exercise = ExerciseLibraryModel(
            id: exerciseID,
            name: "Single-Arm Cable Row",
            movementPattern: "horizontal_pull",
            primaryMuscles: ["lats"],
            secondaryMuscles: ["biceps", "rear_delts"],
            equipment: "cable",
            isUnilateral: true,
            defaultWeightMode: .external,
            mappedGlobalID: mappedID
        )

        let domain = exercise.domainInfo

        #expect(domain.id == exerciseID)
        #expect(domain.name == "Single-Arm Cable Row")
        #expect(domain.movementPattern == "horizontal_pull")
        #expect(domain.primaryMuscles == ["lats"])
        #expect(domain.secondaryMuscles == ["biceps", "rear_delts"])
        #expect(domain.equipment == "cable")
        #expect(domain.isUnilateral)
        #expect(domain.mappedGlobalID == mappedID)
    }

    @Test func miniRepsAddExtraVolumeForMyoRepAndRestPauseOnly() {
        let myoRep = SetModel(
            userID: UUID(),
            setType: .myoRep,
            reps: 12,
            weight: 50,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        myoRep.miniReps = [4, 4, 3]

        #expect(myoRep.miniReps == [4, 4, 3])
        #expect(myoRep.totalVolume == 1_150)

        let restPause = SetModel(
            userID: UUID(),
            setType: .restPause,
            reps: 8,
            weight: 80,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        restPause.miniReps = [3, 2]

        #expect(restPause.totalVolume == 1_040)

        let cluster = SetModel(
            userID: UUID(),
            setType: .cluster,
            reps: 10,
            weight: 100,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        cluster.miniReps = [2, 2, 2, 2, 2]

        #expect(cluster.totalVolume == 1_000)
    }

    @Test func miniRepsEmptySetterClearsJSONAndInvalidJSONDecodesEmpty() {
        let set = SetModel(
            userID: UUID(),
            setType: .myoRep,
            reps: 10,
            weight: 60,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        set.miniReps = [3, 3]
        #expect(set.miniRepsJSON != nil)
        #expect(set.totalVolume == 960)

        set.miniReps = []
        #expect(set.miniRepsJSON == nil)
        #expect(set.miniReps.isEmpty)
        #expect(set.totalVolume == 600)

        set.miniRepsJSON = "not json"
        #expect(set.miniReps.isEmpty)
    }

    @Test func domainEntryReflectsLatestSetFieldsAfterMutation() {
        let set = SetModel(
            userID: UUID(),
            setType: .warmup,
            weightMode: .bodyweight,
            reps: 5,
            bodyweightKg: 80,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        set.setType = SetType.working
        set.weightMode = WeightMode.bodyweightAssisted
        set.assistanceWeight = 25
        set.partialReps = 2
        set.recomputeDerivedMetrics()

        let entry = set.domainEntry

        #expect(entry.setType == SetType.working)
        #expect(entry.weightMode == WeightMode.bodyweightAssisted)
        #expect(entry.reps == 5)
        #expect(entry.bodyweightKg == 80)
        #expect(entry.assistanceWeight == 25)
        #expect(entry.partialReps == 2)
        #expect(set.effectiveLoad == 55)
        #expect(set.totalVolume == 330)
    }
}
