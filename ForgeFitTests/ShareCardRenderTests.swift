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

    /// Every representative Wrapped page kind must render as a share card —
    /// a page that draws blank ships a broken share button.
    @Test func wrappedPagesRenderAsShareCards() {
        let pages: [WrappedPage] = [
            .cover(.init(title: "Your June Wrapped", subtitle: "Let's look at what you built.")),
            .identity(.init(label: "Hybrid Builder", line: "Strength and engine work, side by side.")),
            .bigStats(.init(workouts: 18, trainingMinutes: 1_040, activeDays: 16, totalVolumeKg: 42_000)),
            .trainingMix(.init(strengthCount: 12, cardioCount: 6, strengthMinutes: 700, cardioMinutes: 340)),
            .calendar(.init(year: 2026, month: 6, activeDays: [2, 3, 5, 9, 11, 14, 18, 21, 25, 27])),
            .signatureExercise(.init(name: "Bench Press", sets: 36, sessions: 9)),
            .cardioEngine(.init(minutes: 340, distanceMeters: 52_000, zoneSeconds: [600, 9_000, 5_400, 2_400, 900], longestSessionMinutes: 62, longestSessionKind: "Run")),
            .bossBattle(.init(workoutTitle: "Leg Day", dayLabel: "Jun 21", durationMinutes: 82, volumeKg: 9_400, avgRPE: 8.6)),
            .nextFocus(.init(primary: "Add 2 easy Zone 2 sessions per week.", secondary: "Add 2 pulling exercises per week.", maintain: "Maintain your 18-session pace.")),
            .recap(.init(title: "June 2026", workouts: 18, trainingMinutes: 1_040, volumeKg: 42_000, activeDays: 16, identityLabel: "Hybrid Builder", highlight: "3 records set")),
            // Yearly-only kinds.
            .mostActiveMonth(.init(monthName: "August", workouts: 22)),
            .longestStreak(.init(days: 9, endedLabel: "ended Aug 14")),
            .topWorkouts(.init(entries: [
                .init(title: "Leg Day", dayLabel: "Aug 3", volumeKg: 11_200),
                .init(title: "Push Day", dayLabel: "May 19", volumeKg: 10_400),
                .init(title: "Pull Day", dayLabel: "Sep 2", volumeKg: 9_900),
            ])),
            .badges(.init(earned: ["Century Club — 100+ workouts", "Streak Master — 9 days straight"])),
        ]
        for page in pages {
            let image = WrappedShareRenderer.image(page: page, periodLabel: "June 2026", theme: .sage)
            #expect(image != nil, "page \(page.kind) failed to render")
        }
    }
}
