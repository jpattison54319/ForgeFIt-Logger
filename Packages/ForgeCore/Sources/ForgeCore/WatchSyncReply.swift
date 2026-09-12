import Foundation

public struct WatchSyncReply: Codable, Sendable {
    public var requestID: UUID
    public var metadata: WatchSyncMetadata?
    public var contextData: Data?
    public var issue: WatchSyncIssue?

    public init(requestID: UUID, metadata: WatchSyncMetadata? = nil, contextData: Data? = nil, issue: WatchSyncIssue? = nil) {
        self.requestID = requestID
        self.metadata = metadata
        self.contextData = contextData
        self.issue = issue
    }
}
