import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@Suite(.serialized)
@MainActor
struct PlanSharingTests {
    private let userID = UUID()

    @Test func mesocycleRoundTripPreservesCompletePlanAndExcludesPrivateData() throws {
        UserDefaults.standard.removeObject(forKey: PlanImportService.importedPackagesDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: PlanImportService.importedPackagesDefaultsKey) }

        let (sourceContainer, sourceContext) = try TestStore.make()
        defer { _ = sourceContainer }
        let fixture = try makeMesocycle(in: sourceContext)
        let document = try PlanShareService.mesocycleDocument(
            fixture.mesocycle,
            microcycles: [fixture.microcycle],
            routines: [fixture.routine],
            exercises: fixture.exercises
        )
        let standalone = try PlanShareService.routineDocument(
            fixture.routine,
            exercises: fixture.exercises
        )

        #expect(document.kind == .mesocycle)
        #expect(document.folders.count == 2)
        #expect(document.routines.first?.blocks.count == 2)
        #expect(document.routines.first?.exercises.first?.sets.first?.targetDistanceMeters == 2_000)
        #expect(standalone.routines.first?.folderID == nil)
        try PlanImportService.validate(standalone)

        let data = try ForgeFitPlanCodec.encode(document)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(userID.uuidString))
        #expect(!text.contains("userID"))
        #expect(!text.contains("avgHR"))
        #expect(!text.contains("readiness"))
        #expect(!text.contains("private setup note"))
        #expect(text.contains("routine note shared intentionally"))

        let decoded = try ForgeFitPlanCodec.decode(data)
        #expect(decoded.packageID == document.packageID)
        #expect(decoded.kind == document.kind)
        #expect(decoded.folders == document.folders)
        #expect(decoded.routines == document.routines)
        #expect(decoded.exercises == document.exercises)

        let (recipientContainer, recipientContext) = try TestStore.make()
        defer { _ = recipientContainer }
        UserDefaults.standard.set("unchanged", forKey: CyclePreferenceMigration.activeMesocycleKey)
        let result = try PlanImportService.commit(decoded, in: recipientContext)

        let importedContext = ModelContext(recipientContainer)
        let folders = try importedContext.fetch(FetchDescriptor<RoutineFolderModel>())
        let routines = try importedContext.fetch(FetchDescriptor<RoutineModel>())
        let exercises = try importedContext.fetch(FetchDescriptor<ExerciseLibraryModel>())
        let imported = try #require(routines.first { result.routineIDs.contains($0.id) })
        let rootID = try #require(result.rootFolderID)
        #expect(folders.first { $0.id == rootID }?.name == "Base Block")
        #expect(folders.first { $0.parentID == rootID }?.defaultMicrocycleLengthDays == 10)
        #expect(imported.notes == "routine note shared intentionally")
        #expect(imported.blocks.count == 2)
        let importedSet = try #require(imported.exercises.flatMap(\.sets).first)
        #expect(importedSet.setType == .cluster)
        #expect(importedSet.plannedMiniReps == [3, 3, 3])
        #expect(importedSet.targetDistanceMeters == 2_000)
        #expect(UserDefaults.standard.string(forKey: CyclePreferenceMigration.activeMesocycleKey) == "unchanged")

        let importedCustom = try #require(exercises.first { $0.name == "Sandbag Carry" })
        #expect(importedCustom.ownerID == ForgeFitDemo.userID)
        let importedPlan = try #require(ConditioningPlan.decode(
            from: imported.blocks.first { $0.kind == .conditioning }?.planJSON
        ))
        #expect(importedPlan.sections.first?.movements.first?.exerciseID == importedCustom.id)
        let importedFlow = try #require(YogaFlowPlan.decode(
            from: imported.blocks.first { $0.kind == .yoga }?.planJSON
        ))
        #expect(importedFlow.steps.first?.poseID == exercises.first { $0.name == "Custom Pose" }?.id)

        let url = try PlanShareService.write(document)
        #expect(try PlanImportService.load(from: url).isDuplicate)

        _ = try PlanImportService.commit(decoded, in: recipientContext)
        let repeatedContext = ModelContext(recipientContainer)
        #expect(try repeatedContext.fetch(FetchDescriptor<RoutineModel>()).count == 2)
        #expect(try repeatedContext.fetch(FetchDescriptor<ExerciseLibraryModel>()).count == exercises.count)
    }

    @Test func validatorRejectsFutureAndBrokenDocumentsBeforeImport() throws {
        let exerciseID = UUID()
        let definition = SharedPlanExercise(
            id: exerciseID,
            isCustom: true,
            name: "Custom",
            defaultWeightModeRaw: WeightMode.external.rawValue
        )
        let routine = SharedPlanRoutine(
            id: UUID(),
            name: "Broken",
            position: 0,
            exercises: [SharedPlanRoutineExercise(id: UUID(), exerciseID: UUID(), position: 0)]
        )
        let broken = ForgeFitPlanDocument(
            createdAt: .now,
            kind: .routine,
            name: "Broken",
            routines: [routine],
            exercises: [definition]
        )
        #expect(throws: PlanImportService.ImportError.self) {
            try PlanImportService.validate(broken)
        }

        var future = broken
        future.formatVersion = ForgeFitPlanDocument.currentVersion + 1
        let url = URL.temporaryDirectory.appending(path: "future.forgefitplan")
        try ForgeFitPlanCodec.encode(future).write(to: url, options: .atomic)
        #expect(throws: PlanImportService.ImportError.unsupportedVersion(future.formatVersion)) {
            try PlanImportService.load(from: url)
        }
    }

    private func makeMesocycle(
        in context: ModelContext
    ) throws -> (
        mesocycle: RoutineFolderModel,
        microcycle: RoutineFolderModel,
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel]
    ) {
        let lift = ExerciseLibraryModel(
            ownerID: userID,
            name: "Sandbag Carry",
            movementPattern: "carry",
            primaryMuscles: ["Core"],
            equipment: "Sandbag",
            defaultWeightMode: .external
        )
        let pose = ExerciseLibraryModel(
            ownerID: userID,
            name: "Custom Pose",
            modalityRaw: Modality.yoga.rawValue,
            defaultHoldSeconds: 45
        )
        let yogaSession = ExerciseLibraryModel(name: "Yoga Session", modalityRaw: Modality.yoga.rawValue)
        context.insert(lift)
        context.insert(pose)
        context.insert(yogaSession)

        let mesocycle = RoutineFolderModel(userID: userID, name: "Base Block")
        let microcycle = RoutineFolderModel(
            userID: userID,
            name: "Week A",
            parentID: mesocycle.id,
            defaultMicrocycleLengthDays: 10
        )
        context.insert(mesocycle)
        context.insert(microcycle)

        let cluster = RoutineSetModel(
            userID: userID,
            position: 0,
            setType: .cluster,
            targetRepsLow: 9,
            targetWeight: 50,
            targetRPE: 8,
            targetDistanceMeters: 2_000,
            plannedMiniSetCount: 3,
            plannedMiniRepsJSON: "[3,3,3]"
        )
        let liftRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: lift.id,
            position: 0,
            notes: "exercise note",
            sets: [cluster]
        )
        liftRow.progressionRuleJSON = ProgressionRule.doubleProgression.encodedJSON()
        let flow = YogaFlowPlan(
            style: .yin,
            steps: [.init(poseID: pose.id, name: pose.name, holdSeconds: 45)]
        )
        let yogaRow = RoutineExerciseModel(
            userID: userID,
            exerciseID: yogaSession.id,
            position: 2,
            yogaFlowJSON: flow.encodedJSON()
        )
        let plan = ConditioningPlan(sections: [
            ConditioningSection(
                name: "Carry",
                format: .forTime,
                rounds: 3,
                movements: [ConditioningMovement(exerciseID: lift.id, targetValue: 40, targetUnit: .meters)]
            )
        ])
        let block = RoutineBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 1,
            planJSON: plan.encodedJSON()
        )
        let yogaBlock = RoutineBlockModel(
            userID: userID,
            kind: .yoga,
            position: 3,
            planJSON: flow.encodedJSON()
        )
        let routine = RoutineModel(
            userID: userID,
            name: "Hybrid Day",
            notes: "routine note shared intentionally",
            folderID: microcycle.id,
            exercises: [liftRow, yogaRow],
            blocks: [block, yogaBlock]
        )
        context.insert(routine)
        try context.save()
        return (mesocycle, microcycle, routine, [lift, pose, yogaSession])
    }
}
