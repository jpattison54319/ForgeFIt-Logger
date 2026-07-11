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

/// A multi-routine training program (mesocycle): a named folder of day
/// routines imported together — e.g. Upper/Lower is one program holding four
/// routines, not one routine called "Upper Lower Upper".
struct RoutineProgramTemplate: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let goal: String
    let level: String
    let daysPerWeek: Int
    let weeks: Int
    let equipment: [String]
    let tags: [String]
    let description: String
    /// `ProgramFocus` (ForgeCore) raw value — the training discipline this
    /// program is built around. Bundled JSON always sets a real value, so
    /// this decodes as a plain non-optional string rather than round-tripping
    /// through the enum (RoutineTemplateCatalog stays enum-agnostic; callers
    /// that need `ProgramFocus` map the raw value themselves).
    let focus: String
    /// `RoutineTemplate.id`s of the day routines, in program order.
    let routineIDs: [String]
    /// One week's sessions as `RoutineTemplate.id`s, in order — the honest
    /// answer to "3x/week but only 2 routines?" (A/B/A alternation and
    /// friends). Optional so older JSON still decodes.
    let schedule: [String]?

    func routines(from templates: [RoutineTemplate]) -> [RoutineTemplate] {
        routineIDs.compactMap { id in templates.first { $0.id == id } }
    }

    var sessionsPerWeek: Int { schedule?.count ?? daysPerWeek }

    /// Week strip letters ("A · B · A") — days lettered in program order.
    var scheduleLetters: [String]? {
        guard let schedule else { return nil }
        let alphabet = ["A", "B", "C", "D", "E", "F", "G"]
        var letterByID: [String: String] = [:]
        for id in routineIDs where letterByID[id] == nil {
            letterByID[id] = alphabet[min(letterByID.count, alphabet.count - 1)]
        }
        return schedule.map { letterByID[$0] ?? "?" }
    }

    /// "2 alternating days · 3 sessions/week" — day count and weekly sessions
    /// stated separately so they can never read as a contradiction.
    var structureSummary: String {
        let days = routineIDs.count
        let sessions = sessionsPerWeek
        if days == sessions {
            return "\(days) day\(days == 1 ? "" : "s") · \(sessions)x/week"
        }
        let noun = days < sessions ? "alternating day" : "day"
        return "\(days) \(noun)\(days == 1 ? "" : "s") · \(sessions) sessions/week"
    }
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

    static func loadPrograms() -> [RoutineProgramTemplate] {
        guard let url = Bundle.main.url(forResource: "routine_programs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let programs = try? JSONDecoder().decode([RoutineProgramTemplate].self, from: data) else {
            return []
        }
        return programs
    }

    /// Programs whose every day routine exists and resolves all its exercises.
    static func validPrograms(
        from programs: [RoutineProgramTemplate],
        templates: [RoutineTemplate],
        exercises: [ExerciseLibraryModel]
    ) -> [RoutineProgramTemplate] {
        let valid = Set(validTemplates(from: templates, exercises: exercises).map(\.id))
        return programs.filter { program in
            !program.routineIDs.isEmpty && program.routineIDs.allSatisfy { valid.contains($0) }
        }
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

    /// Imports a full program: creates a mesocycle folder named after the
    /// program and adds every day routine to it, in program order. Returns the
    /// created folder (with its routines saved) or nil when no day resolved.
    @discardableResult
    static func importProgram(
        _ program: RoutineProgramTemplate,
        templates: [RoutineTemplate],
        in context: ModelContext
    ) -> RoutineFolderModel? {
        let days = program.routines(from: templates)
        guard !days.isEmpty else { return nil }

        let allFolders = (try? context.fetch(FetchDescriptor<RoutineFolderModel>())) ?? []
        let activeFolders = allFolders.filter { $0.deletedAt == nil }
        let topLevel = activeFolders.filter { $0.parentID == nil }
        let folder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: uniqueFolderName(program.name, existingFolders: activeFolders),
            position: (topLevel.map(\.position).max() ?? -1) + 1
        )
        context.insert(folder)

        var existingRoutines = (try? context.fetch(FetchDescriptor<RoutineModel>())) ?? []
        for day in days {
            let routine = importTemplate(day, folderID: folder.id, existingRoutines: existingRoutines, in: context)
            existingRoutines.append(routine)
        }
        try? context.save()
        return folder
    }

    private static func uniqueFolderName(_ base: String, existingFolders: [RoutineFolderModel]) -> String {
        let names = Set(existingFolders.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private static func uniqueName(_ base: String, existingRoutines: [RoutineModel]) -> String {
        let names = Set(existingRoutines.filter { $0.deletedAt == nil }.map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
