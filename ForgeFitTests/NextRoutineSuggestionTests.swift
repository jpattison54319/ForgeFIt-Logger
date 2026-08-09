import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// A mesocycle and one of its microcycles are independent active slots. The
/// more specific microcycle wins; an empty one falls back to its mesocycle.
struct NextRoutineSuggestionTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func routine(_ name: String, folderID: UUID? = nil, position: Int = 0) -> RoutineModel {
        let exercise = RoutineExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        return RoutineModel(
            userID: userID,
            name: name,
            folderID: folderID,
            position: position,
            exercises: [exercise]
        )
    }

    private func completedWorkout(routineID: UUID, daysAgo: Int) -> WorkoutModel {
        let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        return WorkoutModel(
            userID: userID,
            routineID: routineID,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600)
        )
    }

    /// Mesocycle "Off-Season" contains Volume and Intensity microcycles;
    /// Prehab is an unrelated standalone microcycle.
    private func fixture() -> (
        mesocycleID: UUID,
        volumeMicrocycleID: UUID,
        intensityMicrocycleID: UUID,
        prehabMicrocycleID: UUID,
        volumeRoutines: [RoutineModel],
        intensityRoutines: [RoutineModel],
        prehabRoutines: [RoutineModel]
    ) {
        let mesocycleID = UUID()
        let volumeMicrocycleID = UUID()
        let intensityMicrocycleID = UUID()
        let prehabMicrocycleID = UUID()
        return (
            mesocycleID,
            volumeMicrocycleID,
            intensityMicrocycleID,
            prehabMicrocycleID,
            [
                routine("Volume A", folderID: volumeMicrocycleID, position: 0),
                routine("Volume B", folderID: volumeMicrocycleID, position: 1),
            ],
            [routine("Intensity A", folderID: intensityMicrocycleID)],
            [routine("Prehab A", folderID: prehabMicrocycleID)]
        )
    }

    private func subtree(
        _ fixture: (
            mesocycleID: UUID,
            volumeMicrocycleID: UUID,
            intensityMicrocycleID: UUID,
            prehabMicrocycleID: UUID,
            volumeRoutines: [RoutineModel],
            intensityRoutines: [RoutineModel],
            prehabRoutines: [RoutineModel]
        )
    ) -> (UUID) -> Set<UUID> {
        { root in
            root == fixture.mesocycleID
                ? [root, fixture.volumeMicrocycleID, fixture.intensityMicrocycleID]
                : [root]
        }
    }

    @Test func noActiveFoldersBestGuessesAcrossEverything() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: [],
            activeMicrocycleFolderID: nil,
            activeMesocycleFolderID: nil,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.routineID == all[0].id)
        #expect(result?.reason == "Start your plan")
    }

    @Test func onlyMesocycleActiveRotatesAcrossItsMicrocycles() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: [],
            activeMicrocycleFolderID: nil,
            activeMesocycleFolderID: fixture.mesocycleID,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.routineID == fixture.volumeRoutines[0].id)
        #expect(result?.reason == "Start your mesocycle")
    }

    @Test func onlyMicrocycleActiveScopesToThatMicrocycle() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: [],
            activeMicrocycleFolderID: fixture.intensityMicrocycleID,
            activeMesocycleFolderID: nil,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.routineID == fixture.intensityRoutines[0].id)
        #expect(result?.reason == "Start your microcycle")
    }

    @Test func mesocycleAndMicrocycleActiveTogetherMicrocycleWins() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: [],
            activeMicrocycleFolderID: fixture.volumeMicrocycleID,
            activeMesocycleFolderID: fixture.mesocycleID,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.routineID == fixture.volumeRoutines[0].id)
        #expect(result?.reason == "Start your microcycle")
    }

    @Test func unrelatedMicrocycleStillWinsOverActiveMesocycle() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: [],
            activeMicrocycleFolderID: fixture.prehabMicrocycleID,
            activeMesocycleFolderID: fixture.mesocycleID,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.routineID == fixture.prehabRoutines[0].id)
        #expect(result?.reason == "Start your microcycle")
    }

    @Test func emptyActiveMicrocycleFallsThroughToMesocycle() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: [],
            activeMicrocycleFolderID: UUID(),
            activeMesocycleFolderID: fixture.mesocycleID,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.reason == "Start your mesocycle")
    }

    @Test func rotatesAfterLastCompletionWithinActiveMicrocycle() {
        let fixture = fixture()
        let all = fixture.volumeRoutines + fixture.intensityRoutines + fixture.prehabRoutines
        let completed = [completedWorkout(routineID: fixture.volumeRoutines[0].id, daysAgo: 2)]
        let result = NextRoutineSuggestion.suggest(
            routines: all,
            completedWorkouts: completed,
            activeMicrocycleFolderID: fixture.volumeMicrocycleID,
            activeMesocycleFolderID: nil,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result?.routineID == fixture.volumeRoutines[1].id)
        #expect(result?.reason.hasPrefix("Next in your microcycle") == true)
    }

    @Test func noRoutinesReturnsNil() {
        let fixture = fixture()
        let result = NextRoutineSuggestion.suggest(
            routines: [],
            completedWorkouts: [],
            activeMicrocycleFolderID: nil,
            activeMesocycleFolderID: nil,
            mesocycleSubtree: subtree(fixture),
            now: now
        )
        #expect(result == nil)
    }
}
