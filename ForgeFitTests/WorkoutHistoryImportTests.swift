import Foundation
import ForgeCore
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutHistoryImportTests {
    @Test func hevyCSVParsesStrengthAndCardioRows() throws {
        let csv = """
        "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_lbs","reps","distance_miles","duration_seconds","rpe"
        "4x4 HIIT & Abs","May 15, 2026, 7:26 PM","May 15, 2026, 7:42 PM","","Elliptical Trainer",,"",0,"normal",,,1.28,240,
        "4x4 HIIT & Abs","May 15, 2026, 7:26 PM","May 15, 2026, 7:42 PM","","Atlantis Ab Crunch",,"",0,"normal",175,8,,,
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")

        #expect(parsed.source == .hevy)
        #expect(parsed.workouts.count == 1)
        #expect(parsed.workouts[0].exercises.count == 2)
        #expect(abs((parsed.workouts[0].exercises[1].sets[0].weightKg ?? 0) - 79.3787) < 0.01)
        #expect(abs((parsed.workouts[0].exercises[0].sets[0].distanceMeters ?? 0) - 2060) < 2)
    }

    @Test func genericStrongStyleCSVParsesSemicolonAndUnits() throws {
        let csv = """
        Date;Workout Name;Exercise Name;Set Order;Weight;Weight Unit;Reps;RPE;Distance;Distance Unit;Seconds;Notes;Workout Notes;Workout Duration
        2026-05-01 18:00:00;Upper;Bench Press;1;225;lbs;5;8;;;;;"Strong day";1h 5m
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "strong.csv")

        #expect(parsed.source == .strong)
        #expect(parsed.workouts.count == 1)
        let set = try #require(parsed.workouts.first?.exercises.first?.sets.first)
        #expect(set.reps == 5)
        #expect(set.rpe == 8)
        #expect(abs((set.weightKg ?? 0) - 102.058) < 0.01)
    }

    @Test func commitCreatesCompletedWorkoutsAndSkipsDuplicateReimport() async throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let bench = ExerciseLibraryModel(name: "Bench Press", primaryMuscles: ["chest"], equipment: "barbell")
        context.insert(bench)
        try context.save()

        let csv = """
        title,start_time,end_time,exercise_title,set_index,set_type,weight_lbs,reps
        Push,"May 15, 2026, 7:26 PM","May 15, 2026, 8:00 PM",Bench Press,0,normal,225,5
        """

        let data = Data(csv.utf8)
        let preview = try await WorkoutHistoryImportService.preview(data: data, fileName: "workouts.csv", workouts: [], exercises: [bench])
        let first = try WorkoutHistoryImportService.commit(preview: preview, workouts: [], exercises: [bench], in: context)
        #expect(first.importedWorkouts == 1)
        #expect(first.createdExercises == 0)

        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        let secondPreview = try await WorkoutHistoryImportService.preview(data: data, fileName: "workouts.csv", workouts: workouts, exercises: [bench])
        let second = try WorkoutHistoryImportService.commit(preview: secondPreview, workouts: workouts, exercises: [bench], in: context)

        #expect(second.importedWorkouts == 0)
        #expect(second.skippedDuplicates == 1)
        #expect(try context.fetch(FetchDescriptor<WorkoutModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<WorkoutImportBatchModel>()).count == 2)
    }

    @Test func importCreatesClassifiedCustomStrengthExercise() async throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        let csv = """
        title,start_time,end_time,exercise_title,set_index,set_type,weight_lbs,reps
        Arms,"May 15, 2026, 7:26 PM","May 15, 2026, 8:00 PM",Atlantis Cable Curl,0,normal,55,12
        """

        let preview = try await WorkoutHistoryImportService.preview(
            data: Data(csv.utf8),
            fileName: "workouts.csv",
            workouts: [],
            exercises: []
        )
        let result = try WorkoutHistoryImportService.commit(preview: preview, workouts: [], exercises: [], in: context)
        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let custom = try #require(exercises.first { $0.name == "Atlantis Cable Curl" })

        #expect(result.createdExercises == 1)
        #expect(custom.primaryMuscles == ["biceps"])
        #expect(custom.needsReview == false)
        #expect(custom.classificationSource == .keyword)
        #expect(custom.importedRawName == "Atlantis Cable Curl")
    }

    @Test func lowConfidenceCustomExerciseNeedsReview() throws {
        let draft = ImportedExerciseDraft(id: "mystery-implement", name: "Mystery Implement", sets: [
            ImportedSetDraft(id: "set-1", index: 0, setType: .working, weightKg: 20, reps: 10)
        ])

        let exercise = WorkoutHistoryImportService.makeCustomExercise(
            from: draft,
            classification: ExerciseClassification(confidence: 0.1, source: .fallback),
            batchID: UUID(),
            userID: ForgeFitDemo.userID
        )

        #expect(exercise.needsReview == true)
        #expect(exercise.primaryMuscles.isEmpty)
        #expect(exercise.classificationSource == .fallback)
    }
}
