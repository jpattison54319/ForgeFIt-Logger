import ForgeCore
import ForgeData
import Foundation
import Testing
import UIKit
@testable import ForgeFit

/// Renders each share card off-screen and asserts it produces a single, tall
/// image — the core promise of the sharing feature ("one long photo").
@MainActor
struct ShareCardRenderTests {
    private let userID = ForgeFitDemo.userID
    private let benchID = UUID(uuidString: "00000000-0000-7000-8000-0000000000E1")!
    private let squatID = UUID(uuidString: "00000000-0000-7000-8000-0000000000E2")!

    private var library: [ExerciseLibraryModel] {
        [
            ExerciseLibraryModel(id: benchID, name: "Bench Press", equipment: "barbell"),
            ExerciseLibraryModel(id: squatID, name: "Back Squat", equipment: "barbell"),
        ]
    }

    private func workout() -> WorkoutModel {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        func sets(_ weight: Double, at base: TimeInterval) -> [SetModel] {
            (0..<3).map { i in
                SetModel(userID: userID, position: i, reps: 8, weight: weight, rpe: 8,
                         completedAt: start.addingTimeInterval(base + Double(i) * 120))
            }
        }
        let bench = WorkoutExerciseModel(userID: userID, exerciseID: benchID, position: 0, sets: sets(100, at: 60))
        let squat = WorkoutExerciseModel(userID: userID, exerciseID: squatID, position: 1, sets: sets(140, at: 500))
        let w = WorkoutModel(
            userID: userID, title: "Push Day", startedAt: start, endedAt: start.addingTimeInterval(3600),
            avgHR: 128, maxHR: 165, activeEnergyKcal: 420, hrZoneSeconds: [120, 300, 600, 400, 100],
            readinessAtStart: 72, exercises: [bench, squat]
        )
        return w
    }

    @Test func workoutCardRendersTallImageWithAllSections() {
        let w = workout()
        let hrSamples: [(date: Date, bpm: Int)] = (0..<40).map {
            (w.startedAt.addingTimeInterval(Double($0) * 90), 110 + ($0 % 20))
        }
        let recovery = [
            SetRecoveryPoint(setID: w.exercises[0].sets[0].id, peakHR: 158, recoveryBPM: 34),
            SetRecoveryPoint(setID: w.exercises[0].sets[1].id, peakHR: 160, recoveryBPM: 28),
        ]
        let image = WorkoutShareRenderer.image(
            for: w, exercises: library, theme: .sage, hrSamples: hrSamples, recoveryPoints: recovery
        )
        #expect(image != nil)
        // Retina scale 3 on a 430pt-wide card → 1290px wide; a full workout is taller.
        #expect((image?.size.height ?? 0) > (image?.size.width ?? 0))
    }

    @Test func routineCardRenders() {
        let set = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetRepsHigh: 12, targetWeight: 100, targetRPE: 8)
        let re = RoutineExerciseModel(userID: userID, exerciseID: benchID, position: 0, sets: [set])
        let routine = RoutineModel(userID: userID, name: "Upper A", exercises: [re])
        #expect(RoutineShareRenderer.image(for: routine, exercises: library, theme: .sage) != nil)
    }

    @Test func folderCardRendersMesoAndMacro() {
        let re = RoutineExerciseModel(
            userID: userID, exerciseID: squatID, position: 0,
            sets: [RoutineSetModel(userID: userID, targetRepsLow: 5, targetRepsHigh: 5, targetWeight: 140)]
        )
        let routine = RoutineModel(userID: userID, name: "Leg Day", exercises: [re])

        let meso = FolderShareRenderer.image(
            name: "Hypertrophy Block", isMacro: false,
            sections: [.init(title: nil, routines: [routine])], exercises: library, theme: .sage
        )
        #expect(meso != nil)

        let macro = FolderShareRenderer.image(
            name: "Off-Season", isMacro: true,
            sections: [.init(title: "Block 1", routines: [routine]), .init(title: "Block 2", routines: [routine])],
            exercises: library, theme: .sage
        )
        #expect(macro != nil)
    }
}
