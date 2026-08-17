import ForgeData
import Foundation

@MainActor
enum MicrocycleActivationOfferPolicy {
    static func content(
        folderID: UUID,
        hasRoutines: Bool,
        activeTracking: MicrocycleTrackingModel?
    ) -> MicrocycleActivationOfferContent {
        let meaning = "A day target sets how many calendar days each cycle lasts before the next one begins."
        guard activeTracking?.folderID != folderID else {
            return MicrocycleActivationOfferContent(
                shouldOffer: false,
                canSetDayTarget: hasRoutines,
                message: meaning
            )
        }
        guard hasRoutines else {
            return MicrocycleActivationOfferContent(
                shouldOffer: true,
                canSetDayTarget: false,
                message: "\(meaning) Add at least one routine before tracking."
            )
        }
        guard let activeTracking else {
            return MicrocycleActivationOfferContent(
                shouldOffer: true,
                canSetDayTarget: true,
                message: meaning
            )
        }
        return MicrocycleActivationOfferContent(
            shouldOffer: true,
            canSetDayTarget: true,
            message: "\(meaning) Starting this tracker stops \(activeTracking.folderName). Its history stays saved."
        )
    }
}
