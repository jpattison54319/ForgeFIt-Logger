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
    /// Watch → phone "always latest" heart-rate channel. Carried through
    /// `updateApplicationContext` (not `sendMessage`/`transferUserInfo`) so a
    /// fresh reading is never dropped just because the watch display is off —
    /// `isReachable` tracks screen-on state, not whether the workout session
    /// is still streaming. Application context coalesces to a single latest
    /// value and is delivered the moment the phone reconnects, so this never
    /// replays a backlog of stale readings the way a queued transfer would.
    public static let liveMetricsKey = "forgefit.livemetrics"

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
    /// Optional for compatibility with contexts encoded by older app versions.
    /// The phone owns the daily verdict so the watch never reinterprets bands.
    public var readinessAction: String?
    public var readinessDetail: String?
    public var unitSuffix: String
    public var updatedAt: Date
    /// Optional so contexts encoded by an older watch/phone still decode; use
    /// the `??` accessors below.
    public var distanceUnit: DistanceUnit?
    public var hrZoneConfig: HRZoneConfig?

    public init(
        workout: WatchWorkoutSnapshot? = nil,
        routines: [WatchRoutineSummary] = [],
        readiness: Int? = nil,
        readinessAction: String? = nil,
        readinessDetail: String? = nil,
        unitSuffix: String = "lb",
        updatedAt: Date = Date(),
        distanceUnit: DistanceUnit? = nil,
        hrZoneConfig: HRZoneConfig? = nil
    ) {
        self.workout = workout
        self.routines = routines
        self.readiness = readiness
        self.readinessAction = readinessAction
        self.readinessDetail = readinessDetail
        self.unitSuffix = unitSuffix
        self.updatedAt = updatedAt
        self.distanceUnit = distanceUnit
        self.hrZoneConfig = hrZoneConfig
    }

    /// The user's distance unit, defaulting to km when a peer hasn't sent one.
    public var effectiveDistanceUnit: DistanceUnit { distanceUnit ?? .km }
    /// The user's HR-zone config, defaulting to the classic model.
    public var effectiveHRZoneConfig: HRZoneConfig { hrZoneConfig ?? HRZoneConfig() }
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
    /// Step kind raw value ("warmup"/"work"/"recover"/"cooldown") for
    /// work/rest coloring, the upcoming step's label, and a "Round 3 of 10"
    /// readout. All additive-optional so older snapshots still decode.
    public var intervalStepKind: String?
    public var intervalNextName: String?
    public var intervalRound: String?
    /// The active HR "zone lock" target (1...5), if a zone-locked cardio session
    /// is running — the watch fires its own haptic cues on leaving/re-entering.
    public var hrZoneTarget: Int?
    /// True when this is a yoga session — the watch engine records the
    /// HKWorkout as `.yoga`. Additive-optional so older snapshots decode.
    public var isYogaWorkout: Bool?

    public init(
        workoutID: UUID,
        title: String? = nil,
        startedAt: Date,
        exercises: [WatchExerciseSnapshot] = [],
        restEndsAt: Date? = nil,
        restTotalSeconds: Int? = nil,
        intervalStepName: String? = nil,
        intervalStepEndsAt: Date? = nil,
        intervalStepKind: String? = nil,
        intervalNextName: String? = nil,
        intervalRound: String? = nil,
        hrZoneTarget: Int? = nil,
        isYogaWorkout: Bool? = nil
    ) {
        self.workoutID = workoutID
        self.title = title
        self.startedAt = startedAt
        self.exercises = exercises
        self.restEndsAt = restEndsAt
        self.restTotalSeconds = restTotalSeconds
        self.intervalStepName = intervalStepName
        self.intervalStepEndsAt = intervalStepEndsAt
        self.intervalStepKind = intervalStepKind
        self.intervalNextName = intervalNextName
        self.intervalRound = intervalRound
        self.hrZoneTarget = hrZoneTarget
        self.isYogaWorkout = isYogaWorkout
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
    /// Yoga sessions share cardio's start/complete lifecycle on the wrist but
    /// render with yoga iconography. Additive-optional.
    public var isYoga: Bool?
    /// Raw cardio kind ("run", "cycle", etc.) so the watch can choose the
    /// correct HealthKit activity type. Additive-optional.
    public var cardioKindRaw: String?
    /// True for outdoor run/walk/ride sessions that should use outdoor
    /// HealthKit/location semantics. Additive-optional.
    public var supportsOutdoorRoute: Bool?
    public var supersetGroup: Int?
    public var cardioState: CardioState?
    public var sets: [WatchSetSnapshot]

    public init(
        id: UUID,
        name: String,
        isCardio: Bool = false,
        isYoga: Bool? = nil,
        cardioKindRaw: String? = nil,
        supportsOutdoorRoute: Bool? = nil,
        supersetGroup: Int? = nil,
        cardioState: CardioState? = nil,
        sets: [WatchSetSnapshot] = []
    ) {
        self.id = id
        self.name = name
        self.isCardio = isCardio
        self.isYoga = isYoga
        self.cardioKindRaw = cardioKindRaw
        self.supportsOutdoorRoute = supportsOutdoorRoute
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
    /// Live distance from the watch's workout session, in meters (nil until the
    /// session accumulates distance / for indoor sessions with no distance).
    public var distanceMeters: Double?
    /// Seconds spent in each of the 5 HR zones.
    public var hrZoneSeconds: [Int]
    public var asOf: Date

    public init(
        heartRate: Int? = nil,
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        distanceMeters: Double? = nil,
        hrZoneSeconds: [Int] = [],
        asOf: Date = Date()
    ) {
        self.heartRate = heartRate
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.distanceMeters = distanceMeters
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
