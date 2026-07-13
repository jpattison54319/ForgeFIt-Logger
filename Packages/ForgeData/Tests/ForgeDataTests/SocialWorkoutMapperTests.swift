import Foundation
import Testing
@testable import ForgeData

@Suite struct SocialWorkoutMapperTests {

    /// A workout with health + provenance + location fields all populated with
    /// unmistakable sentinels — including a cardio session (heart rate, energy,
    /// TSS, samples, steps, floors) and a GPS route point. The shared projection
    /// must carry the training fields but NONE of the sentinels.
    @MainActor
    private func maximallyPopulatedWorkout(userID: UUID) -> WorkoutModel {
        let workout = WorkoutModel(userID: userID, title: "Push Day A", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        workout.endedAt = Date(timeIntervalSince1970: 1_700_003_600) // +3600s
        workout.routineID = UUID()
        workout.sourceDevice = "iphone_SENTINEL"
        workout.notes = "SECRETNOTE_leak"
        workout.externalSource = "hevy_SENTINEL"
        workout.externalWorkoutID = "extid_SENTINEL"
        workout.importFingerprint = "FINGERPRINT_sentinel"
        workout.xpAwardedAmount = 7_654_321
        // WORKOUT HEALTH SENTINELS
        workout.hkWorkoutUUID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")
        workout.avgHR = 15599
        workout.maxHR = 18177
        workout.activeEnergyKcal = 52344.5
        workout.hrZoneSeconds = [11111, 22222, 33333]
        workout.readinessAtStart = 4577

        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        exercise.supersetGroup = 2
        exercise.notes = "EXERCISENOTE_leak"
        exercise.notePinned = true
        workout.exercises.append(exercise)

        let set = SetModel(userID: userID, position: 0)
        set.setTypeRaw = "working"
        set.weightModeRaw = "external"
        set.reps = 8
        set.weight = 61.25
        set.effectiveLoad = 61.25
        set.totalVolume = 490.0
        set.estimated1RM = 77.58
        set.completedAt = Date(timeIntervalSince1970: 1_700_000_500)
        set.bodyweightKg = 82.5432  // HEALTH SENTINEL
        exercise.sets.append(set)

        // Cardio session: training fields are shared; health + GPS are not.
        let session = CardioSessionModel(userID: userID, workoutExerciseID: exercise.id, modality: "run", startedAt: workout.startedAt)
        session.endedAt = workout.endedAt
        session.durationSeconds = 3600     // safe
        session.distanceMeters = 10000     // safe — SHOULD appear
        session.effort = 7                 // safe (rating, not biometric)
        session.avgPaceSecondsPerKm = 315  // safe
        session.avgPowerWatts = 210        // safe
        session.avgCadence = 172           // safe
        session.elevationGainMeters = 123  // safe
        // CARDIO HEALTH SENTINELS
        session.avgHR = 15588
        session.maxHR = 18166
        session.activeEnergyKcal = 52399.9
        session.hrZoneSeconds = [99991, 99992]
        session.tss = 6177.5
        session.sampleSeriesJSON = #"{"samples":[{"t":0,"hr":155991}]}"#
        session.floorsClimbed = 12345
        session.totalSteps = 54321
        session.flexibilityExposureJSON = #"{"hips":999993}"#
        session.hkWorkoutUUID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")
        session.sourceDevice = "watch_SENTINEL"
        workout.cardioSessions.append(session)

        let split = CardioSplitModel(
            userID: userID, cardioSessionID: session.id, index: 0,
            distanceMeters: 1000, durationSeconds: 300, paceSecondsPerKm: 300,
            elevationGainMeters: 12, startedAt: workout.startedAt, endedAt: workout.endedAt ?? workout.startedAt
        )
        split.label = "Lap 1"
        split.autoDetected = true
        session.splits.append(split)

        // GPS route point — LOCATION, must never appear in a public share.
        let point = CardioRoutePointModel(
            userID: userID, cardioSessionID: session.id, timestamp: workout.startedAt,
            latitude: -36.8484597123, longitude: 174.7633315987,
            altitudeMeters: 23.456, horizontalAccuracyMeters: 5.1, speedMetersPerSecond: 2.7
        )
        session.routePoints.append(point)
        return workout
    }

    /// Keys that must never appear in a shared-workout payload.
    private static let forbiddenKeys = [
        "avgHR", "maxHR", "activeEnergyKcal", "hrZoneSeconds", "readinessAtStart",
        "hkWorkoutUUID", "bodyweightKg", "notes", "externalSource", "externalID",
        "externalWorkoutID", "importFingerprint", "xpAwardedAmount", "routineID",
        "sourceDevice", "deletedAt", "sourceRoutineSetID",
        // cardio health + location:
        "tss", "sampleSeriesJSON", "totalSteps", "floorsClimbed", "flexibilityExposureJSON",
        "routePoints", "latitude", "longitude", "altitudeMeters", "liveStartedAt",
        "intervalsAutoApplied", "workoutExerciseID",
    ]
    private static let sentinelValues = [
        // workout + set health
        "15599", "18177", "52344", "11111", "22222", "4577", "82.5432",
        // cardio health
        "15588", "18166", "52399", "99991", "99992", "6177", "155991", "12345", "54321", "999993",
        // GPS
        "36.8484", "174.7633",
        // provenance
        "DEADBEEF", "SECRETNOTE", "EXERCISENOTE", "hevy_SENTINEL", "extid_SENTINEL",
        "FINGERPRINT", "iphone_SENTINEL", "watch_SENTINEL", "7654321",
    ]

    /// The complete v2 key set per JSON object level.
    private static let allowedKeys: [String: Set<String>] = [
        "workout": ["schemaVersion", "id", "title", "startedAt", "endedAt", "exercises", "cardioSessions"],
        "exercise": ["id", "exerciseID", "name", "position", "supersetGroup", "sets"],
        "set": ["id", "position", "setType", "weightMode", "reps", "weightKg", "rpe", "rir",
                "durationSeconds", "holdSeconds", "partialReps", "addedWeight", "assistanceWeight",
                "isUnilateral", "implementWeight", "limbCount", "isEccentric", "isPaused",
                "machineSettingsJSON", "miniRepsJSON", "side2Reps", "side2MiniRepsJSON",
                "plannedMiniSetCount", "plannedMiniRepsJSON", "effectiveLoad", "totalVolume",
                "estimated1RM", "completedAt"],
        "session": ["id", "modality", "startedAt", "endedAt", "durationSeconds", "distanceMeters",
                    "effort", "avgPaceSecondsPerKm", "split500mSeconds", "strokeRate", "avgPowerWatts",
                    "avgCadence", "resistanceLevel", "inclinePercent", "elevationGainMeters",
                    "yogaStyleRaw", "posesCompleted", "splits"],
        "split": ["index", "distanceMeters", "durationSeconds", "paceSecondsPerKm",
                  "elevationGainMeters", "label", "autoDetected"],
    ]

    @MainActor
    @Test func sharedJSONContainsNoHealthKeysLocationProvenanceOrSentinels() throws {
        let userID = UUID()
        let dto = SocialWorkoutMapper.shared(from: maximallyPopulatedWorkout(userID: userID), exerciseNames: [:])
        let json = String(decoding: try SocialWorkoutMapper.encode(dto), as: UTF8.self)

        for key in Self.forbiddenKeys {
            #expect(!json.contains("\"\(key)\""), "forbidden key \(key) leaked into shared JSON")
        }
        for sentinel in Self.sentinelValues {
            #expect(!json.contains(sentinel), "sentinel value \(sentinel) leaked into shared JSON")
        }
        // Sanity: the SAFE training fields DID travel.
        #expect(json.contains("10000"))  // distance
        #expect(json.contains("\"cardioSessions\""))
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
        for session in root["cardioSessions"] as? [[String: Any]] ?? [] {
            check(session, level: "session")
            for split in session["splits"] as? [[String: Any]] ?? [] { check(split, level: "split") }
        }
    }

    @MainActor
    @Test func cardioSessionIsSharedButSanitized() throws {
        let userID = UUID()
        let dto = SocialWorkoutMapper.shared(from: maximallyPopulatedWorkout(userID: userID), exerciseNames: [:])
        let session = try #require(dto.cardioSessions.first)
        #expect(session.modality == "run")
        #expect(session.distanceMeters == 10000)
        #expect(session.avgPaceSecondsPerKm == 315)
        #expect(session.effort == 7)
        #expect(session.splits.count == 1)          // splits kept (no location)
        #expect(session.splits.first?.label == "Lap 1")
        // The type has no property for route points at all.
        let json = String(decoding: try SocialWorkoutMapper.encode(dto), as: UTF8.self)
        #expect(!json.contains("routePoint"))
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
        #expect(set.totalVolume == 490.0)
        #expect(set.estimated1RM == 77.58)
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
        workout.endedAt = Date(timeIntervalSince1970: 1_700_001_800) // +1800s
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        let warmup = SetModel(userID: userID, position: 0)
        warmup.setTypeRaw = "warmup"; warmup.reps = 10; warmup.totalVolume = 200; warmup.completedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let w1 = SetModel(userID: userID, position: 1)
        w1.setTypeRaw = "working"; w1.reps = 8; w1.totalVolume = 490; w1.completedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let w2 = SetModel(userID: userID, position: 2)
        w2.setTypeRaw = "working"; w2.reps = 6; w2.totalVolume = 400; w2.completedAt = Date(timeIntervalSince1970: 1_700_000_300)
        let pending = SetModel(userID: userID, position: 3)
        pending.setTypeRaw = "working"; pending.reps = 6; pending.totalVolume = 400; pending.completedAt = nil
        exercise.sets.append(contentsOf: [warmup, w1, w2, pending])
        workout.exercises.append(exercise)

        let summary = SocialWorkoutMapper.shared(from: workout, exerciseNames: [:]).summary
        #expect(summary.workingSets == 2)
        #expect(summary.reps == 14)
        #expect(summary.volumeKg == 890)
        #expect(summary.durationSeconds == 1800)
        #expect(summary.kind == "strength")
        #expect(summary.distanceMeters == 0)
    }

    @MainActor
    @Test func summaryClassifiesCardioAndYoga() throws {
        let userID = UUID()
        // Cardio-only workout.
        let run = WorkoutModel(userID: userID, title: "Morning Run", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        run.endedAt = Date(timeIntervalSince1970: 1_700_001_800)
        let runSession = CardioSessionModel(userID: userID, workoutExerciseID: nil, modality: "run", startedAt: run.startedAt)
        runSession.durationSeconds = 1800; runSession.distanceMeters = 5000
        run.cardioSessions.append(runSession)
        let runSummary = SocialWorkoutMapper.shared(from: run, exerciseNames: [:]).summary
        #expect(runSummary.kind == "cardio")
        #expect(runSummary.distanceMeters == 5000)
        #expect(runSummary.durationSeconds == 1800)

        // Yoga workout — classified yoga even though it carries an exercise wrapper.
        let yoga = WorkoutModel(userID: userID, title: "Vinyasa", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        yoga.endedAt = Date(timeIntervalSince1970: 1_700_002_400)
        yoga.exercises.append(WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0))
        let yogaSession = CardioSessionModel(userID: userID, workoutExerciseID: nil, modality: "yoga", startedAt: yoga.startedAt)
        yogaSession.durationSeconds = 2400; yogaSession.posesCompleted = 24; yogaSession.yogaStyleRaw = "vinyasa"
        yoga.cardioSessions.append(yogaSession)
        let yogaSummary = SocialWorkoutMapper.shared(from: yoga, exerciseNames: [:]).summary
        #expect(yogaSummary.kind == "yoga")
        #expect(yogaSummary.distanceMeters == 0)
    }
}
