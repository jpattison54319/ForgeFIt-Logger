import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// End-to-end guards for the user-facing data export: health values appear
/// only in the export appendix and never inside the reused backup schema,
/// tombstoned data appears nowhere, and the routine hierarchy flattens
/// correctly from live models.
@MainActor
struct DataExportTests {
    private let userID = UUID()
    // Sentinels: values that cannot occur incidentally in the fixture.
    private static let sentinelAvgHR = 19_991
    private static let sentinelKcal = 4_242.25

    private func seed(context: ModelContext) throws -> (workout: WorkoutModel, deleted: WorkoutModel) {
        let lib = ExerciseLibraryModel(name: "Bench Press")
        context.insert(lib)
        let set = SetModel(userID: userID, position: 0, reps: 8, weight: 100, completedAt: .now)
        let we = WorkoutExerciseModel(userID: userID, exerciseID: lib.id, sets: [set])
        let session = CardioSessionModel(userID: userID, modality: "run")
        session.durationSeconds = 600
        session.distanceMeters = 2000
        session.endedAt = .now
        session.avgHR = Self.sentinelAvgHR
        // Machine readouts + swim contract: training data, one of each kind.
        session.split500mSeconds = 128.5
        session.strokeRate = 26
        session.avgPowerWatts = 185
        session.avgCadence = 88
        session.resistanceLevel = 7
        session.inclinePercent = 2.5
        session.elevationGainMeters = 42
        session.poolLengthMeters = 25
        session.lengthsCompleted = 40
        session.totalStrokes = 720
        session.strokeStyleRaw = "freestyle"
        let workout = WorkoutModel(userID: userID, exercises: [we], cardioSessions: [session])
        workout.title = "Push Day"
        workout.endedAt = .now
        workout.avgHR = Self.sentinelAvgHR
        workout.activeEnergyKcal = Self.sentinelKcal
        workout.readinessAtStart = 75
        context.insert(workout)

        let deleted = WorkoutModel(userID: userID)
        deleted.title = "Ghost Workout Tombstone"
        deleted.deletedAt = .now
        context.insert(deleted)

        // Routine hierarchy: macro folder -> meso folder -> routine.
        let macro = RoutineFolderModel(userID: userID, name: "Strength Block")
        context.insert(macro)
        let meso = RoutineFolderModel(userID: userID, name: "Meso 1", parentID: macro.id)
        context.insert(meso)
        let routineSet = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetRepsHigh: 12, targetWeight: 100)
        let routineExercise = RoutineExerciseModel(userID: userID, exerciseID: lib.id, position: 0, sets: [routineSet])
        let routine = RoutineModel(userID: userID, name: "Push A", folderID: meso.id, exercises: [routineExercise])
        context.insert(routine)
        try context.save()
        return (workout, deleted)
    }

    @Test func jsonKeepsHealthInAppendixOnlyAndDropsTombstones() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let (workout, _) = try seed(context: context)

        let urls = try await DataExportService.export(format: .json, container: container)
        let url = try #require(urls.first)
        #expect(url.lastPathComponent.hasPrefix("ForgeFit-Export-") && url.pathExtension == "json")
        let data = try Data(contentsOf: url)

        let file = try ExportMapper.decode(data)
        #expect(file.exportVersion == ForgeFitExportFile.currentExportVersion)
        #expect(file.trainingLog.workouts.contains { $0.id == workout.id })
        #expect(!file.trainingLog.workouts.contains { $0.title == "Ghost Workout Tombstone" })

        // Health values live in the appendix, keyed by the training-log ids…
        let health = try #require(file.healthMetrics.workouts[workout.id.uuidString])
        #expect(health.avgHR == Self.sentinelAvgHR)
        #expect(health.activeEnergyKcal == Self.sentinelKcal)
        let sessionID = try #require(workout.cardioSessions.first?.id.uuidString)
        #expect(file.healthMetrics.cardioSessions[sessionID]?.avgHR == Self.sentinelAvgHR)

        // Machine readouts and pool metadata are training data: they ride
        // the training log itself, not the appendix.
        let exportedSession = try #require(
            file.trainingLog.workouts.first { $0.id == workout.id }?.cardioSessions.first
        )
        #expect(exportedSession.split500mSeconds == 128.5)
        #expect(exportedSession.strokeRate == 26)
        #expect(exportedSession.avgPowerWatts == 185)
        #expect(exportedSession.avgCadence == 88)
        #expect(exportedSession.resistanceLevel == 7)
        #expect(exportedSession.inclinePercent == 2.5)
        #expect(exportedSession.elevationGainMeters == 42)
        #expect(exportedSession.poolLengthMeters == 25)
        #expect(exportedSession.lengthsCompleted == 40)
        #expect(exportedSession.totalStrokes == 720)
        #expect(exportedSession.strokeStyleRaw == "freestyle")

        // …and NEVER inside the reused backup schema: re-encode just the
        // trainingLog and prove the sentinel bytes aren't there.
        let trainingLogBytes = try BackupMapper.encode(file.trainingLog)
        let trainingLogText = String(decoding: trainingLogBytes, as: UTF8.self)
        #expect(!trainingLogText.contains("\(Self.sentinelAvgHR)"))
        #expect(!trainingLogText.contains("avgHR"))

        // Routines section carries the hierarchy and targets.
        #expect(file.routines.folders.count == 2)
        let exported = try #require(file.routines.routines.first { $0.name == "Push A" })
        #expect(exported.exercises.first?.name == "Bench Press")
        #expect(exported.exercises.first?.sets.first?.targetWeightKg == 100)
    }

    @Test func csvExportsWorkoutsAndRoutinesWithTombstonesDropped() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        _ = try seed(context: context)

        let urls = try await DataExportService.export(format: .csv, container: container)
        #expect(urls.count == 2)
        let workoutsCSV = try String(contentsOf: try #require(urls.first { $0.lastPathComponent.contains("Workouts") }), encoding: .utf8)
        let routinesCSV = try String(contentsOf: try #require(urls.first { $0.lastPathComponent.contains("Routines") }), encoding: .utf8)

        #expect(workoutsCSV.hasPrefix(WorkoutCSVExport.header.joined(separator: ",")))
        #expect(workoutsCSV.contains("Push Day"))
        #expect(workoutsCSV.contains("\(Self.sentinelAvgHR)"))      // health columns present
        #expect(!workoutsCSV.contains("Ghost Workout Tombstone"))   // tombstone dropped
        #expect(workoutsCSV.contains(",set,"))
        #expect(workoutsCSV.contains(",cardio,"))
        #expect(workoutsCSV.contains("freestyle"))                  // swim contract column

        #expect(routinesCSV.hasPrefix(RoutineCSVExport.header.joined(separator: ",")))
        #expect(routinesCSV.contains("Strength Block,Meso 1,Push A"))
        #expect(routinesCSV.contains("Bench Press"))
    }
}
