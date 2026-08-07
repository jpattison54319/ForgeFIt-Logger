import Foundation

/// Privacy-safe handoff from a local experiment notification into SwiftUI.
/// Only an opaque local UUID is carried; experiment names and custom values
/// never enter notification metadata or UserDefaults.
nonisolated enum ExperimentNotificationRoute {
    static let userInfoURLKey = "forgefitExperimentURL"
    static let pendingURLDefaultsKey = "forgefit.pendingExperimentNotificationURL"
    static let pendingExperimentIDDefaultsKey = "forgefit.pendingExperimentID"
    static let openRequested = Notification.Name(
        "forgefit.experimentNotificationOpenRequested"
    )
    static let routeReady = Notification.Name(
        "forgefit.experimentRouteReady"
    )

    static func resultsURL(experimentID: UUID) -> URL {
        URL(string: "forgefit://experiment/\(experimentID.uuidString)/results")!
    }
}
