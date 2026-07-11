import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CoachPlanServiceTests {
    private static let activeMesoFolderKey = "activeMesoFolderID"

    /// Returns the container WITH its context — see `RoutineProgramImportTests`
    /// for why the container must be kept alive by the caller.
    private static func makeContainer() throws -> (container: ModelContainer, context: ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private static func answers(
        focus: TrainingFocus = .strength,
        goal: String = "muscle gain",
        sessionsPerWeek: Int = 3,
        equipment: Set<String> = ["dumbbell"]
    ) -> CoachSetupAnswers {
        CoachSetupAnswers(
            focus: focus,
            goal: goal,
            experience: .beginner,
            sessionsPerWeek: sessionsPerWeek,
            sessionMinutes: 60,
            equipment: equipment,
            preferredCardio: nil
        )
    }

    /// Confirming/attaching a plan only looks up the catalog program by
    /// `candidate.id` — the rest of `ProgramCandidate`'s fields only matter to
    /// `ProgramMatcher`, so a stub with the real id is enough to drive
    /// `confirmPlan`.
    private static func stubCandidate(id: String) -> ProgramCandidate {
        ProgramCandidate(id: id, name: id, focus: .strength, goal: "muscle gain", level: "beginner", daysPerWeek: 3, weeks: 6, equipment: [])
    }

    /// Runs `body` with `activeMesoFolderID` reset to nil beforehand and
    /// restored to its original value afterward, so these tests never leak
    /// state into `UserDefaults.standard` (shared with the rest of the app).
    private static func withIsolatedActiveMesoDefault(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: activeMesoFolderKey)
        defaults.removeObject(forKey: activeMesoFolderKey)
        defer {
            if let original {
                defaults.set(original, forKey: activeMesoFolderKey)
            } else {
                defaults.removeObject(forKey: activeMesoFolderKey)
            }
        }
        try body()
    }

    // MARK: - confirmPlan

    @Test func confirmPlanImportsFolderCreatesActiveProgramAndSyncsActiveMesoDefault() throws {
        try Self.withIsolatedActiveMesoDefault {
            let (container, context) = try Self.makeContainer()

            // A pre-existing routine that must survive untouched.
            let priorRoutine = RoutineModel(userID: ForgeFitDemo.userID, name: "My Own Routine")
            context.insert(priorRoutine)
            try context.save()

            let coached = CoachPlanService.confirmPlan(
                candidate: Self.stubCandidate(id: "dumbbell-home-builder"),
                answers: Self.answers(),
                in: context
            )

            let program = try #require(coached)
            #expect(program.isActive)
            #expect(program.catalogProgramID == "dumbbell-home-builder")
            let folderID = try #require(program.folderID)

            let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
            #expect(folders.contains { $0.id == folderID })

            let routines = try context.fetch(FetchDescriptor<RoutineModel>())
            #expect(routines.contains { $0.folderID == folderID })
            #expect(routines.contains { $0.id == priorRoutine.id && $0.folderID == nil })

            #expect(UserDefaults.standard.string(forKey: Self.activeMesoFolderKey) == folderID.uuidString)
            #expect(CoachPlanService.activeProgram(in: context)?.id == program.id)
            _ = container
        }
    }

    @Test func confirmingSecondPlanDeactivatesFirstWithoutTouchingItsFolder() throws {
        try Self.withIsolatedActiveMesoDefault {
            let (container, context) = try Self.makeContainer()

            let first = try #require(CoachPlanService.confirmPlan(
                candidate: Self.stubCandidate(id: "dumbbell-home-builder"),
                answers: Self.answers(),
                in: context
            ))
            let firstFolderID = try #require(first.folderID)
            let firstRoutineNames = Set(
                try context.fetch(FetchDescriptor<RoutineModel>())
                    .filter { $0.folderID == firstFolderID }
                    .map(\.name)
            )
            #expect(!firstRoutineNames.isEmpty)

            let second = try #require(CoachPlanService.confirmPlan(
                candidate: Self.stubCandidate(id: "machine-fundamentals"),
                answers: Self.answers(),
                in: context
            ))

            // Refetch `first` from the context — SwiftData model instances
            // stay live, but re-fetching is the honest way to assert the
            // persisted state actually flipped.
            let allPrograms = try context.fetch(FetchDescriptor<CoachedProgramModel>())
            let refreshedFirst = try #require(allPrograms.first { $0.id == first.id })
            let refreshedSecond = try #require(allPrograms.first { $0.id == second.id })

            #expect(!refreshedFirst.isActive)
            #expect(refreshedSecond.isActive)
            #expect(refreshedFirst.deletedAt == nil, "deactivation must never delete the prior program")

            // The first program's folder and its routines are untouched.
            let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
            let firstFolder = try #require(folders.first { $0.id == firstFolderID })
            #expect(firstFolder.deletedAt == nil)
            let stillThere = Set(
                try context.fetch(FetchDescriptor<RoutineModel>())
                    .filter { $0.folderID == firstFolderID }
                    .map(\.name)
            )
            #expect(stillThere == firstRoutineNames)

            #expect(CoachPlanService.activeProgram(in: context)?.id == refreshedSecond.id)
            _ = container
        }
    }

    // MARK: - attachPlan

    @Test func attachPlanActivatesWithoutModifyingTheFolder() throws {
        try Self.withIsolatedActiveMesoDefault {
            let (container, context) = try Self.makeContainer()

            let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Hand Built Split")
            context.insert(folder)
            let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Day 1", folderID: folder.id)
            context.insert(routine)
            try context.save()

            let coached = CoachPlanService.attachPlan(folder: folder, sessionsPerWeek: 4, in: context)

            #expect(coached.isActive)
            #expect(coached.catalogProgramID == "")
            #expect(coached.isAttachedPlan)
            #expect(coached.folderID == folder.id)
            #expect(coached.weeklySessionTarget == 4)
            #expect(coached.weeks == 0)

            // The folder and its routine are exactly as before.
            let refreshedFolder = try #require(try context.fetch(FetchDescriptor<RoutineFolderModel>()).first { $0.id == folder.id })
            #expect(refreshedFolder.name == "Hand Built Split")
            let routines = try context.fetch(FetchDescriptor<RoutineModel>()).filter { $0.folderID == folder.id }
            #expect(routines.map(\.name) == ["Day 1"])

            #expect(UserDefaults.standard.string(forKey: Self.activeMesoFolderKey) == folder.id.uuidString)
            _ = container
        }
    }

    // MARK: - Yoga

    @Test func confirmYogaPlanCreatesFolderlessActiveProgram() throws {
        let (container, context) = try Self.makeContainer()

        let coached = CoachPlanService.confirmYogaPlan(
            answers: Self.answers(focus: .yoga, goal: "general fitness", equipment: []),
            sessionsPerWeek: 3,
            in: context
        )

        #expect(coached.isActive)
        #expect(coached.folderID == nil)
        #expect(coached.catalogProgramID == "yoga-flows")
        #expect(coached.weeklySessionTarget == 3)
        #expect(coached.weeks == 0)

        let profiles = try context.fetch(FetchDescriptor<CoachingProfileModel>())
        #expect(profiles.first { $0.userID == ForgeFitDemo.userID }?.focus == .yoga)
        #expect(CoachPlanService.activeProgram(in: context)?.id == coached.id)
        _ = container
    }

    // MARK: - updatePlan / stopCoaching

    @Test func updatePlanEditsWeeksAndTargetAndSyncsProfileCadence() throws {
        try Self.withIsolatedActiveMesoDefault {
            let (container, context) = try Self.makeContainer()

            let coached = try #require(CoachPlanService.confirmPlan(
                candidate: Self.stubCandidate(id: "dumbbell-home-builder"),
                answers: Self.answers(sessionsPerWeek: 3),
                in: context
            ))
            let originalStart = coached.startDate
            let originalFolderID = coached.folderID

            CoachPlanService.updatePlan(coached, weeks: 12, weeklySessionTarget: 5, in: context)

            let refreshed = try #require(
                try context.fetch(FetchDescriptor<CoachedProgramModel>()).first { $0.id == coached.id }
            )
            #expect(refreshed.weeks == 12)
            #expect(refreshed.weeklySessionTarget == 5)
            #expect(refreshed.isActive)
            #expect(refreshed.startDate == originalStart, "editing must never restart the program")
            #expect(refreshed.folderID == originalFolderID)

            let profile = try #require(
                try context.fetch(FetchDescriptor<CoachingProfileModel>()).first { $0.userID == ForgeFitDemo.userID }
            )
            #expect(profile.sessionsPerWeek == 5, "profile cadence follows the edited target")
            _ = container
        }
    }

    @Test func updatePlanClampsNegativeWeeksToOpenEnded() throws {
        let (container, context) = try Self.makeContainer()
        let coached = CoachedProgramModel(userID: ForgeFitDemo.userID, startDate: Date(), weeks: 8, isActive: true)
        context.insert(coached)
        try context.save()

        CoachPlanService.updatePlan(coached, weeks: -3, weeklySessionTarget: 4, in: context)

        #expect(coached.weeks == 0)
        #expect(coached.weeklySessionTarget == 4)
        _ = container
    }

    @Test func stopCoachingDeactivatesWithoutDeletingAnything() throws {
        try Self.withIsolatedActiveMesoDefault {
            let (container, context) = try Self.makeContainer()

            let coached = try #require(CoachPlanService.confirmPlan(
                candidate: Self.stubCandidate(id: "dumbbell-home-builder"),
                answers: Self.answers(),
                in: context
            ))
            let folderID = try #require(coached.folderID)

            CoachPlanService.stopCoaching(in: context)

            let refreshed = try #require(
                try context.fetch(FetchDescriptor<CoachedProgramModel>()).first { $0.id == coached.id }
            )
            #expect(!refreshed.isActive)
            #expect(refreshed.deletedAt == nil)
            #expect(CoachPlanService.activeProgram(in: context) == nil)

            // Folder and routines untouched.
            let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
            #expect(folders.contains { $0.id == folderID && $0.deletedAt == nil })
            #expect(try context.fetch(FetchDescriptor<RoutineModel>()).contains { $0.folderID == folderID })
            _ = container
        }
    }

    // MARK: - currentWeek

    @Test func currentWeekIsOneBasedAndUnclamped() throws {
        let (container, context) = try Self.makeContainer()
        let calendar = Calendar.current
        let now = Date()
        let program = CoachedProgramModel(userID: ForgeFitDemo.userID, startDate: now, weeks: 2)
        context.insert(program)

        #expect(CoachPlanService.currentWeek(of: program, now: now) == 1)

        let day8 = try #require(calendar.date(byAdding: .day, value: 7, to: now))
        #expect(CoachPlanService.currentWeek(of: program, now: day8) == 2)

        // Past the program's final week the value keeps counting — callers
        // compare against `weeks` to detect completion.
        let day22 = try #require(calendar.date(byAdding: .day, value: 21, to: now))
        #expect(CoachPlanService.currentWeek(of: program, now: day22) == 4)
        _ = container
    }

    // MARK: - buildPlan

    @Test func buildPlanReturnsHonestNoneForImpossibleEquipment() throws {
        let (container, context) = try Self.makeContainer()
        try ExerciseSeedRepository.seedGlobalLibrary(in: context)
        try context.save()

        let recommendation = CoachPlanService.buildPlan(
            answers: Self.answers(equipment: ["kettlebell"]),
            in: context
        )

        guard case .program(.none(let reason)) = recommendation else {
            Issue.record("Expected .program(.none), got \(recommendation)")
            return
        }
        #expect(!reason.isEmpty)
        _ = container
    }

    @Test func buildPlanShortCircuitsToYogaWithoutMatching() throws {
        let (container, context) = try Self.makeContainer()

        let recommendation = CoachPlanService.buildPlan(
            answers: Self.answers(focus: .yoga, sessionsPerWeek: 4, equipment: []),
            in: context
        )

        guard case .yoga(let sessionsPerWeek) = recommendation else {
            Issue.record("Expected .yoga, got \(recommendation)")
            return
        }
        #expect(sessionsPerWeek == 4)
        _ = container
    }
}
