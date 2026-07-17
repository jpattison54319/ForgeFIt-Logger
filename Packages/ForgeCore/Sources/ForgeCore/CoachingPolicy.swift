import Foundation

/// One lift's rep-target performance over a review window. The caller (the
/// app, walking `SetModel` history) computes `consecutiveUnderTarget` —
/// how many sessions in a row landed under the routine's target reps — so
/// this type stays a plain snapshot with no persistence knowledge.
public struct LiftWeekOutcome: Equatable, Sendable {
    public let exerciseID: UUID
    public let name: String
    public let consecutiveUnderTarget: Int

    public init(exerciseID: UUID, name: String, consecutiveUnderTarget: Int) {
        self.exerciseID = exerciseID
        self.name = name
        self.consecutiveUnderTarget = consecutiveUnderTarget
    }
}

/// The performance/schedule facts a weekly coach review is built from.
public struct WeekSummary: Equatable, Sendable {
    public let weekStart: Date
    public let sessionsCompleted: Int
    public let sessionsTarget: Int
    /// Which week of the current training block this is (1-indexed), and how
    /// many weeks the block runs. Either may be nil when the lifter isn't
    /// following a block-structured program.
    public let blockWeek: Int?
    public let blockLength: Int?
    public let lifts: [LiftWeekOutcome]

    public init(
        weekStart: Date,
        sessionsCompleted: Int,
        sessionsTarget: Int,
        blockWeek: Int? = nil,
        blockLength: Int? = nil,
        lifts: [LiftWeekOutcome] = []
    ) {
        self.weekStart = weekStart
        self.sessionsCompleted = sessionsCompleted
        self.sessionsTarget = sessionsTarget
        self.blockWeek = blockWeek
        self.blockLength = blockLength
        self.lifts = lifts
    }
}

/// One thing the weekly review offers to do. Several can coexist — a light
/// week with two stalled lifts produces a `carryForward` plus two
/// `progressionHold`s.
public struct WeeklyProposal: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case stayCourse
        case carryForward(missedSessions: Int)
        case progressionHold(exerciseID: UUID, name: String)
        case deloadWeek
    }

    public let kind: Kind
    public let reason: String

    public init(kind: Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

/// Pure weekly-review policy: turns a week's performance/schedule facts into
/// a deterministic list of proposals. No models, no persistence, no dates
/// other than the ones passed in.
///
/// Privacy invariant: every `reason` string this type produces is derived
/// strictly from performance and schedule facts already in `WeekSummary` —
/// sessions completed/target, consecutive under-target sets, block week and
/// length. It must NEVER reference readiness, HRV, sleep, or any other
/// Health-derived signal, because these strings sync to other devices via
/// CloudKit (see `ForgeDataSchema.planModels`), and readiness-class data is
/// forbidden from that sync layer under App Store Guideline 5.1.3(ii).
public enum CoachingPolicy {

    /// Consecutive under-target sessions at or above this count means "own
    /// this weight before adding more" — mirrors `ProgressionEngine`'s own
    /// two-strikes hold threshold for double progression.
    private static let holdThreshold = 2

    public static func review(_ summary: WeekSummary) -> [WeeklyProposal] {
        var proposals: [WeeklyProposal] = []

        for lift in summary.lifts where lift.consecutiveUnderTarget >= holdThreshold {
            proposals.append(WeeklyProposal(
                kind: .progressionHold(exerciseID: lift.exerciseID, name: lift.name),
                reason: "\(lift.name) has missed target reps for \(lift.consecutiveUnderTarget) sessions in a row — hold this weight and rebuild reps before adding load."
            ))
        }

        if summary.sessionsCompleted > 0 && summary.sessionsCompleted < summary.sessionsTarget {
            let missed = summary.sessionsTarget - summary.sessionsCompleted
            proposals.append(WeeklyProposal(
                kind: .carryForward(missedSessions: missed),
                reason: "Completed \(summary.sessionsCompleted) of \(summary.sessionsTarget) planned sessions — the remaining \(missed) carry forward to next week rather than being crammed in now."
            ))
        }

        if let blockWeek = summary.blockWeek, let blockLength = summary.blockLength, blockWeek > blockLength {
            proposals.append(WeeklyProposal(
                kind: .deloadWeek,
                reason: "Week \(blockWeek) of a \(blockLength)-week block — this block has run its course, so it's time to deload before starting the next one."
            ))
        }

        if proposals.isEmpty {
            proposals.append(WeeklyProposal(
                kind: .stayCourse,
                reason: "Sessions completed and lifts progressing as planned — stay the course."
            ))
        }

        return proposals
    }
}
