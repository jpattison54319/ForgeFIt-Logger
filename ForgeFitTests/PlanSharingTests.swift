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

    @Test func alternatingRoutineShareIncludesBothMembersAndImportRemapsThePair() throws {
        UserDefaults.standard.removeObject(forKey: PlanImportService.importedPackagesDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: PlanImportService.importedPackagesDefaultsKey) }

        let owner = RoutineModel(userID: userID, name: "AX400", position: 0)
        let partner = RoutineModel(userID: userID, name: "Cindy", position: 1)
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id
        )

        let document = try PlanShareService.routineDocument(
            owner,
            allRoutines: [owner, partner],
            alternations: [alternation],
            exercises: []
        )
        #expect(document.formatVersion == 2)
        #expect(document.routines.map(\.name) == ["AX400", "Cindy"])
        #expect(document.alternations == [SharedPlanAlternation(
            id: alternation.id,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id
        )])

        let decoded = try ForgeFitPlanCodec.decode(ForgeFitPlanCodec.encode(document))
        try PlanImportService.validate(decoded)

        let (container, context) = try TestStore.make()
        defer { _ = container }
        let result = try PlanImportService.commit(decoded, in: context)
        let importedContext = ModelContext(container)
        let routines = try importedContext.fetch(FetchDescriptor<RoutineModel>())
            .filter { result.routineIDs.contains($0.id) }
        let importedPair = try #require(
            try importedContext.fetch(FetchDescriptor<RoutineAlternationModel>()).first
        )
        let importedByID = Dictionary(uniqueKeysWithValues: routines.map { ($0.id, $0.name) })

        #expect(result.routineIDs.count == 2)
        #expect(importedPair.ownerRoutineID != owner.id)
        #expect(importedPair.partnerRoutineID != partner.id)
        #expect(importedByID[importedPair.ownerRoutineID] == "AX400")
        #expect(importedByID[importedPair.partnerRoutineID] == "Cindy")
    }

    @Test func microcycleShareCarriesAnAlternateFromOutsideTheFolder() throws {
        let microcycle = RoutineFolderModel(userID: userID, name: "Conditioning")
        let otherFolder = RoutineFolderModel(userID: userID, name: "Library")
        let owner = RoutineModel(
            userID: userID,
            name: "AX400",
            folderID: microcycle.id
        )
        let partner = RoutineModel(
            userID: userID,
            name: "Cindy",
            folderID: otherFolder.id
        )
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id
        )

        let document = try PlanShareService.microcycleDocument(
            microcycle,
            routines: [owner],
            allRoutines: [owner, partner],
            alternations: [alternation],
            exercises: []
        )

        #expect(document.routines.count == 2)
        #expect(document.routines.first { $0.id == owner.id }?.folderID == microcycle.id)
        #expect(document.routines.first { $0.id == partner.id }?.folderID == nil)
        #expect(document.alternations.count == 1)
        try PlanImportService.validate(document)
    }

    @Test func versionOnePlanWithoutAlternationsStillDecodes() throws {
        let legacy = ForgeFitPlanDocument(
            formatVersion: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            kind: .routine,
            name: "Legacy",
            routines: [SharedPlanRoutine(id: UUID(), name: "Legacy", position: 0)],
            exercises: []
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: ForgeFitPlanCodec.encode(legacy)) as? [String: Any]
        )
        object.removeValue(forKey: "alternations")
        let decoded = try ForgeFitPlanCodec.decode(JSONSerialization.data(withJSONObject: object))

        #expect(decoded.formatVersion == 1)
        #expect(decoded.alternations.isEmpty)
        try PlanImportService.validate(decoded)
    }

    @Test func validatorRejectsAlternationsWithMissingOrRepeatedMembers() throws {
        let first = SharedPlanRoutine(id: UUID(), name: "A", position: 0)
        let second = SharedPlanRoutine(id: UUID(), name: "B", position: 1)
        let missingMember = ForgeFitPlanDocument(
            createdAt: .now,
            kind: .routine,
            name: "Broken Pair",
            routines: [first, second],
            alternations: [SharedPlanAlternation(
                id: UUID(),
                ownerRoutineID: first.id,
                partnerRoutineID: UUID()
            )],
            exercises: []
        )
        #expect(throws: PlanImportService.ImportError.self) {
            try PlanImportService.validate(missingMember)
        }

        let folderID = UUID()
        let scopedFirst = SharedPlanRoutine(id: first.id, name: first.name, folderID: folderID, position: 0)
        let scopedSecond = SharedPlanRoutine(id: second.id, name: second.name, folderID: folderID, position: 1)
        let third = SharedPlanRoutine(id: UUID(), name: "C", folderID: folderID, position: 2)
        let repeatedMember = ForgeFitPlanDocument(
            createdAt: .now,
            kind: .microcycle,
            name: "Broken Pair",
            folders: [SharedPlanFolder(id: folderID, name: "Week", position: 0)],
            routines: [scopedFirst, scopedSecond, third],
            alternations: [
                SharedPlanAlternation(id: UUID(), ownerRoutineID: first.id, partnerRoutineID: second.id),
                SharedPlanAlternation(id: UUID(), ownerRoutineID: first.id, partnerRoutineID: third.id),
            ],
            exercises: []
        )
        #expect(throws: PlanImportService.ImportError.self) {
            try PlanImportService.validate(repeatedMember)
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
