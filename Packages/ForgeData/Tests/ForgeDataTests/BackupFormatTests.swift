import Foundation
import Testing
@testable import ForgeData

@Suite struct BackupFormatTests {

    /// A workout with EVERY field populated — user-authored fields with
    /// realistic values, health fields with unmistakable sentinels that the
    /// absence tests grep for.
    @MainActor
    private func maximallyPopulatedWorkout(userID: UUID) -> WorkoutModel {
        let workout = WorkoutModel(userID: userID, title: "Sentinel Session", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        workout.routineID = UUID()
        workout.endedAt = Date(timeIntervalSince1970: 1_700_003_600)
        workout.sourceDevice = "iphone"
        workout.notes = "felt strong"
        workout.externalSource = "hevy"
        workout.externalWorkoutID = "ext-42"
        workout.importFingerprint = "fingerprint-abc"
        workout.importBatchID = UUID()
        workout.xpAwardedAmount = 55
        workout.xpAwardedAt = Date(timeIntervalSince1970: 1_700_003_700)
        workout.deletedAt = nil
        // HEALTH SENTINELS — must never appear in the emitted JSON.
        workout.hkWorkoutUUID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")
        workout.avgHR = 15599
        workout.maxHR = 18177
        workout.activeEnergyKcal = 52344.5
        workout.hrZoneSeconds = [11111, 22222, 33333, 44444, 55555]
        workout.readinessAtStart = 4577

        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        exercise.supersetGroup = 1
        exercise.notes = "seat 4"
        exercise.notePinned = true
        exercise.restSeconds = 120
        exercise.microRestSeconds = 15
        exercise.intervalPlanJSON = #"{"steps":[1]}"#
        exercise.yogaFlowJSON = #"{"steps":[2]}"#
        exercise.sourceRoutineExerciseID = UUID()
        workout.exercises.append(exercise)

        let set = SetModel(userID: userID, position: 0)
        set.setTypeRaw = "myoRep"
        set.weightModeRaw = "external"
        set.reps = 8
        set.weight = 61.25
        set.rpe = 8.5
        set.rir = 2
        set.durationSeconds = 45
        set.holdSeconds = 10
        set.partialReps = 3
        set.addedWeight = 5
        set.assistanceWeight = 12.5
        set.isUnilateral = true
        set.implementWeight = 20
        set.limbCount = 1
        set.isEccentric = true
        set.isPaused = true
        set.machineSettingsJSON = #"{"pin":7}"#
        set.sourceRoutineSetID = UUID()
        set.miniRepsJSON = "[5,3]"
        set.side2Reps = 7
        set.side2MiniRepsJSON = "[4,2]"
        set.plannedMiniSetCount = 3
        set.plannedMiniRepsJSON = "[5,3,2]"
        set.completedAt = Date(timeIntervalSince1970: 1_700_000_500)
        // HEALTH SENTINEL
        set.bodyweightKg = 82.5432
        exercise.sets.append(set)

        let session = CardioSessionModel(userID: userID, workoutExerciseID: exercise.id, modality: "run", startedAt: workout.startedAt)
        session.liveStartedAt = workout.startedAt
        session.endedAt = workout.endedAt
        session.sourceDevice = "iphone"
        session.durationSeconds = 3600
        session.distanceMeters = 10000
        session.effort = 7
        session.avgPaceSecondsPerKm = 360
        session.split500mSeconds = 110
        session.strokeRate = 24
        session.avgPowerWatts = 210
        session.avgCadence = 172
        session.resistanceLevel = 5
        session.inclinePercent = 1.5
        session.elevationGainMeters = 120
        session.intervalsAutoApplied = true
        session.yogaStyleRaw = nil
        session.posesCompleted = nil
        session.poolLengthMeters = 25
        session.lengthsCompleted = 40
        session.totalStrokes = 720
        session.strokeStyleRaw = "freestyle"
        // HEALTH SENTINELS
        session.hkWorkoutUUID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")
        session.activeEnergyKcal = 52399.9
        session.avgHR = 15588
        session.maxHR = 18166
        session.hrZoneSeconds = [999_991, 999_992]
        session.tss = 6177.5
        session.sampleSeriesJSON = #"{"samples":[{"t":0,"hr":155991}]}"#
        session.floorsClimbed = 12345
        session.totalSteps = 54321
        session.flexibilityExposureJSON = #"{"hips":999993}"#
        workout.cardioSessions.append(session)

        let split = CardioSplitModel(
            userID: userID, cardioSessionID: session.id, index: 0,
            distanceMeters: 1000, durationSeconds: 360, paceSecondsPerKm: 360,
            elevationGainMeters: 12, startedAt: workout.startedAt, endedAt: workout.endedAt ?? workout.startedAt
        )
        split.label = "Work 1"
        split.autoDetected = true
        session.splits.append(split)

        let point = CardioRoutePointModel(
            userID: userID, cardioSessionID: session.id,
            timestamp: workout.startedAt, latitude: -36.8484597123, longitude: 174.7633315987,
            altitudeMeters: 23.456, horizontalAccuracyMeters: 5.1234, speedMetersPerSecond: 2.789
        )
        session.routePoints.append(point)

        return workout
    }

    /// Every health key/value that must never appear in an emitted backup.
    private static let forbiddenKeys = [
        "avgHR", "maxHR", "activeEnergyKcal", "hrZoneSeconds", "readinessAtStart",
        "hkWorkoutUUID", "bodyweightKg", "tss", "sampleSeriesJSON",
        "flexibilityExposureJSON", "floorsClimbed", "totalSteps",
        "heartRate", "readiness", "checkin", "Checkin", "wrapped", "Wrapped",
    ]
    private static let sentinelValues = [
        "15599", "18177", "52344", "11111", "22222", "4577", "82.5432",
        "15588", "18166", "999991", "999992", "6177", "155991", "12345",
        "54321", "999993", "DEADBEEF",
    ]

    /// The documented v1 key sets, per JSON object level. Any key outside
    /// these sets fails the walk — a future field addition must be reviewed
    /// (and added here) before it ships in the backup.
    private static let allowedKeys: [String: Set<String>] = [
        "file": ["schemaVersion", "exportedAt", "userID", "appVersion", "preferences", "workouts", "importBatches"],
        "workout": ["id", "routineID", "title", "startedAt", "endedAt", "sourceDevice", "notes",
                    "externalSource", "externalID", "importFingerprint", "importBatchID",
                    "xpAwardedAmount", "xpAwardedAt", "createdAt", "updatedAt", "deletedAt",
                    "exercises", "cardioSessions"],
        "exercise": ["id", "exerciseID", "name", "position", "supersetGroup", "notes", "notePinned",
                     "restSeconds", "microRestSeconds", "intervalPlanJSON", "yogaFlowJSON",
                     "sourceRoutineExerciseID", "createdAt", "updatedAt", "sets"],
        "set": ["id", "position", "setType", "weightMode", "reps", "weightKg", "rpe", "rir",
                "durationSeconds", "holdSeconds", "partialReps", "addedWeight", "assistanceWeight",
                "isUnilateral", "implementWeight", "limbCount", "isEccentric", "isPaused",
                "machineSettingsJSON", "sourceRoutineSetID", "miniRepsJSON", "side2Reps",
                "side2MiniRepsJSON", "plannedMiniSetCount", "plannedMiniRepsJSON",
                "completedAt", "createdAt", "updatedAt"],
        "session": ["id", "workoutExerciseID", "modality", "startedAt", "liveStartedAt", "endedAt",
                    "sourceDevice", "durationSeconds", "distanceMeters", "effort",
                    "avgPaceSecondsPerKm", "split500mSeconds", "strokeRate", "avgPowerWatts",
                    "avgCadence", "resistanceLevel", "inclinePercent", "elevationGainMeters",
                    "intervalsAutoApplied", "yogaStyleRaw", "posesCompleted",
                    "poolLengthMeters", "lengthsCompleted", "totalStrokes", "strokeStyleRaw",
                    "createdAt", "updatedAt", "deletedAt", "splits", "routePoints"],
        "split": ["id", "index", "distanceMeters", "durationSeconds", "paceSecondsPerKm",
                  "elevationGainMeters", "label", "autoDetected", "startedAt", "endedAt"],
        "point": ["t", "lat", "lon", "alt", "acc", "spd"],
        "batch": ["id", "source", "fileName", "importedCount", "skippedDuplicateCount",
                  "warningCount", "startedAt", "endedAt", "createdAt"],
    ]

    @MainActor
    @Test func emittedJSONContainsNoHealthKeysOrSentinelValues() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let file = BackupMapper.file(
            workouts: [workout], batches: [], exerciseNames: [:],
            preferences: ["weightUnitRaw": .string("lb")],
            userID: userID, appVersion: "1.0"
        )
        let json = String(decoding: try BackupMapper.encode(file), as: UTF8.self)

        for key in Self.forbiddenKeys {
            #expect(!json.contains("\"\(key)\""), "forbidden key \(key) leaked into backup JSON")
        }
        for sentinel in Self.sentinelValues {
            #expect(!json.contains(sentinel), "health sentinel value \(sentinel) leaked into backup JSON")
        }
    }

    @MainActor
    @Test func everyObjectLevelStaysWithinDocumentedKeySets() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let file = BackupMapper.file(
            workouts: [workout], batches: [], exerciseNames: [workout.exercises[0].exerciseID: "Landmine Press"],
            preferences: [:], userID: userID, appVersion: nil
        )
        let data = try BackupMapper.encode(file)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        func check(_ object: [String: Any], level: String) {
            let allowed = Self.allowedKeys[level]!
            for key in object.keys {
                #expect(allowed.contains(key), "undocumented key '\(key)' at level '\(level)'")
            }
        }
        check(root, level: "file")
        let workouts = try #require(root["workouts"] as? [[String: Any]])
        for workoutObject in workouts {
            check(workoutObject, level: "workout")
            for exercise in workoutObject["exercises"] as? [[String: Any]] ?? [] {
                check(exercise, level: "exercise")
                for set in exercise["sets"] as? [[String: Any]] ?? [] { check(set, level: "set") }
            }
            for session in workoutObject["cardioSessions"] as? [[String: Any]] ?? [] {
                check(session, level: "session")
                for split in session["splits"] as? [[String: Any]] ?? [] { check(split, level: "split") }
                for point in session["routePoints"] as? [[String: Any]] ?? [] { check(point, level: "point") }
            }
        }
    }

    @MainActor
    @Test func roundTripPreservesEveryUserAuthoredField() throws {
        let userID = UUID()
        let original = maximallyPopulatedWorkout(userID: userID)
        let file = BackupMapper.file(
            workouts: [original], batches: [], exerciseNames: [:],
            preferences: [:], userID: userID, appVersion: nil
        )
        let decoded = try BackupMapper.decode(try BackupMapper.encode(file))
        let restored = BackupMapper.workoutModel(from: try #require(decoded.workouts.first), userID: userID)

        let workout = restored.workout
        #expect(workout.id == original.id)
        #expect(workout.routineID == original.routineID)
        #expect(workout.title == original.title)
        #expect(abs(workout.startedAt.timeIntervalSince(original.startedAt)) < 1)
        #expect(workout.notes == original.notes)
        #expect(workout.externalSource == original.externalSource)
        #expect(workout.externalWorkoutID == original.externalWorkoutID)
        #expect(workout.importFingerprint == original.importFingerprint)
        #expect(workout.xpAwardedAmount == original.xpAwardedAmount)
        // Health fields start empty on the restored model.
        #expect(workout.avgHR == nil)
        #expect(workout.maxHR == nil)
        #expect(workout.activeEnergyKcal == nil)
        #expect(workout.hrZoneSeconds.isEmpty)
        #expect(workout.readinessAtStart == nil)
        #expect(workout.hkWorkoutUUID == nil)

        let set = try #require(restored.sets.first)
        let originalSet = original.exercises[0].sets[0]
        #expect(set.id == originalSet.id)
        #expect(set.setTypeRaw == originalSet.setTypeRaw)
        #expect(set.weightModeRaw == originalSet.weightModeRaw)
        #expect(set.reps == originalSet.reps)
        #expect(set.weight == originalSet.weight)
        #expect(set.rpe == originalSet.rpe)
        #expect(set.rir == originalSet.rir)
        #expect(set.holdSeconds == originalSet.holdSeconds)
        #expect(set.partialReps == originalSet.partialReps)
        #expect(set.addedWeight == originalSet.addedWeight)
        #expect(set.assistanceWeight == originalSet.assistanceWeight)
        #expect(set.isUnilateral == originalSet.isUnilateral)
        #expect(set.implementWeight == originalSet.implementWeight)
        #expect(set.limbCount == originalSet.limbCount)
        #expect(set.isEccentric == originalSet.isEccentric)
        #expect(set.isPaused == originalSet.isPaused)
        #expect(set.machineSettingsJSON == originalSet.machineSettingsJSON)
        #expect(set.miniRepsJSON == originalSet.miniRepsJSON)
        #expect(set.side2Reps == originalSet.side2Reps)
        #expect(set.side2MiniRepsJSON == originalSet.side2MiniRepsJSON)
        #expect(set.plannedMiniSetCount == originalSet.plannedMiniSetCount)
        #expect(set.plannedMiniRepsJSON == originalSet.plannedMiniRepsJSON)
        #expect(set.bodyweightKg == nil)

        let session = try #require(restored.sessions.first)
        let originalSession = original.cardioSessions[0]
        #expect(session.id == originalSession.id)
        #expect(session.modality == originalSession.modality)
        #expect(session.distanceMeters == originalSession.distanceMeters)
        #expect(session.effort == originalSession.effort)
        #expect(session.avgPaceSecondsPerKm == originalSession.avgPaceSecondsPerKm)
        #expect(session.split500mSeconds == originalSession.split500mSeconds)
        #expect(session.strokeRate == originalSession.strokeRate)
        #expect(session.avgPowerWatts == originalSession.avgPowerWatts)
        #expect(session.avgCadence == originalSession.avgCadence)
        #expect(session.resistanceLevel == originalSession.resistanceLevel)
        #expect(session.inclinePercent == originalSession.inclinePercent)
        #expect(session.elevationGainMeters == originalSession.elevationGainMeters)
        #expect(session.poolLengthMeters == originalSession.poolLengthMeters)
        #expect(session.lengthsCompleted == originalSession.lengthsCompleted)
        #expect(session.totalStrokes == originalSession.totalStrokes)
        #expect(session.strokeStyleRaw == originalSession.strokeStyleRaw)
        #expect(session.intervalsAutoApplied == originalSession.intervalsAutoApplied)
        #expect(session.avgHR == nil)
        #expect(session.tss == nil)
        #expect(session.sampleSeriesJSON == nil)
        #expect(session.hrZoneSeconds.isEmpty)

        #expect(restored.splits.count == 1)
        #expect(restored.splits[0].label == "Work 1")
        #expect(restored.points.count == 1)
        // 6-decimal rounding: within ~11 cm of the original coordinate.
        #expect(abs(restored.points[0].latitude - (-36.8484597123)) < 0.000001)
    }

    /// Swim fields are additive within schema v1: a backup written before
    /// they existed must keep decoding, with the new fields nil. This is the
    /// test that lets `currentSchemaVersion` stay at 1.
    @Test func preSwimV1BackupDecodesWithNilSwimFields() throws {
        let json = """
        {"schemaVersion":1,"exportedAt":"2026-01-05T10:00:00Z",
         "userID":"11111111-1111-1111-1111-111111111111","preferences":{},"importBatches":[],
         "workouts":[{"id":"22222222-2222-2222-2222-222222222222","startedAt":"2026-01-05T09:00:00Z",
           "createdAt":"2026-01-05T09:00:00Z","updatedAt":"2026-01-05T10:00:00Z","exercises":[],
           "cardioSessions":[{"id":"33333333-3333-3333-3333-333333333333","modality":"row",
             "startedAt":"2026-01-05T09:00:00Z","split500mSeconds":118.5,"strokeRate":26,
             "intervalsAutoApplied":false,"createdAt":"2026-01-05T09:00:00Z",
             "updatedAt":"2026-01-05T10:00:00Z","splits":[],"routePoints":[]}]}]}
        """
        let decoded = try BackupMapper.decode(Data(json.utf8))
        let session = try #require(decoded.workouts.first?.cardioSessions.first)
        #expect(session.split500mSeconds == 118.5)
        #expect(session.strokeRate == 26)
        #expect(session.poolLengthMeters == nil)
        #expect(session.lengthsCompleted == nil)
        #expect(session.totalStrokes == nil)
        #expect(session.strokeStyleRaw == nil)
    }

    @MainActor
    @Test func preferencesRoundTripAllScalarKinds() throws {
        let file = ForgeFitBackupFile(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userID: UUID(),
            preferences: [
                "aString": .string("lb"),
                "anInt": .int(3),
                "aDouble": .double(2.5),
                "aBool": .bool(true),
            ]
        )
        let decoded = try BackupMapper.decode(try BackupMapper.encode(file))
        #expect(decoded.preferences["aString"] == .string("lb"))
        #expect(decoded.preferences["anInt"] == .int(3))
        #expect(decoded.preferences["aDouble"] == .double(2.5))
        #expect(decoded.preferences["aBool"] == .bool(true))
    }
}
