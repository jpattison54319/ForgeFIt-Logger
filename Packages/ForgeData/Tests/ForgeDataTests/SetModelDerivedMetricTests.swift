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

    @Test func side2DataAddsPerSideVolumeForMyoReps() {
        // Unilateral myo-reps logged per side: side 1 = 12 + [4,4,3],
        // side 2 = 11 + [4,3,3], both at 20kg. Each side counts once.
        let set = SetModel(
            userID: UUID(),
            setType: .myoRep,
            reps: 12,
            weight: 20,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        set.miniReps = [4, 4, 3]
        set.side2Reps = 11
        set.side2MiniReps = [4, 3, 3]

        // (12 + 4+4+3) + (11 + 4+3+3) = 23 + 21 = 44 reps × 20kg
        #expect(set.hasSide2Data)
        #expect(set.totalVolume == 880)
    }

    @Test func side2ClusterSegmentsCountOnceWithoutDoubling() {
        // Per-side cluster: `reps` mirrors SIDE 1's segments only; side 2's
        // live in side2MiniReps — folding them into `reps` too would double.
        let set = SetModel(
            userID: UUID(),
            setType: .cluster,
            reps: 10,   // side 1: 2×5 segments
            weight: 40,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        set.miniReps = [5, 5]
        set.side2MiniReps = [5, 4]

        // side 1: 10 reps + side 2: 9 reps, all × 40kg
        #expect(set.totalVolume == 760)
    }

    @Test func setsWithoutSide2DataKeepExactPreExistingVolume() {
        // The per-side path must be invisible to bilateral / single-entry
        // work: nil side-2 fields → byte-identical math to before.
        let set = SetModel(
            userID: UUID(),
            setType: .myoRep,
            reps: 12,
            weight: 50,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        set.miniReps = [4, 4, 3]

        #expect(!set.hasSide2Data)
        #expect(set.totalVolume == 1_150)

        set.side2MiniReps = []
        #expect(set.side2MiniRepsJSON == nil)
        #expect(!set.hasSide2Data)
    }

    @Test func side2WithSingleEntryUnilateralConventionDoesNotDoubleCount() {
        // A set flagged with the older single-entry unilateral convention
        // (limbCount doubles the one logged value) that ALSO gets explicit
        // side-2 data must not count side 1 twice: per-side logging wins.
        let set = SetModel(
            userID: UUID(),
            setType: .myoRep,
            reps: 10,
            isUnilateral: true,
            implementWeight: 20,
            limbCount: 2,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        set.side2Reps = 9
        set.recomputeDerivedMetrics()

        // 10 reps + 9 reps at 20kg — NOT (10×2) + 9.
        #expect(set.totalVolume == 380)
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
