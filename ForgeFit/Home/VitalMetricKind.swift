import Foundation

/// The fixed left-to-right order and favorable direction for Home's Vitals
/// indicators. Direction changes only the presentation axis; the raw personal
/// range remains visible in detail and is never recast as a medical range.
nonisolated enum VitalMetricKind: String, Codable, CaseIterable, Equatable, Sendable {
    case heartRate
    case respiratoryRate
    case bloodOxygen
    case hrv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heartRate: "Heart rate"
        case .respiratoryRate: "Respiratory rate"
        case .bloodOxygen: "Blood oxygen"
        case .hrv: "HRV"
        }
    }

    var systemImage: String {
        switch self {
        case .heartRate: "heart.fill"
        case .respiratoryRate: "lungs.fill"
        case .bloodOxygen: "drop.degreesign.fill"
        case .hrv: "waveform.path.ecg"
        }
    }

    var favorsHigherValue: Bool {
        self == .bloodOxygen || self == .hrv
    }

    /// Range status must use the same precision the person sees. Comparing
    /// hidden fractional values can otherwise label a displayed 97% reading
    /// below a displayed 97% lower bound.
    func valueAtDisplayPrecision(_ value: Double) -> Double {
        switch self {
        case .respiratoryRate:
            (value * 10).rounded() / 10
        case .heartRate, .bloodOxygen, .hrv:
            value.rounded()
        }
    }
}
