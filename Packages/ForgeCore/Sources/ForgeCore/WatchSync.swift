import Foundation

// MARK: - Watch ⇄ iPhone wire protocol
//
// The iPhone owns the data (SwiftData + cloud sync); the watch is a live
// mirror. The phone publishes a `WatchAppContext` snapshot through
// WCSession's application context (latest-wins, delivered even when the watch
// app launches later), and both sides exchange `WatchCommand`s as messages
// (instant when reachable, queued user-info transfers otherwise).

public enum WatchWire {
    public static let contextKey = "forgefit.context"
    public static let commandKey = "forgefit.command"

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}

// MARK: - Snapshot (phone → watch)

/// Everything the watch needs to render: the live workout (if any), the
/// routine list for starting one from the wrist, and today's readiness.
public struct WatchAppContext: Codable, Sendable, Equatable {
    public var workout: WatchWorkoutSnapshot?
    public var routines: [WatchRoutineSummary]
    public var readiness: Int?
    public var unitSuffix: String
    public var updatedAt: Date

    public init(
        workout: WatchWorkoutSnapshot? = nil,
        routines: [WatchRoutineSummary] = [],
        readiness: Int? = nil,
        unitSuffix: String = "lb",
        updatedAt: Date = Date()
    ) {
        self.workout = workout
        self.routines = routines
        self.readiness = readiness
        self.unitSuffix = unitSuffix
        self.updatedAt = updatedAt
    }
}

public struct WatchRoutineSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var exerciseCount: Int

    public init(id: UUID, name: String, exerciseCount: Int) {
        self.id = id
        self.name = name
        self.exerciseCount = exerciseCount
    }
}

public struct WatchWorkoutSnapshot: Codable, Sendable, Equatable {
    public var workoutID: UUID
    public var title: String?
    public var startedAt: Date
    public var exercises: [WatchExerciseSnapshot]
    /// Mirror of the phone's rest timer so the watch shows the same countdown.
    public var restEndsAt: Date?
    public var restTotalSeconds: Int?
    /// Mirror of the phone's interval runner (structured cardio): current
    /// step name + when it ends. Display only — the phone drives execution.
    public var intervalStepName: String?
    public var intervalStepEndsAt: Date?

    public init(
        workoutID: UUID,
        title: String? = nil,
        startedAt: Date,
        exercises: [WatchExerciseSnapshot] = [],
        restEndsAt: Date? = nil,
        restTotalSeconds: Int? = nil,
        intervalStepName: String? = nil,
        intervalStepEndsAt: Date? = nil
    ) {
        self.workoutID = workoutID
        self.title = title
        self.startedAt = startedAt
        self.exercises = exercises
        self.restEndsAt = restEndsAt
        self.restTotalSeconds = restTotalSeconds
        self.intervalStepName = intervalStepName
        self.intervalStepEndsAt = intervalStepEndsAt
    }

    public var completedSets: Int {
        exercises.reduce(0) { $0 + $1.sets.filter(\.completed).count }
    }
    public var totalSets: Int {
        exercises.reduce(0) { $0 + $1.sets.count }
    }
}

public struct WatchExerciseSnapshot: Codable, Sendable, Equatable, Identifiable {
    public enum CardioState: String, Codable, Sendable {
        case notStarted, running, completed
    }

    /// The `WorkoutExerciseModel` id.
    public var id: UUID
    public var name: String
    public var isCardio: Bool
    public var supersetGroup: Int?
    public var cardioState: CardioState?
    public var sets: [WatchSetSnapshot]

    public init(
        id: UUID,
        name: String,
        isCardio: Bool = false,
        supersetGroup: Int? = nil,
        cardioState: CardioState? = nil,
        sets: [WatchSetSnapshot] = []
    ) {
        self.id = id
        self.name = name
        self.isCardio = isCardio
        self.supersetGroup = supersetGroup
        self.cardioState = cardioState
        self.sets = sets
    }
}

public struct WatchSetSnapshot: Codable, Sendable, Equatable, Identifiable {
    /// The `SetModel` id.
    public var id: UUID
    /// Display label: "1", "2", "3B" for numbered sets or "W"/"D"/"M"… badges.
    public var label: String
    /// Weight in the exercise's DISPLAY unit (for rendering).
    public var weight: Double?
    public var unitSuffix: String?
    /// Weight in kilograms (the data-layer unit) — drives exact step math
    /// when editing from the wrist.
    public var weightKg: Double?
    public var reps: Int?
    public var completed: Bool

    public init(
        id: UUID,
        label: String,
        weight: Double? = nil,
        unitSuffix: String? = nil,
        weightKg: Double? = nil,
        reps: Int? = nil,
        completed: Bool = false
    ) {
        self.id = id
        self.label = label
        self.weight = weight
        self.unitSuffix = unitSuffix
        self.weightKg = weightKg
        self.reps = reps
        self.completed = completed
    }
}

// MARK: - Live metrics (watch → phone)

/// Rolling health metrics from the watch's workout session. The final values
/// are stored on the workout itself so the user can reflect on them later.
public struct WatchLiveMetrics: Codable, Sendable, Equatable {
    public var heartRate: Int?
    public var avgHR: Int?
    public var maxHR: Int?
    public var activeEnergyKcal: Double?
    /// Seconds spent in each of the 5 HR zones.
    public var hrZoneSeconds: [Int]
    public var asOf: Date

    public init(
        heartRate: Int? = nil,
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        hrZoneSeconds: [Int] = [],
        asOf: Date = Date()
    ) {
        self.heartRate = heartRate
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.hrZoneSeconds = hrZoneSeconds
        self.asOf = asOf
    }
}

// MARK: - Widget snapshot (app → widget)

public struct ForgeFitWidgetSnapshot: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case idle
        case activeWorkout
    }

    public var mode: Mode
    public var updatedAt: Date
    public var readinessScore: Int?
    public var readinessAction: String?
    public var readinessDetail: String?
    public var reasonChips: [String]
    public var workoutTitle: String?
    public var workoutStartedAt: Date?
    public var currentExerciseName: String?
    public var completedSets: Int
    public var totalSets: Int
    public var restEndsAt: Date?
    public var heartRate: Int?

    public init(
        mode: Mode,
        updatedAt: Date = Date(),
        readinessScore: Int? = nil,
        readinessAction: String? = nil,
        readinessDetail: String? = nil,
        reasonChips: [String] = [],
        workoutTitle: String? = nil,
        workoutStartedAt: Date? = nil,
        currentExerciseName: String? = nil,
        completedSets: Int = 0,
        totalSets: Int = 0,
        restEndsAt: Date? = nil,
        heartRate: Int? = nil
    ) {
        self.mode = mode
        self.updatedAt = updatedAt
        self.readinessScore = readinessScore
        self.readinessAction = readinessAction
        self.readinessDetail = readinessDetail
        self.reasonChips = reasonChips
        self.workoutTitle = workoutTitle
        self.workoutStartedAt = workoutStartedAt
        self.currentExerciseName = currentExerciseName
        self.completedSets = completedSets
        self.totalSets = totalSets
        self.restEndsAt = restEndsAt
        self.heartRate = heartRate
    }
}

public enum ForgeFitWidgetSnapshotStore {
    public static let suiteName = "group.org.xpetsllc.ForgeFit"
    public static let key = "forgefit.widget.snapshot"

    public static func load(defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard) -> ForgeFitWidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ForgeFitWidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: ForgeFitWidgetSnapshot, defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Commands (both directions)

/// Actions either device can request of the other. The phone is the source of
/// truth: watch commands mutate phone data, and the updated snapshot flows
/// back through the application context.
public enum WatchCommand: Codable, Sendable {
    // watch → phone
    case startRoutine(routineID: UUID)
    case startEmpty
    case toggleSet(setID: UUID, completed: Bool)
    /// Edit a set's load/reps from the wrist. `weightKg` is in kilograms
    /// (the data-layer unit); nil fields are left unchanged.
    case updateSet(setID: UUID, weightKg: Double?, reps: Int?)
    case startCardio(workoutExerciseID: UUID)
    case completeCardio(workoutExerciseID: UUID)
    case liveMetrics(WatchLiveMetrics)
    /// `savedToHealth` is true when the watch's HKLiveWorkoutBuilder already
    /// wrote the HKWorkout — the phone then skips its own write to avoid
    /// double-counting in Apple Health.
    case finishWorkout(metrics: WatchLiveMetrics?, savedToHealth: Bool)
    case discardWorkout

    // phone → watch
    case workoutFinished
}
