import Foundation
import Testing
@testable import ForgeCore

struct WatchSyncTests {

    @Test func appContextRoundTripsThroughWireEncoding() throws {
        let workoutID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let exerciseID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let setID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let routineID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let restEndsAt = Date(timeIntervalSince1970: 1_800_000_120)
        let intervalEndsAt = Date(timeIntervalSince1970: 1_800_000_300)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_010)

        let original = WatchAppContext(
            workout: WatchWorkoutSnapshot(
                workoutID: workoutID,
                title: "Push Day",
                startedAt: startedAt,
                exercises: [
                    WatchExerciseSnapshot(
                        id: exerciseID,
                        name: "Bench Press",
                        isCardio: false,
                        supersetGroup: 1,
                        cardioState: nil,
                        sets: [
                            WatchSetSnapshot(
                                id: setID,
                                label: "1",
                                weight: 225,
                                unitSuffix: "lb",
                                weightKg: 102.058,
                                reps: 5,
                                completed: true
                            )
                        ]
                    )
                ],
                restEndsAt: restEndsAt,
                restTotalSeconds: 120,
                intervalStepName: "Work 1/6",
                intervalStepEndsAt: intervalEndsAt
            ),
            routines: [WatchRoutineSummary(id: routineID, name: "Push", exerciseCount: 4)],
            readiness: 82,
            unitSuffix: "lb",
            updatedAt: updatedAt
        )

        let data = try #require(WatchWire.encode(original))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))

        #expect(decoded == original)
        #expect(decoded.workout?.completedSets == 1)
        #expect(decoded.workout?.totalSets == 1)
    }

    @Test func watchCommandsRoundTripAllPayloadShapes() throws {
        let routineID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let setID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let cardioID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let metrics = WatchLiveMetrics(
            heartRate: 151,
            avgHR: 143,
            maxHR: 168,
            activeEnergyKcal: 345.5,
            hrZoneSeconds: [10, 20, 30, 40, 50],
            asOf: Date(timeIntervalSince1970: 1_800_000_400)
        )

        try expectCommand(WatchCommand.startRoutine(routineID: routineID)) { decoded in
            guard case .startRoutine(let decodedID) = decoded else { return false }
            return decodedID == routineID
        }
        try expectCommand(.startEmpty) {
            guard case .startEmpty = $0 else { return false }
            return true
        }
        try expectCommand(.toggleSet(setID: setID, completed: true)) {
            guard case .toggleSet(let decodedID, let completed) = $0 else { return false }
            return decodedID == setID && completed
        }
        try expectCommand(.updateSet(setID: setID, weightKg: 100.5, reps: 8)) {
            guard case .updateSet(let decodedID, let weightKg, let reps) = $0 else { return false }
            return decodedID == setID && weightKg == 100.5 && reps == 8
        }
        try expectCommand(.startCardio(workoutExerciseID: cardioID)) {
            guard case .startCardio(let decodedID) = $0 else { return false }
            return decodedID == cardioID
        }
        try expectCommand(.completeCardio(workoutExerciseID: cardioID)) {
            guard case .completeCardio(let decodedID) = $0 else { return false }
            return decodedID == cardioID
        }
        try expectCommand(.liveMetrics(metrics)) {
            guard case .liveMetrics(let decodedMetrics) = $0 else { return false }
            return decodedMetrics == metrics
        }
        try expectCommand(.finishWorkout(metrics: metrics, savedToHealth: true)) {
            guard case .finishWorkout(let decodedMetrics, let savedToHealth) = $0 else { return false }
            return decodedMetrics == metrics && savedToHealth
        }
        try expectCommand(.discardWorkout) {
            guard case .discardWorkout = $0 else { return false }
            return true
        }
        try expectCommand(.workoutFinished) {
            guard case .workoutFinished = $0 else { return false }
            return true
        }
    }

    @Test func widgetSnapshotStoreHandlesMissingInvalidAndSavedData() throws {
        let suiteName = "ForgeFitWidgetSnapshotStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ForgeFitWidgetSnapshotStore.load(defaults: defaults) == nil)

        defaults.set(Data("not json".utf8), forKey: ForgeFitWidgetSnapshotStore.key)
        #expect(ForgeFitWidgetSnapshotStore.load(defaults: defaults) == nil)

        let snapshot = ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_500),
            readinessScore: 74,
            readinessAction: "Train",
            readinessDetail: "Recovered enough",
            reasonChips: ["Sleep steady", "Low soreness"],
            workoutTitle: "Legs",
            workoutStartedAt: Date(timeIntervalSince1970: 1_800_000_000),
            currentExerciseName: "Squat",
            completedSets: 3,
            totalSets: 12,
            restEndsAt: Date(timeIntervalSince1970: 1_800_000_620),
            heartRate: 132
        )

        ForgeFitWidgetSnapshotStore.save(snapshot, defaults: defaults)

        #expect(ForgeFitWidgetSnapshotStore.load(defaults: defaults) == snapshot)
    }

    private func expectCommand(
        _ command: WatchCommand,
        matches: (WatchCommand) -> Bool
    ) throws {
        let data = try #require(WatchWire.encode(command))
        let decoded = try #require(WatchWire.decode(WatchCommand.self, from: data))
        #expect(matches(decoded))
    }
}
