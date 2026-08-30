import Foundation

struct FeatureDiscoveryOffer: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let feature: FeatureDiscoveryID
        let targetID: UUID
    }

    let feature: FeatureDiscoveryID
    let targetID: UUID
    let title: String
    let whyNow: String
    let benefit: String
    let qualifiedAt: Date

    var id: ID { ID(feature: feature, targetID: targetID) }
}

enum FeatureDiscoveryIneligibility: Equatable, Sendable {
    case suppressed
    case alreadyUsed
    case activeTracking
    case noQualifyingTarget
}

enum FeatureDiscoveryDecision: Equatable, Sendable {
    case offer(FeatureDiscoveryOffer)
    case doNotOffer(FeatureDiscoveryIneligibility)
}
