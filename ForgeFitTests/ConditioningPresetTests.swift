import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ConditioningPresetTests {
    @Test func cindyHasItsCanonicalExercisesAndPrescription() {
        let preset = ConditioningPreset.cindy

        #expect(preset.movements.map(\.catalogName) == ["Pullups", "Pushups", "Bodyweight Squat"])
        #expect(preset.movements.map(\.targetValue) == [5, 10, 15])

        let plan = preset.makePlan(exerciseIDs: [UUID(), UUID(), UUID()])
        let section = plan.sections.first
        #expect(section?.format == .amrap)
        #expect(section?.durationSeconds == 1_200)
        #expect(section?.movements.map(\.targetValue) == [5, 10, 15])
    }

    @Test func everyPresetBuildsAPlanWithEveryDeclaredExercise() {
        for preset in ConditioningPreset.allCases {
            let plan = preset.makePlan(exerciseIDs: preset.movements.map { _ in UUID() })
            #expect(plan.sections.count == 1)
            #expect(plan.sections.first?.movements.count == preset.movements.count)
            #expect(plan.sections.first?.movements.isEmpty == false)
        }
    }

    @Test func applyingPresetChangesOnlyItsSectionAndPreservesExistingRowIdentity() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }

        let oldExercise = ExerciseLibraryModel(name: "Bench Press")
        let oldRow = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: oldExercise.id,
            sets: [RoutineSetModel(userID: ForgeFitDemo.userID, targetRepsLow: 8)]
        )
        let strengthSection = ConditioningSection(
            name: "Strength",
            format: .forTime,
            rounds: 3,
            movements: [ConditioningMovement(exerciseID: oldExercise.id, targetValue: 8)]
        )
        let conditioningSection = ConditioningSection(name: "Finisher", format: .amrap, durationSeconds: 600)
        var plan = ConditioningPlan(sections: [strengthSection, conditioningSection])
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Mixed Session",
            conditioningPlanJSON: plan.encodedJSON(),
            exercises: [oldRow]
        )
        let catalog = ConditioningPreset.cindy.movements.map {
            ExerciseLibraryModel(name: $0.catalogName, defaultWeightMode: $0.weightMode)
        }
        context.insert(oldExercise)
        catalog.forEach(context.insert)
        context.insert(routine)

        try ConditioningPlanCoordinator.apply(
            .cindy,
            to: conditioningSection.id,
            in: &plan,
            to: routine,
            catalog: catalog,
            in: context
        )
        try context.save()

        let sortedRows = routine.exercises.sorted { $0.position < $1.position }
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.name) })
        #expect(routine.name == "Mixed Session")
        #expect(plan.sections.first == strengthSection)
        #expect(plan.sections[1].name == "Cindy")
        #expect(plan.sections[1].movements.map(\.targetValue) == [5, 10, 15])
        #expect(sortedRows.first?.id == oldRow.id)
        #expect(sortedRows.dropFirst().compactMap { catalogByID[$0.exerciseID] } == ["Pullups", "Pushups", "Bodyweight Squat"])
        #expect(ConditioningPlan.decode(from: routine.conditioningPlanJSON) == plan)
    }

    @Test func switchingPresetsReusesSharedMovementRows() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let names = Set(
            ConditioningPreset.cindy.movements.map(\.catalogName)
                + ConditioningPreset.hundredsChipper.movements.map(\.catalogName)
        )
        let catalog = names.map { ExerciseLibraryModel(name: $0, defaultWeightMode: .bodyweight) }
        catalog.forEach(context.insert)
        let section = ConditioningSection(name: "Section 1", format: .amrap, durationSeconds: 600)
        var plan = ConditioningPlan(sections: [section])
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Conditioning",
            conditioningPlanJSON: plan.encodedJSON()
        )
        context.insert(routine)

        try ConditioningPlanCoordinator.apply(
            .cindy,
            to: section.id,
            in: &plan,
            to: routine,
            catalog: catalog,
            in: context
        )
        let cindyRows = Dictionary(uniqueKeysWithValues: routine.exercises.map { ($0.exerciseID, $0.id) })

        try ConditioningPlanCoordinator.apply(
            .hundredsChipper,
            to: section.id,
            in: &plan,
            to: routine,
            catalog: catalog,
            in: context
        )
        let rowByExercise = Dictionary(uniqueKeysWithValues: routine.exercises.map { ($0.exerciseID, $0.id) })
        let exerciseByName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.id) })
        let pushupsID = try #require(exerciseByName["Pushups"])
        let squatID = try #require(exerciseByName["Bodyweight Squat"])

        #expect(rowByExercise[pushupsID] == cindyRows[pushupsID])
        #expect(rowByExercise[squatID] == cindyRows[squatID])
        #expect(routine.exercises.count == 4)
    }
}
