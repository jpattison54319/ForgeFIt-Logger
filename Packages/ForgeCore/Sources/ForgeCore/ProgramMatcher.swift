import Foundation

/// The training discipline a program (or a coaching request) is built
/// around. `mixed` is the catalog's "a bit of everything" tag — a program's
/// `focus` field is being added to the catalog in a later phase; this enum
/// is the shape it will decode into, so `ProgramMatcher` can be written
/// against it now instead of a raw `String`.
public enum ProgramFocus: String, Codable, Equatable, Sendable, CaseIterable {
    case strength, cardio, yoga, mixed
}

/// What the "Coach's Corner" onboarding flow collected from the lifter.
/// Pure snapshot — no SwiftData, no UI — so matching stays a plain function
/// of its inputs.
public struct CoachingProfileInput: Equatable, Sendable {
    public let focus: ProgramFocus
    public let goal: String
    public let experience: String
    public let sessionsPerWeek: Int
    public let sessionMinutes: Int
    public let equipment: Set<String>
    /// Preferred cardio modality ("run", "row", ...); reserved for a future
    /// refinement pass on cardio/mixed candidates. Not consumed by the v1
    /// matching rules below.
    public let preferredCardio: String?

    public init(
        focus: ProgramFocus,
        goal: String,
        experience: String,
        sessionsPerWeek: Int,
        sessionMinutes: Int,
        equipment: Set<String>,
        preferredCardio: String? = nil
    ) {
        self.focus = focus
        self.goal = goal
        self.experience = experience
        self.sessionsPerWeek = sessionsPerWeek
        self.sessionMinutes = sessionMinutes
        self.equipment = equipment
        self.preferredCardio = preferredCardio
    }
}

/// A catalog program's matchable facts. The app builds these from
/// `RoutineProgramTemplate` (see `RoutineTemplateCatalog`) plus its new
/// `focus` field once that lands.
public struct ProgramCandidate: Equatable, Sendable {
    public let id: String
    public let name: String
    public let focus: ProgramFocus
    public let goal: String
    public let level: String
    public let daysPerWeek: Int
    public let weeks: Int
    public let equipment: [String]

    public init(
        id: String,
        name: String,
        focus: ProgramFocus,
        goal: String,
        level: String,
        daysPerWeek: Int,
        weeks: Int,
        equipment: [String]
    ) {
        self.id = id
        self.name = name
        self.focus = focus
        self.goal = goal
        self.level = level
        self.daysPerWeek = daysPerWeek
        self.weeks = weeks
        self.equipment = equipment
    }
}

public enum MatchResult: Equatable, Sendable {
    /// Frequency, goal, level, focus, and equipment all line up.
    case exact(ProgramCandidate)
    /// The closest safe program once something doesn't line up — never a
    /// higher weekly frequency than requested. `reasons` names every axis
    /// that differs from the request, in plain language.
    case fallback(ProgramCandidate, reasons: [String])
    /// Nothing in the catalog can honestly be offered; `reason` explains why.
    case none(reason: String)
}

/// Pure, deterministic program matcher for the Coach's Corner onboarding
/// flow. Same inputs always produce the same `MatchResult` — no randomness,
/// no current-date dependence, no persistence.
public enum ProgramMatcher {

    /// Focus compatibility table. Rows are the lifter's requested focus,
    /// columns are a candidate's focus; ✓ = compatible.
    ///
    ///                strength  cardio  yoga  mixed
    ///     strength      ✓        ·      ·      ✓
    ///     cardio        ·        ✓      ·      ✓
    ///     yoga          ·        ·      ✓      ✓
    ///     mixed         ✓        ✓      ✓      ✓
    ///
    /// `mixed` matches anything sensible in both directions: a lifter who
    /// wants variety is happy with any single-discipline program, and a
    /// mixed-discipline program covers any single-discipline request.
    /// Otherwise disciplines must match exactly — a cardio request never
    /// resolves to a pure strength program or vice versa.
    public static func focusCompatible(requested: ProgramFocus, candidate: ProgramFocus) -> Bool {
        requested == .mixed || candidate == .mixed || requested == candidate
    }

    public static func match(profile: CoachingProfileInput, candidates: [ProgramCandidate]) -> MatchResult {
        // Hard constraints that can never be relaxed: the lifter must own
        // every piece of equipment the program calls for, the disciplines
        // must be compatible, and the program can never ask for more
        // sessions per week than the lifter has available.
        let safe = candidates.filter {
            equipmentSatisfied($0, profile: profile) && focusCompatible(requested: profile.focus, candidate: $0.focus)
        }
        let eligible = safe.filter { $0.daysPerWeek <= profile.sessionsPerWeek }

        guard let best = rank(eligible, profile: profile).first else {
            return .none(reason: noneReason(safe: safe, profile: profile))
        }

        let frequencyMatches = best.daysPerWeek == profile.sessionsPerWeek
        let goalOK = goalMatches(best, profile: profile)
        let levelOK = levelAligned(best, profile: profile)

        if frequencyMatches && goalOK && levelOK {
            return .exact(best)
        }

        var reasons: [String] = []
        if !frequencyMatches {
            reasons.append("Closest available frequency is \(best.daysPerWeek)x/week — you asked for \(profile.sessionsPerWeek)x/week.")
        }
        if !goalOK {
            reasons.append("This program targets \"\(best.goal)\" rather than \"\(profile.goal)\".")
        }
        if !levelOK {
            reasons.append("This program is written for \"\(best.level)\" lifters; you told us \"\(profile.experience)\".")
        }
        return .fallback(best, reasons: reasons)
    }

    // MARK: - Ranking

    /// Fallback ranking: highest weekly frequency ≤ requested first, then a
    /// goal match, then a level match, then a stable tie-break on `id`. The
    /// top of this ordering is also the exact match whenever one exists —
    /// `match(profile:candidates:)` classifies the winner after the fact
    /// instead of running two separate searches.
    private static func rank(_ candidates: [ProgramCandidate], profile: CoachingProfileInput) -> [ProgramCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.daysPerWeek != rhs.daysPerWeek { return lhs.daysPerWeek > rhs.daysPerWeek }
            let lhsGoal = goalMatches(lhs, profile: profile)
            let rhsGoal = goalMatches(rhs, profile: profile)
            if lhsGoal != rhsGoal { return lhsGoal && !rhsGoal }
            let lhsLevel = levelAligned(lhs, profile: profile)
            let rhsLevel = levelAligned(rhs, profile: profile)
            if lhsLevel != rhsLevel { return lhsLevel && !rhsLevel }
            return lhs.id < rhs.id
        }
    }

    private static func noneReason(safe: [ProgramCandidate], profile: CoachingProfileInput) -> String {
        guard let fewestDays = safe.map(\.daysPerWeek).min() else {
            return "No program matches your equipment and \(profile.focus.rawValue) focus."
        }
        // Something matched equipment + focus, but every one of those needs
        // more training days per week than the lifter has — the frequency
        // constraint can never be relaxed upward, so there's honestly
        // nothing to offer.
        return "The lightest matching program needs \(fewestDays)x/week, more than the \(profile.sessionsPerWeek)x/week you have available."
    }

    // MARK: - Alignment

    private static func goalMatches(_ candidate: ProgramCandidate, profile: CoachingProfileInput) -> Bool {
        normalize(candidate.goal) == normalize(profile.goal)
    }

    /// A candidate is level-aligned when its difficulty is neither above the
    /// lifter's experience nor more than one tier below it — a beginner
    /// gets beginner programs, an intermediate lifter gets beginner or
    /// intermediate, and an advanced lifter gets the hardest tier the
    /// catalog offers (intermediate) rather than being handed a beginner
    /// plan as "exact". Unrecognized experience strings default to the
    /// intermediate tier, the safest middle ground.
    private static func levelAligned(_ candidate: ProgramCandidate, profile: CoachingProfileInput) -> Bool {
        let userRank = levelRank(profile.experience)
        let candidateRank = levelRank(candidate.level)
        return candidateRank <= userRank && candidateRank >= userRank - 1
    }

    private static func levelRank(_ level: String) -> Int {
        switch normalize(level) {
        case "beginner": return 1
        case "advanced": return 3
        case "intermediate": return 2
        default: return 2
        }
    }

    // MARK: - Equipment

    private static func equipmentSatisfied(_ candidate: ProgramCandidate, profile: CoachingProfileInput) -> Bool {
        let needed = Set(candidate.equipment.map(normalize))
        let available = Set(profile.equipment.map(normalize))
        return needed.isSubset(of: available)
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
