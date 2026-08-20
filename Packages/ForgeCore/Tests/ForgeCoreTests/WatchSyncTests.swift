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
                                completed: true,
                                setTypeRaw: SetType.myoRep.rawValue,
                                weightModeRaw: WeightMode.bodyweightAdded.rawValue,
                                durationSeconds: 60,
                                isUnilateral: true,
                                miniReps: [3, 3, 2],
                                side2Reps: 5,
                                side2MiniReps: [3, 2],
                                plannedMiniSetCount: 4,
                                plannedMiniReps: [3, 3, 3, 3],
                                microRestSeconds: 15
                            )
                        ]
                    )
                ],
                restEndsAt: restEndsAt,
                restTotalSeconds: 120,
                restIsMicro: true,
                restLabel: "Mini-set 4",
                restOwnerID: setID,
                intervalStepName: "Work 1/6",
                intervalStepEndsAt: intervalEndsAt,
                intervalStepKind: "work",
                intervalNextName: "Recover 1/5",
                intervalRound: "Round 1 of 6",
                hrZoneTarget: 4
            ),
            routines: [WatchRoutineSummary(
                id: routineID,
                name: "Push",
                exerciseCount: 4,
                alternatingPartnerName: "Pull",
                isNextInAlternation: true
            )],
            readiness: 82,
            readinessAction: "Train as planned",
            readinessDetail: "Train as planned.",
            unitSuffix: "lb",
            updatedAt: updatedAt
        )

        let data = try #require(WatchWire.encode(original))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))

        #expect(decoded == original)
        #expect(decoded.workout?.completedSets == 1)
        #expect(decoded.workout?.totalSets == 1)
        #expect(decoded.readinessAction == "Train as planned")
        #expect(decoded.routines.first?.alternatingPartnerName == "Pull")
        #expect(decoded.routines.first?.isNextInAlternation == true)
        let decodedSet = try #require(decoded.workout?.exercises.first?.sets.first)
        #expect(decodedSet.setType == .myoRep)
        #expect(decodedSet.weightMode == .bodyweightAdded)
        #expect(decodedSet.isStructured)
        #expect(decodedSet.structuredProgress.miniReps == [3, 3, 2])
        #expect(decoded.workout?.restOwnerID == setID)
    }

    @Test func legacyRoutineSummaryWithoutAlternationFieldsStillDecodes() throws {
        let routineID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let data = Data(
            "{\"id\":\"\(routineID.uuidString)\",\"name\":\"Push\",\"exerciseCount\":4}".utf8
        )

        let decoded = try #require(WatchWire.decode(WatchRoutineSummary.self, from: data))

        #expect(decoded.id == routineID)
        #expect(decoded.alternatingPartnerName == nil)
        #expect(decoded.isNextInAlternation == nil)
    }

    @Test func watchCommandsRoundTripAllPayloadShapes() throws {
        let routineID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let setID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let cardioID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let blockID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let workoutID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let metrics = WatchLiveMetrics(
            workoutID: workoutID,
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
        let progress = WatchStructuredSetProgress(
            activationReps: 12,
            miniReps: [3, 3],
            side2ActivationReps: 11,
            side2MiniReps: [3]
        )
        let structuredUpdate = WatchStructuredSetUpdate(
            progress: progress,
            event: .miniSet,
            side: 2,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_350),
            weightKg: 42.5
        )
        try expectCommand(.updateStructuredSet(setID: setID, update: structuredUpdate)) {
            guard case .updateStructuredSet(let decodedID, let update) = $0 else { return false }
            return decodedID == setID && update == structuredUpdate
        }
        let timerEnd = Date(timeIntervalSince1970: 1_800_000_410)
        try expectCommand(.startSetTimer(setID: setID, durationSeconds: 60, endsAt: timerEnd)) {
            guard case .startSetTimer(let decodedID, let seconds, let endsAt) = $0 else { return false }
            return decodedID == setID && seconds == 60 && endsAt == timerEnd
        }
        try expectCommand(.stopSetTimer(setID: setID, elapsedSeconds: 41)) {
            guard case .stopSetTimer(let decodedID, let seconds) = $0 else { return false }
            return decodedID == setID && seconds == 41
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
        let conditioningEvent = ConditioningProgressEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_500),
            action: .completeRound
        )
        try expectCommand(.conditioningEvent(conditioningEvent)) {
            guard case .conditioningEvent(let decodedEvent) = $0 else { return false }
            return decodedEvent == conditioningEvent
        }
        try expectCommand(.conditioningBlockEvent(blockID: blockID, event: conditioningEvent)) {
            guard case .conditioningBlockEvent(let decodedID, let decodedEvent) = $0 else { return false }
            return decodedID == blockID && decodedEvent == conditioningEvent
        }
        try expectCommand(.finishWorkout(workoutID: workoutID, metrics: metrics, savedToHealth: true)) {
            guard case .finishWorkout(let decodedID, let decodedMetrics, let savedToHealth) = $0 else { return false }
            return decodedID == workoutID && decodedMetrics == metrics && savedToHealth
        }
        try expectCommand(.discardWorkout(workoutID: workoutID)) {
            guard case .discardWorkout(let decodedID) = $0 else { return false }
            return decodedID == workoutID
        }
        // The optional identity round-trips as nil too — the form a legacy
        // payload decodes into and the shape phone→watch sends without a
        // target workout carry.
        try expectCommand(.finishWorkout(workoutID: nil, metrics: nil, savedToHealth: false)) {
            guard case .finishWorkout(let decodedID, let decodedMetrics, let savedToHealth) = $0 else { return false }
            return decodedID == nil && decodedMetrics == nil && !savedToHealth
        }
        try expectCommand(.discardWorkout(workoutID: nil)) {
            guard case .discardWorkout(let decodedID) = $0 else { return false }
            return decodedID == nil
        }
        try expectCommand(.workoutFinished) {
            guard case .workoutFinished = $0 else { return false }
            return true
        }
    }

    @Test func everySetTypeHasTheCorrectWatchExecutionShape() {
        for type in SetType.allCases {
            let set = WatchSetSnapshot(id: UUID(), label: "", setTypeRaw: type.rawValue)
            #expect(set.isStructured == [.myoRep, .restPause, .cluster].contains(type))
            #expect(set.isAMRAP == (type == .amrap))
        }

        #expect(SetType.myoRep.defaultMicroRestSeconds == 15)
        #expect(SetType.restPause.defaultMicroRestSeconds == 20)
        #expect(SetType.cluster.defaultMicroRestSeconds == 20)
        #expect(SetType.drop.defaultRestSeconds == nil)
    }

    @Test func structuredProgressKeepsBothSidesIndependent() {
        var progress = WatchStructuredSetProgress()
        progress.setActivation(12, for: 1)
        progress.setMinis([3, 3], for: 1)
        progress.setActivation(11, for: 2)
        progress.setMinis([3, 2], for: 2)

        #expect(progress.activation(for: 1) == 12)
        #expect(progress.minis(for: 1) == [3, 3])
        #expect(progress.activation(for: 2) == 11)
        #expect(progress.minis(for: 2) == [3, 2])
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

    @Test func idleWidgetSnapshotExpiresAtCalendarDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let late = Date(timeIntervalSince1970: 1_800_057_540)
        let sameDay = late.addingTimeInterval(30)
        let nextDay = try #require(calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: late)
        ))

        let idle = ForgeFitWidgetSnapshot(
            mode: .idle,
            updatedAt: late,
            readinessScore: 74
        )
        let workout = ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            updatedAt: late,
            workoutTitle: "Legs"
        )

        #expect(idle.isCurrent(at: sameDay, calendar: calendar))
        #expect(!idle.isCurrent(at: nextDay, calendar: calendar))
        #expect(workout.isCurrent(at: nextDay, calendar: calendar))
    }

    @Test func complicationDeliverySignatureChangesForNewDayAndNewReadiness() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let dayOne = calendar.startOfDay(
            for: Date(timeIntervalSince1970: 1_800_057_540)
        ).addingTimeInterval(12 * 60 * 60)
        let dayTwo = try #require(calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: dayOne)
        ))

        let first = try #require(WatchComplicationDeliverySignature(
            context: WatchAppContext(
                readiness: 62,
                readinessAction: "Recover",
                updatedAt: dayOne
            ),
            calendar: calendar
        ))
        let duplicate = try #require(WatchComplicationDeliverySignature(
            context: WatchAppContext(
                readiness: 62,
                readinessAction: "Recover",
                updatedAt: dayOne.addingTimeInterval(60)
            ),
            calendar: calendar
        ))
        let clearedNextDay = try #require(WatchComplicationDeliverySignature(
            context: WatchAppContext(updatedAt: dayTwo),
            calendar: calendar
        ))
        let freshNextDay = try #require(WatchComplicationDeliverySignature(
            context: WatchAppContext(
                readiness: 78,
                readinessAction: "Train",
                updatedAt: dayTwo.addingTimeInterval(60)
            ),
            calendar: calendar
        ))
        let workout = WatchComplicationDeliverySignature(
            context: WatchAppContext(
                workout: WatchWorkoutSnapshot(
                    workoutID: UUID(),
                    title: "Legs",
                    startedAt: dayTwo
                )
            ),
            calendar: calendar
        )

        #expect(first == duplicate)
        #expect(first != clearedNextDay)
        #expect(clearedNextDay != freshNextDay)
        #expect(workout == nil)
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

// MARK: - Live-metrics fallback channel (watch → phone, screen-off HR sync)

extension WatchSyncTests {
    /// `WatchWire.liveMetricsKey` carries the same `.liveMetrics` payload as
    /// `commandKey`, just through `updateApplicationContext` instead of
    /// `sendMessage`/`transferUserInfo` — it must be a distinct key (so a
    /// receiver can tell the two channels apart in one delegate callback) but
    /// decode with the exact same `WatchCommand` codec.
    @Test func liveMetricsKeyIsDistinctFromCommandAndContextKeys() {
        #expect(WatchWire.liveMetricsKey != WatchWire.commandKey)
        #expect(WatchWire.liveMetricsKey != WatchWire.contextKey)
    }

    @Test func liveMetricsPayloadRoundTripsUnderTheFallbackKey() throws {
        let workoutID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let metrics = WatchLiveMetrics(
            workoutID: workoutID,
            heartRate: 158,
            avgHR: 149,
            maxHR: 171,
            activeEnergyKcal: 410.2,
            distanceMeters: 3021.5,
            hrZoneSeconds: [5, 40, 90, 30, 0],
            asOf: Date(timeIntervalSince1970: 1_800_000_900)
        )
        let data = try #require(WatchWire.encode(WatchCommand.liveMetrics(metrics)))

        // Simulate the application-context payload dictionary a receiver sees
        // in `session(_:didReceiveApplicationContext:)`.
        let payload: [String: Any] = [WatchWire.liveMetricsKey: data]

        let roundTripped = try #require(payload[WatchWire.liveMetricsKey] as? Data)
        let decoded = try #require(WatchWire.decode(WatchCommand.self, from: roundTripped))
        guard case .liveMetrics(let decodedMetrics) = decoded else {
            Issue.record("expected .liveMetrics case")
            return
        }
        #expect(decodedMetrics == metrics)
    }

    @Test func legacyLiveMetricsWithoutWorkoutIdentityDecodeAsUnattributed() throws {
        let legacyJSON = """
        {"liveMetrics":{"_0":{"heartRate":158,"avgHR":149,"maxHR":171,"activeEnergyKcal":410.2,"distanceMeters":3021.5,"hrZoneSeconds":[5,40,90,30,0],"asOf":1800000900}}}
        """
        let decoded = try #require(
            WatchWire.decode(WatchCommand.self, from: Data(legacyJSON.utf8))
        )
        guard case .liveMetrics(let metrics) = decoded else {
            Issue.record("expected .liveMetrics case")
            return
        }
        #expect(metrics.workoutID == nil)
        #expect(metrics.heartRate == 158)
        #expect(!WatchLiveMetricsAttributionPolicy.mayApply(
            metricsWorkoutID: metrics.workoutID,
            activeWorkoutID: UUID()
        ))
    }

    @Test func liveHeartRateExpiresInsteadOfPresentingAFrozenReading() {
        let sampledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let metrics = WatchLiveMetrics(heartRate: 158, asOf: sampledAt)

        #expect(metrics.freshHeartRate(at: sampledAt.addingTimeInterval(14)) == 158)
        #expect(metrics.freshHeartRate(at: sampledAt.addingTimeInterval(16)) == nil)
    }
}

// MARK: - Recovered outdoor routes (FF-010)

extension WatchSyncTests {
    @Test func recoveredRouteStartsOnlyForAnActiveOutdoorSession() {
        #expect(WatchRouteCollectionPolicy.shouldStart(
            isOutdoor: true,
            isSessionActive: true,
            isAlreadyCollecting: false
        ))
        #expect(!WatchRouteCollectionPolicy.shouldStart(
            isOutdoor: false,
            isSessionActive: true,
            isAlreadyCollecting: false
        ))
        #expect(!WatchRouteCollectionPolicy.shouldStart(
            isOutdoor: true,
            isSessionActive: false,
            isAlreadyCollecting: false
        ))
        #expect(!WatchRouteCollectionPolicy.shouldStart(
            isOutdoor: true,
            isSessionActive: true,
            isAlreadyCollecting: true
        ))
    }

    @Test func recoveredRouteRejectsCachedOrInvalidLocations() {
        let resumedAt = Date(timeIntervalSince1970: 10_000)
        #expect(WatchRouteCollectionPolicy.shouldInsertLocation(
            timestamp: resumedAt,
            horizontalAccuracy: 5,
            segmentStartedAt: resumedAt
        ))
        #expect(!WatchRouteCollectionPolicy.shouldInsertLocation(
            timestamp: resumedAt.addingTimeInterval(-0.001),
            horizontalAccuracy: 5,
            segmentStartedAt: resumedAt
        ))
        #expect(!WatchRouteCollectionPolicy.shouldInsertLocation(
            timestamp: resumedAt.addingTimeInterval(1),
            horizontalAccuracy: -1,
            segmentStartedAt: resumedAt
        ))
        #expect(!WatchRouteCollectionPolicy.shouldInsertLocation(
            timestamp: resumedAt.addingTimeInterval(1),
            horizontalAccuracy: 101,
            segmentStartedAt: resumedAt
        ))
    }
}

// MARK: - Yoga mirroring

extension WatchSyncTests {
    @Test func workoutSnapshotRoundTripsConditioningBlockFields() throws {
        let blockID = UUID()
        let exerciseID = UUID()
        let movement = ConditioningMovement(exerciseID: exerciseID, targetValue: 10)
        let plan = ConditioningPlan(sections: [
            ConditioningSection(name: "Finisher", format: .amrap, durationSeconds: 600, movements: [movement])
        ])
        let progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(
                timestamp: Date(timeIntervalSinceReferenceDate: 1_000),
                action: .start
            ),
            to: ConditioningProgress(),
            plan: plan
        )
        let snapshot = WatchWorkoutSnapshot(
            workoutID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 900),
            exercises: [
                WatchExerciseSnapshot(
                    id: blockID,
                    position: 2,
                    name: "Conditioning",
                    isCardio: true,
                    workoutBlockKindRaw: "conditioning",
                    conditioningPlan: plan,
                    conditioningProgress: progress,
                    conditioningMovementNames: [exerciseID: "Burpee"]
                )
            ]
        )

        let data = try #require(WatchWire.encode(WatchAppContext(workout: snapshot)))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))
        let block = try #require(decoded.workout?.exercises.first)

        #expect(block.id == blockID)
        #expect(block.position == 2)
        #expect(block.workoutBlockKindRaw == "conditioning")
        #expect(block.conditioningPlan == plan)
        #expect(block.conditioningProgress == progress)
        #expect(block.conditioningMovementNames?[exerciseID] == "Burpee")
    }

    @Test func workoutSnapshotRoundTripsYogaFields() throws {
        let snapshot = WatchWorkoutSnapshot(
            workoutID: UUID(),
            title: "Morning Flow",
            startedAt: Date(timeIntervalSinceReferenceDate: 1_000),
            exercises: [
                WatchExerciseSnapshot(
                    id: UUID(),
                    name: "Guided Flow",
                    isCardio: true,       // yoga shares cardio's wrist lifecycle
                    isYoga: true,
                    cardioState: .running
                )
            ],
            intervalStepName: "Pigeon Pose — Left",
            intervalStepEndsAt: Date(timeIntervalSinceReferenceDate: 1_060),
            intervalStepKind: "pose",
            intervalNextName: "Pigeon Pose — Right",
            intervalRound: "Pose 3 of 12",
            isYogaWorkout: true
        )
        let context = WatchAppContext(workout: snapshot)
        let data = try #require(WatchWire.encode(context))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))

        #expect(decoded.workout?.isYogaWorkout == true)
        #expect(decoded.workout?.intervalStepKind == "pose")
        #expect(decoded.workout?.intervalRound == "Pose 3 of 12")
        #expect(decoded.workout?.exercises.first?.isYoga == true)
        #expect(decoded.workout?.exercises.first?.cardioState == .running)
    }

    /// Pre-yoga snapshots (no yoga fields in the JSON) still decode — the
    /// additive fields are optional.
    @Test func legacySnapshotWithoutYogaFieldsDecodes() throws {
        let snapshot = WatchWorkoutSnapshot(
            workoutID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let context = WatchAppContext(workout: snapshot)
        let data = try #require(WatchWire.encode(context))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))
        #expect(decoded.workout?.isYogaWorkout == nil)
        #expect(decoded.workout?.exercises.first?.isYoga == nil)
    }

    @Test func olderContextWithoutVerdictFieldsStillDecodes() throws {
        let legacyJSON = """
        {"workout":null,"routines":[],"readiness":75,"unitSuffix":"lb","updatedAt":0}
        """
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: Data(legacyJSON.utf8)))

        #expect(decoded.readiness == 75)
        #expect(decoded.readinessAction == nil)
        #expect(decoded.readinessDetail == nil)
        #expect(decoded.themeFamily == nil)
        #expect(decoded.themeMode == nil)
        #expect(decoded.effectiveThemeFamily == .sage)
        #expect(decoded.effectiveThemeMode == .dark)
    }
}

// MARK: - Terminal-command identity (FF-002)

extension WatchSyncTests {
    /// Wire-compatibility decision (FF-002): `workoutID` is additive-optional
    /// on the terminal commands, matching the codebase's established
    /// mixed-version decode pattern. A pre-binding build's `finishWorkout`
    /// (no `workoutID` key) still decodes — carrying `nil` — so old Watch →
    /// new Phone delivery is not dropped at the codec. The phone handler then
    /// treats `nil` exactly like a mismatch: refuse, never apply to whatever
    /// is active.
    @Test func legacyFinishWorkoutWithoutWorkoutIDStillDecodesAsUnbound() throws {
        let legacyJSON = """
        {"finishWorkout":{"metrics":{"heartRate":151,"avgHR":143,"maxHR":168,"activeEnergyKcal":345.5,"hrZoneSeconds":[10,20,30,40,50],"asOf":1800000400},"savedToHealth":true}}
        """
        let decoded = try #require(WatchWire.decode(WatchCommand.self, from: Data(legacyJSON.utf8)))

        guard case .finishWorkout(let decodedID, let decodedMetrics, let savedToHealth) = decoded else {
            Issue.record("expected .finishWorkout case")
            return
        }
        let expectedMetrics = WatchLiveMetrics(
            heartRate: 151,
            avgHR: 143,
            maxHR: 168,
            activeEnergyKcal: 345.5,
            hrZoneSeconds: [10, 20, 30, 40, 50],
            asOf: Date(timeIntervalSince1970: 1_800_000_400)
        )
        #expect(decodedID == nil)
        #expect(decodedMetrics == expectedMetrics)
        #expect(savedToHealth)
    }

    /// A pre-binding `discardWorkout` carried no associated values, and the
    /// synthesized codec emits the case key with an EMPTY object payload
    /// (`{"discardWorkout":{}}` — manager-verified against the pre-change
    /// enum). The new codec must decode that exact legacy form as
    /// `.discardWorkout(workoutID: nil)`, which the phone handler refuses —
    /// so an old Watch's discard can never be honored for the wrong workout.
    @Test func legacyDiscardWorkoutDecodesAsUnbound() throws {
        let legacyJSON = #"{"discardWorkout":{}}"#
        let decoded = try #require(WatchWire.decode(WatchCommand.self, from: Data(legacyJSON.utf8)))

        guard case .discardWorkout(let decodedID) = decoded else {
            Issue.record("expected .discardWorkout case")
            return
        }
        #expect(decodedID == nil)
    }

    // MARK: Terminal-command identity policy — pure decision surface

    /// The phone gate: an identity-less or mismatched terminal command is
    /// never executed. Matching identity is the only path through.
    @Test func terminalCommandPolicyExecutesOnlyForTheNamedWorkout() {
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        #expect(WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: a, activeWorkoutID: a))
        #expect(!WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: a, activeWorkoutID: b))
        #expect(!WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: a, activeWorkoutID: nil))
        #expect(!WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: nil, activeWorkoutID: a))
        #expect(!WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: nil, activeWorkoutID: nil))
    }

    /// The watch gate (WatchStore calls this because the Watch target has no
    /// unit-test target of its own): finish/discard are refused while the
    /// visible workout is a phone-start placeholder awaiting identity.
    @Test func terminalCommandPolicyRefusesWhileIdentityIsPending() {
        #expect(WatchTerminalCommandPolicy.mayRunTerminalCommand(isAwaitingIdentity: false))
        #expect(!WatchTerminalCommandPolicy.mayRunTerminalCommand(isAwaitingIdentity: true))
    }
}

// MARK: - Rest-timer mirroring (incl. block micro-rests)

extension WatchSyncTests {
    @Test func snapshotRoundTripsMicroRestFlag() throws {
        let snapshot = WatchWorkoutSnapshot(
            workoutID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            restEndsAt: Date(timeIntervalSinceReferenceDate: 15),
            restTotalSeconds: 15,
            restIsMicro: true
        )
        let data = try #require(WatchWire.encode(WatchAppContext(workout: snapshot)))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))
        #expect(decoded.workout?.restIsMicro == true)
        #expect(decoded.workout?.restTotalSeconds == 15)
    }

    /// A full rest — or an older snapshot — leaves `restIsMicro` nil while the
    /// countdown itself still mirrors.
    @Test func fullRestLeavesMicroFlagNil() throws {
        let snapshot = WatchWorkoutSnapshot(
            workoutID: UUID(),
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            restEndsAt: Date(timeIntervalSinceReferenceDate: 120),
            restTotalSeconds: 120
        )
        let data = try #require(WatchWire.encode(WatchAppContext(workout: snapshot)))
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: data))
        #expect(decoded.workout?.restIsMicro == nil)
        #expect(decoded.workout?.restEndsAt != nil)
    }
}

// MARK: - Engine workout identity (FF-003)

extension WatchSyncTests {
    private static let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private static let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    /// The confirmed FF-003 trigger: recovery/context against snapshot B while
    /// the live session belongs to A must never resume streaming under B — the
    /// stale session is ended and a fresh one is started for the current
    /// workout.
    @Test func mismatchedSnapshotRestartsInsteadOfResumingUnderB() {
        let resolution = WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: Self.a,
            hasAuthoritativeContext: true,
            contextWorkoutID: Self.b
        )
        #expect(resolution == .endSessionAndStartCurrent)
        #expect(resolution != .keepStreaming)
    }

    /// Matching identity recovers and resumes without restart.
    @Test func matchingIdentityKeepsStreaming() {
        let resolution = WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: Self.a,
            hasAuthoritativeContext: true,
            contextWorkoutID: Self.a
        )
        #expect(resolution == .keepStreaming)
    }

    /// A live session with no authoritative snapshot yet is quarantined, not
    /// cancelled — WCSession being slow is not evidence the workout ended.
    @Test func liveSessionWithNoAuthoritativeContextIsQuarantined() {
        let resolution = WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: Self.a,
            hasAuthoritativeContext: false,
            contextWorkoutID: nil
        )
        #expect(resolution == .awaitContext)
        #expect(resolution != .endSession)
        #expect(resolution != .endSessionAndStartCurrent)
    }

    /// The quarantine holds even when a mirror workout is visible but it is
    /// only the watch-local placeholder (not an authoritative snapshot).
    @Test func liveSessionWithOnlyAPlaceholderMirrorIsQuarantined() {
        let resolution = WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: nil,
            hasAuthoritativeContext: false,
            contextWorkoutID: Self.a
        )
        #expect(resolution == .awaitContext)
    }

    /// An authoritative context that declares no workout ends the live
    /// session — the phone has authoritatively said the workout is over.
    @Test func authoritativeNilWorkoutEndsTheLiveSession() {
        let resolution = WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: Self.a,
            hasAuthoritativeContext: true,
            contextWorkoutID: nil
        )
        #expect(resolution == .endSession)
    }

    /// An unverifiable session (nil identity — legacy/upgrade) can never be
    /// assumed to belong to the current workout: with a workout it is ended
    /// and restarted, with an authoritative nil it is ended.
    @Test func unverifiableSessionCannotStreamUnderAnyWorkout() {
        #expect(WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: nil,
            hasAuthoritativeContext: true,
            contextWorkoutID: Self.a
        ) == .endSessionAndStartCurrent)
        #expect(WatchEngineIdentityPolicy.resolve(
            engineHasSession: true,
            sessionWorkoutID: nil,
            hasAuthoritativeContext: true,
            contextWorkoutID: nil
        ) == .endSession)
    }

    /// No live session: an authoritative workout starts one; otherwise idle.
    @Test func noSessionStartsForTheAuthoritativeWorkoutOrIdles() {
        #expect(WatchEngineIdentityPolicy.resolve(
            engineHasSession: false,
            sessionWorkoutID: nil,
            hasAuthoritativeContext: true,
            contextWorkoutID: Self.a
        ) == .startSession)
        #expect(WatchEngineIdentityPolicy.resolve(
            engineHasSession: false,
            sessionWorkoutID: nil,
            hasAuthoritativeContext: true,
            contextWorkoutID: nil
        ) == .idle)
        #expect(WatchEngineIdentityPolicy.resolve(
            engineHasSession: false,
            sessionWorkoutID: nil,
            hasAuthoritativeContext: false,
            contextWorkoutID: nil
        ) == .idle)
    }

    /// Live metrics are only emitted while the streaming session is verifiably
    /// the current workout's AND the phone has resolved a pending handoff
    /// identity. A quarantined session (no mirror), a pending handoff, and a
    /// mismatched session all suppress the stream.
    @Test func metricsStreamOnlyUnderAMatchingResolvedIdentity() {
        // Normal streaming: identity matches the mirror.
        #expect(WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: Self.a,
            isAwaitingAuthoritativeIdentity: false,
            contextWorkoutID: Self.a
        ))
        // Mismatch: A's session must not stream under B.
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: Self.a,
            isAwaitingAuthoritativeIdentity: false,
            contextWorkoutID: Self.b
        ))
        // Quarantine: no authoritative mirror yet.
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: Self.a,
            isAwaitingAuthoritativeIdentity: false,
            contextWorkoutID: nil
        ))
        // Pending handoff: identity not yet bound — never streams, even if the
        // visible (placeholder) workoutID happens to match.
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: Self.a,
            isAwaitingAuthoritativeIdentity: true,
            contextWorkoutID: Self.a
        ))
        // Unverified session (nil identity) never streams.
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: nil,
            isAwaitingAuthoritativeIdentity: false,
            contextWorkoutID: Self.a
        ))
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: nil,
            isAwaitingAuthoritativeIdentity: false,
            contextWorkoutID: nil
        ))
    }

    /// The pending-handoff invariant: a nil-identity handoff session must not
    /// stream before the first authoritative snapshot binds it. This pins the
    /// exact gate the WatchStore applies while `isAwaitingWorkoutIdentity`.
    @Test func pendingHandoffNeverStreamsBeforeBinding() {
        // Before binding: awaiting flag set, identity nil → blocked.
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: nil,
            isAwaitingAuthoritativeIdentity: true,
            contextWorkoutID: Self.a
        ))
        // Even if the identity were somehow present, the awaiting flag alone
        // blocks until the authoritative snapshot resolves the handoff.
        #expect(!WatchEngineIdentityPolicy.mayStreamMetrics(
            sessionWorkoutID: Self.a,
            isAwaitingAuthoritativeIdentity: true,
            contextWorkoutID: Self.a
        ))
    }

    @Test func pendingHandoffBindingRequiresDurableEngineMarkerAndNilIdentity() {
        #expect(WatchEngineIdentityPolicy.mayBindPendingHandoff(
            sessionWorkoutID: nil,
            isPendingHandoff: true,
            contextWorkoutID: Self.b
        ))
        // A recovered A session must be cancelled/restarted for B even if a
        // phone-start placeholder is visible in the UI.
        #expect(!WatchEngineIdentityPolicy.mayBindPendingHandoff(
            sessionWorkoutID: Self.a,
            isPendingHandoff: true,
            contextWorkoutID: Self.b
        ))
        #expect(!WatchEngineIdentityPolicy.mayBindPendingHandoff(
            sessionWorkoutID: nil,
            isPendingHandoff: false,
            contextWorkoutID: Self.b
        ))
        #expect(!WatchEngineIdentityPolicy.mayBindPendingHandoff(
            sessionWorkoutID: nil,
            isPendingHandoff: true,
            contextWorkoutID: nil
        ))
    }

    @Test func liveMetricsApplyOnlyToTheirExactWorkout() {
        #expect(WatchLiveMetricsAttributionPolicy.mayApply(
            metricsWorkoutID: Self.a,
            activeWorkoutID: Self.a
        ))
        #expect(!WatchLiveMetricsAttributionPolicy.mayApply(
            metricsWorkoutID: Self.a,
            activeWorkoutID: Self.b
        ))
        #expect(!WatchLiveMetricsAttributionPolicy.mayApply(
            metricsWorkoutID: nil,
            activeWorkoutID: Self.a
        ))
        #expect(!WatchLiveMetricsAttributionPolicy.mayApply(
            metricsWorkoutID: Self.a,
            activeWorkoutID: nil
        ))
    }
}

// MARK: - Engine session identity persistence (FF-003)

extension WatchSyncTests {
    /// The durable identity store round-trips a bound workout, clears on nil,
    /// and reports nil for a missing or invalid value — all against an
    /// isolated UserDefaults suite that is always removed afterwards.
    @Test func sessionIdentityStorePersistsClearsAndHandlesMissing() throws {
        let suiteName = "WatchSessionIdentityStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Missing → nil.
        #expect(WatchSessionIdentityStore.load(defaults: defaults) == nil)
        #expect(!WatchSessionIdentityStore.isPendingHandoff(defaults: defaults))

        // Save a pending handoff → survives relaunch without fabricating an
        // identity, then binding clears the pending marker.
        WatchSessionIdentityStore.savePendingHandoff(true, defaults: defaults)
        #expect(WatchSessionIdentityStore.load(defaults: defaults) == nil)
        #expect(WatchSessionIdentityStore.isPendingHandoff(defaults: defaults))

        // Save a bound identity → round-trips.
        let workoutID = UUID()
        WatchSessionIdentityStore.save(workoutID, defaults: defaults)
        WatchSessionIdentityStore.savePendingHandoff(false, defaults: defaults)
        #expect(WatchSessionIdentityStore.load(defaults: defaults) == workoutID)
        #expect(!WatchSessionIdentityStore.isPendingHandoff(defaults: defaults))

        // Clear removes both pieces of state.
        WatchSessionIdentityStore.savePendingHandoff(true, defaults: defaults)
        WatchSessionIdentityStore.clear(defaults: defaults)
        #expect(WatchSessionIdentityStore.load(defaults: defaults) == nil)
        #expect(!WatchSessionIdentityStore.isPendingHandoff(defaults: defaults))

        // Invalid stored value → nil (defensive decode).
        defaults.set("not-a-uuid", forKey: WatchSessionIdentityStore.key)
        #expect(WatchSessionIdentityStore.load(defaults: defaults) == nil)
    }

    // MARK: - Complication reload gating

    @Test func rendersSameContentIgnoresOnlyTheTimestamp() {
        let base = ForgeFitWidgetSnapshot(
            mode: .idle,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            readinessScore: 74,
            readinessAction: "Train as planned",
            readinessDetail: "No restriction detected."
        )
        var republished = base
        republished.updatedAt = Date(timeIntervalSince1970: 1_800_003_600)

        #expect(base.rendersSameContent(as: republished))
        #expect(republished.rendersSameContent(as: base))
    }

    @Test func rendersSameContentDetectsAChangedScore() {
        let base = ForgeFitWidgetSnapshot(
            mode: .idle,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            readinessScore: 74
        )
        var rescored = base
        rescored.readinessScore = 61

        #expect(!base.rendersSameContent(as: rescored))
    }

    @Test func rendersSameContentDetectsSetProgress() {
        let base = ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            workoutTitle: "Push Day",
            completedSets: 3,
            totalSets: 12
        )
        var advanced = base
        advanced.completedSets = 4

        #expect(!base.rendersSameContent(as: advanced))
    }

    @Test func rendersSameContentDetectsAModeChange() {
        let readiness = ForgeFitWidgetSnapshot(
            mode: .idle,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            readinessScore: 74
        )
        let workout = ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            workoutTitle: "Push Day",
            totalSets: 12
        )

        #expect(!readiness.rendersSameContent(as: workout))
    }

    /// A score carried over midnight is a different face even though the
    /// stored fields match: the complication's own day gate clears it.
    @Test func staleReadinessStopsBeingCurrentTheNextDay() {
        let yesterday = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ForgeFitWidgetSnapshot(
            mode: .idle,
            updatedAt: yesterday,
            readinessScore: 74
        )

        #expect(snapshot.isCurrent(at: yesterday.addingTimeInterval(60)))
        #expect(!snapshot.isCurrent(at: yesterday.addingTimeInterval(60 * 60 * 24)))
    }

    // MARK: - Trend vs today's readiness

    /// A seven-day trend must never be presented as today's verdict. Home
    /// makes this distinction; the widget and complication faces now do too.
    @Test func trendOnlyScoreIsLabelledAndDoesNotFillTheGauge() {
        let trend = ForgeFitWidgetSnapshot(
            mode: .idle,
            readinessScore: 62,
            readinessIsTrendOnly: true
        )

        #expect(trend.readinessHeadline == "62% · 7-day")
        #expect(trend.readinessAccessibilityLabel == "62 percent, seven day trend")
        #expect(trend.readinessSymbol == "chart.line.uptrend.xyaxis")
        #expect(!trend.readinessFillsGauge)
    }

    @Test func acuteScoreSpeaksForToday() {
        let acute = ForgeFitWidgetSnapshot(
            mode: .idle,
            readinessScore: 74,
            readinessIsTrendOnly: false
        )

        #expect(acute.readinessHeadline == "74% ready")
        #expect(acute.readinessAccessibilityLabel == "74 percent ready")
        #expect(acute.readinessSymbol == "bolt.heart.fill")
        #expect(acute.readinessFillsGauge)
    }

    @Test func noScoreHasNoHeadlineAndNoGauge() {
        let empty = ForgeFitWidgetSnapshot(mode: .idle)

        #expect(empty.readinessHeadline == nil)
        #expect(empty.readinessAccessibilityLabel == nil)
        #expect(!empty.readinessFillsGauge)
    }

    /// The marker is additive: a snapshot encoded before it existed decodes
    /// with the flag absent and keeps rendering exactly as it used to.
    @Test func snapshotWithoutTheTrendMarkerStillDecodes() throws {
        let legacy = #"{"mode":"idle","updatedAt":1800000000,"readinessScore":74,"reasonChips":[],"completedSets":0,"totalSets":0}"#

        let decoded = try #require(
            WatchWire.decode(ForgeFitWidgetSnapshot.self, from: Data(legacy.utf8))
        )

        #expect(decoded.readinessIsTrendOnly == nil)
        #expect(decoded.readinessHeadline == "74% ready")
        #expect(decoded.readinessFillsGauge)
    }

    /// Flipping between trend and acute changes what the face draws, so it has
    /// to earn a reload even when the number itself is unchanged.
    @Test func trendFlipCountsAsAContentChange() {
        let acute = ForgeFitWidgetSnapshot(
            mode: .idle,
            readinessScore: 62,
            readinessIsTrendOnly: false
        )
        var trend = acute
        trend.readinessIsTrendOnly = true

        #expect(!acute.rendersSameContent(as: trend))
    }

    // MARK: - Account reset

    /// Reset must be able to remove the snapshot outright. It lives in the app
    /// group and outlives every store the reset clears, so leaving an empty
    /// snapshot behind is not the same as leaving none.
    @Test func clearRemovesTheStoredSnapshot() throws {
        let suite = "forgecore.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        ForgeFitWidgetSnapshotStore.save(
            ForgeFitWidgetSnapshot(mode: .idle, readinessScore: 74),
            defaults: defaults
        )
        #expect(ForgeFitWidgetSnapshotStore.load(defaults: defaults) != nil)

        ForgeFitWidgetSnapshotStore.clear(defaults: defaults)

        #expect(ForgeFitWidgetSnapshotStore.load(defaults: defaults) == nil)
    }
}
