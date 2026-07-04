#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// Shared attributes for the workout Live Activity (lock screen + Dynamic
/// Island). Lives in ForgeCore so the app and the widget extension see the
/// exact same type.
public struct WorkoutActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var startedAt: Date
        /// Current exercise (first with incomplete sets) — what the lifter is
        /// actually doing right now.
        public var exerciseName: String?
        public var completedSets: Int
        public var totalSets: Int
        public var mode: WorkoutActivityMode
        public var cardioTitle: String?
        public var cardioMetric: String?
        public var cardioDetail: String?
        /// Live rest countdown; nil when not resting.
        public var restEndsAt: Date?
        /// Live heart rate from the Apple Watch, when streaming.
        public var heartRate: Int?

        public init(
            startedAt: Date,
            exerciseName: String? = nil,
            completedSets: Int = 0,
            totalSets: Int = 0,
            mode: WorkoutActivityMode = .strength,
            cardioTitle: String? = nil,
            cardioMetric: String? = nil,
            cardioDetail: String? = nil,
            restEndsAt: Date? = nil,
            heartRate: Int? = nil
        ) {
            self.startedAt = startedAt
            self.exerciseName = exerciseName
            self.completedSets = completedSets
            self.totalSets = totalSets
            self.mode = mode
            self.cardioTitle = cardioTitle
            self.cardioMetric = cardioMetric
            self.cardioDetail = cardioDetail
            self.restEndsAt = restEndsAt
            self.heartRate = heartRate
        }
    }

    public enum WorkoutActivityMode: String, Codable, Hashable {
        case strength
        case cardio
    }

    public var workoutTitle: String

    public init(workoutTitle: String) {
        self.workoutTitle = workoutTitle
    }
}
#endif
