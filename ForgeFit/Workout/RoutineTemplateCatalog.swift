import ForgeCore
import ForgeData
import Foundation
import SwiftData

struct RoutineTemplate: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let goal: String
    let level: String
    let daysPerWeek: Int
    let estimatedMinutes: Int
    let equipment: [String]
    let tags: [String]
    let description: String
    let exercises: [RoutineTemplateExercise]
}

struct RoutineTemplateExercise: Codable, Hashable {
    let slug: String
    let sets: Int
    let repsLow: Int?
    let repsHigh: Int?
    let durationSeconds: Int?
    let rpe: Double?
    let supersetGroup: Int?
}

enum RoutineTemplateCatalog {
    static func load() -> [RoutineTemplate] {
        guard let url = Bundle.main.url(forResource: "routine_templates", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let templates = try? JSONDecoder().decode([RoutineTemplate].self, from: data) else {
            return []
        }
        return templates
    }

    static func validTemplates(from templates: [RoutineTemplate], exercises: [ExerciseLibraryModel]) -> [RoutineTemplate] {
        let exerciseIDs = Set(exercises.map(\.id))
        return templates.filter { template in
            let isValid = template.exercises.allSatisfy { exerciseIDs.contains(ExerciseCatalog.deterministicID(for: $0.slug)) }
            #if DEBUG
            if !isValid { print("Routine template has unresolved exercise slug: \(template.id)") }
            #endif
            return isValid
        }
    }

    @discardableResult
    static func importTemplate(
        _ template: RoutineTemplate,
        folderID: UUID?,
        existingRoutines: [RoutineModel],
        in context: ModelContext
    ) -> RoutineModel {
        let name = uniqueName(template.name, existingRoutines: existingRoutines)
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: name,
            notes: template.description,
            folderID: folderID,
            position: existingRoutines.filter { $0.deletedAt == nil }.count
        )
        routine.exercises = template.exercises.enumerated().map { index, item in
            let exercise = RoutineExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: ExerciseCatalog.deterministicID(for: item.slug),
                position: index,
                supersetGroup: item.supersetGroup
            )
            exercise.sets = (0..<max(1, item.sets)).map { setIndex in
                RoutineSetModel(
                    userID: ForgeFitDemo.userID,
                    position: setIndex,
                    targetRepsLow: item.repsLow,
                    targetRepsHigh: item.repsHigh,
                    targetRPE: item.rpe,
                    targetDurationSeconds: item.durationSeconds
                )
            }
            return exercise
        }
        context.insert(routine)
        try? context.save()
        return routine
    }

    private static func uniqueName(_ base: String, existingRoutines: [RoutineModel]) -> String {
        let names = Set(existingRoutines.filter { $0.deletedAt == nil }.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
