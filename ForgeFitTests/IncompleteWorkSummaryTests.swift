import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// The finish-time guard against an accidentally skipped set or a whole
/// exercise that never got started.
@MainActor
struct IncompleteWorkSummaryTests {
    private let userID = UUID()

    private func set(
        _ position: Int,
        type: SetType = .working,
        completed: Bool
    ) -> SetModel {
        SetModel(
            userID: userID,
            position: position,
            setType: type,
            reps: 8,
            weight: 60,
            completedAt: completed ? Date() : nil
        )
    }

    private func workout(_ rows: [(exerciseID: UUID, sets: [SetModel])]) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            title: "Push",
            exercises: rows.enumerated().map { index, row in
                WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: row.exerciseID,
                    position: index,
                    sets: row.sets
                )
            }
        )
    }

    @Test func fullyCompletedWorkoutRaisesNothing() {
        let id = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([(id, [set(0, completed: true), set(1, completed: true)])]),
            exerciseNames: [id: "Bench Press"]
        )
        #expect(summary.isEmpty)
    }

    @Test func countsUntickedSetsOnStartedExercises() {
        let id = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([(id, [set(0, completed: true), set(1, completed: false), set(2, completed: false)])]),
            exerciseNames: [id: "Bench Press"]
        )
        #expect(summary.unfinishedSetCount == 2)
        #expect(summary.untouchedExerciseNames.isEmpty)
        #expect(summary.message.contains("2 sets"))
        #expect(summary.message.contains("aren't marked complete"))
    }

    /// The case the founder described: an exercise scrolled off the bottom and
    /// was never started. Naming it is what makes the warning actionable.
    @Test func namesExercisesWhereNothingWasCompleted() {
        let bench = UUID()
        let pulldown = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([
                (bench, [set(0, completed: true)]),
                (pulldown, [set(0, completed: false), set(1, completed: false)])
            ]),
            exerciseNames: [bench: "Bench Press", pulldown: "Lat Pulldown"]
        )
        #expect(summary.unfinishedSetCount == 0, "An untouched exercise is reported by name, not as loose sets.")
        #expect(summary.untouchedExerciseNames == ["Lat Pulldown"])
        #expect(summary.message.contains("Lat Pulldown"))
        #expect(summary.message.contains("isn't marked complete"))
    }

    @Test func combinesSetsAndUntouchedExercises() {
        let bench = UUID()
        let pulldown = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([
                (bench, [set(0, completed: true), set(1, completed: false)]),
                (pulldown, [set(0, completed: false)])
            ]),
            exerciseNames: [bench: "Bench Press", pulldown: "Lat Pulldown"]
        )
        #expect(summary.unfinishedSetCount == 1)
        #expect(summary.untouchedExerciseNames == ["Lat Pulldown"])
        #expect(summary.message.contains("1 set and Lat Pulldown"))
        #expect(summary.message.contains("aren't"), "Two subjects take a plural verb.")
    }

    /// Warm-ups are routinely left unticked by people who did them. Warning
    /// about those would teach the habit of dismissing this without reading.
    @Test func warmupSetsAreNotWarnedAbout() {
        let id = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([(id, [set(0, type: .warmup, completed: false), set(1, completed: true)])]),
            exerciseNames: [id: "Bench Press"]
        )
        #expect(summary.isEmpty)
    }

    /// An exercise whose only sets are unticked warm-ups counts as untouched
    /// working-wise, but there is no working set to miss — stay quiet.
    @Test func warmupOnlyExerciseIsNotReportedAsUntouched() {
        let id = UUID()
        let other = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([
                (id, [set(0, type: .warmup, completed: false)]),
                (other, [set(0, completed: true)])
            ]),
            exerciseNames: [id: "Empty Bar", other: "Bench Press"]
        )
        #expect(summary.isEmpty)
    }

    /// Cardio and yoga rows carry no sets — their completion is a
    /// CardioSessionModel and is covered by the conditioning target guard.
    @Test func sessionBasedRowsAreIgnored() {
        let cardio = UUID()
        let lift = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([(cardio, []), (lift, [set(0, completed: true)])]),
            exerciseNames: [cardio: "Treadmill", lift: "Bench Press"]
        )
        #expect(summary.isEmpty)
    }

    @Test func unresolvedExerciseNameFallsBackRatherThanDisappearing() {
        let unknown = UUID()
        let summary = IncompleteWorkSummary.make(
            for: workout([(unknown, [set(0, completed: false)])]),
            exerciseNames: [:]
        )
        #expect(summary.untouchedExerciseNames == ["an exercise"])
    }

    @Test func longUntouchedListStaysReadable() {
        let ids = (0..<4).map { _ in UUID() }
        let names = ["Row", "Curl", "Fly", "Dip"]
        let summary = IncompleteWorkSummary.make(
            for: workout(ids.map { ($0, [set(0, completed: false)]) }),
            exerciseNames: Dictionary(uniqueKeysWithValues: zip(ids, names))
        )
        #expect(summary.untouchedExerciseNames.count == 4)
        #expect(summary.message.contains("Row, Curl and 2 more"))
    }
}
