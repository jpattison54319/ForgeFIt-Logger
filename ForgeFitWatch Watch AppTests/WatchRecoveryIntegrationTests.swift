import ForgeCore
import Foundation
import HealthKit
import Testing
@testable import ForgeFitWatch_Watch_App

@MainActor
struct WatchRecoveryIntegrationTests {
    @Test func delayedDiscardAndOlderContextCannotStopTheNewWorkout() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.store
        let a = UUID(), b = UUID(), epoch = UUID()
        try acknowledge(store, workoutID: a, epoch: epoch, revision: 1)
        await settle()
        try acknowledge(store, workoutID: b, epoch: epoch, revision: 3)
        await settle()
        #expect(fixture.engine.activeSessionWorkoutID == b)
        let cancelled = fixture.engine.cancellations
        store.handle(.discardWorkout(workoutID: a))
        store.handle(.workoutFinished(workoutID: a))
        try push(store, workoutID: a, epoch: epoch, revision: 2)
        await settle()
        #expect(store.activeWorkout?.workoutID == b)
        #expect(fixture.engine.activeSessionWorkoutID == b)
        #expect(fixture.engine.cancellations == cancelled)
    }

    @Test func localStopDuringRecoveryCannotBeUndoneByItsLateCompletion() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.engine.suspendRecovery = true
        fixture.store.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: HKWorkoutConfiguration()))
        await settle()
        #expect(fixture.engine.recoveryContinuation != nil)
        fixture.store.stopRecordingOnWatch()
        fixture.engine.suspendRecovery = false
        fixture.engine.recoveryContinuation?.resume(returning: .noSession)
        fixture.engine.recoveryContinuation = nil
        await settle()
        let id = UUID(), epoch = UUID()
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 1)
        await settle()
        #expect(fixture.store.isRecordingStopped)
        #expect(!fixture.engine.hasActiveSession)
        #expect(fixture.engine.starts == 0)
        #expect(fixture.store.activeWorkout?.workoutID == id)
    }

    @Test func localStopSurvivesStoreRelaunchAndRepeatedFreshSnapshots() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let id = UUID(), epoch = UUID()
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 1)
        await settle()
        fixture.store.stopRecordingOnWatch()
        await settle()
        let engine = RecoveryTestEngine()
        let relaunched = WatchStore(engine: engine, defaults: fixture.defaults, recoveryRequestSender: { _ in })
        defer { relaunched.stopSyncRecovery(); relaunched.engineRetryTask?.cancel() }
        try acknowledge(relaunched, workoutID: id, epoch: epoch, revision: 2)
        try push(relaunched, workoutID: id, epoch: epoch, revision: 3)
        await settle()
        #expect(relaunched.isRecordingStopped)
        #expect(engine.starts == 0)
        #expect(relaunched.activeWorkout?.workoutID == id)
    }

    @Test func finishedWorkoutDoesNotRestartWhenAnActiveSnapshotArrivesLate() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let id = UUID(), epoch = UUID()
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 1)
        await settle()
        fixture.store.handle(.workoutFinished(workoutID: id))
        await settle()
        try push(fixture.store, workoutID: id, epoch: epoch, revision: 2)
        await settle()
        #expect(fixture.store.activeWorkout == nil)
        #expect(!fixture.engine.hasActiveSession)
        #expect(fixture.engine.starts == 1)
    }

    @Test func pendingHandoffWaitsForCorrelatedIdentityBeforeStarting() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let epoch = UUID(), id = UUID()
        fixture.store.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: HKWorkoutConfiguration()))
        await settle()
        #expect(!fixture.engine.hasActiveSession)
        #expect(fixture.engine.starts == 0)
        try push(fixture.store, workoutID: nil, epoch: epoch, revision: 1)
        await settle()
        #expect(fixture.store.isAwaitingWorkoutIdentity)
        #expect(fixture.engine.cancellations == 0)
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 2)
        await settle()
        #expect(!fixture.store.isAwaitingWorkoutIdentity)
        #expect(fixture.engine.activeSessionWorkoutID == id)
        #expect(fixture.engine.starts == 1)
    }

    @Test func freshContextRestartsRecoveryAfterThreeTransientFailures() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.engine.recoveryFailures = 3
        await fixture.store.recoverOrStartWorkoutSession()
        #expect(fixture.store.needsBootstrapRecovery)
        #expect(fixture.engine.recoveries == 3)
        try acknowledge(fixture.store, workoutID: UUID(), epoch: UUID(), revision: 1)
        await settle()
        #expect(!fixture.store.needsBootstrapRecovery)
        #expect(fixture.engine.recoveries == 4)
        #expect(fixture.engine.starts == 1)
    }

    @Test func unsupportedSnapshotIsVisibleAndDoesNotResolvePendingIdentity() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.store.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: HKWorkoutConfiguration()))
        await settle()
        fixture.store.receiveSnapshot(Data("invalid".utf8), metadata: WatchSyncMetadata(epoch: UUID(), revision: 1, workoutID: nil))
        #expect(fixture.store.isAwaitingWorkoutIdentity)
        #expect(fixture.store.syncRecovery.issue == .invalidPayload)
        #expect(fixture.engine.cancellations == 0)
    }

    @Test func idleRecoveryCannotStopOrSuppressTheNextWorkout() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.store.syncRecovery.failed(.unreachable)
        #expect(!fixture.store.canStopRecordingOnWatch)
        fixture.store.stopRecordingOnWatch()
        try acknowledge(fixture.store, workoutID: UUID(), epoch: UUID(), revision: 1)
        await settle()
        #expect(!fixture.store.isRecordingStopped)
        #expect(fixture.engine.starts == 1)
    }

    @Test func localStopCancelsTheOutstandingRequestAndIgnoresItsReply() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.store.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: HKWorkoutConfiguration()))
        await settle()
        let requestID = try #require(fixture.store.syncRecovery.pendingRequestID)
        fixture.store.stopRecordingOnWatch()
        #expect(fixture.store.syncRecoveryTask == nil)
        #expect(fixture.store.syncHealthCheckTask == nil)
        #expect(fixture.store.syncRecovery.pendingRequestID == nil)
        let context = WatchAppContext(workout: WatchWorkoutSnapshot(workoutID: UUID(), startedAt: Date()))
        let reply = WatchSyncReply(requestID: requestID,
                                  metadata: WatchSyncMetadata(epoch: UUID(), revision: 1, workoutID: context.workout?.workoutID),
                                  contextData: WatchWire.encode(context))
        fixture.store.receiveSyncReply(WatchWire.encode(reply), requestID: requestID)
        await settle()
        #expect(fixture.store.isAwaitingWorkoutIdentity)
        #expect(fixture.store.isRecordingStopped)
        #expect(!fixture.engine.hasActiveSession)
    }

    @Test func resetClearsOnlyTheEpochItInvalidated() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let epochA = UUID(), epochB = UUID(), b = UUID()
        try acknowledge(fixture.store, workoutID: UUID(), epoch: epochA, revision: 1)
        await settle()
        fixture.store.receiveReset(invalidatedEpoch: epochA)
        await settle()
        #expect(fixture.store.context == nil)
        #expect(fixture.store.summary == nil)
        #expect(!fixture.engine.hasActiveSession)
        try acknowledge(fixture.store, workoutID: b, epoch: epochB, revision: 1)
        await settle()
        fixture.store.receiveReset(invalidatedEpoch: epochA)
        await settle()
        #expect(fixture.store.activeWorkout?.workoutID == b)
        #expect(fixture.engine.activeSessionWorkoutID == b)
    }

    @Test func livenessProbeRecoversASilentlyMissedPhoneFinish() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let epoch = UUID()
        try acknowledge(fixture.store, workoutID: UUID(), epoch: epoch, revision: 1)
        await settle()
        #expect(fixture.engine.hasActiveSession)
        fixture.store.requestLivenessProbeIfNeeded(at: Date().addingTimeInterval(10))
        #expect(fixture.store.syncRecovery.pendingRequestID == nil)
        fixture.store.requestLivenessProbeIfNeeded(at: Date().addingTimeInterval(31))
        await settle()
        let requestID = try #require(fixture.store.syncRecovery.pendingRequestID)
        let reply = WatchSyncReply(requestID: requestID,
                                  metadata: WatchSyncMetadata(epoch: epoch, revision: 2, workoutID: nil),
                                  contextData: WatchWire.encode(WatchAppContext()))
        fixture.store.receiveSyncReply(WatchWire.encode(reply), requestID: requestID)
        await settle()
        #expect(fixture.store.activeWorkout == nil)
        #expect(!fixture.engine.hasActiveSession)
        #expect(fixture.store.syncHealthCheckTask == nil)
    }

    @Test func slowHealthSaveKeepsTheWorkoutVisibleAndOnlyFinishesOnce() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let id = UUID(), epoch = UUID()
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 1)
        await settle()
        fixture.engine.suspendFinish = true
        fixture.store.finishWorkout()
        await settle()
        fixture.store.finishWorkout()
        fixture.store.discardWorkout()
        fixture.store.retryWorkoutRecovery()
        try push(fixture.store, workoutID: id, epoch: epoch, revision: 2)
        await settle()
        #expect(fixture.store.isFinishingWorkout)
        #expect(!fixture.store.canStopRecordingOnWatch)
        #expect(fixture.store.summary == nil)
        #expect(fixture.store.activeWorkout?.workoutID == id)
        #expect(fixture.engine.finishes == 1)
        fixture.engine.finishContinuation?.resume(returning: true)
        fixture.engine.finishContinuation = nil
        await settle()
        #expect(!fixture.store.isFinishingWorkout)
        #expect(fixture.store.summary?.workoutID == id)
        #expect(fixture.store.activeWorkout == nil)
    }

    @Test(arguments: [false, true])
    func aNewContextWaitsForTheOriginalHealthSaveToResolve(startNextWorkout: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let a = UUID(), b: UUID? = startNextWorkout ? UUID() : nil, epoch = UUID()
        try acknowledge(fixture.store, workoutID: a, epoch: epoch, revision: 1)
        await settle()
        fixture.engine.suspendFinish = true
        fixture.store.finishWorkout()
        await settle()
        try acknowledge(fixture.store, workoutID: b, epoch: epoch, revision: 2)
        await settle()
        #expect(fixture.store.isFinishingWorkout)
        #expect(fixture.engine.cancellations == 0)
        #expect(fixture.engine.starts == 1)
        #expect(fixture.engine.activeSessionWorkoutID == a)
        fixture.engine.finishContinuation?.resume(returning: true)
        fixture.engine.finishContinuation = nil
        await settle()
        #expect(!fixture.store.isFinishingWorkout)
        #expect(fixture.store.activeWorkout?.workoutID == b)
        #expect(fixture.engine.activeSessionWorkoutID == b)
        #expect(fixture.engine.starts == (startNextWorkout ? 2 : 1))
        #expect(fixture.store.summary == nil)
    }

    @Test func repeatedExpiredHandoffsNeverStartARecorder() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let epoch = UUID()
        for revision in UInt64(1)...5 {
            fixture.store.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: HKWorkoutConfiguration()))
            await settle()
            #expect(fixture.engine.starts == 0)
            try acknowledge(fixture.store, workoutID: nil, epoch: epoch, revision: revision)
            await settle()
            #expect(fixture.store.activeWorkout == nil)
        }
        #expect(fixture.engine.starts == 0)
        #expect(fixture.engine.cancellations == 0)
    }

    @Test func verificationFlushesQuarantinedHeartRateWithIdentityAndSequence() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.engine.hasActiveSession = true
        fixture.engine.isAwaitingSessionWorkoutID = true
        fixture.engine.heartRate = 120
        fixture.engine.flushMetrics()
        #expect(fixture.packets.values.isEmpty)
        let id = UUID(), epoch = UUID()
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 1)
        await settle()
        let first = try #require(fixture.packets.values.first)
        #expect(first.workoutID == id)
        #expect(first.heartRate == 120)
        #expect(first.streamID != nil)
        #expect(first.sequence == 1)
        #expect(first.sentAt != nil)
        let count = fixture.packets.values.count
        try push(fixture.store, workoutID: id, epoch: epoch, revision: 2)
        #expect(fixture.packets.values.count == count)
        fixture.engine.flushMetrics()
        #expect(fixture.packets.values.last?.sequence == UInt64(count + 1))
        fixture.store.stopRecordingOnWatch()
        fixture.engine.flushMetrics()
        #expect(fixture.packets.values.count == count + 1)
        await settle()
    }

    @Test func anOldWakeUpCannotInterruptAVerifiedHeartRateStream() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let id = UUID(), epoch = UUID()
        try acknowledge(fixture.store, workoutID: id, epoch: epoch, revision: 1)
        await settle()
        fixture.engine.heartRate = 125
        fixture.store.handleWorkoutConfiguration(HKWorkoutConfigurationBox(value: HKWorkoutConfiguration()))
        fixture.engine.flushMetrics()
        #expect(fixture.packets.values.last?.heartRate == 125)
        #expect(fixture.store.hasReceivedAuthoritativeContext)
        #expect(fixture.engine.activeSessionWorkoutID == id)
        #expect(fixture.engine.starts == 1)
    }

    @Test func anUnseenWorkoutPushMustBeVerifiedInsteadOfReplayed() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let epoch = UUID()
        try acknowledge(fixture.store, workoutID: nil, epoch: epoch, revision: 1)
        await settle()
        try push(fixture.store, workoutID: UUID(), epoch: epoch, revision: 2)
        await settle()
        #expect(fixture.store.activeWorkout == nil)
        #expect(fixture.engine.starts == 0)
        try acknowledge(fixture.store, workoutID: nil, epoch: epoch, revision: 3)
        await settle()
        #expect(fixture.engine.starts == 0)
    }

    @Test func immediateStartCancellationIsBoundedAndIgnoresLateReply() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let task = Task { await fixture.store.requestImmediateStart(.startEmpty) }
        await settle()
        let id = try #require(fixture.store.pendingStartID)
        #expect(fixture.store.isStartingWorkout)
        let duplicate = await fixture.store.requestImmediateStart(.startEmpty)
        #expect(duplicate == .unavailable(message: "A workout start is already in progress."))
        task.cancel()
        let result = await task.value
        #expect(result == .unavailable(message: "Workout start was not confirmed."))
        #expect(!fixture.store.isStartingWorkout)
        let reply = WatchStartReply(requestID: id, result: .started(title: "Late"))
        fixture.store.receiveStartReply(WatchWire.encode(reply), requestID: id)
        #expect(!fixture.store.isStartingWorkout)
        #expect(fixture.engine.starts == 0)
    }

    @Test func startAcknowledgementWaitsForVerifiedExercisesAndIgnoresDuplicateReply() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let task = Task { await fixture.store.requestImmediateStart(.startRoutine(routineID: UUID())) }
        await settle()
        let id = try #require(fixture.store.pendingStartID)
        let reply = WatchWire.encode(WatchStartReply(requestID: id, result: .started(title: "Push")))
        fixture.store.receiveStartReply(reply, requestID: id)
        #expect(await task.value == .started(title: "Push"))
        #expect(fixture.store.isWaitingForStartSnapshot)
        #expect(fixture.engine.starts == 0)
        try acknowledge(fixture.store, workoutID: id, epoch: UUID(), revision: 1)
        await settle()
        #expect(!fixture.store.isStartingWorkout)
        #expect(fixture.store.startIssue == nil)
        #expect(fixture.engine.starts == 1)
        fixture.store.receiveStartReply(reply, requestID: id)
        #expect(!fixture.store.isStartingWorkout)
    }

    private func acknowledge(_ store: WatchStore, workoutID: UUID?, epoch: UUID, revision: UInt64) throws {
        store.syncRecovery.refresh(at: Date(), force: true)
        let request = try #require({ store.syncRecovery.nextRequest(at: Date()) }())
        let context = WatchAppContext(workout: workoutID.map { WatchWorkoutSnapshot(workoutID: $0, startedAt: Date()) })
        let reply = WatchSyncReply(requestID: request.id,
                                  metadata: WatchSyncMetadata(epoch: epoch, revision: revision, workoutID: workoutID),
                                  contextData: try #require(WatchWire.encode(context)))
        store.receiveSyncReply(try #require(WatchWire.encode(reply)), requestID: request.id)
    }

    private func push(_ store: WatchStore, workoutID: UUID?, epoch: UUID, revision: UInt64) throws {
        let context = WatchAppContext(workout: workoutID.map { WatchWorkoutSnapshot(workoutID: $0, startedAt: Date()) })
        store.receiveSnapshot(try #require(WatchWire.encode(context)), metadata: WatchSyncMetadata(epoch: epoch, revision: revision, workoutID: workoutID))
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @MainActor
    private final class Fixture {
        let suite = "WatchRecoveryIntegration-\(UUID().uuidString)"
        let defaults: UserDefaults
        let engine = RecoveryTestEngine()
        final class Packets { var values: [WatchLiveMetrics] = [] }
        let packets = Packets()
        let store: WatchStore
        init() {
            defaults = UserDefaults(suiteName: suite)!
            let packets = packets
            store = WatchStore(engine: engine, defaults: defaults, recoveryRequestSender: { _ in },
                               startRequestSender: { _ in }, metricsSender: { packets.values.append($0) })
        }
        func cleanUp() {
            store.cancelImmediateStart()
            store.clearStartPresentation()
            store.stopSyncRecovery()
            store.engineRetryTask?.cancel()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}
