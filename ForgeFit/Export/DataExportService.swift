import ForgeData
import Foundation
import SwiftData

/// Builds the user-facing "export my data" files on demand. The snapshot is
/// the same one the iCloud backup uses (so the two can never disagree about
/// the training log); the export then adds what the backup must never carry —
/// the health appendix and the routine library — and writes plain files to
/// the temp directory for the share sheet.
enum DataExportService {
    enum Format: String, CaseIterable, Identifiable {
        case json
        case csv
        var id: String { rawValue }
    }

    /// Snapshot on the main actor (models are main-bound; the nightly backup
    /// proves this fetch is tolerable), then encode and write off it.
    @MainActor
    static func export(format: Format, container: ModelContainer) async throws -> [URL] {
        let context = container.mainContext
        let trainingLog = ExportMapper.filteringTombstones(
            try BackupExporter.snapshotFile(container: container)
        )
        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
        let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        let routines = try context.fetch(FetchDescriptor<RoutineModel>())
        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let names = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let health = ExportMapper.healthMetrics(workouts: workouts)
        let library = ExportMapper.routineLibrary(folders: folders, routines: routines, exerciseNames: names)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let stamp = Date.now.formatted(.iso8601.year().month().day())

        // Everything below works on Sendable values — leave the main actor.
        return try await Task.detached(priority: .userInitiated) {
            let directory = FileManager.default.temporaryDirectory
            switch format {
            case .json:
                let file = ForgeFitExportFile(
                    exportedAt: Date.now,
                    appVersion: appVersion,
                    trainingLog: trainingLog,
                    healthMetrics: health,
                    routines: library
                )
                let url = directory.appendingPathComponent("ForgeFit-Export-\(stamp).json")
                try ExportMapper.encode(file).write(to: url, options: .atomic)
                return [url]
            case .csv:
                let workoutsURL = directory.appendingPathComponent("ForgeFit-Workouts-\(stamp).csv")
                let routinesURL = directory.appendingPathComponent("ForgeFit-Routines-\(stamp).csv")
                try WorkoutCSVExport.csv(workouts: trainingLog.workouts, health: health)
                    .write(to: workoutsURL, atomically: true, encoding: .utf8)
                try RoutineCSVExport.csv(library: library)
                    .write(to: routinesURL, atomically: true, encoding: .utf8)
                return [workoutsURL, routinesURL]
            }
        }.value
    }
}
