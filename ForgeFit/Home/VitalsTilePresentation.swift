import Foundation

nonisolated struct VitalsTilePresentation: Codable, Equatable, Sendable {
    let indicators: [VitalIndicatorPresentation]

    static func make(assessment: HealthRangeAssessment) -> VitalsTilePresentation {
        let readings = Dictionary(uniqueKeysWithValues: assessment.readings.map { ($0.kind, $0) })
        return VitalsTilePresentation(indicators: VitalMetricKind.allCases.map { kind in
            guard let reading = readings[kind] else {
                return VitalIndicatorPresentation(
                    kind: kind,
                    name: kind.title,
                    valueText: nil,
                    relationText: "no reading",
                    interpretation: .unavailable,
                    position: 0.5
                )
            }
            return VitalIndicatorPresentation(
                kind: kind,
                name: reading.name,
                valueText: reading.formattedVitalValue,
                relationText: reading.vitalRelationText,
                interpretation: reading.interpretation,
                position: min(1, max(0, reading.normalizedVitalPosition))
            )
        })
    }

    static var loading: VitalsTilePresentation {
        VitalsTilePresentation(indicators: VitalMetricKind.allCases.map { kind in
            VitalIndicatorPresentation(
                kind: kind,
                name: kind.title,
                valueText: nil,
                relationText: "loading today's reading",
                interpretation: .building,
                position: 0.5
            )
        })
    }

    var accessibilityValue: String {
        indicators.map { indicator in
            let value = indicator.valueText.map { ", \($0)" } ?? ""
            return "\(indicator.name)\(value), \(indicator.relationText)"
        }.joined(separator: ". ")
    }
}
