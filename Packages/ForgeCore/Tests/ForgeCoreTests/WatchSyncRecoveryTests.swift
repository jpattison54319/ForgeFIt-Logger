import Foundation
import Testing
@testable import ForgeCore

struct WatchSyncRecoveryTests {
    private let grace = WatchSyncRecoveryState.transientIssueGracePeriod
    private let now = Date(timeIntervalSince1970: 10_000)
    private let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @Test func transientFailuresStayQuietUntilRecoveryHasHadTimeToWork() throws {
        var state = WatchSyncRecoveryState()
        state.refresh(at: now)
        let first = try #require({ state.nextRequest(at: now) }())
        state.failed(.unreachable, requestID: first.id, at: now)
        #expect(state.issue == .unreachable)
        #expect(state.presentedIssue == nil)
        _ = state.nextRequest(at: now.addingTimeInterval(3))
        state.failed(.transport, at: now.addingTimeInterval(3))
        state.updatePresentation(at: now.addingTimeInterval(grace - 0.1))
        #expect(state.presentedIssue == nil)
        state.updatePresentation(at: now.addingTimeInterval(grace))
        #expect(state.presentedIssue == .transport)
    }

    @Test func successfulRetryNeverFlashesADelayedError() throws {
        var state = WatchSyncRecoveryState()
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        state.failed(.transport, requestID: request.id, at: now)
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 1, workoutID: b), replyTo: request.id) == .accepted }())
        state.updatePresentation(at: now.addingTimeInterval(60))
        #expect(state.issue == nil)
        #expect(state.presentedIssue == nil)
    }

    @Test func phoneHandoffGivesTransientStorageAndDecodeFailuresTimeToClear() throws {
        var state = WatchSyncRecoveryState()
        state.requireVerification(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        state.failed(.storageUnavailable, requestID: request.id, at: now)
        #expect(state.presentedIssue == nil)
        state.failed(.invalidPayload, requestID: request.id, at: now.addingTimeInterval(grace - 1))
        #expect(state.presentedIssue == nil)
        state.updatePresentation(at: now.addingTimeInterval(grace))
        #expect(state.presentedIssue == .invalidPayload)
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 1, workoutID: b), replyTo: request.id) == .accepted }())
        #expect(state.presentedIssue == nil)
    }

    @Test func stoppingRecoveryClearsErrorsAndInvalidatesLateFailures() throws {
        var state = try verifiedState()
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        state.failed(.unreachable, requestID: request.id, at: now)
        state.updatePresentation(at: now.addingTimeInterval(grace + 1))
        #expect(state.presentedIssue != nil)
        state.cancelRequest()
        state.failed(.transport, requestID: request.id, at: now.addingTimeInterval(20))
        state.updatePresentation(at: now.addingTimeInterval(30))
        #expect(state.issue == nil)
        #expect(state.presentedIssue == nil)
        #expect(state.hasVerifiedContext)
        #expect(state.epoch == a)
    }

    @Test func reconnectionExpeditesBackoffWithoutReplacingAHealthyRequest() throws {
        var state = try verifiedState()
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        let due = state.nextAttemptAt
        state.retryAfterReconnect(at: now.addingTimeInterval(1))
        #expect(state.pendingRequestID == request.id)
        #expect(state.nextAttemptAt == due)
        state.failed(.unreachable, requestID: request.id, at: now)
        state.retryAfterReconnect(at: now.addingTimeInterval(1))
        #expect({ state.nextRequest(at: now.addingTimeInterval(1)) != nil }())
        #expect(state.hasVerifiedContext)
    }

    @Test func unchangedCorrelatedContextClearsFailureAndCanReverify() throws {
        var state = try verifiedState()
        for reverify in [false, true] {
            if reverify { state.requireVerification(at: now) } else { state.refresh(at: now) }
            let request = try #require({ state.nextRequest(at: now) }())
            state.failed(.transport, requestID: request.id, at: now)
            state.updatePresentation(at: now.addingTimeInterval(grace + 1))
            let result = state.accept(WatchSyncMetadata(epoch: a, revision: 1, workoutID: a), replyTo: request.id)
            #expect(result == (reverify ? .accepted : .duplicate))
            #expect(state.hasVerifiedContext)
            #expect(state.pendingRequestID == nil)
            #expect(state.presentedIssue == nil)
        }
    }

    @Test func actionableConfigurationFailuresDoNotWaitForTheGracePeriod() {
        var state = WatchSyncRecoveryState()
        for issue in [WatchSyncIssue.incompatible, .storageUnavailable, .invalidPayload] {
            state.failed(issue, at: now)
            #expect(state.presentedIssue == issue)
        }
    }

    @Test func configurationFailureKeepsBackoffAndSurvivesTheIdleRetryBudget() throws {
        var state = WatchSyncRecoveryState()
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        state.failed(.storageUnavailable, requestID: request.id, at: now)
        let due = state.nextAttemptAt
        state.retryAfterReconnect(at: now.addingTimeInterval(1))
        #expect(state.nextAttemptAt == due)
        state.cancelRequest(clearIssue: false)
        #expect(state.pendingRequestID == nil)
        #expect(state.nextAttemptAt == nil)
        #expect(state.presentedIssue == .storageUnavailable)
        state.failed(.transport, requestID: request.id, at: now.addingTimeInterval(10))
        #expect(state.presentedIssue == .storageUnavailable)
        state.cancelRequest()
        #expect(state.presentedIssue == nil)
    }

    @Test func lostResponseRetriesWithoutAcceptingAnObsoleteReply() throws {
        var state = WatchSyncRecoveryState()
        state.requireVerification(at: now)
        let first = try #require({ state.nextRequest(at: now) }())
        #expect({ state.nextRequest(at: now.addingTimeInterval(2)) == nil }())
        let second = try #require({ state.nextRequest(at: now.addingTimeInterval(3)) }())
        #expect(first.id != second.id)
        let metadata = WatchSyncMetadata(epoch: a, revision: 1, workoutID: b)
        #expect({ state.accept(metadata, replyTo: first.id) == .obsoleteReply }())
        #expect(!state.hasVerifiedContext)
        #expect({ state.accept(metadata, replyTo: second.id) == .accepted }())
        #expect(state.hasVerifiedContext)
        #expect(state.nextAttemptAt == nil)
        #expect(state.issue == nil)
    }

    @Test func retryDelayIsBoundedAcrossALongDisconnection() throws {
        var state = WatchSyncRecoveryState()
        state.refresh(at: now)
        var time = now
        for _ in 0..<100 {
            _ = try #require({ state.nextRequest(at: time) }())
            state.failed(.unreachable)
            let next = try #require(state.nextAttemptAt)
            #expect((3...30).contains(next.timeIntervalSince(time)))
            time = next
        }
        #expect(state.attempts == 100)
        #expect(!state.hasVerifiedContext)
    }

    @Test func retainedOrUnsolicitedContextCannotResolveAColdRecovery() {
        var state = WatchSyncRecoveryState()
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 9, workoutID: nil)) == .needsHandshake }())
        #expect(!state.hasVerifiedContext)
        #expect(state.epoch == nil)
    }

    @Test func olderSnapshotsCannotReplaceNewerWorkoutState() throws {
        var state = try verifiedState()
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 3, workoutID: b)) == .accepted }())
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 2, workoutID: nil)) == .duplicate }())
        #expect(state.revision == 3)
    }

    @Test func aNewPhoneProcessMustAnswerTheCurrentRequest() throws {
        var state = try verifiedState()
        #expect({ state.accept(WatchSyncMetadata(epoch: b, revision: 1, workoutID: a)) == .needsHandshake }())
        #expect(state.epoch == a)
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        #expect({ state.accept(WatchSyncMetadata(epoch: b, revision: 1, workoutID: a), replyTo: request.id) == .accepted }())
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 999, workoutID: nil)) == .needsHandshake }())
        #expect(state.epoch == b)
    }

    @Test func aNewHandoffRequiresANewAcknowledgementEvenInTheSameEpoch() throws {
        var state = try verifiedState()
        state.requireVerification(at: now)
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 5, workoutID: b)) == .needsHandshake }())
        let request = try #require({ state.nextRequest(at: now) }())
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 6, workoutID: b), replyTo: request.id) == .accepted }())
    }

    @Test func transportFailureDoesNotDiscardVerifiedAuthority() throws {
        var state = try verifiedState()
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        state.failed(.transport, requestID: request.id)
        #expect(state.hasVerifiedContext)
        #expect(state.issue == .transport)
        #expect(state.nextAttemptAt != nil)
    }

    @Test func incompatibleProtocolCannotChangeSessionAuthority() throws {
        var state = try verifiedState()
        var metadata = WatchSyncMetadata(epoch: a, revision: 10, workoutID: b)
        metadata.protocolVersion = 900
        #expect({ state.accept(metadata) == .incompatible }())
        #expect(state.revision == 1)
        #expect(state.issue == nil)
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        #expect({ state.accept(metadata, replyTo: request.id) == .incompatible }())
        #expect(state.issue == .incompatible)
    }

    @Test func stoppingAnUnidentifiedHandoffSurvivesBindingAndRelaunch() throws {
        var suppression = WatchWorkoutSuppression()
        suppression.stop(nil)
        #expect(suppression.isSuppressed(nil))
        let data = try #require(WatchWire.encode(suppression))
        suppression = try #require(WatchWire.decode(WatchWorkoutSuppression.self, from: data))
        suppression.resolve(a)
        #expect(suppression.isSuppressed(a))
        #expect(!suppression.isSuppressed(b))
        suppression.resume(a)
        #expect(!suppression.isSuppressed(a))
    }

    @Test func finishedWorkoutsCannotBeResumedAndTheLedgerStaysBounded() throws {
        var suppression = WatchWorkoutSuppression()
        for _ in 0..<40 { suppression.finish(UUID()); suppression.stop(UUID()) }
        suppression.finish(a)
        suppression.resume(a)
        #expect(suppression.isSuppressed(a))
        #expect(suppression.terminalIDs.count == 24)
        #expect(suppression.stoppedIDs.count == 24)
    }

    @Test func snapshotRefreshesCannotResetTheEngineRetryBudget() {
        var retry = WatchEngineRetryState()
        #expect({ retry.mayStart(a, at: now) }())
        for attempt in 1...3 {
            retry.failed(.transient, at: now)
            if attempt < 3 {
                #expect({ !retry.mayStart(a, at: now) }())
                #expect({ retry.mayStart(a, at: now.addingTimeInterval(20)) }())
                retry.started()
            }
        }
        #expect(retry.issue == .retryLimit)
        #expect({ !retry.mayStart(a, at: now.addingTimeInterval(600)) }())
        retry.retryExplicitly()
        #expect({ retry.mayStart(a, at: now) }())
    }

    @Test func anotherWorkoutAndPermissionFailuresRequireExplicitAction() {
        for issue in [WatchEngineRetryState.Issue.anotherWorkout, .permissionRequired] {
            var retry = WatchEngineRetryState()
            #expect({ retry.mayStart(a, at: now) }())
            retry.failed(issue, at: now)
            for _ in 0..<20 { #expect({ !retry.mayStart(a, at: now.addingTimeInterval(600)) }()) }
            retry.retryExplicitly()
            #expect({ retry.mayStart(a, at: now) }())
        }
    }

    @Test func bindingAPendingEnginePreservesItsFailureBudget() {
        var retry = WatchEngineRetryState()
        #expect({ retry.mayStart(nil, at: now) }())
        retry.failed(.transient, at: now)
        retry.bind(a)
        #expect({ !retry.mayStart(a, at: now) }())
        #expect(retry.failures == 1)
    }

    @Test func unknownAppearanceValuesDoNotDiscardTheWorkoutGraph() throws {
        let context = WatchAppContext(workout: WatchWorkoutSnapshot(workoutID: a, startedAt: now), themeFamily: .sage)
        let encoded = try #require(WatchWire.encode(context))
        let raw = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(raw as? [String: Any])
        object["themeFamily"] = "future-theme"
        object["themeMode"] = "future-mode"
        object["readinessBasis"] = "future-basis"
        let decoded = try #require(WatchWire.decode(WatchAppContext.self, from: JSONSerialization.data(withJSONObject: object)))
        #expect(decoded.workout?.workoutID == a)
        #expect(decoded.themeFamily == nil)
        #expect(decoded.themeMode == nil)
        #expect(decoded.readinessBasis == nil)
    }

    @Test func malformedWorkoutIdentityStillFailsClosed() throws {
        let context = WatchAppContext(workout: WatchWorkoutSnapshot(workoutID: a, startedAt: now))
        let encoded = try #require(WatchWire.encode(context))
        let raw = try JSONSerialization.jsonObject(with: encoded)
        var object = try #require(raw as? [String: Any])
        var workout = try #require(object["workout"] as? [String: Any])
        workout["workoutID"] = "invalid-id"
        object["workout"] = workout
        #expect(WatchWire.decode(WatchAppContext.self, from: try JSONSerialization.data(withJSONObject: object)) == nil)
    }

    @Test func diagnosticsAreBoundedLocalAndResettable() throws {
        let suite = "WatchSyncDiagnostics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for _ in 0..<40 { WatchSyncDiagnostics.record("transport-failed", defaults: defaults) }
        let data = try #require(defaults.data(forKey: "watch.sync.diagnostics.v1"))
        let raw = try JSONSerialization.jsonObject(with: data)
        let events = try #require(raw as? [[String: Any]])
        #expect(events.count == 32)
        #expect(events.allSatisfy { Set($0.keys).isSubset(of: ["at", "kind", "errorDomain", "errorCode", "peer"]) })
        WatchSyncDiagnostics.clear(defaults: defaults)
        #expect(defaults.data(forKey: "watch.sync.diagnostics.v1") == nil)
    }

    private func verifiedState() throws -> WatchSyncRecoveryState {
        var state = WatchSyncRecoveryState()
        state.refresh(at: now)
        let request = try #require({ state.nextRequest(at: now) }())
        #expect({ state.accept(WatchSyncMetadata(epoch: a, revision: 1, workoutID: a), replyTo: request.id) == .accepted }())
        return state
    }
}
