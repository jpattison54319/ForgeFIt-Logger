import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleActivationOfferPolicyTests {
    @Test func alreadyTrackedMicrocycleDoesNotOfferASecondRun() {
        let folderID = UUID()
        let tracking = makeTracking(folderID: folderID, name: "Current")

        let content = MicrocycleActivationOfferPolicy.content(
            folderID: folderID,
            hasRoutines: true,
            activeTracking: tracking
        )

        #expect(!content.shouldOffer)
        #expect(content.canSetDayTarget)
    }

    @Test func differentTrackedMicrocycleExplainsReplacementConsequence() {
        let tracking = makeTracking(folderID: UUID(), name: "Old Block")

        let content = MicrocycleActivationOfferPolicy.content(
            folderID: UUID(),
            hasRoutines: true,
            activeTracking: tracking
        )

        #expect(content.shouldOffer)
        #expect(content.canSetDayTarget)
        #expect(content.message.contains("calendar days"))
        #expect(content.message.contains("stops Old Block"))
        #expect(content.message.contains("history stays saved"))
    }

    @Test func emptyMicrocycleStillOffersButCannotOpenSetup() {
        let content = MicrocycleActivationOfferPolicy.content(
            folderID: UUID(),
            hasRoutines: false,
            activeTracking: nil
        )

        #expect(content.shouldOffer)
        #expect(!content.canSetDayTarget)
        #expect(content.message.contains("Add at least one routine"))
    }

    private func makeTracking(folderID: UUID, name: String) -> MicrocycleTrackingModel {
        MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: folderID,
            folderName: name,
            anchorDate: .now,
            durationDays: 7
        )
    }
}
