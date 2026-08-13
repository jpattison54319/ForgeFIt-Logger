import Foundation

/// A record or milestone earned by one completed workout. Awards are derived
/// from history instead of persisted so edits and deletions cannot leave stale
/// badges behind.
struct WorkoutAward: Identifiable, Equatable {
    enum Kind: String {
        case heaviestWeight
        case bestSetVolume
        case bestEstimated1RM
        case conditioningBestTime
        case conditioningBestScore
        case conditioningFastestRound
        case conditioningBestLoad
        case yogaLongestPractice
        case yogaMostPoses
        case yogaStreak

        var label: String {
            switch self {
            case .heaviestWeight: "Heaviest weight"
            case .bestSetVolume: "Best set volume"
            case .bestEstimated1RM: "Best est. 1RM"
            case .conditioningBestTime: "Best time"
            case .conditioningBestScore: "Best score"
            case .conditioningFastestRound: "Fastest round"
            case .conditioningBestLoad: "Best load"
            case .yogaLongestPractice: "Longest practice"
            case .yogaMostPoses: "Most poses"
            case .yogaStreak: "Yoga streak"
            }
        }

        var icon: String {
            switch self {
            case .heaviestWeight, .conditioningBestLoad: "scalemass.fill"
            case .bestSetVolume, .conditioningBestScore: "chart.bar.fill"
            case .bestEstimated1RM: "bolt.fill"
            case .conditioningBestTime: "stopwatch.fill"
            case .conditioningFastestRound: "speedometer"
            case .yogaLongestPractice: "clock.fill"
            case .yogaMostPoses: "figure.yoga"
            case .yogaStreak: "flame.fill"
            }
        }
    }

    let id: String
    let title: String
    let kind: Kind
    let valueText: String
}
