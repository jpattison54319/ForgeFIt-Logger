import Foundation
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct RoutineProgramImportTests {
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

        let folder = RoutineTemplateCatalog.importProgram(Self.program, templates: [Self.upperDay, Self.lowerDay], in: context)

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

        let first = RoutineTemplateCatalog.importProgram(Self.program, templates: templates, in: context)
        let second = RoutineTemplateCatalog.importProgram(Self.program, templates: templates, in: context)

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

        let folder = RoutineTemplateCatalog.importProgram(orphan, templates: [Self.upperDay], in: context)

        #expect(folder == nil)
        #expect(try context.fetch(FetchDescriptor<RoutineFolderModel>()).isEmpty)
        _ = container
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
