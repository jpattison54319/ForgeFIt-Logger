import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ExerciseNotePolicyTests {
    @Test func blankTextIsNotAnAuthoredNote() {
        #expect(ExerciseNotePolicy.authoredText(nil) == nil)
        #expect(ExerciseNotePolicy.authoredText("") == nil)
        #expect(ExerciseNotePolicy.authoredText("  \n\t ") == nil)
        #expect(ExerciseNotePolicy.authoredText("  Seat 4  \n") == "Seat 4")
    }

    @Test func deletingFocusedTextCannotCreateAnEmptyPin() {
        #expect(ExerciseNotePolicy.pinStateAfterToggle(currentlyPinned: true, draft: "") == false)
        #expect(ExerciseNotePolicy.pinStateAfterToggle(currentlyPinned: false, draft: "  ") == false)
        #expect(ExerciseNotePolicy.pinStateAfterToggle(currentlyPinned: false, draft: "Seat 4") == true)
        #expect(ExerciseNotePolicy.pinStateAfterToggle(currentlyPinned: true, draft: "Seat 4") == false)
    }

    @Test func routineStartDoesNotResurrectABlankPinnedNote() throws {
        let (container, context) = try TestStore.make()
        _ = container
        let userID = ForgeFitDemo.userID
        let exercise = ExerciseLibraryModel(
            name: "Cable Row",
            primaryMuscles: ["back"],
            equipment: "cable"
        )
        let blankPinnedNote = UserExerciseNoteModel(
            userID: userID,
            exerciseID: exercise.id,
            note: "  \n "
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            sets: [RoutineSetModel(userID: userID)]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Pull",
            exercises: [routineExercise]
        )
        context.insert(exercise)
        context.insert(blankPinnedNote)
        context.insert(routine)
        try context.save()

        let committedWorkout = WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            setupNotes: [blankPinnedNote],
            in: context,
            onCommit: { _ in }
        )
        let workout = try #require(committedWorkout)

        #expect(workout.exercises.first?.notes == nil)
        #expect(workout.exercises.first?.notePinned == false)
    }

    @Test func blankRoutineTextFallsBackToARealPinnedNote() throws {
        let (container, context) = try TestStore.make()
        _ = container
        let userID = ForgeFitDemo.userID
        let exercise = ExerciseLibraryModel(
            name: "Cable Row",
            primaryMuscles: ["back"],
            equipment: "cable"
        )
        let pinnedNote = UserExerciseNoteModel(
            userID: userID,
            exerciseID: exercise.id,
            note: "Chest tall"
        )
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            notes: "   ",
            sets: [RoutineSetModel(userID: userID)]
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Pull",
            exercises: [routineExercise]
        )
        context.insert(exercise)
        context.insert(pinnedNote)
        context.insert(routine)
        try context.save()

        let committedWorkout = WorkoutFactory.start(
            routine: routine,
            exercises: [exercise],
            setupNotes: [pinnedNote],
            in: context,
            onCommit: { _ in }
        )
        let workout = try #require(committedWorkout)

        #expect(workout.exercises.first?.notes == "Chest tall")
        #expect(workout.exercises.first?.notePinned == true)
    }
}
