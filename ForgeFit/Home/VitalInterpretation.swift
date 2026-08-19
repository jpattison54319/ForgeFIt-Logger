import Foundation

nonisolated enum VitalInterpretation: String, Codable, Equatable, Sendable {
    case favorable
    case typical
    case adverse
    case building
    case unavailable
}
