import Foundation
import SwiftData
import Testing
@testable import ForgeData

/// Serialized parent for every suite that opens on-disk SwiftData stores
/// with partial schemas: concurrent containers over different schemas of
/// the same models abort the test process (NSEntityDescription collisions),
/// so these run one at a time.
@Suite(.serialized) enum PersistenceSplitTests {}

/// The load-bearing assumptions behind the 5.1.3(ii) persistence split:
/// the PLAN/LOG partition is exhaustive, a two-configuration container
/// actually routes each entity to its own store file, and the UUID-scalar
/// bridges between the layers still resolve. These run BEFORE anything is
/// built on the split — if SwiftData's multi-config behavior regresses,
/// this suite fails first.
extension PersistenceSplitTests {
@Suite struct SchemaSplitTests {

    private func names(_ models: [any PersistentModel.Type]) -> Set<String> {
        Set(models.map { String(describing: $0) })
    }

    @Test func partitionIsExhaustiveAndDisjoint() {
        let plan = names(ForgeDataSchema.planModels)
        let log = names(ForgeDataSchema.logModels)
        let all = names(ForgeDataSchema.models)
        #expect(plan.intersection(log).isEmpty)
        #expect(plan.union(log) == all)
        #expect(plan.count + log.count == all.count)
    }

    @Test func planLayerNeverContainsKnownHealthCarriers() {
        // The models with Health-derived fields, by name — a compile-time
        // list would be circular, so names anchor the policy here.
        let healthCarriers: Set<String> = [
            "WorkoutModel", "CardioSessionModel", "SetModel",
            "DailyCheckinModel", "WrappedReportModel"
        ]
        #expect(names(ForgeDataSchema.planModels).intersection(healthCarriers).isEmpty)
    }

    /// The core partition proof: build a container with both configurations,
    /// insert one graph per layer, then reopen EACH store file alone with
    /// only its sub-schema and confirm the rows landed in the right file.
    @MainActor
    @Test func twoConfigurationContainerPartitionsEntitiesByStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("schema-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("log.store")
        let planURL = dir.appendingPathComponent("plan.store")

        let routineID = UUID()
        let workoutID = UUID()

        // Scope so the container closes before the stores reopen below.
        do {
            let container = try ModelContainer(
                for: Schema(ForgeDataSchema.models),
                configurations: [
                    ModelConfiguration("log", schema: Schema(ForgeDataSchema.logModels), url: logURL, cloudKitDatabase: .none),
                    ModelConfiguration("plan", schema: Schema(ForgeDataSchema.planModels), url: planURL, cloudKitDatabase: .none),
                ]
            )
            let context = container.mainContext

            let routine = RoutineModel(userID: UUID(), name: "Push Day")
            routine.id = routineID
            let routineExercise = RoutineExerciseModel(userID: routine.userID, exerciseID: UUID())
            context.insert(routine)
            context.insert(routineExercise)
            routine.exercises.append(routineExercise)

            let workout = WorkoutModel(userID: routine.userID, title: "Push Day")
            workout.id = workoutID
            workout.routineID = routineID   // cross-layer UUID bridge
            let workoutExercise = WorkoutExerciseModel(userID: workout.userID, exerciseID: routineExercise.exerciseID, position: 0)
            context.insert(workout)
            context.insert(workoutExercise)
            workout.exercises.append(workoutExercise)

            try context.save()

            // Cross-layer UUID reference resolves via a second fetch.
            let workouts = try context.fetch(FetchDescriptor<WorkoutModel>())
            let bridgedID = try #require(workouts.first?.routineID)
            let bridged = try context.fetch(FetchDescriptor<RoutineModel>()).first { $0.id == bridgedID }
            #expect(bridged?.name == "Push Day")
        }

        // Reopen each store ALONE with only its sub-schema: the right rows
        // must be in the right file, and only there.
        do {
            let logOnly = try ModelContainer(
                for: Schema(ForgeDataSchema.logModels),
                configurations: [ModelConfiguration(schema: Schema(ForgeDataSchema.logModels), url: logURL, cloudKitDatabase: .none)]
            )
            let logContext = ModelContext(logOnly)
            let workouts = try logContext.fetch(FetchDescriptor<WorkoutModel>())
            #expect(workouts.map(\.id) == [workoutID])
            #expect(workouts.first?.exercises.count == 1)
        }
        do {
            let planOnly = try ModelContainer(
                for: Schema(ForgeDataSchema.planModels),
                configurations: [ModelConfiguration(schema: Schema(ForgeDataSchema.planModels), url: planURL, cloudKitDatabase: .none)]
            )
            let planContext = ModelContext(planOnly)
            let routines = try planContext.fetch(FetchDescriptor<RoutineModel>())
            #expect(routines.map(\.id) == [routineID])
            #expect(routines.first?.exercises.count == 1)
            // And no log entities leaked into the plan store: opening the
            // plan store with the log schema must find nothing.
        }
        do {
            let crossCheck = try ModelContainer(
                for: Schema(ForgeDataSchema.logModels),
                configurations: [ModelConfiguration(schema: Schema(ForgeDataSchema.logModels), url: planURL, cloudKitDatabase: .none)]
            )
            let context = ModelContext(crossCheck)
            #expect(try context.fetchCount(FetchDescriptor<WorkoutModel>()) == 0)
        }
    }
}
}
