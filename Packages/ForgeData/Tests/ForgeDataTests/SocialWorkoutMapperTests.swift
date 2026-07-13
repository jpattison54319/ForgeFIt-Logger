import Foundation
import Testing
@testable import ForgeData

@Suite struct SocialWorkoutMapperTests {

    /// A workout with health + provenance + free-text fields all populated with
    /// unmistakable sentinels. The shared projection must carry NONE of them —
    /// this is the public-sharing analogue of BackupFormatTests' fixture, and
    /// stricter (it also drops provenance, notes, and cardio).
    @MainActor
    private func maximallyPopulatedWorkout(userID: UUID) -> WorkoutModel {
        let workout = WorkoutModel(userID: userID, title: "Push Day A", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        workout.endedAt = Date(timeIntervalSince1970: 1_700_003_600) // +3600s
        // Provenance / internal — must NOT reach a friend's device.
        workout.routineID = UUID()
        workout.sourceDevice = "iphone_SENTINEL"
        workout.notes = "SECRETNOTE_leak"
        workout.externalSource = "hevy_SENTINEL"
        workout.externalWorkoutID = "extid_SENTINEL"
        workout.importFingerprint = "FINGERPRINT_sentinel"
        workout.xpAwardedAmount = 7_654_321
        // HEALTH SENTINELS — must never appear in the shared JSON.
        workout.hkWorkoutUUID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")
        workout.avgHR = 15599
        workout.maxHR = 18177
        workout.activeEnergyKcal = 52344.5
        workout.hrZoneSeconds = [11111, 22222, 33333]
        workout.readinessAtStart = 4577

        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        exercise.supersetGroup = 2
        exercise.notes = "EXERCISENOTE_leak"       // free-text — must not leak
        exercise.notePinned = true
        exercise.restSeconds = 120
        workout.exercises.append(exercise)

        let set = SetModel(userID: userID, position: 0)
        set.setTypeRaw = "working"
        set.weightModeRaw = "external"
        set.reps = 8
        set.weight = 61.25
        set.rpe = 8.5
        set.rir = 2
        set.machineSettingsJSON = #"{"pin":7}"#
        // Derived aggregates — these SHOULD travel (they don't reveal weight).
        set.effectiveLoad = 61.25
        set.totalVolume = 490.0
        set.estimated1RM = 77.58
        set.completedAt = Date(timeIntervalSince1970: 1_700_000_500)
        // HEALTH SENTINEL — body weight must never leak.
        set.bodyweightKg = 82.5432
        exercise.sets.append(set)

        // A cardio session (GPS + HR heavy) — must be omitted whole.
        let session = CardioSessionModel(userID: userID, workoutExerciseID: exercise.id, modality: "run", startedAt: workout.startedAt)
        session.distanceMeters = 10000
        session.avgHR = 15588
        session.hkWorkoutUUID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")
        workout.cardioSessions.append(session)
        return workout
    }

    /// Keys and values that must never appear in a shared-workout payload.
    private static let forbiddenKeys = [
        "avgHR", "maxHR", "activeEnergyKcal", "hrZoneSeconds", "readinessAtStart",
        "hkWorkoutUUID", "bodyweightKg", "notes", "externalSource", "externalID",
        "externalWorkoutID", "importFingerprint", "xpAwardedAmount", "routineID",
        "sourceDevice", "cardioSessions", "deletedAt", "sourceRoutineSetID",
    ]
    private static let sentinelValues = [
        "15599", "18177", "52344", "11111", "22222", "4577", "82.5432",
        "15588", "DEADBEEF", "SECRETNOTE", "EXERCISENOTE", "hevy_SENTINEL",
        "extid_SENTINEL", "FINGERPRINT", "iphone_SENTINEL", "7654321",
    ]

    /// The complete v1 key set per JSON object level. A future field addition
    /// must be reviewed and added here before it ships — an undocumented key
    /// fails the walk.
    private static let allowedKeys: [String: Set<String>] = [
        "workout": ["schemaVersion", "id", "title", "startedAt", "endedAt", "exercises"],
        "exercise": ["id", "exerciseID", "name", "position", "supersetGroup", "sets"],
        "set": ["id", "position", "setType", "weightMode", "reps", "weightKg", "rpe", "rir",
                "durationSeconds", "holdSeconds", "partialReps", "addedWeight", "assistanceWeight",
                "isUnilateral", "implementWeight", "limbCount", "isEccentric", "isPaused",
                "machineSettingsJSON", "miniRepsJSON", "side2Reps", "side2MiniRepsJSON",
                "plannedMiniSetCount", "plannedMiniRepsJSON", "effectiveLoad", "totalVolume",
                "estimated1RM", "completedAt"],
    ]

    @MainActor
    @Test func sharedJSONContainsNoHealthKeysProvenanceOrSentinels() throws {
        let userID = UUID()
        let dto = SocialWorkoutMapper.shared(from: maximallyPopulatedWorkout(userID: userID), exerciseNames: [:])
        let json = String(decoding: try SocialWorkoutMapper.encode(dto), as: UTF8.self)

        for key in Self.forbiddenKeys {
            #expect(!json.contains("\"\(key)\""), "forbidden key \(key) leaked into shared JSON")
        }
        for sentinel in Self.sentinelValues {
            #expect(!json.contains(sentinel), "sentinel value \(sentinel) leaked into shared JSON")
        }
    }

    @MainActor
    @Test func everyObjectLevelStaysWithinDocumentedKeySets() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let dto = SocialWorkoutMapper.shared(from: workout, exerciseNames: [workout.exercises[0].exerciseID: "Bench Press"])
        let data = try SocialWorkoutMapper.encode(dto)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        func check(_ object: [String: Any], level: String) {
            let allowed = Self.allowedKeys[level]!
            for key in object.keys {
                #expect(allowed.contains(key), "undocumented key '\(key)' at level '\(level)'")
            }
        }
        check(root, level: "workout")
        for exercise in root["exercises"] as? [[String: Any]] ?? [] {
            check(exercise, level: "exercise")
            for set in exercise["sets"] as? [[String: Any]] ?? [] { check(set, level: "set") }
        }
    }

    @MainActor
    @Test func cardioSessionsAreOmittedEntirely() throws {
        let userID = UUID()
        let dto = SocialWorkoutMapper.shared(from: maximallyPopulatedWorkout(userID: userID), exerciseNames: [:])
        // Only the strength exercise survives; there is no place for cardio.
        #expect(dto.exercises.count == 1)
        let json = String(decoding: try SocialWorkoutMapper.encode(dto), as: UTF8.self)
        #expect(!json.contains("cardio"))
        #expect(!json.contains("run"))
    }

    @MainActor
    @Test func derivedAggregatesAndTrainingFieldsAreCarried() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let dto = SocialWorkoutMapper.shared(from: workout, exerciseNames: [workout.exercises[0].exerciseID: "Bench Press"])
        let set = try #require(dto.exercises.first?.sets.first)
        #expect(dto.exercises.first?.name == "Bench Press")
        #expect(set.reps == 8)
        #expect(set.weightKg == 61.25)
        #expect(set.rpe == 8.5)
        #expect(set.effectiveLoad == 61.25)
        #expect(set.totalVolume == 490.0)
        #expect(set.estimated1RM == 77.58)
        #expect(set.machineSettingsJSON == #"{"pin":7}"#)
    }

    @MainActor
    @Test func roundTripThroughJSONIsStable() throws {
        let userID = UUID()
        let dto = SocialWorkoutMapper.shared(from: maximallyPopulatedWorkout(userID: userID), exerciseNames: [:])
        let decoded = try SocialWorkoutMapper.decode(try SocialWorkoutMapper.encode(dto))
        #expect(decoded == dto)
    }

    @MainActor
    @Test func exercisesAndSetsAreSortedByPosition() throws {
        let userID = UUID()
        let workout = WorkoutModel(userID: userID, title: "Order", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        for position in [2, 0, 1] {
            let ex = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: position)
            for setPos in [1, 0] {
                let s = SetModel(userID: userID, position: setPos)
                s.setTypeRaw = "working"
                ex.sets.append(s)
            }
            workout.exercises.append(ex)
        }
        let dto = SocialWorkoutMapper.shared(from: workout, exerciseNames: [:])
        #expect(dto.exercises.map(\.position) == [0, 1, 2])
        #expect(dto.exercises.allSatisfy { $0.sets.map(\.position) == [0, 1] })
    }

    @MainActor
    @Test func summaryCountsOnlyCompletedWorkingSets() throws {
        let userID = UUID()
        let workout = WorkoutModel(userID: userID, title: "Summary", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        workout.endedAt = Date(timeIntervalSince1970: 1_700_001_800) // +1800s = 30 min
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0)

        // Warm-up (completed) — must NOT count as working volume.
        let warmup = SetModel(userID: userID, position: 0)
        warmup.setTypeRaw = "warmup"; warmup.reps = 10; warmup.totalVolume = 200; warmup.completedAt = Date(timeIntervalSince1970: 1_700_000_100)
        // Two completed working sets — count.
        let w1 = SetModel(userID: userID, position: 1)
        w1.setTypeRaw = "working"; w1.reps = 8; w1.totalVolume = 490; w1.completedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let w2 = SetModel(userID: userID, position: 2)
        w2.setTypeRaw = "working"; w2.reps = 6; w2.totalVolume = 400; w2.completedAt = Date(timeIntervalSince1970: 1_700_000_300)
        // Working but NOT completed — must NOT count.
        let pending = SetModel(userID: userID, position: 3)
        pending.setTypeRaw = "working"; pending.reps = 6; pending.totalVolume = 400; pending.completedAt = nil
        exercise.sets.append(contentsOf: [warmup, w1, w2, pending])
        workout.exercises.append(exercise)

        let summary = SocialWorkoutMapper.shared(from: workout, exerciseNames: [:]).summary
        #expect(summary.workingSets == 2)
        #expect(summary.reps == 14)          // 8 + 6, warm-up and pending excluded
        #expect(summary.volumeKg == 890)     // 490 + 400
        #expect(summary.durationSeconds == 1800)
        #expect(summary.exerciseCount == 1)
    }
}
