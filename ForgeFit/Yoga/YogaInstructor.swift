import Foundation

/// The instructor identity shared by every bundled pose image and narration
/// clip. It never changes the pose, flow, or logged workout data.
enum YogaInstructor: String, Codable, CaseIterable, Identifiable, Sendable {
    static let preferenceKey = "yogaInstructorRaw"

    case female
    case male

    var id: String { rawValue }

    var title: String {
        switch self {
        case .female: "Female"
        case .male: "Male"
        }
    }

    static func resolved(from rawValue: String) -> YogaInstructor {
        YogaInstructor(rawValue: rawValue) ?? .female
    }
}
