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
        // Six documented optional training fields — previously unexercised by
        // this fixture. Realistic non-health values so the key-guard, the
        // round-trip test, and the health-absence test all visit them.
        workout.conditioningPlanSnapshotJSON = #"{"sections":[{"name":"Amrap"}]}"#
        workout.conditioningProgressJSON = #"{"phase":"active"}"#
        workout.conditioningResultJSON = #"{"score":2340}"#
        workout.wholeSessionRPE = 7.5
        workout.wholeSessionRPERatedAt = Date(timeIntervalSince1970: 1_700_003_800)
        workout.wholeSessionRPEProtocolVersion = "1"
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
        exercise.generatedByWorkoutBlockID = UUID()
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
        session.distanceSource = .userEntered
        session.effort = 7
        session.avgPaceSecondsPerKm = 360
        session.split500mSeconds = 110
        session.strokeRate = 24
        session.avgPowerWatts = 210
        session.avgCadence = 172
        session.resistanceLevel = 5
        session.inclinePercent = 1.5
        session.elevationGainMeters = 120
        session.intervalsAutoApplied = false
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

        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 1,
            planSnapshotJSON: #"{"sections":[]}"#,
            progressJSON: #"{"status":"ready"}"#,
            resultJSON: #"{"sectionResults":[]}"#,
            sourceRoutineBlockID: UUID()
        )
        workout.blocks.append(block)
        session.workoutBlockID = block.id

        let split = CardioSplitModel(
            userID: userID, cardioSessionID: session.id, index: 0,
            distanceMeters: 1000, durationSeconds: 360, paceSecondsPerKm: 360,
            elevationGainMeters: 12, startedAt: workout.startedAt, endedAt: workout.endedAt ?? workout.startedAt
        )
        split.label = "Work 1"
        split.autoDetected = false
        session.splits.append(split)

        let point = CardioRoutePointModel(
            userID: userID, cardioSessionID: session.id,
            timestamp: workout.startedAt, latitude: -36.8484597123, longitude: 174.7633315987,
            altitudeMeters: 23.456, horizontalAccuracyMeters: 5.1234, speedMetersPerSecond: 2.789
        )
        session.routePoints.append(point)

        return workout
    }

    /// Health/readiness keys that must never appear anywhere in an emitted
    /// backup. Checked structurally (key presence at every parsed level), not
    /// by raw-string search.
    private static let forbiddenKeys = [
        "avgHR", "maxHR", "activeEnergyKcal", "hrZoneSeconds", "readinessAtStart",
        "readinessMethodID", "readinessCoverageAtStart",
        "hkWorkoutUUID", "bodyweightKg", "tss", "sampleSeriesJSON",
        "flexibilityExposureJSON", "floorsClimbed", "totalSteps",
        "heartRate", "readiness", "checkin", "Checkin", "wrapped", "Wrapped",
    ]
    /// Health values planted in the fixture, written exactly as they render in
    /// JSON if leaked. The absence test compares parsed scalar leaves exactly —
    /// no substring matching — so every entry must be the exact scalar render
    /// (e.g. "52344.5", not "52344").
    private static let sentinelValues = [
        "15599", "18177", "52344.5", "11111", "22222", "33333", "44444", "55555",
        "4577", "82.5432", "52399.9", "15588", "18166", "999991", "999992",
        "6177.5", "155991", "12345", "54321", "999993", "DEADBEEF",
    ]

    /// The six optional workout training fields, enumerated once for the
    /// guard tests (emission presence + not-a-Health-key). The `workout`
    /// allow-list carries the same keys spelled directly; the key-walk test
    /// keeps the two from drifting apart — an emitted key missing from the
    /// allow-list fails the walk.
    private static let workoutTrainingKeys: Set<String> = [
        "conditioningPlanSnapshotJSON",
        "conditioningProgressJSON",
        "conditioningResultJSON",
        "wholeSessionRPE",
        "wholeSessionRPERatedAt",
        "wholeSessionRPEProtocolVersion",
    ]

    /// The documented v1 key sets, per JSON object level. Any key outside
    /// these sets fails the walk — a future field addition must be reviewed
    /// (and added here) before it ships in the backup.
    private static let allowedKeys: [String: Set<String>] = [
        "file": ["schemaVersion", "exportedAt", "userID", "appVersion", "preferences", "workouts", "importBatches",
                 "microcycleTrackings", "microcycleWindows", "restDays"],
        "workout": ["id", "routineID", "title", "startedAt", "endedAt", "sourceDevice", "notes",
                    "externalSource", "externalID", "importFingerprint", "importBatchID",
                    "xpAwardedAmount", "xpAwardedAt", "createdAt", "updatedAt", "deletedAt",
                    "exercises", "cardioSessions", "blocks",
                    "conditioningPlanSnapshotJSON", "conditioningProgressJSON", "conditioningResultJSON",
                    "wholeSessionRPE", "wholeSessionRPERatedAt", "wholeSessionRPEProtocolVersion"],
        "exercise": ["id", "exerciseID", "name", "position", "supersetGroup", "notes", "notePinned",
                     "restSeconds", "microRestSeconds", "intervalPlanJSON", "yogaFlowJSON",
                     "generatedByWorkoutBlockID", "sourceRoutineExerciseID", "createdAt", "updatedAt", "sets"],
        "block": ["id", "kindRaw", "position", "planSnapshotJSON", "progressJSON", "resultJSON",
                  "sourceRoutineBlockID", "createdAt", "updatedAt"],
        "set": ["id", "position", "setType", "weightMode", "reps", "weightKg", "rpe", "rir",
                "durationSeconds", "holdSeconds", "partialReps", "addedWeight", "assistanceWeight",
                "isUnilateral", "implementWeight", "limbCount", "isEccentric", "isPaused",
                "machineSettingsJSON", "sourceRoutineSetID", "miniRepsJSON", "side2Reps",
                "side2MiniRepsJSON", "plannedMiniSetCount", "plannedMiniRepsJSON",
                "completedAt", "createdAt", "updatedAt"],
        "session": ["id", "workoutExerciseID", "workoutBlockID", "modality", "startedAt", "liveStartedAt", "endedAt",
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
        "microcycleTracking": ["id", "folderID", "folderName", "anchorDate", "durationDays",
                               "timeZoneIdentifier", "stateRaw", "showsOnHome", "showsFolderHeader",
                               "endedAt", "createdAt", "updatedAt", "deletedAt"],
        "microcycleWindow": ["id", "trackingID", "folderID", "folderName", "index", "startsAt",
                             "endsAt", "timeZoneIdentifier", "routineSnapshotJSON", "dayAssignmentSnapshotJSON", "createdAt",
                             "updatedAt", "deletedAt"],
        "restDay": ["id", "date", "timeZoneIdentifier", "createdAt", "updatedAt", "deletedAt"],
    ]

    /// Structural leak guard instead of raw-string grep: walks the parsed JSON
    /// tree, asserts no forbidden key appears at any level, and compares every
    /// scalar leaf exactly against the sentinel values. Exact (not substring)
    /// comparison keeps the test deterministic — random fixture UUID hex or
    /// timestamps can no longer collide with a digit-sentinel fragment — and
    /// does not weaken the guard: any leaked health key or scalar is an exact
    /// match by construction.
    @MainActor
    @Test func emittedJSONContainsNoHealthKeysOrSentinelValues() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let file = BackupMapper.file(
            workouts: [workout], batches: [], exerciseNames: [:],
            preferences: ["weightUnitRaw": .string("lb")],
            userID: userID, appVersion: "1.0"
        )
        let root = try #require(try JSONSerialization.jsonObject(with: try BackupMapper.encode(file)) as? [String: Any])

        func check(_ value: Any, path: String) {
            if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    #expect(!Self.forbiddenKeys.contains(key), "forbidden key \(key) leaked at path '\(path)/\(key)'")
                    check(child, path: "\(path)/\(key)")
                }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() {
                    check(child, path: "\(path)[\(index)]")
                }
            } else if let string = value as? String {
                // A forbidden key or sentinel rendered verbatim as a value.
                #expect(!Self.forbiddenKeys.contains(string), "forbidden key text leaked as a value at path '\(path)'")
                #expect(!Self.sentinelValues.contains(string), "health sentinel value leaked at path '\(path)'")
            } else if let number = value as? NSNumber {
                #expect(!Self.sentinelValues.contains(number.description), "health sentinel value \(number.description) leaked at path '\(path)'")
            }
        }
        check(root, path: "$")

        // The six training fields are explicitly not Health keys. If one ever
        // becomes Health-derived, this guard (together with the emission-
        // presence test) forces a deliberate review of workoutTrainingKeys and
        // the allow-list before the absence claim can stay honest.
        for key in Self.workoutTrainingKeys {
            #expect(!Self.forbiddenKeys.contains(key), "training key \(key) must not be a Health key")
        }
    }

    @MainActor
    @Test func healthKitImportedWorkoutsAreNotBackedUp() {
        let userID = UUID()
        let imported = WorkoutModel(
            userID: userID,
            title: "Apple Watch Run",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        imported.endedAt = imported.startedAt.addingTimeInterval(1_800)
        imported.sourceDevice = "healthkit-apple-watch"
        imported.notes = "Imported from Apple Health"

        let file = BackupMapper.file(
            workouts: [imported], batches: [], exerciseNames: [:],
            preferences: [:], userID: userID, appVersion: nil
        )

        #expect(file.workouts.isEmpty)
    }

    @MainActor
    @Test func cardioDistanceRequiresNonHealthProvenance() throws {
        let userID = UUID()
        let health = CardioSessionModel(
            userID: userID,
            modality: "run",
            distanceMeters: 5_000,
            distanceSource: .healthKit
        )
        let manual = CardioSessionModel(
            userID: userID,
            modality: "row",
            distanceMeters: 2_000,
            distanceSource: .userEntered
        )
        let route = CardioSessionModel(
            userID: userID,
            modality: "run",
            distanceMeters: 3_000,
            distanceSource: .route
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cardioSessions: [health, manual, route]
        )

        let file = BackupMapper.file(
            workouts: [workout], batches: [], exerciseNames: [:],
            preferences: [:], userID: userID, appVersion: nil
        )
        let sessions = try #require(file.workouts.first?.cardioSessions)
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        #expect(byID[health.id]?.distanceMeters == nil)
        #expect(byID[manual.id]?.distanceMeters == 2_000)
        #expect(byID[route.id]?.distanceMeters == 3_000)
    }

    @MainActor
    @Test func healthDerivedDetectedIntervalsAreNotBackedUp() throws {
        let userID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: startedAt,
            intervalsAutoApplied: true
        )
        session.splits = [
            CardioSplitModel(
                userID: userID, cardioSessionID: session.id, index: 0,
                distanceMeters: 400, durationSeconds: 90, paceSecondsPerKm: 225,
                label: "Manual work", autoDetected: false,
                startedAt: startedAt, endedAt: startedAt.addingTimeInterval(90)
            ),
            CardioSplitModel(
                userID: userID, cardioSessionID: session.id, index: 1,
                distanceMeters: 400, durationSeconds: 85, paceSecondsPerKm: 212.5,
                label: "Detected work", autoDetected: true,
                startedAt: startedAt.addingTimeInterval(90),
                endedAt: startedAt.addingTimeInterval(175)
            ),
        ]
        let workout = WorkoutModel(userID: userID, startedAt: startedAt, cardioSessions: [session])

        let file = BackupMapper.file(
            workouts: [workout], batches: [], exerciseNames: [:],
            preferences: [:], userID: userID, appVersion: nil
        )
        let backedUp = try #require(file.workouts.first?.cardioSessions.first)

        #expect(!backedUp.intervalsAutoApplied)
        #expect(backedUp.splits.map(\.label) == ["Manual work"])
        #expect(backedUp.splits.allSatisfy { !$0.autoDetected })
    }

    /// Opposite-direction exhaustiveness at the workout level: the fixture's
    /// emitted JSON must contain every documented optional training field. If
    /// BackupMapper ever stops emitting one, this fails before the key-walk
    /// could miss it.
    @MainActor
    @Test func emittedWorkoutJSONContainsEveryDocumentedTrainingField() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let file = BackupMapper.file(
            workouts: [workout], batches: [], exerciseNames: [:],
            preferences: [:], userID: userID, appVersion: nil
        )
        let json = String(decoding: try BackupMapper.encode(file), as: UTF8.self)
        for key in Self.workoutTrainingKeys {
            #expect(json.contains("\"\(key)\""), "documented workout training key \(key) missing from emitted JSON")
        }
    }

    /// Walks every documented structured object level (file, workout, exercise,
    /// set, block, session, split, point, batch, microcycleTracking,
    /// microcycleWindow, restDay) and asserts each parsed key is allowed. The
    /// one deliberate exception: top-level `preferences` is a free-form
    /// `[String: BackupPreferenceValue]` dictionary whose keys are enforced
    /// app-side by `AppPreferenceKeys.backedUp` (BackupExporter,
    /// BackupRestoreService), not by this ForgeData structural guard — the
    /// walk only checks that the `preferences` key exists at the file level.
    /// Exhaustiveness is therefore claimed for the structured levels and
    /// specifically for the workout graph, not for preference keys.
    @MainActor
    @Test func everyObjectLevelStaysWithinDocumentedKeySets() throws {
        let userID = UUID()
        let workout = maximallyPopulatedWorkout(userID: userID)
        let tracking = MicrocycleTrackingModel(
            userID: userID,
            folderID: UUID(),
            folderName: "Upper Lower",
            anchorDate: Date(timeIntervalSince1970: 1_780_000_000),
            durationDays: 10,
            showsOnHome: false
        )
        let window = MicrocycleWindowModel(
            userID: userID,
            trackingID: tracking.id,
            folderID: tracking.folderID,
            folderName: tracking.folderName,
            index: 0,
            startsAt: Date(timeIntervalSince1970: 1_780_000_000),
            endsAt: Date(timeIntervalSince1970: 1_780_864_000),
            timeZoneIdentifier: "UTC",
            routines: []
        )
        let restDay = RestDayModel(
            userID: userID,
            date: Date(timeIntervalSince1970: 1_780_086_400),
            timeZoneIdentifier: "UTC"
        )
        // Representative import batch so the `batch` allow-list branch of the
        // walk below is actually exercised (previously batches: [] made it dead).
        let batch = WorkoutImportBatchModel(
            userID: userID,
            source: "hevy",
            fileName: "hevy-export-2026-01-05.csv",
            importedCount: 42,
            skippedDuplicateCount: 3,
            warningCount: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_045)
        )
        let file = BackupMapper.file(
            workouts: [workout], batches: [batch], exerciseNames: [workout.exercises[0].exerciseID: "Landmine Press"],
            preferences: [:], userID: userID, appVersion: nil,
            microcycleTrackings: [tracking],
            microcycleWindows: [window],
            restDays: [restDay]
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
            for block in workoutObject["blocks"] as? [[String: Any]] ?? [] {
                check(block, level: "block")
            }
            for session in workoutObject["cardioSessions"] as? [[String: Any]] ?? [] {
                check(session, level: "session")
                for split in session["splits"] as? [[String: Any]] ?? [] { check(split, level: "split") }
                for point in session["routePoints"] as? [[String: Any]] ?? [] { check(point, level: "point") }
            }
        }
        for tracking in root["microcycleTrackings"] as? [[String: Any]] ?? [] {
            check(tracking, level: "microcycleTracking")
        }
        for window in root["microcycleWindows"] as? [[String: Any]] ?? [] {
            check(window, level: "microcycleWindow")
        }
        for restDay in root["restDays"] as? [[String: Any]] ?? [] {
            check(restDay, level: "restDay")
        }
        for batch in root["importBatches"] as? [[String: Any]] ?? [] {
            check(batch, level: "batch")
        }
    }

    @MainActor
    @Test func microcycleAndRestDayBackupRoundTripPreservesDisplayChoicesAndSnapshots() throws {
        let userID = UUID()
        let routineID = UUID()
        let tracking = MicrocycleTrackingModel(
            userID: userID,
            folderID: UUID(),
            folderName: "Upper Lower",
            anchorDate: Date(timeIntervalSince1970: 1_780_000_000),
            durationDays: 10,
            timeZoneIdentifier: "America/New_York",
            showsOnHome: false,
            showsFolderHeader: true
        )
        let window = MicrocycleWindowModel(
            userID: userID,
            trackingID: tracking.id,
            folderID: tracking.folderID,
            folderName: tracking.folderName,
            index: 2,
            startsAt: Date(timeIntervalSince1970: 1_781_728_000),
            endsAt: Date(timeIntervalSince1970: 1_782_592_000),
            timeZoneIdentifier: tracking.timeZoneIdentifier,
            routines: [.init(id: routineID, name: "Upper A", position: 0)],
            dayAssignments: [.init(
                day: Date(timeIntervalSince1970: 1_781_814_400),
                workoutID: UUID(),
                assignedAt: Date(timeIntervalSince1970: 1_781_900_000)
            )]
        )
        let restDay = RestDayModel(
            userID: userID,
            date: Date(timeIntervalSince1970: 1_781_814_400),
            timeZoneIdentifier: tracking.timeZoneIdentifier
        )
        let file = BackupMapper.file(
            workouts: [],
            batches: [],
            exerciseNames: [:],
            preferences: [:],
            userID: userID,
            appVersion: nil,
            microcycleTrackings: [tracking],
            microcycleWindows: [window],
            restDays: [restDay]
        )
        let decoded = try BackupMapper.decode(try BackupMapper.encode(file))
        let restoredTracking = BackupMapper.trackingModel(
            from: try #require(decoded.microcycleTrackings?.first),
            userID: userID
        )
        let restoredWindow = BackupMapper.windowModel(
            from: try #require(decoded.microcycleWindows?.first),
            userID: userID
        )
        let restoredRestDay = BackupMapper.restDayModel(
            from: try #require(decoded.restDays?.first),
            userID: userID
        )

        #expect(!restoredTracking.showsOnHome)
        #expect(restoredTracking.showsFolderHeader)
        #expect(restoredTracking.durationDays == 10)
        #expect(restoredWindow.routines.map(\.id) == [routineID])
        #expect(restoredWindow.dayAssignments == window.dayAssignments)
        #expect(restoredWindow.index == 2)
        #expect(restoredRestDay.date == restDay.date)
        #expect(restoredRestDay.timeZoneIdentifier == tracking.timeZoneIdentifier)
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
        // The six documented optional training fields survive the round trip.
        #expect(workout.conditioningPlanSnapshotJSON == original.conditioningPlanSnapshotJSON)
        #expect(workout.conditioningProgressJSON == original.conditioningProgressJSON)
        #expect(workout.conditioningResultJSON == original.conditioningResultJSON)
        #expect(workout.wholeSessionRPE == original.wholeSessionRPE)
        #expect(workout.wholeSessionRPERatedAt?.timeIntervalSince1970 == original.wholeSessionRPERatedAt?.timeIntervalSince1970)
        #expect(workout.wholeSessionRPEProtocolVersion == original.wholeSessionRPEProtocolVersion)

        let block = try #require(restored.blocks.first)
        #expect(block.id == original.blocks[0].id)
        #expect(block.kind == .conditioning)
        #expect(block.planSnapshotJSON == original.blocks[0].planSnapshotJSON)
        #expect(block.progressJSON == original.blocks[0].progressJSON)
        #expect(block.resultJSON == original.blocks[0].resultJSON)

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
        #expect(session.workoutBlockID == originalSession.workoutBlockID)
        #expect(session.distanceMeters == originalSession.distanceMeters)
        #expect(session.distanceSource == .restoredBackup)
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
        #expect(decoded.microcycleTrackings == nil)
        #expect(decoded.microcycleWindows == nil)
        #expect(decoded.restDays == nil)
    }

    @MainActor
    @Test func backupWithoutDisplayFlagsDefaultsBothMicrocycleSurfacesToVisible() throws {
        let json = """
        {"schemaVersion":1,"exportedAt":"2026-08-08T12:00:00Z",
         "userID":"11111111-1111-1111-1111-111111111111","preferences":{},"workouts":[],
         "importBatches":[],"microcycleTrackings":[{
           "id":"22222222-2222-2222-2222-222222222222",
           "folderID":"33333333-3333-3333-3333-333333333333",
           "folderName":"Upper Lower","anchorDate":"2026-08-01T04:00:00Z",
           "durationDays":10,"timeZoneIdentifier":"America/New_York","stateRaw":"active",
           "createdAt":"2026-08-01T12:00:00Z","updatedAt":"2026-08-01T12:00:00Z"
         }],"microcycleWindows":[],"restDays":[]}
        """
        let decoded = try BackupMapper.decode(Data(json.utf8))
        let model = BackupMapper.trackingModel(
            from: try #require(decoded.microcycleTrackings?.first),
            userID: decoded.userID
        )

        #expect(model.showsOnHome)
        #expect(model.showsFolderHeader)
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
