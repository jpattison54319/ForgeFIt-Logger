import Foundation

/// Tabs users can choose as ForgeFit's cold-launch destination.
///
/// This is intentionally narrower than `AppTab`: Insights and Profile remain
/// destinations rather than primary starting points.
enum DefaultLaunchTab: String, CaseIterable, Identifiable {
    case home
    case workout

    static let key = "defaultLaunchTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .workout: "Workout"
        }
    }

    var appTab: AppTab {
        switch self {
        case .home: .home
        case .workout: .workout
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> DefaultLaunchTab {
        guard let rawValue = defaults.string(forKey: key),
              let tab = DefaultLaunchTab(rawValue: rawValue) else {
            return .home
        }
        return tab
    }
}
