import Foundation

public enum ConditioningFormat: String, Codable, CaseIterable, Sendable {
    case amrap
    case forTime
    case emom
    case intervals
    case ladder
    case maxLoad

    public var title: String {
        switch self {
        case .amrap: "AMRAP"
        case .forTime: "For Time"
        case .emom: "EMOM"
        case .intervals: "Intervals"
        case .ladder: "Ladder"
        case .maxLoad: "For Load"
        }
    }
}

public enum ConditioningOrdering: String, Codable, CaseIterable, Sendable {
    case inOrder
    case partitionable

    public var title: String { self == .inOrder ? "In Order" : "Any Order" }
}

public enum ConditioningScoreKind: String, Codable, Sendable {
    case roundsAndReps
    case elapsedTime
    case totalReps
    case completedIntervals
    case load
}

public enum ConditioningTargetUnit: String, Codable, CaseIterable, Sendable {
    case reps
    case meters
    case calories
    case seconds

    public var shortLabel: String {
        switch self {
        case .reps: "reps"
        case .meters: "m"
        case .calories: "cal"
        case .seconds: "sec"
        }
    }
}

public struct ConditioningMovement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var exerciseID: UUID
    public var targetValue: Double
    public var targetUnit: ConditioningTargetUnit
    public var targetLoad: Double?
    public var weightMode: WeightMode

    public init(
        id: UUID = UUID(),
        exerciseID: UUID,
        targetValue: Double,
        targetUnit: ConditioningTargetUnit = .reps,
        targetLoad: Double? = nil,
        weightMode: WeightMode = .external
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.targetValue = max(0, targetValue)
        self.targetUnit = targetUnit
        self.targetLoad = targetLoad
        self.weightMode = weightMode
    }
}

public struct ConditioningSection: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Stable preset lineage frozen into routines and workouts. Optional so
    /// plans written before preset identity existed continue to decode.
    public var presetReferenceID: String?
    public var name: String
    public var format: ConditioningFormat
    public var ordering: ConditioningOrdering
    public var scoreKind: ConditioningScoreKind
    public var durationSeconds: Int?
    public var timeCapSeconds: Int?
    public var rounds: Int?
    public var intervalSeconds: Int?
    public var workSeconds: Int?
    public var restSeconds: Int?
    public var repScheme: [Int]
    public var ladderStep: Int?
    public var endsOnFailure: Bool
    public var restartEachInterval: Bool
    public var movements: [ConditioningMovement]

    public init(
        id: UUID = UUID(),
        presetReferenceID: String? = nil,
        name: String,
        format: ConditioningFormat,
        ordering: ConditioningOrdering = .inOrder,
        scoreKind: ConditioningScoreKind? = nil,
        durationSeconds: Int? = nil,
        timeCapSeconds: Int? = nil,
        rounds: Int? = nil,
        intervalSeconds: Int? = nil,
        workSeconds: Int? = nil,
        restSeconds: Int? = nil,
        repScheme: [Int] = [],
        ladderStep: Int? = nil,
        endsOnFailure: Bool = false,
        restartEachInterval: Bool = false,
        movements: [ConditioningMovement] = []
    ) {
        self.id = id
        self.presetReferenceID = presetReferenceID
        self.name = name
        self.format = format
        self.ordering = ordering
        self.scoreKind = scoreKind ?? format.defaultScoreKind
        self.durationSeconds = durationSeconds
        self.timeCapSeconds = timeCapSeconds
        self.rounds = rounds
        self.intervalSeconds = intervalSeconds
        self.workSeconds = workSeconds
        self.restSeconds = restSeconds
        self.repScheme = repScheme
        self.ladderStep = ladderStep
        self.endsOnFailure = endsOnFailure
        self.restartEachInterval = restartEachInterval
        self.movements = movements
    }

    public func target(for movement: ConditioningMovement, round: Int) -> Double {
        guard movement.targetUnit == .reps else { return movement.targetValue }
        if repScheme.indices.contains(round - 1) { return Double(repScheme[round - 1]) }
        if let ladderStep, format == .ladder {
            return max(0, movement.targetValue + Double((round - 1) * ladderStep))
        }
        return movement.targetValue
    }

    public var prescribedRounds: Int? {
        if !repScheme.isEmpty { return repScheme.count }
        return rounds
    }
}

public struct ConditioningPlan: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sections: [ConditioningSection]

    public init(version: Int = Self.currentVersion, sections: [ConditioningSection]) {
        self.version = version
        self.sections = sections
    }

    public var isEmpty: Bool { sections.isEmpty || sections.allSatisfy(\.movements.isEmpty) }

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public struct ConditioningProgress: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ready, active, paused, completed, expired }

    public var sectionIndex: Int
    public var round: Int
    public var completedMovementIDs: Set<UUID>
    public var movementTotals: [UUID: Double]
    public var partialValues: [UUID: Double]
    public var recordedLoad: Double?
    public var processedEventIDs: Set<UUID>
    public var startedAt: Date?
    public var sectionStartedAt: Date?
    public var pausedAt: Date?
    public var accumulatedPauseSeconds: TimeInterval
    public var sectionAccumulatedPauseSeconds: TimeInterval?
    /// Active seconds from the start of the current section at each completed
    /// round. Optional so progress saved by older builds still decodes; `nil`
    /// means round-level pacing was not captured reliably.
    public var roundCompletionElapsedSeconds: [Int]?
    public var completedAt: Date?
    public var status: Status
    public var sectionResults: [ConditioningSectionResult]

    public init(
        sectionIndex: Int = 0,
        round: Int = 1,
        completedMovementIDs: Set<UUID> = [],
        movementTotals: [UUID: Double] = [:],
        partialValues: [UUID: Double] = [:],
        recordedLoad: Double? = nil,
        processedEventIDs: Set<UUID> = [],
        startedAt: Date? = nil,
        sectionStartedAt: Date? = nil,
        pausedAt: Date? = nil,
        accumulatedPauseSeconds: TimeInterval = 0,
        sectionAccumulatedPauseSeconds: TimeInterval? = nil,
        roundCompletionElapsedSeconds: [Int]? = nil,
        completedAt: Date? = nil,
        status: Status = .ready,
        sectionResults: [ConditioningSectionResult] = []
    ) {
        self.sectionIndex = sectionIndex
        self.round = round
        self.completedMovementIDs = completedMovementIDs
        self.movementTotals = movementTotals
        self.partialValues = partialValues
        self.recordedLoad = recordedLoad
        self.processedEventIDs = processedEventIDs
        self.startedAt = startedAt
        self.sectionStartedAt = sectionStartedAt
        self.pausedAt = pausedAt
        self.accumulatedPauseSeconds = accumulatedPauseSeconds
        self.sectionAccumulatedPauseSeconds = sectionAccumulatedPauseSeconds
        self.roundCompletionElapsedSeconds = roundCompletionElapsedSeconds
        self.completedAt = completedAt
        self.status = status
        self.sectionResults = sectionResults
    }

    public var fullRounds: Int { max(0, round - 1) }

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public struct ConditioningResult: Codable, Equatable, Sendable {
    public var sectionResults: [ConditioningSectionResult]
    public var modified: Bool

    public init(sectionResults: [ConditioningSectionResult], modified: Bool = false) {
        self.sectionResults = sectionResults
        self.modified = modified
    }

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

public struct ConditioningSectionResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var format: ConditioningFormat
    public var scoreKind: ConditioningScoreKind
    public var elapsedSeconds: Int?
    public var fullRounds: Int?
    public var partialMovementID: UUID?
    public var partialValue: Double?
    public var totalReps: Int?
    public var completedIntervals: Int?
    public var load: Double?
    /// Active seconds from section start at each logged round completion.
    /// Missing on workouts recorded before round pacing was introduced or when
    /// the final score was entered manually.
    public var roundCompletionElapsedSeconds: [Int]?
    public var completed: Bool

    public init(
        id: UUID,
        format: ConditioningFormat,
        scoreKind: ConditioningScoreKind,
        elapsedSeconds: Int? = nil,
        fullRounds: Int? = nil,
        partialMovementID: UUID? = nil,
        partialValue: Double? = nil,
        totalReps: Int? = nil,
        completedIntervals: Int? = nil,
        load: Double? = nil,
        roundCompletionElapsedSeconds: [Int]? = nil,
        completed: Bool
    ) {
        self.id = id
        self.format = format
        self.scoreKind = scoreKind
        self.elapsedSeconds = elapsedSeconds
        self.fullRounds = fullRounds
        self.partialMovementID = partialMovementID
        self.partialValue = partialValue
        self.totalReps = totalReps
        self.completedIntervals = completedIntervals
        self.load = load
        self.roundCompletionElapsedSeconds = roundCompletionElapsedSeconds
        self.completed = completed
    }
}

public struct ConditioningProgressEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Action: Codable, Equatable, Sendable {
        case start
        case toggleMovement(UUID)
        case completeRound
        case setPartial(UUID, Double)
        case setScore(rounds: Int, partialMovementID: UUID?, partialValue: Double, load: Double?)
        case pause
        case resume
        case expire
    }

    public var id: UUID
    public var timestamp: Date
    public var action: Action

    public init(id: UUID = UUID(), timestamp: Date = Date(), action: Action) {
        self.id = id
        self.timestamp = timestamp
        self.action = action
    }
}

public enum ConditioningProgressEngine {
    /// Fixed-work conditioning without a time cap is "for time": the clock
    /// keeps running until every prescribed round is complete. Returning the
    /// remaining rounds here gives phone, Watch, and the shared finish path
    /// one rule instead of letting a generic Finish button save a DNF.
    public static func requiredRoundsRemaining(
        for progress: ConditioningProgress,
        plan: ConditioningPlan
    ) -> Int {
        guard plan.sections.indices.contains(progress.sectionIndex) else { return 0 }
        let section = plan.sections[progress.sectionIndex]
        guard section.format == .forTime || section.format == .ladder,
              section.timeCapSeconds == nil,
              let prescribedRounds = section.prescribedRounds,
              prescribedRounds > 0 else { return 0 }
        return max(0, prescribedRounds - progress.fullRounds)
    }

    public static func apply(
        _ event: ConditioningProgressEvent,
        to progress: ConditioningProgress,
        plan: ConditioningPlan
    ) -> ConditioningProgress {
        guard !progress.processedEventIDs.contains(event.id),
              plan.sections.indices.contains(progress.sectionIndex) else { return progress }

        var next = progress
        next.processedEventIDs.insert(event.id)
        let section = plan.sections[next.sectionIndex]

        switch event.action {
        case .start:
            guard next.status == .ready else { return next }
            // Partial reps are retained in the wire/storage schema so older
            // builds and saved workouts still decode, but they are no longer a
            // supported logging state. A new run always starts clean.
            next.partialValues.removeAll()
            next.startedAt = event.timestamp
            next.sectionStartedAt = event.timestamp
            next.roundCompletionElapsedSeconds = []
            next.status = .active
        case .toggleMovement(let movementID):
            guard next.status == .active,
                  let movement = section.movements.first(where: { $0.id == movementID }) else { return next }
            let target = section.target(for: movement, round: next.round)
            if next.completedMovementIDs.remove(movementID) != nil {
                next.movementTotals[movementID] = max(0, (next.movementTotals[movementID] ?? 0) - target)
            } else {
                next.completedMovementIDs.insert(movementID)
                next.movementTotals[movementID, default: 0] += target
            }
            if next.completedMovementIDs.count == section.movements.count {
                finishRound(&next, section: section, at: event.timestamp)
                advanceCompletedSectionIfNeeded(&next, plan: plan, section: section, at: event.timestamp)
            }
        case .completeRound:
            guard next.status == .active else { return next }
            for movement in section.movements where !next.completedMovementIDs.contains(movement.id) {
                next.movementTotals[movement.id, default: 0] += section.target(for: movement, round: next.round)
            }
            finishRound(&next, section: section, at: event.timestamp)
            advanceCompletedSectionIfNeeded(&next, plan: plan, section: section, at: event.timestamp)
        case .setPartial:
            // Compatibility no-op for an event sent by an older paired build.
            next.partialValues.removeAll()
        case .setScore(let rounds, _, _, let load):
            let completedRounds = max(0, rounds)
            let loggedRounds = next.fullRounds
            next.round = completedRounds + 1
            next.completedMovementIDs.removeAll()
            next.movementTotals = next.movementTotals.filter { total in
                !section.movements.contains(where: { $0.id == total.key })
            }
            for movement in section.movements {
                next.movementTotals[movement.id] = completedRounds == 0 ? 0 : (1...completedRounds).reduce(0) { total, round in
                    total + section.target(for: movement, round: round)
                }
            }
            next.partialValues.removeAll()
            next.recordedLoad = load.map { max(0, $0) }
            if completedRounds != loggedRounds {
                next.roundCompletionElapsedSeconds = nil
            }
            // Timed sections capture a provisional result when their clock
            // expires. Rebuild it from the confirmed score so edits made in the
            // finish sheet (and pacing invalidation above) are actually saved.
            next.sectionResults.removeAll { $0.id == section.id }
        case .pause:
            guard next.status == .active else { return next }
            next.pausedAt = event.timestamp
            next.status = .paused
        case .resume:
            guard next.status == .paused, let pausedAt = next.pausedAt else { return next }
            next.accumulatedPauseSeconds += max(0, event.timestamp.timeIntervalSince(pausedAt))
            next.sectionAccumulatedPauseSeconds = (next.sectionAccumulatedPauseSeconds ?? 0)
                + max(0, event.timestamp.timeIntervalSince(pausedAt))
            next.pausedAt = nil
            next.status = .active
        case .expire:
            guard next.status == .active || next.status == .paused else { return next }
            captureSection(&next, section: section, at: event.timestamp, completed: section.format == .amrap || section.format == .intervals)
            if plan.sections.indices.contains(next.sectionIndex + 1) {
                next.sectionIndex += 1
                next.round = 1
                next.completedMovementIDs.removeAll()
                next.partialValues.removeAll()
                next.recordedLoad = nil
                next.sectionStartedAt = event.timestamp
                next.sectionAccumulatedPauseSeconds = 0
                next.roundCompletionElapsedSeconds = []
                next.pausedAt = nil
                next.status = .active
            } else {
                next.completedAt = event.timestamp
                next.status = .expired
            }
        }
        return next
    }

    public static func elapsedSeconds(for progress: ConditioningProgress, at date: Date = Date()) -> Int {
        guard let startedAt = progress.startedAt else { return 0 }
        let end = progress.completedAt ?? progress.pausedAt ?? date
        return max(0, Int(end.timeIntervalSince(startedAt) - progress.accumulatedPauseSeconds))
    }

    public static func result(
        for progress: ConditioningProgress,
        plan: ConditioningPlan,
        at date: Date = Date(),
        modified: Bool = false
    ) -> ConditioningResult {
        let elapsed = elapsedSeconds(for: progress, at: date)
        var results = progress.sectionResults
        if plan.sections.indices.contains(progress.sectionIndex),
           !results.contains(where: { $0.id == plan.sections[progress.sectionIndex].id }) {
            let index = progress.sectionIndex
            let section = plan.sections[index]
            let isCurrent = index == progress.sectionIndex
            let totals = isCurrent ? section.movements.reduce(0.0) {
                $0 + (progress.movementTotals[$1.id] ?? 0)
            } : 0
            let completedByClock = progress.status == .expired
                && (section.format == .amrap || section.format == .intervals)
            results.append(ConditioningSectionResult(
                id: section.id,
                format: section.format,
                scoreKind: section.scoreKind,
                elapsedSeconds: isCurrent ? elapsed : nil,
                fullRounds: isCurrent ? progress.fullRounds : nil,
                partialMovementID: nil,
                partialValue: nil,
                totalReps: section.movements.allSatisfy { $0.targetUnit == .reps } ? Int(totals) : nil,
                completedIntervals: section.format == .emom && isCurrent ? progress.fullRounds : nil,
                load: section.scoreKind == .load && isCurrent ? progress.recordedLoad : nil,
                roundCompletionElapsedSeconds: isCurrent ? progress.roundCompletionElapsedSeconds : nil,
                completed: index < progress.sectionIndex
                    || (isCurrent && (progress.status == .completed || completedByClock))
            ))
        }
        return ConditioningResult(sectionResults: results, modified: modified)
    }

    private static func finishRound(
        _ progress: inout ConditioningProgress,
        section: ConditioningSection,
        at date: Date
    ) {
        recordRoundCompletion(&progress, at: date)
        progress.round += 1
        progress.completedMovementIDs.removeAll()
        progress.partialValues.removeAll()
        guard let rounds = section.prescribedRounds, progress.fullRounds >= rounds else { return }
        progress.completedAt = date
        progress.status = .completed
    }

    private static func advanceCompletedSectionIfNeeded(
        _ progress: inout ConditioningProgress,
        plan: ConditioningPlan,
        section: ConditioningSection,
        at date: Date
    ) {
        guard progress.status == .completed else { return }
        captureSection(&progress, section: section, at: date, completed: true)
        guard plan.sections.indices.contains(progress.sectionIndex + 1) else { return }
        progress.sectionIndex += 1
        progress.round = 1
        progress.completedMovementIDs.removeAll()
        progress.partialValues.removeAll()
        progress.recordedLoad = nil
        progress.sectionStartedAt = date
        progress.sectionAccumulatedPauseSeconds = 0
        progress.roundCompletionElapsedSeconds = []
        progress.completedAt = nil
        progress.status = .active
    }

    private static func captureSection(
        _ progress: inout ConditioningProgress,
        section: ConditioningSection,
        at date: Date,
        completed: Bool
    ) {
        let total = section.movements.reduce(0.0) {
            $0 + (progress.movementTotals[$1.id] ?? 0)
        }
        let paused = progress.sectionAccumulatedPauseSeconds ?? 0
        let sectionElapsed = max(0, Int(date.timeIntervalSince(progress.sectionStartedAt ?? progress.startedAt ?? date) - paused))
        progress.sectionResults.removeAll { $0.id == section.id }
        progress.sectionResults.append(ConditioningSectionResult(
            id: section.id,
            format: section.format,
            scoreKind: section.scoreKind,
            elapsedSeconds: sectionElapsed,
            fullRounds: progress.fullRounds,
            partialMovementID: nil,
            partialValue: nil,
            totalReps: section.movements.allSatisfy { $0.targetUnit == .reps } ? Int(total) : nil,
            completedIntervals: section.format == .emom ? progress.fullRounds : nil,
            load: section.scoreKind == .load ? progress.recordedLoad : nil,
            roundCompletionElapsedSeconds: progress.roundCompletionElapsedSeconds,
            completed: completed
        ))
    }

    private static func recordRoundCompletion(
        _ progress: inout ConditioningProgress,
        at date: Date
    ) {
        guard let start = progress.sectionStartedAt ?? progress.startedAt else { return }
        // If this is an in-flight workout saved by a build that did not capture
        // prior rounds, do not relabel a later split as round one.
        guard progress.roundCompletionElapsedSeconds?.count == progress.fullRounds else { return }
        let paused = progress.sectionAccumulatedPauseSeconds ?? 0
        let measured = Int(max(0, date.timeIntervalSince(start) - paused).rounded())
        var completions = progress.roundCompletionElapsedSeconds ?? []
        completions.append(max((completions.last ?? 0) + 1, measured))
        progress.roundCompletionElapsedSeconds = completions
    }
}

private extension ConditioningFormat {
    var defaultScoreKind: ConditioningScoreKind {
        switch self {
        case .amrap: .roundsAndReps
        case .forTime: .elapsedTime
        case .emom: .completedIntervals
        case .intervals: .totalReps
        case .ladder: .totalReps
        case .maxLoad: .load
        }
    }
}
