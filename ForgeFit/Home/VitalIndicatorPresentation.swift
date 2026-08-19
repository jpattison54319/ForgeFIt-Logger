import Foundation

nonisolated struct VitalIndicatorPresentation: Identifiable, Codable, Equatable, Sendable {
    var id: VitalMetricKind { kind }

    let kind: VitalMetricKind
    let name: String
    let valueText: String?
    let relationText: String
    let interpretation: VitalInterpretation
    let position: Double
}
