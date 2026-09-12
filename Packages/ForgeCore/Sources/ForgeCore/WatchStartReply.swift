import Foundation

public struct WatchStartReply: Codable, Sendable {
    public let requestID: UUID
    public let result: WatchImmediateStartResult

    public init(requestID: UUID, result: WatchImmediateStartResult) {
        self.requestID = requestID
        self.result = result
    }
}
