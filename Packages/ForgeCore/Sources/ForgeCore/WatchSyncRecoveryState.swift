import Foundation

/// The same reducer drives transport retries and fault-injection tests.
/// Clocks and delivery are supplied by the caller; no platform IPC lives here.
public struct WatchSyncRecoveryState: Sendable {
    public enum Acceptance: Equatable, Sendable {
        case accepted, duplicate, obsoleteReply, needsHandshake, incompatible
    }

    public private(set) var epoch: UUID?
    public private(set) var revision: UInt64 = 0
    public private(set) var hasVerifiedContext = false
    public private(set) var pendingRequestID: UUID?
    public private(set) var nextAttemptAt: Date?
    public private(set) var attempts = 0
    public private(set) var issue: WatchSyncIssue?
    public private(set) var peer: WatchPeerInfo?

    public init() {}

    public mutating func requireVerification(at now: Date) {
        hasVerifiedContext = false
        refresh(at: now, force: true)
    }

    public mutating func refresh(at now: Date, force: Bool = false) {
        guard force || nextAttemptAt == nil else { return }
        pendingRequestID = nil
        attempts = 0
        nextAttemptAt = now
        issue = nil
    }

    public mutating func nextRequest(at now: Date, peer: WatchPeerInfo = .current) -> WatchSyncRequest? {
        guard let nextAttemptAt, now >= nextAttemptAt else { return nil }
        if attempts > 0, issue == nil { issue = .timedOut }
        let request = WatchSyncRequest(peer: peer)
        pendingRequestID = request.id
        attempts += 1
        let delays: [TimeInterval] = [3, 6, 12, 20, 30]
        self.nextAttemptAt = now.addingTimeInterval(delays[min(attempts - 1, delays.count - 1)])
        return request
    }

    public mutating func failed(_ issue: WatchSyncIssue, requestID: UUID? = nil) {
        if let requestID, requestID != pendingRequestID { return }
        self.issue = issue
    }

    public mutating func cancelRequest() {
        pendingRequestID = nil
        nextAttemptAt = nil
    }

    public mutating func accept(_ metadata: WatchSyncMetadata, replyTo requestID: UUID? = nil) -> Acceptance {
        if let requestID, requestID != pendingRequestID { return .obsoleteReply }
        guard metadata.protocolVersion == WatchSyncRequest.protocolVersion else {
            issue = .incompatible
            return .incompatible
        }
        if (!hasVerifiedContext || epoch != metadata.epoch), requestID == nil {
            return .needsHandshake
        }
        // Even a correlated response cannot move the current epoch backward.
        if epoch == metadata.epoch, metadata.revision <= revision {
            if requestID != nil, hasVerifiedContext {
                cancelRequest()
                issue = nil
            }
            return .duplicate
        }
        epoch = metadata.epoch
        revision = metadata.revision
        peer = metadata.peer
        hasVerifiedContext = true
        issue = nil
        cancelRequest()
        return .accepted
    }
}
