import Foundation

/// Format-aware performance signals derived from one completed conditioning
/// section. The analysis reports only measurements supported by the saved score;
/// round-to-round pacing is withheld when round workloads are not comparable.
public struct ConditioningPerformanceAnalysis: Equatable, Sendable {
    public struct RoundSplit: Equatable, Identifiable, Sendable {
        public let round: Int
        public let durationSeconds: Int

        public var id: Int { round }
    }

    public let completedRounds: Int
    public let prescribedRounds: Int?
    public let roundSplits: [RoundSplit]
    public let averageRoundSeconds: Int?
    public let averageLoggedSplitSeconds: Int?
    public let fastestRoundSeconds: Int?
    public let slowestRoundSeconds: Int?
    /// Positive values mean the second half took longer; negative values mean
    /// it was faster. The middle round is ignored for an odd number of splits.
    public let secondHalfPaceChangePercent: Double?
    public let repsPerMinute: Double?
    public let repsPerRound: Double?
    public let completionPercent: Double?
    public let missedRounds: Int?

    public init(section: ConditioningSection, result: ConditioningSectionResult) {
        let completesAtRoundTarget = switch section.format {
        case .forTime, .ladder, .maxLoad: true
        case .amrap, .emom, .intervals: false
        }
        let inferredCompletedRounds: Int = if result.fullRounds == nil,
                                              result.completedIntervals == nil,
                                              result.completed,
                                              completesAtRoundTarget {
            section.prescribedRounds ?? 0
        } else {
            0
        }
        let reportedRounds = max(
            0,
            result.fullRounds ?? result.completedIntervals ?? inferredCompletedRounds
        )
        let rawCompletions = result.roundCompletionElapsedSeconds ?? []
        completedRounds = max(reportedRounds, rawCompletions.count)
        prescribedRounds = section.prescribedRounds.flatMap { $0 > 0 ? $0 : nil }

        var previousCompletion = 0
        var splits: [RoundSplit] = []
        for (index, completion) in rawCompletions.prefix(completedRounds).enumerated() {
            guard completion > previousCompletion else { break }
            splits.append(.init(round: index + 1, durationSeconds: completion - previousCompletion))
            previousCompletion = completion
        }
        roundSplits = splits

        let comparableRoundWork = section.repScheme.isEmpty
            && section.ladderStep == nil
            && (section.format == .amrap || section.format == .forTime)
        if comparableRoundWork, completedRounds > 0, let elapsed = result.elapsedSeconds, elapsed > 0 {
            averageRoundSeconds = Int((Double(elapsed) / Double(completedRounds)).rounded())
        } else {
            averageRoundSeconds = nil
        }

        if comparableRoundWork, !splits.isEmpty {
            let durations = splits.map(\.durationSeconds)
            averageLoggedSplitSeconds = Int(
                (Double(durations.reduce(0, +)) / Double(durations.count)).rounded()
            )
            fastestRoundSeconds = durations.min()
            slowestRoundSeconds = durations.max()
            secondHalfPaceChangePercent = Self.paceChangePercent(durations)
        } else {
            averageLoggedSplitSeconds = nil
            fastestRoundSeconds = nil
            slowestRoundSeconds = nil
            secondHalfPaceChangePercent = nil
        }

        if let totalReps = result.totalReps,
           totalReps > 0,
           let elapsed = result.elapsedSeconds,
           elapsed > 0 {
            repsPerMinute = Double(totalReps) * 60 / Double(elapsed)
        } else {
            repsPerMinute = nil
        }

        if let totalReps = result.totalReps, totalReps > 0, completedRounds > 0 {
            repsPerRound = Double(totalReps) / Double(completedRounds)
        } else {
            repsPerRound = nil
        }

        if let prescribedRounds {
            completionPercent = min(100, Double(completedRounds) * 100 / Double(prescribedRounds))
            missedRounds = max(0, prescribedRounds - completedRounds)
        } else {
            completionPercent = nil
            missedRounds = nil
        }
    }

    private static func paceChangePercent(_ durations: [Int]) -> Double? {
        let halfCount = durations.count / 2
        guard halfCount > 0 else { return nil }
        let firstHalf = durations.prefix(halfCount)
        let secondHalf = durations.suffix(halfCount)
        let firstAverage = Double(firstHalf.reduce(0, +)) / Double(halfCount)
        guard firstAverage > 0 else { return nil }
        let secondAverage = Double(secondHalf.reduce(0, +)) / Double(halfCount)
        return (secondAverage - firstAverage) * 100 / firstAverage
    }
}
