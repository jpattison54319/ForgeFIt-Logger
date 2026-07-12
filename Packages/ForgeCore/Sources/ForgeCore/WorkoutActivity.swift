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
        /// What's coming after the current exercise — nil on the final one
        /// (the UI shows a "final exercise" state instead of a name).
        public var nextExerciseName: String?
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
        /// Yoga mode: wall-clock end of the current pose hold, so the lock
        /// screen renders a native countdown. Nil outside a guided class.
        public var poseEndsAt: Date?

        public init(
            startedAt: Date,
            exerciseName: String? = nil,
            nextExerciseName: String? = nil,
            completedSets: Int = 0,
            totalSets: Int = 0,
            mode: WorkoutActivityMode = .strength,
            cardioTitle: String? = nil,
            cardioMetric: String? = nil,
            cardioDetail: String? = nil,
            restEndsAt: Date? = nil,
            heartRate: Int? = nil,
            poseEndsAt: Date? = nil
        ) {
            self.startedAt = startedAt
            self.exerciseName = exerciseName
            self.nextExerciseName = nextExerciseName
            self.completedSets = completedSets
            self.totalSets = totalSets
            self.mode = mode
            self.cardioTitle = cardioTitle
            self.cardioMetric = cardioMetric
            self.cardioDetail = cardioDetail
            self.restEndsAt = restEndsAt
            self.heartRate = heartRate
            self.poseEndsAt = poseEndsAt
        }
    }

    public enum WorkoutActivityMode: String, Codable, Hashable {
        case strength
        case cardio
        case yoga
    }

    public var workoutTitle: String

    public init(workoutTitle: String) {
        self.workoutTitle = workoutTitle
    }
}
#endif
