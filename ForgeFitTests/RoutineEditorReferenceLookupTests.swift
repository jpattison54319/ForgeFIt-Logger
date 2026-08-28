import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct RoutineEditorReferenceLookupTests {
    @Test("Routine editor resolves exercises and newest authored notes in O(1)")
    func buildsReferenceLookup() {
        let exercise = ExerciseLibraryModel(name: "Bench Press")
        let older = UserExerciseNoteModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            note: "Old setup",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let newest = UserExerciseNoteModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            note: "New setup",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )

        let lookup = RoutineEditorReferenceLookup.make(
            exercises: [exercise],
            setupNotes: [newest, older]
        )

        #expect(lookup.exerciseByID[exercise.id] === exercise)
        #expect(lookup.setupNoteByExerciseID[exercise.id] === newest)
    }

    @Test("An older setup-note mutation invalidates the lookup revision")
    func olderNoteMutationInvalidatesRevision() {
        let exercise = ExerciseLibraryModel(name: "Bench Press")
        let older = UserExerciseNoteModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            note: "Old setup",
            updatedAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let newest = UserExerciseNoteModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            note: "New setup",
            updatedAt: Date(timeIntervalSinceReferenceDate: 20)
        )
        let before = RoutineEditorReferenceLookup.revision(
            exercises: [exercise],
            setupNotes: [older, newest]
        )

        older.note = "Changed old setup"

        #expect(RoutineEditorReferenceLookup.revision(
            exercises: [exercise],
            setupNotes: [older, newest]
        ) != before)
    }
}
