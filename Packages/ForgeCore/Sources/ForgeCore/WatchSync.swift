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
    /// Provenance for the optional readiness number. Older contexts omit this
    /// field and are rendered conservatively by the watch.
    public var readinessBasis: ForgeFitWidgetSnapshot.ReadinessBasis?
    public var unitSuffix: String
    public var updatedAt: Date
    /// Optional so contexts encoded by an older watch/phone still decode; use
    /// the `??` accessors below.
    public var distanceUnit: DistanceUnit?
    public var hrZoneConfig: HRZoneConfig?
    /// Additive optionals keep mixed-version phone/watch pairs decodable.
    public var themeFamily: ThemeFamily?
    public var themeMode: ForgeThemeMode?

    public init(
        workout: WatchWorkoutSnapshot? = nil,
        routines: [WatchRoutineSummary] = [],
        readiness: Int? = nil,
        readinessAction: String? = nil,
        readinessDetail: String? = nil,
        readinessBasis: ForgeFitWidgetSnapshot.ReadinessBasis? = nil,
        unitSuffix: String = "lb",
        updatedAt: Date = Date(),
        distanceUnit: DistanceUnit? = nil,
        hrZoneConfig: HRZoneConfig? = nil,
        themeFamily: ThemeFamily? = nil,
        themeMode: ForgeThemeMode? = nil
    ) {
        self.workout = workout
        self.routines = routines
        self.readiness = readiness
        self.readinessAction = readinessAction
        self.readinessDetail = readinessDetail
        self.readinessBasis = readinessBasis
        self.unitSuffix = unitSuffix
        self.updatedAt = updatedAt
        self.distanceUnit = distanceUnit
        self.hrZoneConfig = hrZoneConfig
        self.themeFamily = themeFamily
        self.themeMode = themeMode
    }

    /// The user's distance unit, defaulting to km when a peer hasn't sent one.
    /// Readiness belongs to one calendar day.
    ///
    /// WCSession retains the last application context indefinitely, and the
    /// phone only publishes while its app is running — so a watch that hasn't
    /// heard from the phone since yesterday is still holding yesterday's
    /// score. Reading it through this gate is what stops that number from
    /// being shown (and re-published to the complication) as if it were
    /// today's. Mirrors `ForgeFitWidgetSnapshot.isCurrent`: an active workout
    /// stays valid across midnight because its own lifecycle ends it.
    public func isReadinessCurrent(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        workout != nil || calendar.isDate(updatedAt, inSameDayAs: date)
    }

    /// `readiness`, or nil once it belongs to a previous day.
    public func currentReadiness(at date: Date = .now, calendar: Calendar = .current) -> Int? {
        isReadinessCurrent(at: date, calendar: calendar) ? readiness : nil
    }

    /// `readinessAction`, or nil once it belongs to a previous day.
    public func currentReadinessAction(at date: Date = .now, calendar: Calendar = .current) -> String? {
        isReadinessCurrent(at: date, calendar: calendar) ? readinessAction : nil
    }

    /// `readinessDetail`, or nil once it belongs to a previous day.
    public func currentReadinessDetail(at date: Date = .now, calendar: Calendar = .current) -> String? {
        isReadinessCurrent(at: date, calendar: calendar) ? readinessDetail : nil
    }

    /// `readinessBasis`, or nil once it belongs to a previous day.
    public func currentReadinessBasis(at date: Date = .now, calendar: Calendar = .current) -> ForgeFitWidgetSnapshot.ReadinessBasis? {
        isReadinessCurrent(at: date, calendar: calendar) ? readinessBasis : nil
    }

    public var effectiveDistanceUnit: DistanceUnit { distanceUnit ?? .km }
    /// The user's HR-zone config, defaulting to the classic model.
    public var effectiveHRZoneConfig: HRZoneConfig { hrZoneConfig ?? HRZoneConfig() }
    public var effectiveThemeFamily: ThemeFamily { themeFamily ?? .sage }
    public var effectiveThemeMode: ForgeThemeMode { themeMode ?? .dark }
}

/// Stable, small comparison key for the scarce complication-priority channel.
/// The day changes at local midnight; intra-day transfers occur only when the
/// readiness presentation actually changes (including clearing stale data).
public struct WatchComplicationDeliverySignature: Codable, Equatable, Sendable {
    public let day: Date
    public let readiness: Int?
    public let readinessAction: String?
    public let readinessDetail: String?
    public let readinessBasis: ForgeFitWidgetSnapshot.ReadinessBasis?

    public init?(context: WatchAppContext, calendar: Calendar = .current) {
        guard context.workout == nil else { return nil }
        day = calendar.startOfDay(for: context.updatedAt)
        readiness = context.readiness
        readinessAction = context.readinessAction
        readinessDetail = context.readinessDetail
        readinessBasis = context.readinessBasis
    }
}

public struct WatchRoutineSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var exerciseCount: Int
    /// Additive optionals preserve phone/watch compatibility during rollout.
    public var alternatingPartnerName: String?
    public var isNextInAlternation: Bool?

    public init(
        id: UUID,
        name: String,
        exerciseCount: Int,
        alternatingPartnerName: String? = nil,
        isNextInAlternation: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.exerciseCount = exerciseCount
        self.alternatingPartnerName = alternatingPartnerName
        self.isNextInAlternation = isNextInAlternation
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
    /// True while the countdown is a block micro-rest (myo-rep / drop / cluster)
    /// so the wrist can style it distinctly. Additive-optional.
    public var restIsMicro: Bool?
    /// Timer identity lets the wrist distinguish AMRAP work from ordinary
    /// post-set rest and keep the controls attached to the set that owns it.
    /// Additive optionals preserve mixed-version decoding.
    public var restLabel: String?
    public var restOwnerID: UUID?
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
    /// Shared conditioning state. Additive optionals keep mixed-version phone
    /// and watch installations compatible.
    public var conditioningPlan: ConditioningPlan?
    public var conditioningProgress: ConditioningProgress?

    public init(
        workoutID: UUID,
        title: String? = nil,
        startedAt: Date,
        exercises: [WatchExerciseSnapshot] = [],
        restEndsAt: Date? = nil,
        restTotalSeconds: Int? = nil,
        restIsMicro: Bool? = nil,
        restLabel: String? = nil,
        restOwnerID: UUID? = nil,
        intervalStepName: String? = nil,
        intervalStepEndsAt: Date? = nil,
        intervalStepKind: String? = nil,
        intervalNextName: String? = nil,
        intervalRound: String? = nil,
        hrZoneTarget: Int? = nil,
        isYogaWorkout: Bool? = nil,
        conditioningPlan: ConditioningPlan? = nil,
        conditioningProgress: ConditioningProgress? = nil
    ) {
        self.workoutID = workoutID
        self.title = title
        self.startedAt = startedAt
        self.exercises = exercises
        self.restEndsAt = restEndsAt
        self.restTotalSeconds = restTotalSeconds
        self.restIsMicro = restIsMicro
        self.restLabel = restLabel
        self.restOwnerID = restOwnerID
        self.intervalStepName = intervalStepName
        self.intervalStepEndsAt = intervalStepEndsAt
        self.intervalStepKind = intervalStepKind
        self.intervalNextName = intervalNextName
        self.intervalRound = intervalRound
        self.hrZoneTarget = hrZoneTarget
        self.isYogaWorkout = isYogaWorkout
        self.conditioningPlan = conditioningPlan
        self.conditioningProgress = conditioningProgress
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
    /// Position in the workout's shared exercise/block order. Optional for
    /// contexts produced before workout blocks existed.
    public var position: Int?
    /// The library id used by conditioning-plan movements. Additive-optional.
    public var exerciseID: UUID?
    public var name: String
    public var isCardio: Bool
    /// Yoga sessions share cardio's start/complete lifecycle on the wrist but
    /// render with yoga iconography. Additive-optional.
    public var isYoga: Bool?
    /// Non-nil when this row represents a first-class workout block rather
    /// than a library exercise. Older watches safely render it as cardio.
    public var workoutBlockKindRaw: String?
    public var conditioningPlan: ConditioningPlan?
    public var conditioningProgress: ConditioningProgress?
    public var conditioningMovementNames: [UUID: String]?
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
        position: Int? = nil,
        exerciseID: UUID? = nil,
        name: String,
        isCardio: Bool = false,
        isYoga: Bool? = nil,
        workoutBlockKindRaw: String? = nil,
        conditioningPlan: ConditioningPlan? = nil,
        conditioningProgress: ConditioningProgress? = nil,
        conditioningMovementNames: [UUID: String]? = nil,
        cardioKindRaw: String? = nil,
        supportsOutdoorRoute: Bool? = nil,
        supersetGroup: Int? = nil,
        cardioState: CardioState? = nil,
        sets: [WatchSetSnapshot] = []
    ) {
        self.id = id
        self.position = position
        self.exerciseID = exerciseID
        self.name = name
        self.isCardio = isCardio
        self.isYoga = isYoga
        self.workoutBlockKindRaw = workoutBlockKindRaw
        self.conditioningPlan = conditioningPlan
        self.conditioningProgress = conditioningProgress
        self.conditioningMovementNames = conditioningMovementNames
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
    /// Additive set semantics for full wrist execution. Older peers omit
    /// these and continue to render the original flat weight/reps row.
    public var setTypeRaw: String?
    public var weightModeRaw: String?
    public var durationSeconds: Int?
    public var isUnilateral: Bool?
    public var miniReps: [Int]?
    public var side2Reps: Int?
    public var side2MiniReps: [Int]?
    public var plannedMiniSetCount: Int?
    public var plannedMiniReps: [Int]?
    public var microRestSeconds: Int?
    /// Compact authored context such as "82.5% e1RM". Additive optional so
    /// mixed app/Watch versions continue to decode and log concrete loads.
    public var loadPrescriptionText: String?
    /// Machine-readable prescription mode and immutable authored rep target.
    /// All are additive optional for compatibility with older peers.
    public var loadPrescriptionModeRaw: String?
    public var prescribedRepsLow: Int?
    public var prescribedRepsHigh: Int?

    public init(
        id: UUID,
        label: String,
        weight: Double? = nil,
        unitSuffix: String? = nil,
        weightKg: Double? = nil,
        reps: Int? = nil,
        completed: Bool = false,
        setTypeRaw: String? = nil,
        weightModeRaw: String? = nil,
        durationSeconds: Int? = nil,
        isUnilateral: Bool? = nil,
        miniReps: [Int]? = nil,
        side2Reps: Int? = nil,
        side2MiniReps: [Int]? = nil,
        plannedMiniSetCount: Int? = nil,
        plannedMiniReps: [Int]? = nil,
        microRestSeconds: Int? = nil,
        loadPrescriptionText: String? = nil,
        loadPrescriptionModeRaw: String? = nil,
        prescribedRepsLow: Int? = nil,
        prescribedRepsHigh: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.weight = weight
        self.unitSuffix = unitSuffix
        self.weightKg = weightKg
        self.reps = reps
        self.completed = completed
        self.setTypeRaw = setTypeRaw
        self.weightModeRaw = weightModeRaw
        self.durationSeconds = durationSeconds
        self.isUnilateral = isUnilateral
        self.miniReps = miniReps
        self.side2Reps = side2Reps
        self.side2MiniReps = side2MiniReps
        self.plannedMiniSetCount = plannedMiniSetCount
        self.plannedMiniReps = plannedMiniReps
        self.microRestSeconds = microRestSeconds
        self.loadPrescriptionText = loadPrescriptionText
        self.loadPrescriptionModeRaw = loadPrescriptionModeRaw
        self.prescribedRepsLow = prescribedRepsLow
        self.prescribedRepsHigh = prescribedRepsHigh
    }

    public var setType: SetType {
        setTypeRaw.flatMap(SetType.init(rawValue:)) ?? .working
    }

    public var weightMode: WeightMode {
        weightModeRaw.flatMap(WeightMode.init(rawValue:)) ?? .external
    }

    public var supportsLoadEntry: Bool { weightMode != .bodyweight }
    public var usesSides: Bool { isUnilateral == true }
    public var isStructured: Bool { setType.isBlockType }
    public var isAMRAP: Bool { setType == .amrap }
    public var loadPrescriptionMode: LoadPrescriptionMode {
        loadPrescriptionModeRaw.flatMap(LoadPrescriptionMode.init(rawValue:)) ?? .fixed
    }
    public var prescribedRepTarget: PlannedRepTarget? {
        PlannedRepTarget(low: prescribedRepsLow, high: prescribedRepsHigh)
    }
    public var requiresConcreteRepsBeforeCompletion: Bool {
        loadPrescriptionMode == .percentEstimatedOneRepMax
            && !isStructured
            && !isAMRAP
            && prescribedRepTarget?.exactValue == nil
            && reps == nil
    }
    public var effectiveMicroRestSeconds: Int {
        microRestSeconds ?? setType.defaultMicroRestSeconds ?? 15
    }

    public var structuredProgress: WatchStructuredSetProgress {
        WatchStructuredSetProgress(
            activationReps: setType == .cluster ? nil : reps,
            miniReps: miniReps ?? [],
            side2ActivationReps: setType == .cluster ? nil : side2Reps,
            side2MiniReps: side2MiniReps ?? []
        )
    }
}

/// The performed state of one Myo/rest-pause/cluster block. It is sent as one
/// atomic value so activation and every mini-set stay in order across a queued
/// WatchConnectivity delivery.
public struct WatchStructuredSetProgress: Codable, Sendable, Equatable {
    public var activationReps: Int?
    public var miniReps: [Int]
    public var side2ActivationReps: Int?
    public var side2MiniReps: [Int]

    public init(
        activationReps: Int? = nil,
        miniReps: [Int] = [],
        side2ActivationReps: Int? = nil,
        side2MiniReps: [Int] = []
    ) {
        self.activationReps = activationReps
        self.miniReps = miniReps
        self.side2ActivationReps = side2ActivationReps
        self.side2MiniReps = side2MiniReps
    }

    public func activation(for side: Int) -> Int? {
        side == 2 ? side2ActivationReps : activationReps
    }

    public func minis(for side: Int) -> [Int] {
        side == 2 ? side2MiniReps : miniReps
    }

    public mutating func setActivation(_ reps: Int?, for side: Int) {
        if side == 2 { side2ActivationReps = reps } else { activationReps = reps }
    }

    public mutating func setMinis(_ reps: [Int], for side: Int) {
        if side == 2 { side2MiniReps = reps } else { miniReps = reps }
    }
}

public enum WatchStructuredSetEventKind: String, Codable, Sendable, Equatable {
    case activation
    case miniSet
    case correction
}

/// Describes why structured progress changed. The timestamp lets the phone
/// avoid starting a stale micro-rest when an offline Watch command arrives
/// after the athlete has already moved on.
public struct WatchStructuredSetUpdate: Codable, Sendable, Equatable {
    public var progress: WatchStructuredSetProgress
    public var event: WatchStructuredSetEventKind
    public var side: Int
    public var occurredAt: Date
    public var weightKg: Double?

    public init(
        progress: WatchStructuredSetProgress,
        event: WatchStructuredSetEventKind,
        side: Int,
        occurredAt: Date = Date(),
        weightKg: Double? = nil
    ) {
        self.progress = progress
        self.event = event
        self.side = side
        self.occurredAt = occurredAt
        self.weightKg = weightKg
    }
}

// MARK: - Live metrics (watch → phone)

/// Rolling health metrics from the watch's workout session. The final values
/// are stored on the workout itself so the user can reflect on them later.
public struct WatchLiveMetrics: Codable, Sendable, Equatable {
    /// A live HR value older than this is a sensor/session gap, not a current
    /// reading. Workout sessions normally deliver wrist samples every few
    /// seconds; 15 seconds leaves room for HealthKit batching without letting
    /// a frozen value masquerade as live.
    public static let heartRateFreshnessInterval: TimeInterval = 15

    /// Workout whose HKWorkoutSession produced this packet. Additive optional
    /// for mixed-version decoding; the phone rejects nil/mismatched identity
    /// rather than attributing an old Watch stream to a newer workout.
    public var workoutID: UUID?
    public var heartRate: Int?
    public var avgHR: Int?
    public var maxHR: Int?
    public var activeEnergyKcal: Double?
    /// Live distance from the watch's workout session, in meters (nil until the
    /// session accumulates distance / for indoor sessions with no distance).
    public var distanceMeters: Double?
    /// Seconds spent in each of the 5 HR zones.
    public var hrZoneSeconds: [Int]
    /// Time of the heart-rate sample when `heartRate` is present. Producers
    /// without HR use their packet timestamp instead.
    public var asOf: Date

    public init(
        workoutID: UUID? = nil,
        heartRate: Int? = nil,
        avgHR: Int? = nil,
        maxHR: Int? = nil,
        activeEnergyKcal: Double? = nil,
        distanceMeters: Double? = nil,
        hrZoneSeconds: [Int] = [],
        asOf: Date = Date()
    ) {
        self.workoutID = workoutID
        self.heartRate = heartRate
        self.avgHR = avgHR
        self.maxHR = maxHR
        self.activeEnergyKcal = activeEnergyKcal
        self.distanceMeters = distanceMeters
        self.hrZoneSeconds = hrZoneSeconds
        self.asOf = asOf
    }

    public func freshHeartRate(at date: Date = Date()) -> Int? {
        guard let heartRate,
              date.timeIntervalSince(asOf) <= Self.heartRateFreshnessInterval else { return nil }
        return heartRate
    }
}

// MARK: - Widget snapshot (app → widget)

public struct ForgeFitWidgetSnapshot: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case idle
        case activeWorkout
    }

    /// What a readiness number actually measures. This travels with the
    /// snapshot because a bare integer is ambiguous: the Home screen may show
    /// a seven-day trend while a filled "N% ready" gauge claims something
    /// about today.
    public enum ReadinessBasis: String, Codable, Sendable {
        case daily
        case trend
    }

    public var mode: Mode
    public var updatedAt: Date
    public var readinessScore: Int?
    /// Optional keeps snapshots written by older app versions decodable. A
    /// new producer must set it whenever it publishes a score.
    public var readinessBasis: ReadinessBasis?
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
        readinessBasis: ReadinessBasis? = nil,
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
        self.readinessBasis = readinessBasis
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

    /// Idle readiness belongs to one calendar day. Active-workout snapshots
    /// remain valid across midnight because their own lifecycle ends them.
    public func isCurrent(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        mode == .activeWorkout || calendar.isDate(updatedAt, inSameDayAs: date)
    }

    /// True when both snapshots would draw the same widget or complication.
    ///
    /// `updatedAt` advances on every publish, so raw equality reports a change
    /// even when nothing on the face moved. Reload requests are the scarce
    /// resource — WidgetKit budgets them to roughly 40-70 a day per widget —
    /// so the decision to spend one has to be made on rendered content alone.
    public func rendersSameContent(as other: ForgeFitWidgetSnapshot) -> Bool {
        var comparison = self
        comparison.updatedAt = other.updatedAt
        return comparison == other
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

    /// Remove the snapshot entirely, leaving readers with no data rather than
    /// an empty one. Account reset needs this: the snapshot lives in the app
    /// group and outlives every store the reset clears.
    public static func clear(defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard) {
        defaults.removeObject(forKey: key)
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
    /// Perform activation and mini-set progress for Myo/rest-pause/cluster
    /// blocks. The phone remains the persisted source of truth.
    case updateStructuredSet(setID: UUID, update: WatchStructuredSetUpdate)
    /// Run the fixed work window belonging to an AMRAP set. `endsAt` is an
    /// absolute wrist timestamp so delayed delivery never shifts the workout.
    case startSetTimer(setID: UUID, durationSeconds: Int, endsAt: Date)
    case stopSetTimer(setID: UUID, elapsedSeconds: Int)
    case startCardio(workoutExerciseID: UUID)
    case completeCardio(workoutExerciseID: UUID)
    case liveMetrics(WatchLiveMetrics)
    case conditioningEvent(ConditioningProgressEvent)
    case conditioningBlockEvent(blockID: UUID, event: ConditioningProgressEvent)
    /// `savedToHealth` is true when the watch's HKLiveWorkoutBuilder already
    /// wrote the HKWorkout — the phone then skips its own write to avoid
    /// double-counting in Apple Health. `workoutID` binds the command to the
    /// exact workout the wrist was mirroring when the user tapped Finish, so a
    /// slow-delivered command for a superseded workout is dropped by the phone
    /// instead of terminating whatever is active there. Additive-optional:
    /// pre-binding payloads decode as `nil`, which the phone handler refuses.
    case finishWorkout(workoutID: UUID?, metrics: WatchLiveMetrics?, savedToHealth: Bool)
    /// Bidirectional terminal command: whichever device receives it cancels
    /// and discards its local live workout resources. `workoutID` binds the
    /// watch → phone direction — the phone drops a discard whose ID no longer
    /// matches its active workout. Phone → watch sends stay authoritative: the
    /// watch clears its mirror unconditionally and ignores the carried ID.
    case discardWorkout(workoutID: UUID?)

    // phone → watch
    case workoutFinished
    /// watch → phone: "publish a fresh context". The watch can't refresh
    /// day-scoped data on its own — without this it shows whatever the phone
    /// last pushed until the user opens the phone app.
    case requestContext
}

// MARK: - Terminal-command identity policy (FF-002)

/// The shared gate for watch → phone terminal commands. Keeping the decision in
/// ForgeCore lets the watch store and the phone handler both run the exact
/// tested policy, and gives unit tests a pure surface independent of
/// WatchConnectivity and the UI.
public enum WatchTerminalCommandPolicy {
    /// The phone may execute a terminal command only for the exact workout it
    /// names. A nil carried ID is the legacy pre-binding wire form —
    /// unverifiable — and any mismatch means the command is stale; both are
    /// refused, and the phone re-publishes its authoritative snapshot so a
    /// watch that cleared itself on the stale command converges.
    public static func shouldExecute(carriedWorkoutID: UUID?, activeWorkoutID: UUID?) -> Bool {
        guard let carriedWorkoutID, let activeWorkoutID else { return false }
        return carriedWorkoutID == activeWorkoutID
    }

    /// The watch may run finish/discard only once the visible workout carries
    /// authoritative identity. A phone-start placeholder awaits the real
    /// snapshot and shows a fabricated `workoutID`: mutating the engine,
    /// saving to HealthKit, or sending a terminal command against it would
    /// have been refused by the phone anyway, so the command is refused up
    /// front, before any local mutation.
    public static func mayRunTerminalCommand(isAwaitingIdentity: Bool) -> Bool {
        !isAwaitingIdentity
    }
}

// MARK: - Engine workout identity policy (FF-003)

/// The watch engine's live HKWorkoutSession is bound to the workout it was
/// started for, and that identity is carried through interrupts. Recovery
/// reattaches a session that may belong to an earlier workout; an unverified
/// or mismatched session must never resume or stream under the current
/// snapshot. This pure decision surface is shared by the watch store's two
/// session-reconciliation points (authoritative snapshot apply and
/// post-recovery bootstrap) and is exactly what the unit tests pin down —
/// the Watch target has no unit-test target of its own, so the policy lives
/// here in ForgeCore like FF-002's `WatchTerminalCommandPolicy`.
public enum WatchEngineIdentityPolicy {

    /// What the engine's active (or recovered) session is bound to.
    public enum Resolution: Equatable, Sendable {
        /// No session and nothing to start.
        case idle
        /// No live session and an authoritative context names a workout;
        /// start one for it.
        case startSession
        /// A live session exists but no authoritative phone snapshot has been
        /// received yet. The session is quarantined: it must NOT stream, and
        /// it must NOT be cancelled merely because WCSession delivery is
        /// slow. The first authoritative snapshot — matching, mismatched, or
        /// with no workout — resolves it.
        case awaitContext
        /// The live session's identity matches the context workout; it is
        /// left streaming untouched (normal recovery).
        case keepStreaming
        /// The live session is stale or unverifiable and the authoritative
        /// context declares no workout: end it without saving.
        case endSession
        /// The live session is stale or unverifiable and the authoritative
        /// context names a different workout: end the stale session, then
        /// start a fresh one for the current workout. The stale session is
        /// never resumed under the newer identity.
        case endSessionAndStartCurrent
    }

    /// Reconcile the engine's live session against the phone's state.
    ///
    /// - Parameters:
    ///   - engineHasSession: `WatchWorkoutEngine.hasActiveSession` — covers a
    ///     live, starting, or recovering session.
    ///   - sessionWorkoutID: the identity bound to that session. Nil means
    ///     either the session predates identity recording (legacy/upgrade) or
    ///     it was started from the phone-start handoff whose real identity is
    ///     still pending — in both cases it can only be bound or ended, never
    ///     assumed to belong to the current workout.
    ///   - hasAuthoritativeContext: whether the phone has EVER published an
    ///     authoritative snapshot to this watch process. Distinct from
    ///     `contextWorkoutID == nil` — the mirror can be absent simply because
    ///     WCSession is slow, which must not be mistaken for the phone saying
    ///     the workout is over.
    ///   - contextWorkoutID: the current snapshot's workout id (nil when the
    ///     authoritative snapshot declares no active workout).
    public static func resolve(
        engineHasSession: Bool,
        sessionWorkoutID: UUID?,
        hasAuthoritativeContext: Bool,
        contextWorkoutID: UUID?
    ) -> Resolution {
        guard engineHasSession else {
            guard hasAuthoritativeContext, contextWorkoutID != nil else { return .idle }
            return .startSession
        }
        // A live session with no authoritative snapshot yet is quarantined,
        // not ended — WCSession being slow is not evidence the workout ended.
        guard hasAuthoritativeContext else { return .awaitContext }
        if let sessionWorkoutID, let contextWorkoutID, sessionWorkoutID == contextWorkoutID {
            return .keepStreaming
        }
        return contextWorkoutID == nil ? .endSession : .endSessionAndStartCurrent
    }

    /// Live metrics may only be sent to the phone while the streaming session
    /// is verifiably the current workout's and the phone has resolved a
    /// pending handoff identity. A quarantined session (no authoritative
    /// mirror, or `isAwaitingWorkoutIdentity` still set) and a session whose
    /// identity differs from the mirror must not emit — the caller's
    /// reconcile actions clean those sessions up at the next snapshot.
    public static func mayStreamMetrics(
        sessionWorkoutID: UUID?,
        isAwaitingAuthoritativeIdentity: Bool,
        contextWorkoutID: UUID?
    ) -> Bool {
        guard !isAwaitingAuthoritativeIdentity, let sessionWorkoutID, let contextWorkoutID else {
            return false
        }
        return sessionWorkoutID == contextWorkoutID
    }

    /// A session may be re-bound only when the engine itself durably records
    /// that it accepted a phone handoff and still has no workout identity.
    /// A UI placeholder flag is intentionally insufficient: it can coexist
    /// with a recovered A session while a new B handoff arrives.
    public static func mayBindPendingHandoff(
        sessionWorkoutID: UUID?,
        isPendingHandoff: Bool,
        contextWorkoutID: UUID?
    ) -> Bool {
        isPendingHandoff && sessionWorkoutID == nil && contextWorkoutID != nil
    }
}

// MARK: - Recovered outdoor-route policy (FF-010)

/// HealthKit-free policy for watch route startup/recovery. Recovery begins a
/// new route segment only for an active outdoor workout, and rejects cached
/// Core Location updates from before the new segment began so prior route
/// points cannot be inserted twice.
public enum WatchRouteCollectionPolicy {
    public static func shouldStart(
        isOutdoor: Bool,
        isSessionActive: Bool,
        isAlreadyCollecting: Bool
    ) -> Bool {
        isOutdoor && isSessionActive && !isAlreadyCollecting
    }

    public static func shouldInsertLocation(
        timestamp: Date,
        horizontalAccuracy: Double,
        segmentStartedAt: Date
    ) -> Bool {
        horizontalAccuracy >= 0
            && horizontalAccuracy <= 100
            && timestamp >= segmentStartedAt
    }
}

// MARK: - Engine session identity persistence (FF-003)

/// Durable record of which workout the currently-live (possibly recovered)
/// engine session was started for. Written when a session begins, cleared
/// when it ends, and read when watchOS relaunches the watch app mid-workout,
/// so recovery reattaches with the originating identity in hand instead of
/// letting the session stream under whatever snapshot is current. A workout
/// identity UUID only — never health data, never crosses the wire, and it
/// lives in the watch's own defaults, not the shared app group.
///
/// Hosted in ForgeCore (like `ForgeFitWidgetSnapshotStore`) so the
/// clear/persist lifecycle is deterministic in unit tests via the injectable
/// `defaults`; the watch app and engine use the `UserDefaults.standard`
/// default.
public enum WatchSessionIdentityStore {
    public static let key = "forgefit.watch.engine.sessionWorkoutID"
    public static let pendingHandoffKey = "forgefit.watch.engine.sessionIdentityPendingHandoff"

    public static func load(defaults: UserDefaults = UserDefaults.standard) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    public static func save(_ id: UUID?, defaults: UserDefaults = UserDefaults.standard) {
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public static func isPendingHandoff(defaults: UserDefaults = UserDefaults.standard) -> Bool {
        defaults.bool(forKey: pendingHandoffKey)
    }

    public static func savePendingHandoff(
        _ pending: Bool,
        defaults: UserDefaults = UserDefaults.standard
    ) {
        if pending {
            defaults.set(true, forKey: pendingHandoffKey)
        } else {
            defaults.removeObject(forKey: pendingHandoffKey)
        }
    }

    public static func clear(defaults: UserDefaults = UserDefaults.standard) {
        save(nil, defaults: defaults)
        savePendingHandoff(false, defaults: defaults)
    }
}

/// Phone-side attribution guard for live Watch metrics. Older packets decode
/// with a nil workoutID and are dropped: temporarily losing a live number is
/// safer than persisting A's heart rate, distance, or energy onto workout B.
public enum WatchLiveMetricsAttributionPolicy {
    public static func mayApply(metricsWorkoutID: UUID?, activeWorkoutID: UUID?) -> Bool {
        guard let metricsWorkoutID, let activeWorkoutID else { return false }
        return metricsWorkoutID == activeWorkoutID
    }
}
