#if DEBUG
import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// Recreates both structured-prefill failures: the routine carries hidden
/// 50 lb targets while matching history visibly ghosts 72.5 kg.
@MainActor
enum BlockPrefillUITestFixture {
    private static let myoRoutineSetID = UUID(uuidString: "00000000-0000-7000-8000-000000000913")!

    static func seed(in modelContext: ModelContext) throws {
        let includesRoutineMyo = ProcessInfo.processInfo.arguments.contains("--seed-routine-myo-prefill-history")
        let targetID = ForgeFitDemo.starterRoutineSetID
        var targetDescriptor = FetchDescriptor<RoutineSetModel>(
            predicate: #Predicate { $0.id == targetID }
        )
        targetDescriptor.fetchLimit = 1
        if let target = try modelContext.fetch(targetDescriptor).first {
            target.targetWeight = 50 / 2.2046226218
            if includesRoutineMyo,
               let routineExercise = target.routineExercise,
               !routineExercise.sets.contains(where: { $0.id == myoRoutineSetID }) {
                let myoTarget = RoutineSetModel(
                    id: myoRoutineSetID,
                    userID: ForgeFitDemo.userID,
                    position: 1,
                    setType: .myoRep,
                    targetWeight: 50 / 2.2046226218,
                    plannedMiniSetCount: 4
                )
                modelContext.insert(myoTarget)
                routineExercise.sets.append(myoTarget)
            }
        }

        let title = "Block Prefill History Fixture"
        var workoutDescriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == title }
        )
        workoutDescriptor.fetchLimit = 1
        guard try modelContext.fetch(workoutDescriptor).isEmpty else {
            try modelContext.save()
            return
        }

        let completedAt = Date().addingTimeInterval(-3_600)
        let workingSet = SetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            setType: .working,
            reps: 10,
            weight: 72.5,
            completedAt: completedAt
        )
        var historySets = [workingSet]
        if includesRoutineMyo {
            let myoSet = SetModel(
                userID: ForgeFitDemo.userID,
                position: 1,
                setType: .myoRep,
                reps: 8,
                weight: 72.5,
                completedAt: completedAt
            )
            myoSet.miniReps = [4, 3, 3, 3]
            historySets.append(myoSet)
        }
        let exercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            sets: historySets
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: completedAt.addingTimeInterval(-1_800),
            endedAt: completedAt,
            exercises: [exercise]
        )
        workout.recomputeTotalVolume()
        modelContext.insert(workout)
        try modelContext.save()
    }
}
#endif
