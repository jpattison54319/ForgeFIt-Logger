import ForgeCore
@testable import ForgeData
import SwiftData
import XCTest

@MainActor
final class ExerciseSeedRepositoryTests: XCTestCase {

    func testGlobalExerciseSeedIsIdempotent() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)
        try ExerciseSeedRepository.seedGlobalLibrary(in: context)

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let aliases = try context.fetch(FetchDescriptor<ExerciseAliasModel>())

        XCTAssertEqual(exercises.count, GlobalExerciseLibrary.snapshot.exercises.count)
        XCTAssertEqual(aliases.count, GlobalExerciseLibrary.snapshot.aliases.count)
        XCTAssertTrue(exercises.contains { $0.id == GlobalExerciseLibrary.bayesianCableCurlID })
        XCTAssertTrue(aliases.contains { $0.id == GlobalExerciseLibrary.rdlAliasID && $0.alias == "RDL" })
    }

    func testGlobalCardioExercisesAreTaggedAndUseCardiovascularMuscles() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let treadmill = try XCTUnwrap(exercises.first { $0.id == GlobalExerciseLibrary.treadmillRunID })
        let row = try XCTUnwrap(exercises.first { $0.id == GlobalExerciseLibrary.rowErgID })

        XCTAssertTrue(treadmill.isCardio)
        XCTAssertEqual(treadmill.movementPattern, "cardio")
        XCTAssertEqual(treadmill.defaultWeightMode, .bodyweight)
        XCTAssertTrue(treadmill.primaryMuscles.contains("cardiovascular"))
        XCTAssertFalse(treadmill.primaryMuscles.contains("cardiorespiratory"))
        XCTAssertTrue(row.primaryMuscles.contains("cardiovascular"))
    }

    /// A second seed pass over an unchanged catalog must not dirty any row:
    /// unconditional assignment bumped `updatedAt` on every built-in each
    /// launch, pushing them all to CloudKit for no reason.
    func testRepeatSeedLeavesUpdatedAtUntouched() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)
        let stamps = Dictionary(
            try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).map { ($0.id, $0.updatedAt) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertFalse(stamps.isEmpty)

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)

        for exercise in try context.fetch(FetchDescriptor<ExerciseLibraryModel>()) {
            XCTAssertEqual(exercise.updatedAt, stamps[exercise.id], "\(exercise.name) was dirtied by a no-op reseed")
        }
    }

    /// A genuinely drifted row is still corrected (and only that row moves).
    func testRepeatSeedRepairsOnlyDriftedRows() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)
        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let drifted = try XCTUnwrap(exercises.first { $0.id == GlobalExerciseLibrary.treadmillRunID })
        let stamps = Dictionary(exercises.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
        drifted.name = "Corrupted Name"
        drifted.updatedAt = Date.distantPast
        try context.save()

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)

        for exercise in try context.fetch(FetchDescriptor<ExerciseLibraryModel>()) {
            if exercise.id == drifted.id {
                XCTAssertEqual(exercise.name, "Treadmill Run")
                XCTAssertGreaterThan(exercise.updatedAt, Date.distantPast)
            } else {
                XCTAssertEqual(exercise.updatedAt, stamps[exercise.id])
            }
        }
    }

    /// User-edited built-ins keep their edits — the reseed only maintains the
    /// catalog linkage.
    func testRepeatSeedNeverClobbersUserModifiedRows() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)
        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let edited = try XCTUnwrap(exercises.first { $0.id == GlobalExerciseLibrary.treadmillRunID })
        edited.name = "My Treadmill Intervals"
        edited.userModified = true
        try context.save()

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)

        let after = try XCTUnwrap(
            try context.fetch(FetchDescriptor<ExerciseLibraryModel>()).first { $0.id == GlobalExerciseLibrary.treadmillRunID }
        )
        XCTAssertEqual(after.name, "My Treadmill Intervals")
        XCTAssertTrue(after.userModified)
    }

    func testSeededRowsCanRebuildSearchSnapshot() throws {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        try ExerciseSeedRepository.seedGlobalLibrary(in: context)

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
            .map(\.domainInfo)
        let aliases = try context.fetch(FetchDescriptor<ExerciseAliasModel>())
            .map(\.domainAlias)
        let snapshot = ExerciseLibrarySnapshot(exercises: exercises, aliases: aliases)

        let result = try XCTUnwrap(snapshot.search("tbar row").first)
        XCTAssertEqual(result.exercise.id, GlobalExerciseLibrary.chestSupportedTBarRowID)
    }
}
