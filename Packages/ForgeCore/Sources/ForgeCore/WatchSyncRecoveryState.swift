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
    public private(set) var presentedIssue: WatchSyncIssue?
    private var failureStartedAt: Date?
    private var verificationStartedAt: Date?
    public private(set) var peer: WatchPeerInfo?

    public static let transientIssueGracePeriod: TimeInterval = 15

    public init() {}

    public mutating func requireVerification(at now: Date) {
        hasVerifiedContext = false
        refresh(at: now, force: true)
        verificationStartedAt = now
    }

    public mutating func refresh(at now: Date, force: Bool = false) {
        guard force || nextAttemptAt == nil else { return }
        pendingRequestID = nil
        attempts = 0
        nextAttemptAt = now
        issue = nil
        presentedIssue = nil
        failureStartedAt = nil
        verificationStartedAt = nil
    }

    public mutating func nextRequest(at now: Date, peer: WatchPeerInfo = .current) -> WatchSyncRequest? {
        guard let nextAttemptAt, now >= nextAttemptAt else { return nil }
        if attempts > 0, issue == nil { failed(.timedOut, at: now) }
        let request = WatchSyncRequest(peer: peer)
        pendingRequestID = request.id
        attempts += 1
        let delays: [TimeInterval] = [3, 6, 12, 20, 30]
        self.nextAttemptAt = now.addingTimeInterval(delays[min(attempts - 1, delays.count - 1)])
        return request
    }

    public mutating func failed(_ issue: WatchSyncIssue, requestID: UUID? = nil, at now: Date = Date()) {
        if let requestID, requestID != pendingRequestID { return }
        self.issue = issue
        if failureStartedAt == nil { failureStartedAt = now }
        updatePresentation(at: now)
    }

    /// The retry loop advances this clock; rendering never polls wall time.
    public mutating func updatePresentation(at now: Date) {
        guard let issue else { return }
        if let verificationStartedAt,
           now.timeIntervalSince(verificationStartedAt) < Self.transientIssueGracePeriod {
            presentedIssue = nil
            return
        }
        if !issue.isTransient || failureStartedAt.map({ now.timeIntervalSince($0) >= Self.transientIssueGracePeriod }) == true {
            presentedIssue = issue
        } else {
            presentedIssue = nil
        }
    }

    public mutating func retryAfterReconnect(at now: Date) {
        // Keep a healthy in-flight reply valid, but do not wait up to 30 s
        // after a failed request when the connection has already returned.
        if issue?.isTransient == true { nextAttemptAt = now }
    }

    public mutating func cancelRequest(clearIssue: Bool = true) {
        pendingRequestID = nil
        nextAttemptAt = nil
        guard clearIssue else { return }
        issue = nil
        presentedIssue = nil
        failureStartedAt = nil
        verificationStartedAt = nil
    }

    public mutating func accept(_ metadata: WatchSyncMetadata, replyTo requestID: UUID? = nil) -> Acceptance {
        if let requestID, requestID != pendingRequestID { return .obsoleteReply }
        guard metadata.protocolVersion == WatchSyncRequest.protocolVersion else {
            if requestID != nil { failed(.incompatible) }
            return .incompatible
        }
        if (!hasVerifiedContext || epoch != metadata.epoch), requestID == nil {
            return .needsHandshake
        }
        // Even a correlated response cannot move the current epoch backward.
        if epoch == metadata.epoch, metadata.revision < revision {
            return .duplicate
        }
        if epoch == metadata.epoch, metadata.revision == revision, hasVerifiedContext {
            if requestID != nil {
                cancelRequest()
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
