import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CoachWeeklyReviewTests {
    private let userID = ForgeFitDemo.userID

    /// A single fixed "now" for every test, and the week anchors derived
    /// from it via the function under test — self-referential on purpose so
    /// these tests never depend on which real calendar day they happen to
    /// run on.
    private static let now = Date()
    private static let currentAnchor = CoachWeeklyReview.weekAnchor(for: now)
    private static let reviewedWeekStart = Calendar.current.date(byAdding: .day, value: -7, to: currentAnchor)!

    private func makeProgram(weeks: Int = 0, sessionsPerWeek: Int = 3, startDate: Date? = nil) -> CoachedProgramModel {
        CoachedProgramModel(
            userID: userID,
            folderID: UUID(),
            catalogProgramID: "",
            startDate: startDate ?? Self.reviewedWeekStart.addingTimeInterval(-90 * 86400),
            weeks: weeks,
            weeklySessionTarget: sessionsPerWeek,
            isActive: true
        )
    }

    private func makeExercise(id: UUID = UUID(), name: String = "Bench Press") -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: id, name: name, equipment: "Barbell",
            defaultWeightMode: .external, preferredWeightUnitRaw: WeightUnit.lb.rawValue
        )
    }

    private func makeRoutine(name: String = "Push Day", exerciseIDs: [UUID]) -> RoutineModel {
        let routineExercises = exerciseIDs.enumerated().map { index, exerciseID in
            RoutineExerciseModel(
                userID: userID, exerciseID: exerciseID, position: index,
                sets: (0..<3).map { RoutineSetModel(userID: userID, position: $0, targetRepsLow: 8, targetRepsHigh: 10, targetWeight: 100) }
            )
        }
        return RoutineModel(userID: userID, name: name, exercises: routineExercises)
    }

    /// A completed strength workout — one exercise, 3 working sets logged at
    /// `reps`/`weight`, dated `startedAt`.
    @discardableResult
    private func insertCompletedWorkout(
        exerciseID: UUID, reps: Int, weight: Double, startedAt: Date, in context: ModelContext
    ) -> WorkoutModel {
        let sets = (0..<3).map {
            SetModel(userID: userID, position: $0, weightMode: .external, reps: reps, weight: weight, completedAt: startedAt.addingTimeInterval(600))
        }
        let workoutExercise = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: sets)
        let workout = WorkoutModel(
            userID: userID, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1800), exercises: [workoutExercise]
        )
        context.insert(workout)
        return workout
    }

    @discardableResult
    private func insertSuggestion(
        exerciseID: UUID, workoutID: UUID, workoutExerciseID: UUID, kind: ProgressionSuggestion.Kind, in context: ModelContext
    ) -> ProgressionSuggestionModel {
        let suggestion = ProgressionSuggestionModel(
            userID: userID, exerciseID: exerciseID, workoutID: workoutID, workoutExerciseID: workoutExerciseID, kindRaw: kind.rawValue
        )
        context.insert(suggestion)
        return suggestion
    }

    /// Builds a fresh pending workout the way `WorkoutFactory.start` does —
    /// mirrors `ProgressionPlannerTests`' helper of the same name.
    private func startWorkout(routine: RoutineModel, in context: ModelContext) -> WorkoutModel {
        let workoutExercises = routine.exercises.map { routineExercise -> WorkoutExerciseModel in
            let sets = routineExercise.sets.sorted { $0.position < $1.position }.map { target in
                SetModel(
                    userID: userID, position: target.position, setType: target.setType,
                    reps: target.targetRepsLow, weight: target.targetWeight,
                    sourceRoutineSetID: target.id
                )
            }
            return WorkoutExerciseModel(
                userID: userID, exerciseID: routineExercise.exerciseID, position: routineExercise.position,
                sourceRoutineExerciseID: routineExercise.id, sets: sets
            )
        }
        let workout = WorkoutModel(userID: userID, routineID: routine.id, exercises: workoutExercises)
        context.insert(workout)
        return workout
    }

    // MARK: - 1. On-track week → no proposals, anchor stamped

    @Test func onTrackWeekProducesNoProposalsAndStampsAnchor() throws {
        let (container, context) = try TestStore.make()
        let program = makeProgram(weeks: 0, sessionsPerWeek: 3)
        context.insert(program)
        for offsetDays in [1, 3, 5] {
            insertCompletedWorkout(
                exerciseID: UUID(), reps: 10, weight: 100,
                startedAt: Self.reviewedWeekStart.addingTimeInterval(Double(offsetDays) * 86400), in: context
            )
        }
        try context.save()

        #expect(program.lastReviewedWeekAnchor == nil)
        let proposals = CoachWeeklyReview.proposals(for: program, now: Self.now, in: context)

        #expect(proposals.isEmpty)
        #expect(program.lastReviewedWeekAnchor == Self.currentAnchor)
        _ = container
    }

    // MARK: - 2. Incomplete week → carryForward proposal

    @Test func incompleteWeekProducesCarryForwardProposal() throws {
        let (container, context) = try TestStore.make()
        let program = makeProgram(weeks: 0, sessionsPerWeek: 3)
        context.insert(program)
        // Only 1 of 3 target sessions this week.
        insertCompletedWorkout(
            exerciseID: UUID(), reps: 10, weight: 100,
            startedAt: Self.reviewedWeekStart.addingTimeInterval(86400), in: context
        )
        try context.save()

        let proposals = CoachWeeklyReview.proposals(for: program, now: Self.now, in: context)

        #expect(proposals.count == 1)
        let row = try #require(proposals.first)
        #expect(row.kindRaw == CoachingOverrideKind.carryForward.rawValue)
        #expect(row.statusRaw == CoachingOverrideStatus.proposed.rawValue)
        #expect(row.weekStart == Self.currentAnchor)
        #expect(!row.reason.isEmpty)
        _ = container
    }

    // MARK: - 3. Lift held 2 consecutive sessions → hold proposal → accept →
    // active override → ProgressionPlanner actually holds it (preview == apply)

    @Test func liftHeldTwoConsecutiveSessionsProducesHoldProposalAndAcceptedOverrideHoldsInProgressionPlanner() throws {
        let (container, context) = try TestStore.make()
        let program = makeProgram(weeks: 0, sessionsPerWeek: 1)
        context.insert(program)

        let heldExerciseID = UUID()
        let progressingExerciseID = UUID()
        let heldExercise = makeExercise(id: heldExerciseID, name: "Bench Press")
        let progressingExercise = makeExercise(id: progressingExerciseID, name: "Back Squat")
        context.insert(heldExercise)
        context.insert(progressingExercise)

        // Two sessions inside the reviewed week where the engine held Bench
        // Press both times (kindRaw == .hold) — the deterministic
        // consecutive-under-target signal `buildSummary` reads.
        let session1 = insertCompletedWorkout(
            exerciseID: heldExerciseID, reps: 6, weight: 100,
            startedAt: Self.reviewedWeekStart.addingTimeInterval(86400), in: context
        )
        let session2 = insertCompletedWorkout(
            exerciseID: heldExerciseID, reps: 6, weight: 100,
            startedAt: Self.reviewedWeekStart.addingTimeInterval(3 * 86400), in: context
        )
        try context.save()
        insertSuggestion(exerciseID: heldExerciseID, workoutID: session1.id, workoutExerciseID: session1.exercises[0].id, kind: .hold, in: context)
        insertSuggestion(exerciseID: heldExerciseID, workoutID: session2.id, workoutExerciseID: session2.exercises[0].id, kind: .hold, in: context)
        try context.save()

        let proposals = CoachWeeklyReview.proposals(for: program, now: Self.now, in: context)
        let holdProposal = try #require(proposals.first {
            $0.kindRaw == CoachingOverrideKind.progressionHold.rawValue && $0.exerciseID == heldExerciseID
        })
        #expect(holdProposal.statusRaw == CoachingOverrideStatus.proposed.rawValue)

        CoachWeeklyReview.accept(holdProposal, in: context)
        #expect(holdProposal.statusRaw == CoachingOverrideStatus.active.rawValue)

        let activeThisWeek = CoachWeeklyReview.activeOverrides(for: Self.currentAnchor, in: context)
        #expect(activeThisWeek.contains { $0.id == holdProposal.id })

        let holds = CoachWeeklyReview.activeProgressionHolds(now: Self.now, in: context)
        #expect(holds.ids == [heldExerciseID])
        #expect(holds.reasons[heldExerciseID] == holdProposal.reason)

        // Drive real progression: both exercises have one prior completed
        // session that would independently earn an increase (topped the rep
        // range). The held exercise must stay at last session's numbers
        // instead; the other progresses normally — and preview must match
        // apply exactly.
        let routine = makeRoutine(exerciseIDs: [heldExerciseID, progressingExerciseID])
        context.insert(routine)
        let lastWeightKg = WeightUnit.lb.kilograms(fromDisplayValue: 100)
        let mostRecentSessionDate = Self.reviewedWeekStart.addingTimeInterval(10 * 86400)
        insertCompletedWorkout(exerciseID: heldExerciseID, reps: 10, weight: lastWeightKg, startedAt: mostRecentSessionDate, in: context)
        insertCompletedWorkout(exerciseID: progressingExerciseID, reps: 10, weight: lastWeightKg, startedAt: mostRecentSessionDate, in: context)
        try context.save()

        let workout = startWorkout(routine: routine, in: context)
        let exercises = [heldExercise, progressingExercise]

        let previewed = ProgressionPlanner.preview(
            routine: routine, exercises: exercises, in: context, heldExerciseIDs: holds.ids, holdReasons: holds.reasons
        )
        ProgressionPlanner.apply(
            to: workout, routine: routine, exercises: exercises, in: context, heldExerciseIDs: holds.ids, holdReasons: holds.reasons
        )

        let heldPlan = try #require(previewed.first { $0.exerciseID == heldExerciseID })
        let progressingPlan = try #require(previewed.first { $0.exerciseID == progressingExerciseID })
        #expect(heldPlan.suggestion.kind == .hold)
        #expect(heldPlan.suggestion.rationale == holdProposal.reason)
        #expect(progressingPlan.suggestion.kind == .increase)

        for workoutExercise in workout.exercises {
            let pending = workoutExercise.sets.filter { $0.completedAt == nil }
            #expect(!pending.isEmpty)
            if workoutExercise.exerciseID == heldExerciseID {
                for set in pending {
                    let weight = try #require(set.weight)
                    #expect(abs(weight - lastWeightKg) < 0.001, "Held exercise must repeat last session's weight exactly.")
                }
            } else {
                for set in pending {
                    let weight = try #require(set.weight)
                    #expect(weight > lastWeightKg, "Non-held exercise must progress past last session's weight.")
                }
            }
        }
        _ = container
    }

    // MARK: - 4. Completed block → deloadWeek proposal

    @Test func completedBlockProducesDeloadWeekProposal() throws {
        let (container, context) = try TestStore.make()
        // A 4-week block that started 5 whole weeks before the reviewed
        // week — block week 6 of 4, well past the block's length.
        let blockStart = Calendar.current.date(byAdding: .day, value: -35, to: Self.reviewedWeekStart)!
        let program = makeProgram(weeks: 4, sessionsPerWeek: 3, startDate: blockStart)
        context.insert(program)
        // Hit the session target exactly so no carryForward proposal
        // muddies the assertion.
        for offsetDays in [1, 3, 5] {
            insertCompletedWorkout(
                exerciseID: UUID(), reps: 10, weight: 100,
                startedAt: Self.reviewedWeekStart.addingTimeInterval(Double(offsetDays) * 86400), in: context
            )
        }
        try context.save()

        let proposals = CoachWeeklyReview.proposals(for: program, now: Self.now, in: context)

        let deload = try #require(proposals.first { $0.kindRaw == CoachingOverrideKind.deloadWeek.rawValue })
        #expect(deload.weekStart == Self.currentAnchor)
        #expect(deload.statusRaw == CoachingOverrideStatus.proposed.rawValue)
        _ = container
    }

    // MARK: - 5. Declined proposal never recreated on re-review same week

    @Test func declinedProposalNeverRecreatedOnRereviewSameWeek() throws {
        let (container, context) = try TestStore.make()
        let program = makeProgram(weeks: 0, sessionsPerWeek: 3)
        context.insert(program)
        insertCompletedWorkout(
            exerciseID: UUID(), reps: 10, weight: 100,
            startedAt: Self.reviewedWeekStart.addingTimeInterval(86400), in: context
        )
        try context.save()

        let firstPass = CoachWeeklyReview.proposals(for: program, now: Self.now, in: context)
        let carryForward = try #require(firstPass.first { $0.kindRaw == CoachingOverrideKind.carryForward.rawValue })
        CoachWeeklyReview.decline(carryForward, in: context)
        #expect(carryForward.statusRaw == CoachingOverrideStatus.cancelled.rawValue)

        let secondPass = CoachWeeklyReview.proposals(for: program, now: Self.now, in: context)
        #expect(!secondPass.contains { $0.kindRaw == CoachingOverrideKind.carryForward.rawValue })

        // Still exactly one carryForward row this week — declining doesn't
        // duplicate, it just changes status.
        let allOverrides = try context.fetch(FetchDescriptor<CoachingWeekOverrideModel>())
        let carryForwardRows = allOverrides.filter {
            $0.programID == program.id && $0.weekStart == Self.currentAnchor && $0.kindRaw == CoachingOverrideKind.carryForward.rawValue
        }
        #expect(carryForwardRows.count == 1)
        #expect(carryForwardRows.first?.statusRaw == CoachingOverrideStatus.cancelled.rawValue)
        _ = container
    }

    // MARK: - 6. Last week's active override is NOT returned for this week (expiry)

    @Test func lastWeeksActiveOverrideIsNotReturnedForThisWeek() throws {
        let (container, context) = try TestStore.make()
        let program = makeProgram()
        context.insert(program)
        let lastWeekOverride = CoachingWeekOverrideModel(
            userID: userID, programID: program.id, kindRaw: CoachingOverrideKind.deloadWeek.rawValue,
            weekStart: Self.reviewedWeekStart, statusRaw: CoachingOverrideStatus.active.rawValue,
            reason: "Deload from last week"
        )
        context.insert(lastWeekOverride)
        try context.save()

        let thisWeek = CoachWeeklyReview.activeOverrides(for: Self.currentAnchor, in: context)
        #expect(!thisWeek.contains { $0.id == lastWeekOverride.id })

        let lastWeek = CoachWeeklyReview.activeOverrides(for: Self.reviewedWeekStart, in: context)
        #expect(lastWeek.contains { $0.id == lastWeekOverride.id })
        _ = container
    }

    // MARK: - 7. Cancel works

    @Test func cancelTurnsAnActiveOverrideCancelled() throws {
        let (container, context) = try TestStore.make()
        let program = makeProgram()
        context.insert(program)
        let override = CoachingWeekOverrideModel(
            userID: userID, programID: program.id, kindRaw: CoachingOverrideKind.progressionHold.rawValue,
            exerciseID: UUID(), weekStart: Self.currentAnchor, statusRaw: CoachingOverrideStatus.active.rawValue,
            reason: "Holding Bench Press"
        )
        context.insert(override)
        try context.save()

        CoachWeeklyReview.cancel(override, in: context)

        #expect(override.statusRaw == CoachingOverrideStatus.cancelled.rawValue)
        #expect(CoachWeeklyReview.activeOverrides(for: Self.currentAnchor, in: context).isEmpty)
        _ = container
    }

    // MARK: - 8. weekAnchor is Monday regardless of a Sunday-first calendar

    @Test func weekAnchorIsAlwaysMondayRegardlessOfSundayFirstCalendar() throws {
        var sundayFirstCalendar = Calendar(identifier: .gregorian)
        sundayFirstCalendar.firstWeekday = 1 // Sunday-first, e.g. en_US
        sundayFirstCalendar.timeZone = .current

        func date(year: Int, month: Int, day: Int) throws -> Date {
            try #require(sundayFirstCalendar.date(from: DateComponents(year: year, month: month, day: day)))
        }

        // 2026-07-06 is a Monday, 2026-07-08 a Wednesday, 2026-07-12 the
        // Sunday that ENDS that same Mon–Sun week, 2026-07-13 the next
        // Monday.
        let expectedMonday = try date(year: 2026, month: 7, day: 6)
        let wednesday = try date(year: 2026, month: 7, day: 8)
        let sunday = try date(year: 2026, month: 7, day: 12)
        let nextMonday = try date(year: 2026, month: 7, day: 13)

        #expect(Calendar.current.isDate(CoachWeeklyReview.weekAnchor(for: wednesday), inSameDayAs: expectedMonday))
        // The Sunday-first calendar would treat Sunday as the START of a new
        // week — `weekAnchor` must still resolve it to the Monday that
        // began the week Sunday ends, not treat it as day 1 of the next one.
        #expect(Calendar.current.isDate(CoachWeeklyReview.weekAnchor(for: sunday), inSameDayAs: expectedMonday))
        #expect(Calendar.current.isDate(CoachWeeklyReview.weekAnchor(for: expectedMonday), inSameDayAs: expectedMonday))
        #expect(Calendar.current.isDate(CoachWeeklyReview.weekAnchor(for: nextMonday), inSameDayAs: nextMonday))
    }

    // MARK: - 9. Conservative-dose precedence

    @Test func weeklyDeloadBeatsDailyReduceVolumeAndNeverStacksTwoReductions() throws {
        let reduceVolume = try #require(CoachAdjustments.plan(for: .reduceVolume))
        let deload = try #require(CoachAdjustments.plan(for: .deloadRecover))

        let weeklyWins = CoachAdjustments.effectivePlan(daily: reduceVolume, weeklyDeloadActive: true)
        #expect(weeklyWins?.plan == deload)
        #expect(weeklyWins?.sourceLabel == CoachAdjustments.weeklySourceLabel)

        // Only the daily plan exists (no weekly deload) — it runs alone,
        // unmodified.
        let dailyOnly = CoachAdjustments.effectivePlan(daily: reduceVolume, weeklyDeloadActive: false)
        #expect(dailyOnly?.plan == reduceVolume)
        #expect(dailyOnly?.sourceLabel == CoachAdjustments.dailySourceLabel)

        // Only the weekly deload exists (train-as-planned day) — it still
        // wins outright.
        let weeklyOnly = CoachAdjustments.effectivePlan(daily: nil, weeklyDeloadActive: true)
        #expect(weeklyOnly?.plan == deload)
        #expect(weeklyOnly?.sourceLabel == CoachAdjustments.weeklySourceLabel)

        // Neither applies — train as written.
        #expect(CoachAdjustments.effectivePlan(daily: nil, weeklyDeloadActive: false) == nil)
    }
}
