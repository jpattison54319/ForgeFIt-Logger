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
        #expect(parsed.checkedRowCount == 2)
        #expect(parsed.workouts.count == 1)
        #expect(parsed.workouts[0].exercises.count == 2)
        #expect(abs((parsed.workouts[0].exercises[1].sets[0].weightKg ?? 0) - 79.3787) < 0.01)
        #expect(abs((parsed.workouts[0].exercises[0].sets[0].distanceMeters ?? 0) - 2060) < 2)
    }

    @Test func hevyCSVParsesDayFirst24HourDatesAndKilograms() throws {
        let csv = """
        "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_kg","reps","distance_km","duration_seconds","rpe"
        "Push Day","28 Mar 2025, 17:29","28 Mar 2025, 18:45","","Bench Press (Barbell)",,"",0,"normal",85,8,,,8
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")

        #expect(parsed.source == .hevy)
        #expect(parsed.workouts.count == 1)
        #expect(parsed.workouts[0].title == "Push Day")
        #expect(parsed.workouts[0].exercises[0].sets[0].weightKg == 85)
        #expect(parsed.workouts[0].exercises[0].sets[0].reps == 8)
    }

    @Test func hevyCSVCommitsCompleteWorkoutIntoCurrentDataModel() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = ExerciseLibraryModel(
            name: "Bench Press (Barbell)",
            primaryMuscles: ["chest"],
            equipment: "barbell"
        )
        let cycling = ExerciseLibraryModel(
            name: "Indoor Cycling",
            primaryMuscles: ["quadriceps"],
            equipment: "bike",
            defaultWeightMode: .bodyweight,
            isCardio: true,
            cardioKindRaw: CardioKind.cycle.rawValue,
            category: "cardio"
        )
        context.insert(bench)
        context.insert(cycling)
        try context.save()

        let csv = """
        "title","start_time","end_time","description","exercise_title","superset_id","exercise_notes","set_index","set_type","weight_lbs","reps","distance_miles","duration_seconds","rpe"
        "Upper A","25 Aug 2025, 09:38","25 Aug 2025, 10:54","Coach said \"\"steady\"\"","Bench Press (Barbell)",1,"Pause, then press",0,"warmup",150,3,,0,6
        "Upper A","25 Aug 2025, 09:38","25 Aug 2025, 10:54","Coach said \"\"steady\"\"","Bench Press (Barbell)",1,"Pause, then press",1,"normal",190,5,,0,8
        "Upper A","25 Aug 2025, 09:38","25 Aug 2025, 10:54","Coach said \"\"steady\"\"","Indoor Cycling",,,0,"normal",,,3.1,1200,7.5
        """

        let preview = try await WorkoutHistoryImportService.preview(
            data: Data(csv.utf8),
            fileName: "workouts.csv",
            workouts: [],
            exercises: [bench, cycling]
        )
        #expect(preview.parseResult.source == .hevy)
        #expect(preview.importableCount == 1)
        #expect(preview.customExerciseCount == 0)

        let result = try WorkoutHistoryImportService.commit(
            preview: preview,
            workouts: [],
            exercises: [bench, cycling],
            in: context
        )
        #expect(result.importedWorkouts == 1)
        #expect(result.createdExercises == 0)

        let workout = try #require(context.fetch(FetchDescriptor<WorkoutModel>()).first)
        #expect(workout.title == "Upper A")
        #expect(workout.notes == "Coach said \"steady\"")
        #expect(workout.externalSource == WorkoutImportSource.hevy.rawValue)
        #expect(workout.importFingerprint?.isEmpty == false)
        #expect(workout.endedAt?.timeIntervalSince(workout.startedAt) == 4_560)

        let strength = try #require(workout.exercises.first { $0.exerciseID == bench.id })
        #expect(strength.notes == "Pause, then press")
        #expect(strength.supersetGroup == 1)
        #expect(strength.sets.count == 2)
        let sets = strength.sets.sorted { $0.position < $1.position }
        #expect(sets[0].setType == .warmup)
        #expect(sets[1].setType == .working)
        #expect(abs((sets[1].weight ?? 0) - 86.1826) < 0.001)
        #expect(sets[1].reps == 5)
        #expect(sets[1].rpe == 8)
        #expect(sets.allSatisfy { $0.completedAt == workout.endedAt })

        let cardio = try #require(workout.cardioSessions.first)
        let cardioExercise = try #require(workout.exercises.first { $0.exerciseID == cycling.id })
        #expect(cardio.workoutExerciseID == cardioExercise.id)
        #expect(cardio.modality == CardioKind.cycle.rawValue)
        #expect(cardio.durationSeconds == 1_200)
        #expect(abs((cardio.distanceMeters ?? 0) - 4_988.9664) < 0.01)
        #expect(abs((cardio.avgPaceSecondsPerKm ?? 0) - 240.530) < 0.01)

        let batch = try #require(context.fetch(FetchDescriptor<WorkoutImportBatchModel>()).first)
        #expect(batch.importedCount == 1)
        #expect(batch.skippedDuplicateCount == 0)
    }

    @Test func hevyCSVParsesLargeHistoryExport() throws {
        let header = "title,start_time,end_time,description,exercise_title,superset_id,exercise_notes,set_index,set_type,weight_lbs,reps,distance_miles,duration_seconds,rpe"
        let rows = (0..<2_000).map { index in
            "Workout \(index / 10),\"25 Aug 2025, 09:38\",\"25 Aug 2025, 10:54\",,Bench Press (Barbell),,,\(index % 10),normal,190,5,,0,8"
        }
        let csv = ([header] + rows).joined(separator: "\n")

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")

        #expect(parsed.workouts.count == 200)
        #expect(parsed.workouts.reduce(0) { $0 + $1.setCount } == 2_000)
    }

    @Test func hevyCSVAllowsOptionalColumnsToBeAbsent() throws {
        let csv = """
        title,start_time,end_time,description,exercise_title,set_index,set_type,weight_lbs,reps,distance_miles,duration_seconds,muscle_group
        Morning workout ☀️,"13 Jul 2025, 10:56","13 Jul 2025, 11:53",,Warm Up,0,normal,,,,400,Cardio
        Morning workout ☀️,"13 Jul 2025, 10:56","13 Jul 2025, 11:53",,Band Pullaparts,0,normal,,10,,,Shoulders
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")

        #expect(parsed.source == .hevy)
        #expect(parsed.workouts.count == 1)
        #expect(parsed.workouts[0].exercises.count == 2)
        #expect(parsed.workouts[0].setCount == 2)
    }

    @Test func hevyRoutineLikeCSVExplainsHowToExportWorkoutHistory() throws {
        let csv = """
        title,exercise_title,set_index,set_type,weight_lbs,reps
        Push Day,Bench Press (Barbell),0,normal,185,5
        """

        do {
            _ = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "routines.csv")
            Issue.record("Expected validation to reject a Hevy file without workout dates")
        } catch let error as WorkoutImportError {
            guard case .hevyWorkoutDateColumnMissing = error else {
                Issue.record("Expected the Hevy workout-export error, got \(error)")
                return
            }
            #expect(error.columnDetails == ["start_time"])
            #expect(error.errorDescription?.contains("routine or template") == true)
            #expect(error.recoverySuggestion.contains("Export Workouts"))
            #expect(error.recoverySuggestion.contains("Save the CSV to Files"))
            #expect(error.recoverySuggestion.contains("return to ForgeFit"))
        }
    }

    @Test func hevyCSVReportsUnrecognizedDateWithRowAndValue() throws {
        let csv = """
        title,start_time,exercise_title,set_index,set_type,weight_lbs,reps
        Push Day,sometime last Tuesday,Bench Press (Barbell),0,normal,185,5
        """

        do {
            _ = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")
            Issue.record("Expected validation to reject unreadable workout dates")
        } catch let error as WorkoutImportError {
            guard case let .unreadableWorkoutDates(source, rowCount, firstRow, example) = error else {
                Issue.record("Expected an unreadable-date error, got \(error)")
                return
            }
            #expect(source == .hevy)
            #expect(rowCount == 1)
            #expect(firstRow == 2)
            #expect(example == "sometime last Tuesday")
        }
    }

    @Test func CSVReportsMissingExerciseColumnBeforeReadingRows() throws {
        let csv = """
        title,start_time,set_index,weight_lbs,reps
        Push Day,"May 15, 2026, 7:26 PM",0,185,5
        """

        do {
            _ = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "history.csv")
            Issue.record("Expected validation to reject a CSV with no exercise-name column")
        } catch let error as WorkoutImportError {
            guard case .missingRequiredColumns(let columns) = error else {
                Issue.record("Expected a missing-column error, got \(error)")
                return
            }
            #expect(columns == ["exercise_title / exercise_name"])
        }
    }

    @Test func hevyCSVKeepsImportingWhenItAddsAnOptionalColumn() throws {
        let csv = """
        title,start_time,end_time,exercise_title,set_index,set_type,weight_lbs,reps,new_hevy_metric
        Push,"May 15, 2026, 7:26 PM","May 15, 2026, 8:00 PM",Bench Press,0,normal,185,5,42
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")

        #expect(parsed.workouts.count == 1)
        #expect(parsed.warnings.contains { $0.message.contains("new_hevy_metric") })
        #expect(parsed.warnings.contains { $0.message.contains("were ignored") })
    }

    @Test func customCSVWithExerciseTitleIsNotMisidentifiedAsHevyRoutine() throws {
        let csv = """
        title,date,exercise_title,weight,reps
        Push,2026-05-15,Bench Press,100,5
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "custom.csv")

        #expect(parsed.source == .genericCSV)
        #expect(parsed.workouts.count == 1)
    }

    @Test func hevyCSVImportsValidRowsAndSummarizesInvalidRows() throws {
        let csv = """
        title,start_time,end_time,exercise_title,set_index,set_type,weight_lbs,reps
        Push,"May 15, 2026, 7:26 PM","May 15, 2026, 8:00 PM",Bench Press,0,normal,185,5
        Push,not-a-date,"May 15, 2026, 8:00 PM",Bench Press,1,normal,185,5
        """

        let parsed = try WorkoutHistoryImportParser.parse(data: Data(csv.utf8), fileName: "workouts.csv")

        #expect(parsed.workouts.count == 1)
        #expect(parsed.checkedRowCount == 2)
        #expect(parsed.warnings.contains { $0.message.contains("Skipped 1 row") && $0.message.contains("row 3") })
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
        let (container, context) = try TestStore.make()
        defer { _ = container }
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
        let (container, context) = try TestStore.make()
        defer { _ = container }

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

    // MARK: - Conservative import matching

    private static let matcherLibrary: [ExerciseInfo] = [
        ExerciseInfo(name: "Barbell Squat", equipment: "barbell"),
        ExerciseInfo(name: "Dumbbell Squat", equipment: "dumbbell"),
        ExerciseInfo(name: "Squat Jerk", equipment: "barbell"),
        ExerciseInfo(name: "Goblet Squat", equipment: "kettlebell"),
        ExerciseInfo(name: "Barbell Bench Press", equipment: "barbell"),
        ExerciseInfo(name: "Band Assisted Pull-Up", equipment: "bands"),
        ExerciseInfo(name: "Calf Press On The Leg Press Machine", equipment: "machine"),
    ]

    @Test func matcherReunitesHevyEquipmentSuffixWithCatalogOrdering() {
        let match = ImportExerciseMatcher.bestMatch(importedName: "Squat (Barbell)", in: Self.matcherLibrary)
        #expect(match?.exercise.name == "Barbell Squat")
    }

    @Test func matcherKeepsEquipmentVariantsDistinct() {
        let match = ImportExerciseMatcher.bestMatch(importedName: "Squat (Dumbbell)", in: Self.matcherLibrary)
        #expect(match?.exercise.name == "Dumbbell Squat")
    }

    @Test func matcherDoesNotLinkBareSquatToSquatJerk() {
        // The old fuzzy scorer matched "Squat" -> "Squat Jerk" at 90. A bare,
        // equipment-less "Squat" must stay unmatched (becomes a custom exercise)
        // rather than silently becoming an olympic lift — or a goblet squat.
        let match = ImportExerciseMatcher.bestMatch(importedName: "Squat", in: Self.matcherLibrary)
        #expect(match == nil)
    }

    @Test func matcherDoesNotSubstringMatch() {
        #expect(ImportExerciseMatcher.bestMatch(importedName: "Pull Up", in: Self.matcherLibrary) == nil)
        #expect(ImportExerciseMatcher.bestMatch(importedName: "Leg Press", in: Self.matcherLibrary) == nil)
    }

    @Test func matcherMatchesWhenOnlyImportSpecifiesEquipment() {
        let match = ImportExerciseMatcher.bestMatch(importedName: "Goblet Squat (Kettlebell)", in: Self.matcherLibrary)
        #expect(match?.exercise.name == "Goblet Squat")
    }

    @Test func matcherHandlesPluralAndOrder() {
        let match = ImportExerciseMatcher.bestMatch(importedName: "Bench Press (Barbell)", in: Self.matcherLibrary)
        #expect(match?.exercise.name == "Barbell Bench Press")
    }

    // MARK: - Pending-import-review surface

    @Test func pendingReviewIncludesConfidentBulkAddedExercises() throws {
        let predicate = ExerciseLibraryModel.pendingImportReviewPredicate

        // Confidently classified, added by an import, not yet confirmed → review.
        let confident = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID, name: "Barbell Squat",
            needsReview: false, classificationConfidence: 0.9, importBatchID: UUID()
        )
        #expect(try predicate.evaluate(confident))

        // Legacy low-confidence guess with no batch → still review.
        let lowConfidence = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID, name: "Mystery", needsReview: true
        )
        #expect(try predicate.evaluate(lowConfidence))

        // Confirmed/edited (userModified) → drops off the list.
        let confirmed = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID, name: "Confirmed",
            userModified: true, needsReview: false, importBatchID: UUID()
        )
        #expect(try !predicate.evaluate(confirmed))

        // A hand-created exercise (no import batch, confident) → not review.
        let handMade = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID, name: "Custom", needsReview: false
        )
        #expect(try !predicate.evaluate(handMade))
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
