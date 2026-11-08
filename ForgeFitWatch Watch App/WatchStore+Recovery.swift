import Foundation
import ForgeCore
import WatchConnectivity

extension WatchStore {
    func stopSyncRecovery() {
        syncHealthCheckTask?.cancel()
        syncHealthCheckTask = nil
        syncRecoveryTask?.cancel()
        syncRecoveryTask = nil
        syncRecovery.cancelRequest()
    }

    func startSyncRecovery() {
        #if DEBUG
        if WatchAppStoreDemo.isRequested { return }
        #endif
        guard recoveryRequestSender != nil || WCSession.isSupported() else { return }
        syncRecovery.refresh(at: Date())
        guard syncRecoveryTask == nil else { return }
        syncRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.syncRecoveryTask = nil } }
            while !Task.isCancelled, let due = self.syncRecovery.nextAttemptAt {
                let delay = max(0, due.timeIntervalSinceNow)
                if delay > 0 {
                    do { try await Task.sleep(for: .seconds(min(delay, 1))) } catch { return }
                }
                guard !Task.isCancelled else { return }
                let now = Date()
                var recovery = self.syncRecovery
                recovery.updatePresentation(at: now)
                if recovery.presentedIssue != self.syncRecovery.presentedIssue {
                    self.syncRecovery = recovery
                }
                // A sleeping retry must not publish unchanged observable
                // state on each clock check.
                guard let due = self.syncRecovery.nextAttemptAt, now >= due else { continue }
                if (self.activeWorkout == nil || self.isRecordingStopped), self.syncRecovery.attempts >= 6 {
                    // Stop background work without hiding an actionable
                    // version or storage problem that still needs attention.
                    self.syncRecovery.cancelRequest(clearIssue: false)
                    return
                }
                guard !Task.isCancelled,
                      let request = self.syncRecovery.nextRequest(at: now) else { continue }
                self.sendSyncRequest(request)
            }
        }
    }

    private func sendSyncRequest(_ request: WatchSyncRequest) {
        if let recoveryRequestSender {
            recoveryRequestSender(request)
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            session.activate()
            tryMirroredSync(request, fallbackIssue: .transport)
            return
        }
        guard session.isReachable else {
            tryMirroredSync(request, fallbackIssue: .unreachable)
            return
        }
        guard let data = WatchWire.encode(request) else { return }
        session.sendMessage([WatchWire.syncRequestKey: data], replyHandler: { [weak self] reply in
            let data = reply[WatchWire.syncReplyKey] as? Data
            Task { @MainActor in self?.receiveSyncReply(data, requestID: request.id) }
        }, errorHandler: { [weak self] error in
            WatchSyncDiagnostics.record("sync-request-failed", error: error)
            Task { @MainActor in self?.tryMirroredSync(request, fallbackIssue: .transport) }
        })
    }

    private func tryMirroredSync(_ request: WatchSyncRequest, fallbackIssue: WatchSyncIssue) {
        guard request.id == syncRecovery.pendingRequestID else { return }
        guard let workoutMirroring else {
            syncRecovery.failed(fallbackIssue, requestID: request.id)
            return
        }
        Task { [weak self] in
            let sent = await workoutMirroring.requestSync(request)
            guard !sent else { return }
            self?.syncRecovery.failed(fallbackIssue, requestID: request.id)
        }
    }

    func receiveSyncReply(_ data: Data?, requestID: UUID) {
        guard requestID == syncRecovery.pendingRequestID else { return }
        guard let data, let reply = WatchWire.decode(WatchSyncReply.self, from: data),
              reply.requestID == requestID else {
            syncRecovery.failed(.transport, requestID: requestID)
            WatchSyncDiagnostics.record("sync-reply-unreadable")
            return
        }
        receiveSyncReply(reply, requestID: requestID)
    }

    func receiveSyncReply(_ reply: WatchSyncReply, requestID: UUID) {
        guard requestID == syncRecovery.pendingRequestID, reply.requestID == requestID else { return }
        if let issue = reply.issue {
            syncRecovery.failed(issue, requestID: requestID)
            return
        }
        guard let contextData = reply.contextData, let metadata = reply.metadata else {
            syncRecovery.failed(.invalidPayload, requestID: requestID)
            return
        }
        receiveSnapshot(contextData, metadata: metadata, replyTo: requestID)
    }

    func receiveSnapshot(_ data: Data, metadataData: Data?) {
        guard let metadataData,
              let metadata = WatchWire.decode(WatchSyncMetadata.self, from: metadataData) else {
            requestFreshContext()
            return
        }
        receiveSnapshot(data, metadata: metadata)
    }

    func receiveSnapshot(_ data: Data, metadata: WatchSyncMetadata, replyTo requestID: UUID? = nil) {
        guard let context = WatchWire.decode(WatchAppContext.self, from: data),
              context.workout?.workoutID == metadata.workoutID else {
            if let requestID { syncRecovery.failed(.invalidPayload, requestID: requestID) }
            WatchSyncDiagnostics.record("context-decode-failed", peer: metadata.peer)
            requestFreshContext()
            return
        }
        // A previously unseen workout in retained/background state is a
        // refresh hint, never authority to replay a historical start. Keep
        // the current stream until a fresh reply identifies the next workout.
        if requestID == nil, let id = context.workout?.workoutID,
           isTerminalWorkout(id) { return }
        if requestID == nil, let id = context.workout?.workoutID, id != activeWorkout?.workoutID {
            requestFreshContext()
            return
        }
        switch syncRecovery.accept(metadata, replyTo: requestID) {
        case .accepted:
            if requestID != nil { WatchSyncDiagnostics.record("sync-verified", peer: metadata.peer) }
            lastSnapshotReceivedAt = Date()
            apply(context: context)
            scheduleSyncHealthCheck()
        case .needsHandshake:
            requestFreshContext()
        case .duplicate:
            if requestID != nil, syncRecovery.pendingRequestID == nil {
                lastSnapshotReceivedAt = Date()
                scheduleSyncHealthCheck()
            }
        case .incompatible:
            if requestID == nil { requestFreshContext() }
        case .obsoleteReply:
            break
        }
    }

    /// Reconnection callbacks are not guaranteed after a silently lost update.
    /// One active-only probe follows 30 seconds without an accepted snapshot.
    private func scheduleSyncHealthCheck() {
        syncHealthCheckTask?.cancel()
        syncHealthCheckTask = nil
        #if DEBUG
        if WatchAppStoreDemo.isRequested { return }
        #endif
        guard activeWorkout != nil, !isRecordingStopped else { return }
        syncHealthCheckTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.syncHealthCheckTask = nil
            self.requestLivenessProbeIfNeeded(at: Date())
        }
    }

    func requestLivenessProbeIfNeeded(at now: Date) {
        guard activeWorkout != nil, !isRecordingStopped,
              let lastSnapshotReceivedAt, now.timeIntervalSince(lastSnapshotReceivedAt) >= 30 else { return }
        requestFreshContext()
    }

    func scheduleEngineRecovery() {
        #if DEBUG
        if WatchAppStoreDemo.isRequested { return }
        #endif
        guard engineRetryTask == nil, !isRecordingStopped else { return }
        let next = engine.retryState.nextAttemptAt
        guard needsBootstrapRecovery || next != nil else { return }
        let delay = next.map { max(0.5, $0.timeIntervalSinceNow) } ?? 10
        engineRetryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.engineRetryTask = nil
            guard !self.isRecordingStopped else { return }
            await self.recoverOrStartWorkoutSession()
            self.scheduleEngineRecovery()
        }
    }

    #if DEBUG
    func completeRecoveryDemo() {
        let context = recoveryDemoContext ?? WatchAppStoreDemo.context()
        recoveryDemoContext = context
        syncRecovery.refresh(at: Date(), force: true)
        guard let request = syncRecovery.nextRequest(at: Date()), let data = WatchWire.encode(context) else { return }
        receiveSnapshot(data, metadata: WatchSyncMetadata(epoch: UUID(), revision: 1, workoutID: context.workout?.workoutID), replyTo: request.id)
        if context.workout != nil { WatchAppStoreDemo.startHeartRateTicker(WatchWorkoutEngine.shared) }
    }
    #endif
}
