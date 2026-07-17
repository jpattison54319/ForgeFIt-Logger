import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// The Coach's Corner setup answers, collected by `CoachingSetupView` and
/// consumed by `CoachPlanService`. Mirrors `TrainingFocus` (app-level) plus
/// the extra fields the coach matcher needs — kept separate from
/// `ForgeCore.CoachingProfileInput` so the view layer never has to import
/// ForgeCore's matching types directly.
struct CoachSetupAnswers {
    var focus: TrainingFocus
    /// Catalog goal vocabulary (e.g. "general fitness", "muscle gain",
    /// "strength", "hybrid fitness", "cardio base", "maintenance").
    var goal: String
    var experience: CoachingExperience
    var sessionsPerWeek: Int
    var sessionMinutes: Int
    var equipment: Set<String>
    var preferredCardio: String?
}

/// What `CoachPlanService.buildPlan` hands back to the setup flow: either a
/// catalog-program match result, or — for yoga, which has no routine
/// programs — a dedicated case carrying just the weekly session target so
/// the UI can offer the guided-flows path instead.
enum CoachPlanRecommendation {
    case program(MatchResult)
    case yoga(sessionsPerWeek: Int)
}

/// Coach's Corner plan-store service: turns setup answers into a matched
/// catalog program (or an attached existing folder) and tracks which
/// `CoachedProgramModel` is active. Follows `AccountResetService`'s style —
/// a stateless `@MainActor` enum operating on a caller-supplied
/// `ModelContext`.
@MainActor
enum CoachPlanService {

    // MARK: - Reads

    /// The single active (non-deleted) coached program, if any.
    static func activeProgram(in context: ModelContext) -> CoachedProgramModel? {
        let programs = (try? context.fetch(FetchDescriptor<CoachedProgramModel>())) ?? []
        return programs.first { $0.isActive && $0.deletedAt == nil }
    }

    // MARK: - Matching

    /// Maps the setup answers onto the bundled catalog and runs
    /// `ProgramMatcher`. Yoga never resolves to a routine program — it
    /// short-circuits to `.yoga` with the requested weekly session target so
    /// the UI can route to the guided-flows recommendation screen instead.
    static func buildPlan(answers: CoachSetupAnswers, in context: ModelContext) -> CoachPlanRecommendation {
        guard answers.focus != .yoga else {
            return .yoga(sessionsPerWeek: answers.sessionsPerWeek)
        }

        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let templates = RoutineTemplateCatalog.load()
        let validTemplates = RoutineTemplateCatalog.validTemplates(from: templates, exercises: exercises)
        let programs = RoutineTemplateCatalog.validPrograms(
            from: RoutineTemplateCatalog.loadPrograms(),
            templates: validTemplates,
            exercises: exercises
        )

        let candidates = programs.compactMap { program -> ProgramCandidate? in
            guard let focus = ProgramFocus(rawValue: program.focus) else { return nil }
            return ProgramCandidate(
                id: program.id,
                name: program.name,
                focus: focus,
                goal: program.goal,
                level: program.level,
                daysPerWeek: program.daysPerWeek,
                weeks: program.weeks,
                equipment: program.equipment
            )
        }

        let profileInput = CoachingProfileInput(
            focus: ProgramFocus(rawValue: answers.focus.rawValue) ?? .mixed,
            goal: answers.goal,
            experience: answers.experience.rawValue,
            sessionsPerWeek: answers.sessionsPerWeek,
            sessionMinutes: answers.sessionMinutes,
            equipment: answers.equipment,
            preferredCardio: answers.preferredCardio
        )

        return .program(ProgramMatcher.match(profile: profileInput, candidates: candidates))
    }

    // MARK: - Confirming a catalog-program plan

    /// Imports `candidate`'s catalog program into a new mesocycle folder,
    /// persists the coaching profile, deactivates any prior active program
    /// (never deletes it — its folder and routines are left exactly as they
    /// were), and activates the new one. Syncs `activeMesoFolderID` so
    /// `NextRoutineSuggestion` keeps pointing at the right folder.
    @discardableResult
    static func confirmPlan(
        candidate: ProgramCandidate,
        answers: CoachSetupAnswers,
        in context: ModelContext
    ) -> CoachedProgramModel? {
        guard let program = RoutineTemplateCatalog.loadPrograms().first(where: { $0.id == candidate.id }) else {
            return nil
        }
        let templates = RoutineTemplateCatalog.load()
        guard let folder = RoutineTemplateCatalog.importProgram(program, templates: templates, in: context) else {
            return nil
        }

        upsertProfile(answers: answers, in: context)
        deactivateActivePrograms(in: context)

        let coached = CoachedProgramModel(
            userID: ForgeFitDemo.userID,
            folderID: folder.id,
            catalogProgramID: program.id,
            startDate: Date(),
            weeks: program.weeks,
            weeklySessionTarget: answers.sessionsPerWeek,
            isActive: true
        )
        context.insert(coached)
        try? context.save()

        syncActiveMesoFolder(folder.id)
        return coached
    }

    /// The "Coach this plan" path: adopts an existing folder the user
    /// already built by hand instead of importing a catalog program. The
    /// folder and its routines are never modified.
    @discardableResult
    static func attachPlan(
        folder: RoutineFolderModel,
        sessionsPerWeek: Int,
        in context: ModelContext
    ) -> CoachedProgramModel {
        deactivateActivePrograms(in: context)

        let coached = CoachedProgramModel(
            userID: ForgeFitDemo.userID,
            folderID: folder.id,
            catalogProgramID: "",
            startDate: Date(),
            weeks: 0,
            weeklySessionTarget: sessionsPerWeek,
            isActive: true
        )
        context.insert(coached)
        try? context.save()

        syncActiveMesoFolder(folder.id)
        return coached
    }

    /// Yoga has no routine program to import — the "plan" is a weekly
    /// session target over the existing guided flows, so the coached
    /// program is folderless (`catalogProgramID == "yoga-flows"`).
    @discardableResult
    static func confirmYogaPlan(
        answers: CoachSetupAnswers,
        sessionsPerWeek: Int,
        in context: ModelContext
    ) -> CoachedProgramModel {
        upsertProfile(answers: answers, in: context)
        deactivateActivePrograms(in: context)

        let coached = CoachedProgramModel(
            userID: ForgeFitDemo.userID,
            folderID: nil,
            catalogProgramID: "yoga-flows",
            startDate: Date(),
            weeks: 0,
            weeklySessionTarget: sessionsPerWeek,
            isActive: true
        )
        context.insert(coached)
        try? context.save()
        return coached
    }

    // MARK: - Editing an active plan

    /// Edits a coached plan in place: total length (`weeks`, 0 = open-ended)
    /// and weekly session target. The stored coaching profile's cadence is
    /// kept in sync so the next setup run starts from the target the user
    /// actually trains to.
    static func updatePlan(
        _ program: CoachedProgramModel,
        weeks: Int,
        weeklySessionTarget: Int,
        in context: ModelContext
    ) {
        program.weeks = max(0, weeks)
        program.weeklySessionTarget = weeklySessionTarget
        program.updatedAt = Date()

        if let profile = (try? context.fetch(FetchDescriptor<CoachingProfileModel>()))?
            .first(where: { $0.userID == program.userID }) {
            profile.sessionsPerWeek = weeklySessionTarget
            profile.updatedAt = Date()
        }
        try? context.save()
    }

    /// Stops coaching entirely: deactivates the active program without
    /// deleting anything — the plan's folder, routines, and history stay
    /// exactly as they are, and the `activeMesoFolderID` default is left
    /// alone so Home's "Up next" suggestion keeps working off the folder.
    static func stopCoaching(in context: ModelContext) {
        deactivateActivePrograms(in: context)
    }

    /// 1-based calendar week of the program a given date falls in (week 1 =
    /// the first 7 days from `startDate`). Deliberately unclamped — callers
    /// compare against `program.weeks` to detect a completed program.
    static func currentWeek(of program: CoachedProgramModel, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: program.startDate)
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        return max(1, days / 7 + 1)
    }

    // MARK: - Helpers

    /// One row per user: updates the existing profile in place if present,
    /// otherwise inserts a new one (query-before-insert — CloudKit forbids
    /// unique constraints).
    @discardableResult
    private static func upsertProfile(answers: CoachSetupAnswers, in context: ModelContext) -> CoachingProfileModel {
        let userID = ForgeFitDemo.userID
        let existing = (try? context.fetch(FetchDescriptor<CoachingProfileModel>()))?
            .first { $0.userID == userID }

        let profile = existing ?? {
            let created = CoachingProfileModel(
                userID: userID,
                focusRaw: "",
                goalRaw: "",
                experienceRaw: ""
            )
            context.insert(created)
            return created
        }()

        profile.focus = CoachingFocus(rawValue: answers.focus.rawValue)
        profile.goalRaw = answers.goal
        profile.experience = answers.experience
        profile.sessionsPerWeek = answers.sessionsPerWeek
        profile.sessionMinutes = answers.sessionMinutes
        profile.equipment = Array(answers.equipment)
        profile.preferredCardioRaw = answers.preferredCardio
        profile.updatedAt = Date()
        try? context.save()
        return profile
    }

    /// Deactivates every currently-active coached program. Prior folders and
    /// routines are never touched — only `isActive` flips.
    private static func deactivateActivePrograms(in context: ModelContext) {
        let programs = (try? context.fetch(FetchDescriptor<CoachedProgramModel>())) ?? []
        for program in programs where program.isActive && program.deletedAt == nil {
            program.isActive = false
            program.updatedAt = Date()
        }
        try? context.save()
    }

    /// Keeps the UI-only "active plan" AppStorage keys in sync with the
    /// coach's chosen folder so `NextRoutineSuggestion` (Home) resolves
    /// correctly without any changes on its side.
    private static func syncActiveMesoFolder(_ folderID: UUID) {
        UserDefaults.standard.set(folderID.uuidString, forKey: "activeMesoFolderID")
    }
}
