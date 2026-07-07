import Foundation

/// The frozen snapshot a Wrapped report renders from. Everything the story
/// shows is computed once at generation time and JSON-encoded into
/// `WrappedReportModel.payloadJSON` — analytics inputs drift (health metrics
/// only reach ~60 days back; workouts can be edited), so old reports must
/// replay exactly as generated, never recompute.
///
/// Missing-data handling is by construction: a page whose data doesn't exist
/// for the period simply isn't in `pages`.
struct WrappedPayload: Codable, Equatable {
    var version: Int = 1
    /// "June Wrapped" / "2026 Wrapped".
    var title: String
    /// "June 2026" / "2026".
    var periodLabel: String
    var pages: [WrappedPage]
}

/// One story page. Enum-with-payload so each page carries exactly what its
/// screen renders; Codable is synthesized (type-discriminated).
enum WrappedPage: Codable, Equatable {
    case cover(Cover)
    case identity(Identity)
    case bigStats(BigStats)
    case trainingMix(TrainingMix)
    case calendar(CalendarHeatmap)
    case strongestWeek(StrongestWeek)
    case signatureExercise(SignatureExercise)
    case muscleMap(MuscleMap)
    case strengthProgress(StrengthProgress)
    case cardioEngine(CardioEngine)
    case heartRate(HeartRate)
    case bossBattle(BossBattle)
    case improved(InsightPage)
    case heldBack(InsightPage)
    case comparison(Comparison)
    case nextFocus(Focus)
    case recap(Recap)
    // Yearly-only pages.
    case mostActiveMonth(MostActiveMonth)
    case longestStreak(LongestStreak)
    case topWorkouts(TopWorkouts)
    case badges(Badges)

    struct Cover: Codable, Equatable {
        var title: String            // "Your June Wrapped"
        var subtitle: String         // "Let's look at what you built."
    }

    struct Identity: Codable, Equatable {
        var label: String            // "Hybrid Builder"
        var line: String             // one-sentence why
    }

    struct BigStats: Codable, Equatable {
        var workouts: Int
        var trainingMinutes: Int
        var activeDays: Int
        var totalVolumeKg: Double
    }

    struct TrainingMix: Codable, Equatable {
        var strengthCount: Int
        var cardioCount: Int
        var strengthMinutes: Int
        var cardioMinutes: Int
    }

    struct CalendarHeatmap: Codable, Equatable {
        var year: Int
        var month: Int               // 1–12
        /// Day-of-month numbers that had ≥1 completed workout.
        var activeDays: [Int]
    }

    struct StrongestWeek: Codable, Equatable {
        var weekLabel: String        // "Jun 9 – Jun 15"
        var workouts: Int
        var volumeKg: Double
    }

    struct SignatureExercise: Codable, Equatable {
        var name: String
        var sets: Double             // effective sets
        var sessions: Int
    }

    struct MuscleMap: Codable, Equatable {
        var most: [MuscleShareItem]  // top 3
        var least: [MuscleShareItem] // bottom 2 of trained muscles
    }

    struct MuscleShareItem: Codable, Equatable {
        var muscle: String
        var sets: Double
    }

    struct StrengthProgress: Codable, Equatable {
        var recordsSet: Int
        /// Biggest estimated-1RM improvement inside the period, if any lift
        /// was tested more than once.
        var bestLiftName: String?
        var bestLiftE1RMGainKg: Double?
    }

    struct CardioEngine: Codable, Equatable {
        var minutes: Int
        var distanceMeters: Double
        /// Seconds in HR zones 1–5 (5 entries), summed across sessions.
        var zoneSeconds: [Int]
        var longestSessionMinutes: Int?
        var longestSessionKind: String?
    }

    struct HeartRate: Codable, Equatable {
        var highestWorkoutHR: Int
        var highestWorkoutTitle: String
        var averageWorkoutHR: Int?
    }

    struct BossBattle: Codable, Equatable {
        var workoutTitle: String
        var dayLabel: String         // "Jun 21"
        var durationMinutes: Int
        var volumeKg: Double
        var avgRPE: Double?
    }

    struct InsightPage: Codable, Equatable {
        var headline: String
        var detail: String
    }

    struct Comparison: Codable, Equatable {
        var workoutsDelta: Int
        var volumeDeltaKg: Double
        var minutesDelta: Int
        var previousLabel: String    // "May"
    }

    struct Focus: Codable, Equatable {
        var primary: String
        var secondary: String?
        var maintain: String?
    }

    struct Recap: Codable, Equatable {
        var title: String
        var workouts: Int
        var trainingMinutes: Int
        var volumeKg: Double
        var activeDays: Int
        var identityLabel: String?
        var highlight: String?       // one line, e.g. "3 records set"
    }

    struct MostActiveMonth: Codable, Equatable {
        var monthName: String
        var workouts: Int
    }

    struct LongestStreak: Codable, Equatable {
        var days: Int
        var endedLabel: String?      // "ended Aug 14"
    }

    struct TopWorkouts: Codable, Equatable {
        var entries: [TopWorkoutItem] // up to 5
    }

    struct TopWorkoutItem: Codable, Equatable {
        var title: String
        var dayLabel: String
        var volumeKg: Double
    }

    struct Badges: Codable, Equatable {
        var earned: [String]         // badge labels
    }

    /// Stable per-kind identity for paging/ForEach and share filenames.
    var kind: String {
        switch self {
        case .cover: "cover"
        case .identity: "identity"
        case .bigStats: "bigStats"
        case .trainingMix: "trainingMix"
        case .calendar: "calendar"
        case .strongestWeek: "strongestWeek"
        case .signatureExercise: "signatureExercise"
        case .muscleMap: "muscleMap"
        case .strengthProgress: "strengthProgress"
        case .cardioEngine: "cardioEngine"
        case .heartRate: "heartRate"
        case .bossBattle: "bossBattle"
        case .improved: "improved"
        case .heldBack: "heldBack"
        case .comparison: "comparison"
        case .nextFocus: "nextFocus"
        case .recap: "recap"
        case .mostActiveMonth: "mostActiveMonth"
        case .longestStreak: "longestStreak"
        case .topWorkouts: "topWorkouts"
        case .badges: "badges"
        }
    }
}

extension WrappedPayload {
    func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decode(from json: String) -> WrappedPayload? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WrappedPayload.self, from: data)
    }
}
