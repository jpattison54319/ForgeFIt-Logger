import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
@Suite("Routine library performance snapshot")
struct RoutineLibraryPerformanceSnapshotTests {
    @Test("Grouping and alternation resolution happen once per snapshot")
    func groupsLibraryAndIndexesAlternations() throws {
        let userID = ForgeFitDemo.userID
        let mesocycle = RoutineFolderModel(
            userID: userID,
            name: "Base",
            position: 0
        )
        let microcycle = RoutineFolderModel(
            userID: userID,
            name: "Week A",
            position: 0,
            parentID: mesocycle.id
        )
        let owner = RoutineModel(
            userID: userID,
            name: "A",
            folderID: microcycle.id,
            position: 0
        )
        let partner = RoutineModel(
            userID: userID,
            name: "B",
            folderID: microcycle.id,
            position: 1
        )
        let loose = RoutineModel(userID: userID, name: "Loose", position: 2)
        let createdAt = Date(timeIntervalSince1970: 100)
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        let completedOwner = WorkoutModel(
            userID: userID,
            routineID: owner.id,
            startedAt: Date(timeIntervalSince1970: 200),
            endedAt: Date(timeIntervalSince1970: 300)
        )

        let snapshot = RoutineLibraryPerformanceSnapshot.make(
            routines: [partner, loose, owner],
            folders: [microcycle, mesocycle],
            alternations: [alternation],
            workouts: [completedOwner],
            generation: "test"
        )

        #expect(snapshot.topLevelFolders.map(\.id) == [mesocycle.id])
        #expect(snapshot.childFolders(of: mesocycle).map(\.id) == [microcycle.id])
        #expect(snapshot.routines(in: microcycle).map(\.id) == [owner.id, partner.id])
        #expect(snapshot.ungroupedRoutines.map(\.id) == [loose.id])
        #expect(snapshot.alternationStates.count == 1)
        #expect(snapshot.alternationStateByRoutineID[owner.id]?.due.id == partner.id)
        #expect(snapshot.alternationStateByRoutineID[partner.id]?.due.id == partner.id)
        #expect(snapshot.configuredAlternationRoutineIDs == [owner.id, partner.id])
        #expect(RoutineLibraryCardPresentation.make(for: owner).orderedItems.isEmpty)
    }

    @Test("A persistence signal invalidates the O(1) library key")
    func persistenceSignalInvalidatesKey() {
        let before = RoutineLibraryPerformanceKey(
            persistenceRevision: 4,
            routineCount: 20,
            folderCount: 3,
            alternationCount: 2,
            workoutCount: 100
        )
        let after = RoutineLibraryPerformanceKey(
            persistenceRevision: 5,
            routineCount: 20,
            folderCount: 3,
            alternationCount: 2,
            workoutCount: 100
        )
        #expect(before != after)
    }

    @Test("A canonical tombstone prevents a stale folder from flickering")
    func canonicalizesFoldersBeforeFiltering() {
        let id = UUID()
        let live = RoutineFolderModel(id: id, userID: ForgeFitDemo.userID, name: "Stale")
        live.updatedAt = Date(timeIntervalSince1970: 500)
        let tombstone = RoutineFolderModel(id: id, userID: ForgeFitDemo.userID, name: "Deleted")
        tombstone.updatedAt = Date(timeIntervalSince1970: 100)
        tombstone.deletedAt = Date(timeIntervalSince1970: 200)

        let snapshot = RoutineLibraryPerformanceSnapshot.make(
            routines: [],
            folders: [live, tombstone],
            alternations: [],
            workouts: [],
            generation: "test"
        )

        #expect(snapshot.folders.isEmpty)
        #expect(snapshot.topLevelFolders.isEmpty)
    }

    @Test("A non-newest exercise rename invalidates the O(1) name lookup")
    func exerciseNameLookupTracksEveryCatalogRow() {
        let older = ExerciseLibraryModel(name: "Older")
        older.updatedAt = Date(timeIntervalSince1970: 10)
        let newest = ExerciseLibraryModel(name: "Newest")
        newest.updatedAt = Date(timeIntervalSince1970: 20)
        older.name = "Renamed Older"

        #expect(RoutineLibraryExerciseLookup.namesByID([older, newest])[older.id] == "Renamed Older")
    }
}
