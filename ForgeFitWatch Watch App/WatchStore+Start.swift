import Foundation
import ForgeCore
import WatchConnectivity
import WatchKit

extension WatchStore {
    var isStartingWorkout: Bool { pendingStartID != nil || isWaitingForStartSnapshot }

    func startRoutine(_ routine: WatchRoutineSummary) {
        Task { await requestImmediateStart(.startRoutine(routineID: routine.id)) }
    }

    func startEmpty() {
        Task { await requestImmediateStart(.startEmpty) }
    }

    /// UI and Siri share one expiring, correlated request. Starts never enter
    /// the durable command queue, including when reachability changes in flight.
    @discardableResult
    func requestImmediateStart(_ command: WatchCommand) async -> WatchImmediateStartResult {
        guard command.startsWorkout else { return .unavailable(message: "That workout start is unavailable.") }
        guard !isStartingWorkout else { return .unavailable(message: "A workout start is already in progress.") }
        clearStartPresentation()
        guard canSendStartRequest else {
            startIssue = "iPhone is unavailable."
            return .unavailable(message: "Your iPhone must be reachable to start a workout from Apple Watch.")
        }
        let request = WatchStartRequest(command: command)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .unavailable(message: "Workout start cancelled."))
                    return
                }
                pendingStartID = request.id
                startContinuation = continuation
                startTimeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(WatchStartRequest.maximumAge)) } catch { return }
                    self?.completeStart(request.id, result: .unavailable(message: "iPhone did not confirm the start."))
                }
                sendStartRequest(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelImmediateStart(requestID: request.id) }
        }
    }

    private var canSendStartRequest: Bool {
        #if DEBUG
        if WatchAppStoreDemo.wantsStartRecovery { return true }
        #endif
        return startRequestSender != nil || (WCSession.isSupported()
            && WCSession.default.activationState == .activated && WCSession.default.isReachable)
    }

    private func sendStartRequest(_ request: WatchStartRequest) {
        #if DEBUG
        if WatchAppStoreDemo.wantsStartRecovery {
            simulateStartReply(request)
            return
        }
        #endif
        if let startRequestSender { startRequestSender(request); return }
        guard let data = WatchWire.encode(request) else {
            completeStart(request.id, result: .unavailable(message: "Workout request could not be prepared."))
            return
        }
        WCSession.default.sendMessage([WatchWire.startRequestKey: data], replyHandler: { [weak self] reply in
            let data = reply[WatchWire.startReplyKey] as? Data
            Task { @MainActor in self?.receiveStartReply(data, requestID: request.id) }
        }, errorHandler: { [weak self] error in
            WatchSyncDiagnostics.record("start-request-failed", error: error)
            Task { @MainActor in
                self?.completeStart(request.id, result: .unavailable(message: "iPhone did not confirm the start."))
            }
        })
    }

    func receiveStartReply(_ data: Data?, requestID: UUID) {
        guard pendingStartID == requestID else { return }
        guard let data, let reply = WatchWire.decode(WatchStartReply.self, from: data),
              reply.requestID == requestID else {
            completeStart(requestID, result: .unavailable(message: "Update ForgeFit on iPhone and Apple Watch."))
            return
        }
        completeStart(requestID, result: reply.result)
    }

    func cancelImmediateStart(requestID: UUID? = nil) {
        guard let pending = pendingStartID, requestID == nil || pending == requestID else { return }
        completeStart(pending, result: .unavailable(message: "Workout start was not confirmed."))
    }

    private func completeStart(_ requestID: UUID, result: WatchImmediateStartResult) {
        guard pendingStartID == requestID else { return }
        let continuation = startContinuation
        pendingStartID = nil
        startContinuation = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        switch result {
        case .started, .activeWorkout:
            startIssue = nil
            if activeWorkout == nil {
                isWaitingForStartSnapshot = true
                startSnapshotTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    guard let self else { return }
                    self.isWaitingForStartSnapshot = false
                    self.startIssue = "Workout is on iPhone. Watch sync is delayed."
                    self.startSnapshotTask = nil
                }
            }
            if case .started = result { WKInterfaceDevice.current().play(.start) }
        case .unavailable(let message), .chooseWorkout(let message):
            startIssue = message
        }
        requestFreshContext()
        continuation?.resume(returning: result)
    }

    #if DEBUG
    private func simulateStartReply(_ request: WatchStartRequest) {
        guard !ProcessInfo.processInfo.arguments.contains("--seed-watch-start-timeout") else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pendingStartID == request.id else { return }
            let context = WatchAppStoreDemo.startedContext(for: request)
            self.receiveStartReply(WatchWire.encode(WatchStartReply(
                requestID: request.id, result: .started(title: context.workout?.title ?? "Workout")
            )), requestID: request.id)
            self.syncRecovery.refresh(at: Date(), force: true)
            guard let sync = self.syncRecovery.nextRequest(at: Date()),
                  let data = WatchWire.encode(context) else { return }
            self.receiveSnapshot(data, metadata: WatchSyncMetadata(epoch: UUID(), revision: 1,
                                 workoutID: context.workout?.workoutID), replyTo: sync.id)
        }
    }
    #endif

    func clearStartPresentation() {
        startSnapshotTask?.cancel()
        startSnapshotTask = nil
        isWaitingForStartSnapshot = false
        startIssue = nil
    }
}
