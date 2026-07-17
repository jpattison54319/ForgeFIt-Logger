import Foundation

/// The model shown in every bundled yoga pose image. This is a presentation
/// preference only; it never changes the pose, flow, or logged workout data.
enum YogaInstructor: String, CaseIterable, Identifiable {
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
