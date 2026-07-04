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
