import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct StrengthHoldTests {
    @Test func aPartialHoldExcludesPausedTimeAndCannotCompleteTwice() {
        let initial = ContinuousClock.now
        var elapsed: Duration = .zero
        let timer = StrengthHoldTimer(clockNow: { initial.advanced(by: elapsed) })
        let workoutID = UUID(), exerciseID = UUID(), setID = UUID()
        var completed: [Int] = []
        timer.start(workoutID: workoutID, exerciseID: exerciseID, setID: setID, seconds: 65) {
            seconds, _ in completed.append(seconds)
        }
        elapsed = .seconds(12)
        timer.pause(setID: setID)
        elapsed = .seconds(120)
        #expect(timer.hold?.remaining(at: initial.advanced(by: elapsed)) == 53)
        timer.resume(setID: setID)
        elapsed += .seconds(7)
        timer.pause(setID: setID)
        elapsed += .seconds(100)
        timer.finish(setID: setID)
        timer.finish(setID: setID)
        #expect(completed == [19])
        #expect(timer.hold == nil)
    }

    @Test func anExpiredCountdownCompletesWithoutATap() async {
        let timer = StrengthHoldTimer()
        let setID = UUID()
        var completed: [Int] = []
        timer.start(workoutID: UUID(), exerciseID: UUID(), setID: setID, seconds: 1) {
            seconds, _ in completed.append(seconds)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while completed.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(completed == [1])
        #expect(timer.hold == nil)
    }

    @Test func cancellingTheOwningExerciseDoesNotLogTheSet() {
        let start = ContinuousClock.now
        var now = start
        let timer = StrengthHoldTimer(clockNow: { now })
        let workoutID = UUID(), exerciseID = UUID(), setID = UUID()
        var completed = false
        timer.start(workoutID: workoutID, exerciseID: exerciseID, setID: setID, seconds: 30) {
            _, _ in completed = true
        }
        now = start.advanced(by: .seconds(7))
        timer.cancel(workoutID: workoutID, exerciseID: UUID())
        #expect(timer.hold?.setID == setID)
        timer.cancel(workoutID: workoutID, exerciseID: exerciseID)
        timer.finish(setID: setID)
        #expect(!completed)
    }

    @Test func routineTimeBecomesAWorkingHoldAndActualSecondsSurviveReload() throws {
        let (container, context) = try TestStore.make()
        let userID = ForgeFitDemo.userID
        let exercise = ExerciseLibraryModel(
            ownerID: userID, name: "Wall sit", equipment: "body only", defaultHoldSeconds: 30
        )
        let target = RoutineSetModel(userID: userID, setType: .timedHold, targetDurationSeconds: 65)
        let routine = RoutineModel(userID: userID, name: "Legs", exercises: [
            RoutineExerciseModel(userID: userID, exerciseID: exercise.id, sets: [target])
        ])
        context.insert(exercise)
        context.insert(routine)
        let workout = try #require(WorkoutFactory.start(
            routine: routine, exercises: [exercise], in: context, onCommit: { _ in }
        ))
        let set = try #require(workout.exercises.first?.sets.first)
        #expect(set.setType == .timedHold)
        #expect(set.durationSeconds == 65)
        #expect(set.reps == nil)
        #expect(set.weightMode == .bodyweight)

        set.durationSeconds = 19
        LiveSetCompletion.prepare(set, completedAt: .now, latestBodyweight: 82)
        try context.save()

        let id = set.id
        let readback = try #require(ModelContext(container).fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == id }
        )).first)
        #expect(readback.completedAt != nil)
        #expect(HistoricalSetPresentation.outputText(readback) == "19s")
        #expect(readback.reps == nil)
        #expect(readback.totalVolume == 82)
        #expect(readback.estimated1RM == nil)
        #expect(target.targetDurationSeconds == 65)
    }
}
