import Foundation
import ForgeCore
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct RoutineProgramImportTests {
    private enum ForcedSaveFailure: Error {
        case failed
    }

    private static let upperDay = RoutineTemplate(
        id: "upper-a", name: "Upper Body A", goal: "muscle gain", level: "intermediate",
        daysPerWeek: 4, estimatedMinutes: 55, equipment: ["barbell"], tags: [],
        description: "Upper day",
        exercises: [RoutineTemplateExercise(slug: "Barbell_Bench_Press_-_Medium_Grip", sets: 3, repsLow: 5, repsHigh: 8, durationSeconds: nil, rpe: 8, supersetGroup: nil)]
    )

    private static let lowerDay = RoutineTemplate(
        id: "lower-a", name: "Lower Body A", goal: "muscle gain", level: "intermediate",
        daysPerWeek: 4, estimatedMinutes: 55, equipment: ["barbell"], tags: [],
        description: "Lower day",
        exercises: [RoutineTemplateExercise(slug: "Barbell_Squat", sets: 4, repsLow: 4, repsHigh: 6, durationSeconds: nil, rpe: 8, supersetGroup: nil)]
    )

    private static let program = RoutineProgramTemplate(
        id: "upper-lower", name: "Upper / Lower Split", goal: "muscle gain", level: "intermediate",
        daysPerWeek: 4, weeks: 6, equipment: ["barbell"], tags: [],
        description: "Program", focus: "strength", routineIDs: ["upper-a", "lower-a"], schedule: nil
    )

    @Test func importProgramCreatesFolderWithRoutinesInside() throws {
        let (container, context) = try TestStore.make()

        let folder = try RoutineTemplateCatalog.importProgram(
            Self.program,
            templates: [Self.upperDay, Self.lowerDay],
            in: context,
            saveChanges: true
        )

        let created = try #require(folder)
        #expect(created.name == "Upper / Lower Split")
        #expect(created.parentID == nil)

        let routines = try context.fetch(FetchDescriptor<RoutineModel>())
            .filter { $0.folderID == created.id }
            .sorted { $0.position < $1.position }
        #expect(routines.map(\.name) == ["Upper Body A", "Lower Body A"])
        #expect(routines.allSatisfy { !$0.exercises.isEmpty })
        _ = container
    }

    @Test func importProgramTwiceKeepsFolderAndRoutineNamesUnique() throws {
        let (container, context) = try TestStore.make()
        let templates = [Self.upperDay, Self.lowerDay]

        let first = try RoutineTemplateCatalog.importProgram(
            Self.program, templates: templates, in: context, saveChanges: true
        )
        let second = try RoutineTemplateCatalog.importProgram(
            Self.program, templates: templates, in: context, saveChanges: true
        )

        #expect(first?.name == "Upper / Lower Split")
        #expect(second?.name == "Upper / Lower Split 2")
        #expect((second?.position ?? 0) > (first?.position ?? 0))

        let routineNames = try context.fetch(FetchDescriptor<RoutineModel>()).map(\.name)
        #expect(Set(routineNames).count == routineNames.count)
        _ = container
    }

    @Test func importProgramWithNoResolvableDaysReturnsNil() throws {
        let (container, context) = try TestStore.make()
        let orphan = RoutineProgramTemplate(
            id: "ghost", name: "Ghost", goal: "strength", level: "beginner",
            daysPerWeek: 3, weeks: 4, equipment: [], tags: [],
            description: "", focus: "strength", routineIDs: ["missing-day"], schedule: nil
        )

        let folder = try RoutineTemplateCatalog.importProgram(
            orphan,
            templates: [Self.upperDay],
            in: context,
            saveChanges: true
        )

        #expect(folder == nil)
        #expect(try context.fetch(FetchDescriptor<RoutineFolderModel>()).isEmpty)
        _ = container
    }

    @Test func cardioTemplateDurationImportsAsAnExplicitGoal() throws {
        let (container, context) = try TestStore.make()
        let slug = "Running_Treadmill"
        let treadmill = ExerciseLibraryModel(
            id: ExerciseCatalog.deterministicID(for: slug),
            name: "Treadmill Run",
            movementPattern: "cardio",
            primaryMuscles: ["cardiovascular"],
            equipment: "treadmill",
            defaultWeightMode: .bodyweight,
            isCardio: true,
            category: "cardio"
        )
        context.insert(treadmill)
        try context.save()
        let template = RoutineTemplate(
            id: "treadmill-base",
            name: "Treadmill Base",
            goal: "cardio base",
            level: "beginner",
            daysPerWeek: 2,
            estimatedMinutes: 30,
            equipment: ["machine"],
            tags: ["cardio"],
            description: "Open with an authored duration target.",
            exercises: [RoutineTemplateExercise(
                slug: slug,
                sets: 1,
                repsLow: nil,
                repsHigh: nil,
                durationSeconds: 1_800,
                rpe: 4,
                supersetGroup: nil
            )]
        )

        let routine = try RoutineTemplateCatalog.importTemplate(
            template,
            folderID: nil,
            existingRoutines: [],
            in: context,
            saveChanges: true
        )

        let imported = try #require(routine.exercises.first)
        let plan = try #require(IntervalPlan.decode(from: imported.intervalPlanJSON))
        #expect(imported.sets.isEmpty)
        #expect(plan.goal?.kind == .duration)
        #expect(plan.goal?.value == 1_800)
        _ = container
    }

    @Test func failedUserImportLeavesNoGraphAndRetryCommitsExactlyOneProgram() async throws {
        let (container, context) = try TestStore.make()
        let center = PersistentChangeSaveCenter()
        let attempt = RoutineProgramImportAttempt(
            program: Self.program,
            templates: [Self.upperDay, Self.lowerDay],
            in: context
        )
        var saves = 0
        var committedFolderID: UUID?

        let didImport = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ForcedSaveFailure.failed }
                try isolatedContext.save()
            },
            onCommit: { committedFolderID = $0.id }
        )
        #expect(!didImport)
        #expect(committedFolderID == nil)
        var fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<RoutineFolderModel>()).isEmpty)
        #expect(try fresh.fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        fresh = ModelContext(container)
        let folders = try fresh.fetch(FetchDescriptor<RoutineFolderModel>())
        let routines = try fresh.fetch(FetchDescriptor<RoutineModel>())
        #expect(saves == 2)
        #expect(folders.count == 1)
        #expect(folders.first?.id == committedFolderID)
        #expect(routines.count == 2)
        #expect(routines.allSatisfy { $0.folderID == folders.first?.id })
    }

    @Test func validProgramsRequiresEveryDayToResolve() {
        let exercises = [
            ExerciseLibraryModel(id: ExerciseCatalog.deterministicID(for: "Barbell_Squat"), name: "Barbell Squat"),
            ExerciseLibraryModel(id: ExerciseCatalog.deterministicID(for: "Barbell_Bench_Press_-_Medium_Grip"), name: "Bench Press")
        ]
        let broken = RoutineProgramTemplate(
            id: "broken", name: "Broken", goal: "muscle gain", level: "beginner",
            daysPerWeek: 3, weeks: 4, equipment: [], tags: [],
            description: "", focus: "strength", routineIDs: ["upper-a", "missing-day"], schedule: nil
        )

        let valid = RoutineTemplateCatalog.validPrograms(
            from: [Self.program, broken],
            templates: [Self.upperDay, Self.lowerDay],
            exercises: exercises
        )

        #expect(valid.map(\.id) == ["upper-lower"])
    }
}
