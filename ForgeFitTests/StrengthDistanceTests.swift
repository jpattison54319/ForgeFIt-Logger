import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct StrengthDistanceTests {
    @Test func aDistanceRoutineKeepsBandLoadAndRecordsCanonicalMeters() throws {
        let (container, context) = try TestStore.make()
        let userID = ForgeFitDemo.userID
        let exercise = ExerciseLibraryModel(
            name: "Monster Walk", equipment: "bands",
            modalityRaw: ExerciseLibraryModel.strengthDistanceModalityRaw
        )
        let target = RoutineSetModel(
            userID: userID, targetRepsLow: 20, targetWeight: 12, targetDistanceMeters: 30
        )
        let routine = RoutineModel(userID: userID, name: "Legs", exercises: [
            RoutineExerciseModel(userID: userID, exerciseID: exercise.id, sets: [target])
        ])
        context.insert(exercise)
        context.insert(routine)
        let workout = try #require(WorkoutFactory.start(
            routine: routine, exercises: [exercise], in: context, onCommit: { _ in }
        ))
        let set = try #require(workout.exercises.first?.sets.first)
        #expect(exercise.modality == .strength)
        #expect(set.setType == .distance)
        #expect(set.reps == nil)
        #expect(set.modeWeight == 12)
        #expect(set.strengthDistanceMeters == 30)
        #expect(StrengthDistanceUnit.feet.number(meters: 30) == "98.43")

        set.machineSettingsJSON = #"{"seat":3}"#
        set.strengthDistanceMeters = StrengthDistanceUnit.feet.meters(from: 100)
        LiveSetCompletion.prepare(set, completedAt: .now, latestBodyweight: nil)
        try context.save()
        let id = set.id
        let reloaded = try #require(ModelContext(container).fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == id }
        )).first)
        #expect(reloaded.strengthDistanceMeters == 30.48)
        #expect(reloaded.machineSettingsJSON?.contains(#""seat":3"#) == true)
        #expect(reloaded.reps == nil)
        #expect(reloaded.estimated1RM == nil)
        #expect(reloaded.totalVolume == 12)
    }
}
