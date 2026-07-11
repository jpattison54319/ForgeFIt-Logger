import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// The weekly coach review: turns a completed Mon–Sun training week into
/// `CoachingWeekOverrideModel` proposals (progression holds, carry-forward,
/// deload) via `ForgeCore.CoachingPolicy`, and manages their proposed →
/// active/cancelled lifecycle. Follows `CoachPlanService`'s style — a
/// stateless `@MainActor` enum operating on a caller-supplied `ModelContext`.
///
/// PRIVACY: every override this type creates carries a `reason` straight
/// from `WeeklyProposal.reason`, which `CoachingPolicy` guarantees is
/// performance/schedule-derived only — see that type's doc comment. Nothing
/// here ever reads or writes readiness/HRV/sleep data.
@MainActor
enum CoachWeeklyReview {

    // MARK: - Week anchoring

    /// Monday 00:00 of the week containing `date`, computed explicitly from
    /// the `.weekday` component (1 = Sunday … 7 = Saturday, which `Calendar`
    /// reports the same way regardless of `firstWeekday`) rather than
    /// `dateInterval(of: .weekOfYear)` — the latter honors the calendar's
    /// (locale-dependent) first weekday, which would silently anchor on
    /// Sunday for a US calendar. This must always be Monday.
    static func weekAnchor(for date: Date) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = .current
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        // Sunday(1)->6, Monday(2)->0, Tuesday(3)->1, ... Saturday(7)->5.
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    }

    /// True when the program has never been reviewed, or was last reviewed
    /// before the week containing `now`.
    static func isReviewDue(program: CoachedProgramModel, now: Date) -> Bool {
        guard let last = program.lastReviewedWeekAnchor else { return true }
        return last < weekAnchor(for: now)
    }

    // MARK: - Building the week's performance summary

    /// Analyzes the Mon–Sun week immediately BEFORE the week containing
    /// `now` — the week that just finished — and turns it into a
    /// `WeekSummary` for `CoachingPolicy`.
    static func buildSummary(program: CoachedProgramModel, now: Date, in context: ModelContext) -> WeekSummary {
        var calendar = Calendar.current
        calendar.timeZone = .current

        let currentAnchor = weekAnchor(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -7, to: currentAnchor) ?? currentAnchor

        let allWorkouts = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        let completed = allWorkouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
        // Imported history (Hevy/Strong/CSV/HealthKit) never counts toward a
        // "did you train this week" tally — same provenance fields other
        // import-aware code (e.g. `XPService.isImportedHistory`) checks.
        let completedNonImported = completed.filter {
            $0.externalSource == nil && $0.importFingerprint == nil && $0.importBatchID == nil
        }
        let weekWorkouts = completedNonImported.filter { $0.startedAt >= weekStart && $0.startedAt < currentAnchor }

        let startAnchor = weekAnchor(for: program.startDate)
        let daysSinceStart = calendar.dateComponents([.day], from: startAnchor, to: weekStart).day ?? 0
        let blockWeek = max(0, daysSinceStart / 7) + 1
        let blockLength = program.weeks > 0 ? program.weeks : nil

        return WeekSummary(
            weekStart: weekStart,
            sessionsCompleted: weekWorkouts.count,
            sessionsTarget: program.weeklySessionTarget,
            blockWeek: blockWeek,
            blockLength: blockLength,
            lifts: liftOutcomes(weekWorkouts: weekWorkouts, completedWorkouts: completed, in: context)
        )
    }

    /// Deterministic "consecutive under-target sessions" rule: for every
    /// exercise trained during the reviewed week, walk its
    /// `ProgressionSuggestionModel` history — one row per completed session,
    /// written by `ProgressionPlanner.apply` — ordered most-recent session
    /// first, and count how many sessions in a row (starting from the most
    /// recent) the engine recorded a `.hold` suggestion. `.hold` IS
    /// `ProgressionEngine`'s own "missed target reps" call (see
    /// `computeSuggestion`'s `underCount >= 2` / "missed target reps last
    /// time" branches), so this reuses the engine's judgment instead of
    /// re-deriving "under target" from raw set data. The streak breaks at
    /// the first non-hold suggestion (increase/addReps) or when history runs
    /// out; a lift the engine has never held has `consecutiveUnderTarget == 0`.
    private static func liftOutcomes(
        weekWorkouts: [WorkoutModel],
        completedWorkouts: [WorkoutModel],
        in context: ModelContext
    ) -> [LiftWeekOutcome] {
        let weekWorkoutIDs = Set(weekWorkouts.map(\.id))
        guard !weekWorkoutIDs.isEmpty else { return [] }

        let allSuggestions = ((try? context.fetch(FetchDescriptor<ProgressionSuggestionModel>())) ?? [])
            .filter { $0.deletedAt == nil }
        let candidateExerciseIDs = Set(allSuggestions.filter { weekWorkoutIDs.contains($0.workoutID) }.map(\.exerciseID))
        guard !candidateExerciseIDs.isEmpty else { return [] }

        let dateByWorkoutID = Dictionary(completedWorkouts.map { ($0.id, $0.startedAt) }, uniquingKeysWith: { first, _ in first })
        let exerciseNames = Dictionary(
            (((try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []).filter { $0.deletedAt == nil })
                .map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var outcomes: [LiftWeekOutcome] = []
        for exerciseID in candidateExerciseIDs {
            let history = allSuggestions
                .filter { $0.exerciseID == exerciseID }
                .compactMap { suggestion -> (Date, ProgressionSuggestionModel)? in
                    guard let date = dateByWorkoutID[suggestion.workoutID] else { return nil }
                    return (date, suggestion)
                }
                .sorted { $0.0 > $1.0 }

            var streak = 0
            for (_, suggestion) in history {
                guard suggestion.kindRaw == ProgressionSuggestion.Kind.hold.rawValue else { break }
                streak += 1
            }

            outcomes.append(LiftWeekOutcome(
                exerciseID: exerciseID,
                name: exerciseNames[exerciseID] ?? "Exercise",
                consecutiveUnderTarget: streak
            ))
        }
        return outcomes.sorted { $0.name < $1.name }
    }

    // MARK: - Materializing proposals

    /// Runs `CoachingPolicy` over the just-finished week and materializes
    /// its proposals as `proposed`-status `CoachingWeekOverrideModel` rows
    /// scoped to the CURRENT week anchor (`.stayCourse` produces no row —
    /// there's nothing to accept/decline). Skips any kind (+ exercise, for
    /// holds) that already has a row for this week regardless of status, so
    /// a declined proposal never reappears and an already-accepted one is
    /// never duplicated. Always stamps `lastReviewedWeekAnchor` to the
    /// current anchor, even when nothing new fired, so `isReviewDue` goes
    /// false for the rest of the week. Returns every still-`proposed` row
    /// for the current week (new + pre-existing).
    @discardableResult
    static func proposals(for program: CoachedProgramModel, now: Date, in context: ModelContext) -> [CoachingWeekOverrideModel] {
        let currentAnchor = weekAnchor(for: now)
        let summary = buildSummary(program: program, now: now, in: context)
        let weeklyProposals = CoachingPolicy.review(summary)

        let existingThisWeek = ((try? context.fetch(FetchDescriptor<CoachingWeekOverrideModel>())) ?? [])
            .filter { $0.programID == program.id && $0.weekStart == currentAnchor }

        func alreadyHandled(kind: CoachingOverrideKind, exerciseID: UUID?) -> Bool {
            existingThisWeek.contains { $0.kindRaw == kind.rawValue && $0.exerciseID == exerciseID }
        }

        for proposal in weeklyProposals {
            switch proposal.kind {
            case .stayCourse:
                continue
            case .carryForward:
                guard !alreadyHandled(kind: .carryForward, exerciseID: nil) else { continue }
                context.insert(CoachingWeekOverrideModel(
                    userID: program.userID,
                    programID: program.id,
                    kindRaw: CoachingOverrideKind.carryForward.rawValue,
                    weekStart: currentAnchor,
                    statusRaw: CoachingOverrideStatus.proposed.rawValue,
                    reason: proposal.reason
                ))
            case .progressionHold(let exerciseID, _):
                guard !alreadyHandled(kind: .progressionHold, exerciseID: exerciseID) else { continue }
                context.insert(CoachingWeekOverrideModel(
                    userID: program.userID,
                    programID: program.id,
                    kindRaw: CoachingOverrideKind.progressionHold.rawValue,
                    exerciseID: exerciseID,
                    weekStart: currentAnchor,
                    statusRaw: CoachingOverrideStatus.proposed.rawValue,
                    reason: proposal.reason
                ))
            case .deloadWeek:
                guard !alreadyHandled(kind: .deloadWeek, exerciseID: nil) else { continue }
                context.insert(CoachingWeekOverrideModel(
                    userID: program.userID,
                    programID: program.id,
                    kindRaw: CoachingOverrideKind.deloadWeek.rawValue,
                    weekStart: currentAnchor,
                    statusRaw: CoachingOverrideStatus.proposed.rawValue,
                    reason: proposal.reason
                ))
            }
        }

        program.lastReviewedWeekAnchor = currentAnchor
        program.updatedAt = Date()
        try? context.save()

        return pendingProposals(for: program, weekAnchor: currentAnchor, in: context)
    }

    /// Read-only: the current `proposed`-status rows for `program` in the
    /// given week, without running the policy or touching
    /// `lastReviewedWeekAnchor`. Used to redisplay a week's still-open
    /// proposals on repeat view appearances once `proposals(for:now:in:)`
    /// has already run for the week.
    static func pendingProposals(for program: CoachedProgramModel, weekAnchor: Date, in context: ModelContext) -> [CoachingWeekOverrideModel] {
        ((try? context.fetch(FetchDescriptor<CoachingWeekOverrideModel>())) ?? [])
            .filter { $0.programID == program.id && $0.weekStart == weekAnchor && $0.statusRaw == CoachingOverrideStatus.proposed.rawValue }
    }

    /// `active`-status overrides scoped to exactly `weekAnchor`. Expiry is
    /// purely date-derived — a prior week's active override simply isn't
    /// `weekAnchor`, so it's never returned here.
    static func activeOverrides(for weekAnchor: Date, in context: ModelContext) -> [CoachingWeekOverrideModel] {
        ((try? context.fetch(FetchDescriptor<CoachingWeekOverrideModel>())) ?? [])
            .filter { $0.statusRaw == CoachingOverrideStatus.active.rawValue && $0.weekStart == weekAnchor }
    }

    /// This week's active progression holds, keyed for
    /// `ProgressionPlanner.apply`/`.preview`'s `heldExerciseIDs`/`holdReasons`
    /// parameters — the single place `WorkoutFactory.start` and Coach's
    /// Corner's progression preview both read from, so preview and start
    /// always agree.
    static func activeProgressionHolds(now: Date = Date(), in context: ModelContext) -> (ids: Set<UUID>, reasons: [UUID: String]) {
        let holds = activeOverrides(for: weekAnchor(for: now), in: context)
            .filter { $0.kindRaw == CoachingOverrideKind.progressionHold.rawValue }
        var ids: Set<UUID> = []
        var reasons: [UUID: String] = [:]
        for hold in holds {
            guard let exerciseID = hold.exerciseID else { continue }
            ids.insert(exerciseID)
            reasons[exerciseID] = hold.reason
        }
        return (ids, reasons)
    }

    /// Whether a weekly deload-week override is active for the week
    /// containing `now` — feeds `CoachAdjustments.effectivePlan`'s
    /// conservative-dose precedence.
    static func isDeloadWeekActive(now: Date = Date(), in context: ModelContext) -> Bool {
        activeOverrides(for: weekAnchor(for: now), in: context)
            .contains { $0.kindRaw == CoachingOverrideKind.deloadWeek.rawValue }
    }

    // MARK: - Lifecycle

    /// Accepting a proposal turns it into this week's active override.
    static func accept(_ override: CoachingWeekOverrideModel, in context: ModelContext) {
        override.statusRaw = CoachingOverrideStatus.active.rawValue
        override.updatedAt = Date()
        try? context.save()
    }

    /// Declining a proposal cancels it — `proposals(for:now:in:)` treats a
    /// cancelled row as "already handled," so it never comes back this week.
    static func decline(_ override: CoachingWeekOverrideModel, in context: ModelContext) {
        override.statusRaw = CoachingOverrideStatus.cancelled.rawValue
        override.updatedAt = Date()
        try? context.save()
    }

    /// Cancels an already-active override (e.g. the lifter wants to drop a
    /// hold or a deload week mid-week).
    static func cancel(_ override: CoachingWeekOverrideModel, in context: ModelContext) {
        override.statusRaw = CoachingOverrideStatus.cancelled.rawValue
        override.updatedAt = Date()
        try? context.save()
    }
}
