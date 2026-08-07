import Foundation
import Testing
@testable import ForgeFit

struct CardioRouteOwnershipPolicyTests {
    @Test func authorizationCannotStartLocationWhenBothSessionIDsAreNil() {
        #expect(!CardioRouteOwnershipPolicy.shouldStartAfterAuthorization(
            isAuthorized: true,
            pendingSessionID: nil,
            recordingSessionID: nil
        ))
    }

    @Test func authorizationStartsOnlyForTheStillPendingRecordingSession() {
        let sessionID = UUID()

        #expect(CardioRouteOwnershipPolicy.shouldStartAfterAuthorization(
            isAuthorized: true,
            pendingSessionID: sessionID,
            recordingSessionID: sessionID
        ))
        #expect(!CardioRouteOwnershipPolicy.shouldStartAfterAuthorization(
            isAuthorized: false,
            pendingSessionID: sessionID,
            recordingSessionID: sessionID
        ))
        #expect(!CardioRouteOwnershipPolicy.shouldStartAfterAuthorization(
            isAuthorized: true,
            pendingSessionID: sessionID,
            recordingSessionID: UUID()
        ))
    }

    @Test func recorderIsCancelledWhenItsOwningSessionDisappears() {
        let recordingID = UUID()

        #expect(!CardioRouteOwnershipPolicy.shouldCancelAsOrphan(
            recordingSessionID: recordingID,
            pendingSessionID: nil,
            validSessionIDs: [recordingID]
        ))
        #expect(CardioRouteOwnershipPolicy.shouldCancelAsOrphan(
            recordingSessionID: recordingID,
            pendingSessionID: nil,
            validSessionIDs: []
        ))
        #expect(!CardioRouteOwnershipPolicy.shouldCancelAsOrphan(
            recordingSessionID: nil,
            pendingSessionID: nil,
            validSessionIDs: []
        ))
    }
}
