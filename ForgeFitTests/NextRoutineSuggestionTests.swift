import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// Verifies the active-macro/active-meso drilldown: a mesocycle and its
/// parent macrocycle are independent slots that can both be active — the
/// bug being fixed here is that they used to share one slot, so choosing a
/// mesocycle silently clobbered an active macrocycle (and vice versa).
struct NextRoutineSuggestionTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func routine(_ name: String, folderID: UUID? = nil, position: Int = 0) -> RoutineModel {
        let exercise = RoutineExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        return RoutineModel(userID: userID, name: name, folderID: folderID, position: position, exercises: [exercise])
    }

    private func completedWorkout(routineID: UUID, daysAgo: Int) -> WorkoutModel {
        let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return WorkoutModel(userID: userID, routineID: routineID, startedAt: start, endedAt: start.addingTimeInterval(3_600))
    }

    /// A macrocycle "Off-Season" containing two mesocycles ("Volume",
    /// "Intensity"), each with routines, plus one unrelated standalone
    /// mesocycle ("Prehab") — enough structure to exercise every drilldown
    /// branch.
    private func fixture() -> (
        macroID: UUID, volumeMesoID: UUID, intensityMesoID: UUID, prehabMesoID: UUID,
        volumeRoutines: [RoutineModel], intensityRoutines: [RoutineModel], prehabRoutines: [RoutineModel]
    ) {
        let macroID = UUID()
        let volumeMesoID = UUID()
        let intensityMesoID = UUID()
        let prehabMesoID = UUID()
        let volumeRoutines = [
            routine("Volume A", folderID: volumeMesoID, position: 0),
            routine("Volume B", folderID: volumeMesoID, position: 1),
        ]
        let intensityRoutines = [
            routine("Intensity A", folderID: intensityMesoID, position: 0),
        ]
        let prehabRoutines = [
            routine("Prehab A", folderID: prehabMesoID, position: 0),
        ]
        return (macroID, volumeMesoID, intensityMesoID, prehabMesoID, volumeRoutines, intensityRoutines, prehabRoutines)
    }

    /// volumeMesoID and intensityMesoID both roll up to macroID; prehabMesoID
    /// does not (it's an unrelated standalone mesocycle).
    private func subtree(_ f: (macroID: UUID, volumeMesoID: UUID, intensityMesoID: UUID, prehabMesoID: UUID, volumeRoutines: [RoutineModel], intensityRoutines: [RoutineModel], prehabRoutines: [RoutineModel])) -> (UUID) -> Set<UUID> {
        { root in root == f.macroID ? [f.macroID, f.volumeMesoID, f.intensityMesoID] : [root] }
    }

    @Test func noActiveFoldersBestGuessesAcrossEverything() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: [],
            activeMesoFolderID: nil, activeMacroFolderID: nil,
            macroSubtree: subtree(f), now: now
        )
        #expect(result?.routineID == all[0].id)
        #expect(result?.reason == "Start your plan")
    }

    @Test func onlyMacroActiveRotatesAcrossAllItsMesocycles() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: [],
            activeMesoFolderID: nil, activeMacroFolderID: f.macroID,
            macroSubtree: subtree(f), now: now
        )
        // Pool is Volume A/B + Intensity A (Prehab excluded) — first in pool.
        #expect(result?.routineID == f.volumeRoutines[0].id)
        #expect(result?.reason == "Start your macrocycle")
    }

    @Test func onlyMesoActiveScopesToJustThatMesocycle() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: [],
            activeMesoFolderID: f.intensityMesoID, activeMacroFolderID: nil,
            macroSubtree: subtree(f), now: now
        )
        #expect(result?.routineID == f.intensityRoutines[0].id)
        #expect(result?.reason == "Start your mesocycle")
    }

    /// The reported bug: a macro and one of its mesocycles active at once —
    /// the mesocycle (more specific) must win, and the macro must NOT have
    /// been silently cleared to produce this result (that's asserted by the
    /// caller still being able to pass both IDs in — a single shared slot
    /// design couldn't represent this call at all).
    @Test func macroAndItsMesoActiveTogetherMesoWins() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: [],
            activeMesoFolderID: f.volumeMesoID, activeMacroFolderID: f.macroID,
            macroSubtree: subtree(f), now: now
        )
        #expect(result?.routineID == f.volumeRoutines[0].id)
        #expect(result?.reason == "Start your mesocycle")
    }

    /// The meso and macro don't even need to be related — independent slots.
    @Test func unrelatedMesoStillWinsOverActiveMacro() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: [],
            activeMesoFolderID: f.prehabMesoID, activeMacroFolderID: f.macroID,
            macroSubtree: subtree(f), now: now
        )
        #expect(result?.routineID == f.prehabRoutines[0].id)
        #expect(result?.reason == "Start your mesocycle")
    }

    /// An active mesocycle with nothing suggestible (no valid routines)
    /// falls through to the active macrocycle rather than producing no
    /// scoped suggestion at all.
    @Test func emptyActiveMesoFallsThroughToMacro() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let emptyMesoID = UUID()
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: [],
            activeMesoFolderID: emptyMesoID, activeMacroFolderID: f.macroID,
            macroSubtree: subtree(f), now: now
        )
        #expect(result?.reason == "Start your macrocycle")
    }

    @Test func rotatesToNextAfterLastCompletedWithinActiveMeso() {
        let f = fixture()
        let all = f.volumeRoutines + f.intensityRoutines + f.prehabRoutines
        let completed = [completedWorkout(routineID: f.volumeRoutines[0].id, daysAgo: 2)]
        let result = NextRoutineSuggestion.suggest(
            routines: all, completedWorkouts: completed,
            activeMesoFolderID: f.volumeMesoID, activeMacroFolderID: nil,
            macroSubtree: subtree(f), now: now
        )
        #expect(result?.routineID == f.volumeRoutines[1].id)
        #expect(result?.reason.hasPrefix("Next in your mesocycle") == true)
    }

    @Test func noRoutinesReturnsNil() {
        let f = fixture()
        let result = NextRoutineSuggestion.suggest(
            routines: [], completedWorkouts: [],
            activeMesoFolderID: nil, activeMacroFolderID: nil,
            macroSubtree: subtree(f), now: now
        )
        #expect(result == nil)
    }
}
