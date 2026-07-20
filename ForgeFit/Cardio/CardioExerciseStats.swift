import Foundation
import ForgeCore
import ForgeData

/// Per-exercise cardio analytics for the exercise detail screen. The strength
/// detail page charts e1RM from set rows; cardio logs as `CardioSessionModel`,
/// so its progression, records, and history all derive from sessions — and the
/// metric vocabulary follows the exercise's `CardioKind` contract (a rower
/// speaks /500m splits, a stair machine floors, a pool /100m pace).
nonisolated enum CardioExerciseStats {

    /// One performed session of this exercise. `session` is nil only for
    /// legacy set-based cardio logs, which carried duration on their sets.
    struct SessionEntry: Identifiable {
        let workout: WorkoutModel
        let session: CardioSessionModel?
        let legacyDurationSeconds: Int?

        var id: UUID { session?.id ?? workout.id }
        var date: Date { session?.startedAt ?? workout.startedAt }
        var durationSeconds: Int? { session?.durationSeconds ?? legacyDurationSeconds }
    }

    /// Every session of `exerciseID` across `workouts`, newest first.
    /// Sessions match through `workoutExerciseID`; yoga imports carry nil
    /// there, so yoga entries fall back to "this workout contains the pose
    /// and the session is a yoga session".
    static func entries(for exerciseID: UUID, in workouts: [WorkoutModel], isYoga: Bool = false) -> [SessionEntry] {
        workouts
            .filter { $0.deletedAt == nil }
            .flatMap { workout -> [SessionEntry] in
                let exerciseRowIDs = Set(
                    workout.exercises.filter { $0.exerciseID == exerciseID }.map(\.id)
                )
                guard !exerciseRowIDs.isEmpty else { return [] }
                let sessions = workout.cardioSessions.filter { session in
                    guard session.deletedAt == nil else { return false }
                    if let rowID = session.workoutExerciseID { return exerciseRowIDs.contains(rowID) }
                    return isYoga && session.isYogaSession
                }
                if !sessions.isEmpty {
                    return sessions.map { SessionEntry(workout: workout, session: $0, legacyDurationSeconds: nil) }
                }
                // Legacy set-based cardio: duration lived on completed sets.
                let setSeconds = workout.exercises
                    .filter { exerciseRowIDs.contains($0.id) }
                    .flatMap(\.sets)
                    .filter { $0.completedAt != nil }
                    .compactMap(\.durationSeconds)
                    .reduce(0, +)
                guard setSeconds > 0 else { return [] }
                return [SessionEntry(workout: workout, session: nil, legacyDurationSeconds: setSeconds)]
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Trend

    /// The metric the progression chart plots. Point values stay in the
    /// metric's canonical unit (sec/km, sec/500m, watts…); `format` renders
    /// them in the user's display units.
    enum TrendMetric: Equatable {
        case pace          // sec per km, land pace in the user's km/mi unit
        case split500      // sec per 500 m (rower)
        case swimPace100   // sec per 100 m (pool contract — fixed meters)
        case speed         // km/h
        case power         // watts
        case floors        // floors per session
        case jumps         // jumps per session
        case distance      // meters per session
        case duration      // seconds per session

        var title: String {
            switch self {
            case .pace: "Pace"
            case .split500: "Split /500m"
            case .swimPace100: "Pace /100m"
            case .speed: "Speed"
            case .power: "Avg Power"
            case .floors: "Floors"
            case .jumps: "Jumps"
            case .distance: "Distance"
            case .duration: "Duration"
            }
        }

        /// Pace-family metrics improve downward; the info line names that so
        /// a descending chart isn't misread as regression.
        var lowerIsBetter: Bool {
            switch self {
            case .pace, .split500, .swimPace100: true
            default: false
            }
        }

        func format(_ value: Double, distanceUnit: DistanceUnit) -> String {
            switch self {
            case .pace:
                let secPerUnit = value * (distanceUnit.metersPerUnit / 1000)
                return String(format: "%d:%02d %@", Int(secPerUnit) / 60, Int(secPerUnit) % 60, distanceUnit.paceSuffix)
            case .split500:
                return String(format: "%d:%02d /500m", Int(value) / 60, Int(value) % 60)
            case .swimPace100:
                return String(format: "%d:%02d /100m", Int(value) / 60, Int(value) % 60)
            case .speed:
                let converted = distanceUnit == .km ? value : value / (DistanceUnit.mi.metersPerUnit / 1000)
                return "\(converted.formatted(.number.precision(.fractionLength(1)))) \(distanceUnit.speedSuffix)"
            case .power:
                return "\(Int(value.rounded())) W"
            case .floors:
                return "\(Int(value)) floors"
            case .jumps:
                return "\(Int(value)) jumps"
            case .distance:
                return Fmt.distance(value, unit: distanceUnit)
            case .duration:
                return Fmt.durationShort(Int(value))
            }
        }
    }

    /// Preference order per modality; the chart takes the first metric with
    /// enough data. Duration closes every chain so a sparse log still trends.
    static func trendCandidates(for kind: CardioKind) -> [TrendMetric] {
        switch kind {
        case .run, .trailRun, .walk: [.pace, .duration]
        case .row: [.split500, .duration]
        case .cycle: [.power, .speed, .duration]
        case .swim: [.swimPace100, .duration]
        case .stair: [.floors, .duration]
        case .jumpRope: [.jumps, .duration]
        case .elliptical: [.distance, .duration]
        case .skate: [.speed, .duration]
        case .other: [.duration]
        }
    }

    /// First candidate that can chart (2+ points), else the first with any
    /// point, else an empty duration trend.
    static func trend(for kind: CardioKind, entries: [SessionEntry]) -> (metric: TrendMetric, points: [MetricPoint]) {
        let candidates = trendCandidates(for: kind)
        var best: (metric: TrendMetric, points: [MetricPoint])?
        for metric in candidates {
            let points = series(metric, entries: entries)
            if points.count >= 2 { return (metric, points) }
            if best == nil, !points.isEmpty { best = (metric, points) }
        }
        return best ?? (candidates.last ?? .duration, [])
    }

    /// Chart series for one metric, oldest first. Pace guards mirror
    /// `StatisticsAnalytics.paceSeries`: a GPS blip or a 30 s token effort
    /// must not chart a fantasy pace.
    static func series(_ metric: TrendMetric, entries: [SessionEntry]) -> [MetricPoint] {
        entries
            .compactMap { entry -> MetricPoint? in
                value(metric, entry: entry).map { MetricPoint(date: entry.date, value: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    private static func value(_ metric: TrendMetric, entry: SessionEntry) -> Double? {
        let session = entry.session
        switch metric {
        case .pace:
            guard let secPerKm = guardedSecPerKm(session, minMeters: 500) else { return nil }
            return secPerKm
        case .split500:
            if let split = session?.split500mSeconds, split > 0 { return split }
            guard let secPerKm = guardedSecPerKm(session, minMeters: 250) else { return nil }
            return secPerKm / 2
        case .swimPace100:
            guard let secPerKm = guardedSecPerKm(session, minMeters: 100) else { return nil }
            return secPerKm / 10
        case .speed:
            guard let meters = session?.distanceMeters, meters > 500,
                  let seconds = session?.durationSeconds, seconds > 0 else { return nil }
            let kmh = (meters / 1000) / (Double(seconds) / 3600)
            return kmh.isFinite && kmh > 0 ? kmh : nil
        case .power:
            guard let watts = session?.avgPowerWatts, watts > 0 else { return nil }
            return watts
        case .floors:
            guard let floors = session?.floorsClimbed, floors > 0 else { return nil }
            return Double(floors)
        case .jumps:
            guard let jumps = session?.totalSteps, jumps > 0 else { return nil }
            return Double(jumps)
        case .distance:
            guard let meters = session?.distanceMeters, meters > 0 else { return nil }
            return meters
        case .duration:
            guard let seconds = entry.durationSeconds, seconds > 0 else { return nil }
            return Double(seconds)
        }
    }

    /// Session pace in sec/km, nil unless the distance clears `minMeters`
    /// and the pace is physically plausible (< 60 min/km).
    private static func guardedSecPerKm(_ session: CardioSessionModel?, minMeters: Double) -> Double? {
        guard let session,
              let meters = session.distanceMeters, meters >= minMeters,
              let seconds = session.durationSeconds, seconds > 0 else { return nil }
        let secPerKm = Double(seconds) / (meters / 1000)
        guard secPerKm.isFinite, secPerKm < 3600 else { return nil }
        return secPerKm
    }

    // MARK: - Records

    struct Record: Identifiable {
        enum Kind: String {
            case longestDistance, longestDuration, fastestPace, bestSplit500,
                 fastestSwimPace, highestPower, mostFloors, mostJumps,
                 longestPractice, mostPoses

            var label: String {
                switch self {
                case .longestDistance: "Longest distance"
                case .longestDuration: "Longest session"
                case .fastestPace: "Fastest pace"
                case .bestSplit500: "Best split"
                case .fastestSwimPace: "Fastest /100m"
                case .highestPower: "Highest avg power"
                case .mostFloors: "Most floors"
                case .mostJumps: "Most jumps"
                case .longestPractice: "Longest practice"
                case .mostPoses: "Most poses"
                }
            }

            var icon: String {
                switch self {
                case .longestDistance: "point.topleft.down.to.point.bottomright.curvepath.fill"
                case .longestDuration: "clock.fill"
                case .fastestPace, .fastestSwimPace, .bestSplit500: "hare.fill"
                case .highestPower: "bolt.fill"
                case .mostFloors: "figure.stair.stepper"
                case .mostJumps: "figure.jumprope"
                case .longestPractice: "clock.fill"
                case .mostPoses: "figure.yoga"
                }
            }
        }

        let kind: Kind
        let value: Double
        let date: Date
        var id: String { kind.rawValue }

        func valueText(distanceUnit: DistanceUnit, fixedMeters: Bool) -> String {
            switch kind {
            case .longestDistance:
                fixedMeters ? "\(Int(value)) m" : Fmt.distance(value, unit: distanceUnit)
            case .longestDuration: Fmt.durationShort(Int(value))
            case .fastestPace: TrendMetric.pace.format(value, distanceUnit: distanceUnit)
            case .bestSplit500: TrendMetric.split500.format(value, distanceUnit: distanceUnit)
            case .fastestSwimPace: TrendMetric.swimPace100.format(value, distanceUnit: distanceUnit)
            case .highestPower: TrendMetric.power.format(value, distanceUnit: distanceUnit)
            case .mostFloors: "\(Int(value))"
            case .mostJumps: "\(Int(value))"
            case .longestPractice: Fmt.durationShort(Int(value))
            case .mostPoses: "\(Int(value))"
            }
        }
    }

    /// All-time bests, gated to the metrics this modality actually measures —
    /// a rower earns splits not paces, a stair machine floors not distance.
    static func records(for kind: CardioKind, entries: [SessionEntry]) -> [Record] {
        var result: [Record] = []
        func best(_ metric: TrendMetric, as recordKind: Record.Kind, min: Bool = false) {
            let points = series(metric, entries: entries)
            let pick = min ? points.min { $0.value < $1.value } : points.max { $0.value < $1.value }
            if let pick { result.append(Record(kind: recordKind, value: pick.value, date: pick.date)) }
        }

        switch kind {
        case .run, .trailRun, .walk: best(.pace, as: .fastestPace, min: true)
        case .row: best(.split500, as: .bestSplit500, min: true)
        case .swim: best(.swimPace100, as: .fastestSwimPace, min: true)
        case .cycle: best(.power, as: .highestPower)
        case .stair: best(.floors, as: .mostFloors)
        case .jumpRope: best(.jumps, as: .mostJumps)
        case .elliptical, .skate, .other: break
        }
        if kind.usesDistance { best(.distance, as: .longestDistance) }
        best(.duration, as: .longestDuration)
        return result
    }

    // MARK: - Yoga

    /// Yoga's records speak mat vocabulary: time practiced and poses held,
    /// never distance or pace — the mat doesn't move.
    static func yogaRecords(entries: [SessionEntry]) -> [Record] {
        var result: [Record] = []
        if let longest = entries
            .compactMap({ entry in entry.durationSeconds.map { (entry: entry, seconds: $0) } })
            .filter({ $0.seconds > 0 })
            .max(by: { $0.seconds < $1.seconds }) {
            result.append(Record(kind: .longestPractice, value: Double(longest.seconds), date: longest.entry.date))
        }
        if let most = entries
            .compactMap({ entry in entry.session?.posesCompleted.map { (entry: entry, poses: $0) } })
            .filter({ $0.poses > 0 })
            .max(by: { $0.poses < $1.poses }) {
            result.append(Record(kind: .mostPoses, value: Double(most.poses), date: most.entry.date))
        }
        return result
    }

    /// "32min · 12 poses · Vinyasa · 104 bpm" — style comes from the session,
    /// so a pose practiced across Yin and Power days shows both truthfully.
    static func yogaSummary(for entry: SessionEntry) -> String {
        var parts: [String] = []
        if let seconds = entry.durationSeconds, seconds > 0 {
            parts.append(Fmt.durationShort(seconds))
        }
        if let session = entry.session {
            if let poses = session.posesCompleted, poses > 0 {
                parts.append("\(poses) pose\(poses == 1 ? "" : "s")")
            }
            if let style = session.yogaStyleRaw.flatMap(YogaStyle.init(rawValue:)) {
                parts.append(style.title)
            }
            if let hr = session.avgHR, hr > 0 { parts.append("\(hr) bpm") }
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    // MARK: - History line

    /// One-line session summary in the modality's vocabulary:
    /// "42min · 8.2 km · 5:11 /km · 152 bpm". Metrics appear only when
    /// present — imported or manual logs may carry duration alone.
    static func summary(for entry: SessionEntry, kind: CardioKind, distanceUnit: DistanceUnit = Fmt.distanceUnit) -> String {
        var parts: [String] = []
        if let seconds = entry.durationSeconds, seconds > 0 {
            parts.append(Fmt.durationShort(seconds))
        }
        guard let session = entry.session else {
            return parts.isEmpty ? "—" : parts.joined(separator: " · ")
        }
        if kind.usesDistance, let meters = session.distanceMeters, meters > 0 {
            parts.append(Fmt.cardioDistance(meters, kind: kind, unit: distanceUnit))
        }
        if let paceMetric = paceStyleMetric(for: kind), let paceValue = value(paceMetric, entry: entry) {
            parts.append(paceMetric.format(paceValue, distanceUnit: distanceUnit))
        }
        switch kind {
        case .cycle:
            if let watts = session.avgPowerWatts, watts > 0 { parts.append("\(Int(watts.rounded())) W") }
        case .stair:
            if let floors = session.floorsClimbed, floors > 0 { parts.append("\(floors) floors") }
        case .jumpRope:
            if let jumps = session.totalSteps, jumps > 0 { parts.append("\(jumps) jumps") }
        default:
            break
        }
        if let hr = session.avgHR, hr > 0 { parts.append("\(hr) bpm") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private static func paceStyleMetric(for kind: CardioKind) -> TrendMetric? {
        if kind.usesSplit500 { return .split500 }
        if kind.usesFixedMeters { return .swimPace100 }
        if kind.usesPace { return .pace }
        if kind.usesDistance { return .speed }
        return nil
    }
}
