# FF-015 — Yoga pose-count semantics

- **ID:** FF-015
- **Title:** Yoga pose-count semantics
- **Status:** In Review
- **Severity:** P2
- **Owner:** Codex direct remediation
- **Source audit date:** 2026-08-10

## Problem

`posesCompleted` uses the expanded left/right hold split count, while history
folds both sides of a pose into one logical pose, producing conflicting counts
depending on which surface is queried (live stats vs history vs sharing vs
stats/insights).

## Confirmed trigger

- `ForgeFit/Yoga/YogaFlowRunner.swift` `finishFlow()` writes `session.posesCompleted = steps.count` (expanded holds, both-sides counted per side).
- `ForgeFit/Yoga/YogaSupport.swift` (`hasRecordedSessionsCompletion` path) sets `session.posesCompleted = completedPoseIndexes.count` from `session.splits` — again expanded.
- `ForgeFit/Shared/YogaHistoryPresentation.swift` `poses(...)` and `poseCount(...)` fold an adjacent Left/Right pair back into one logical pose (`rows.count`), which diverges from `posesCompleted`.
- Consumers read either value interchangeably (e.g. `ForgeFit/Yoga/YogaViews.swift`, `YogaBlockCard.swift`, `ForgeFit/Insights/Builder/InsightSnapshots.swift`, `ForgeFit/Analytics/StatisticsAnalytics.swift`, `ForgeFit/Experiments/ExperimentPresentation.swift`).

The same logical pose therefore reports as 2 somewhere and 1 somewhere else.

## User impact

Inconsistent "poses completed" numbers across the active session, history,
share cards, stats, and insights. A "12 pose" session can surface as 12 in one
place and 6 in another, confusing users about what actually counts as a pose.

## Source evidence

- `ForgeFit/Yoga/YogaFlowRunner.swift` — `session.posesCompleted = steps.count` (line ~299).
- `ForgeFit/Yoga/YogaSupport.swift` — `session.posesCompleted = completedPoseIndexes.count` (lines ~138–145).
- `ForgeFit/Shared/YogaHistoryPresentation.swift` — `poses(...)` folds `first.name == second.name` with sides `{"Left","Right"}` into a "Both sides" row; `poseCount(...)` returns `rows.count` (lines ~16–66).
- Consumers listed under Confirmed trigger.

## Scope

- The single user-facing semantics of "a completed pose" across the yoga session stat, history, share, stats, and insights surfaces.
- Derived presentation in `ForgeFit/Shared/YogaHistoryPresentation.swift` and any stat aggregation that reads `posesCompleted`.

## Non-goals

- No change to how left/right holds are timed, credited, or recorded in `session.splits`.
- Avoid SwiftData schema/model changes if the semantics can be reconciled in derived presentation.

## High-level fix direction

Define one user-facing pose-count semantic. Prefer the "logical pose" (both
sides folded into one) as the user-facing count, name left/right holds
separately where a per-side count is genuinely needed, and migrate the derived
presentation so every surface computes this single semantic. Keep the folded
history view consistent with any live "poses completed" number. If `posesCompleted`
must be reinterpreted, migrate derived presentation without a schema change
where possible and get schema-change approval (per `ForgeData` invariant) before
touching the stored value.

## Acceptance criteria

- [ ] A single documented semantic for "poses completed" is used by every user-facing surface.
- [ ] Active-session and history/share/stats/insights counts agree for the same session.
- [ ] Left/right holds of one pose are not double-counted as two poses in the user-facing count.
- [ ] Per-side information remains available where displayed (side detail), without changing the logical pose count.
- [ ] No unexplained numeric regression in existing share/stats tests.

## Required automated tests

- All-suface consistency test: build a session with known expanded splits and assert the logical pose count is identical across `YogaHistoryPresentation`, stat aggregation, and the active-session counter.
- Regression tests for existing `posesCompleted` consumers (`ShareCard*`, `CardioExerciseStats`, `Experiment`/`Insight` snapshots, `StatisticsAnalytics`).

## Required runtime/hardware validation

- Manual: run a both-sides flow and confirm the live counter, history row, and share card all show the same pose count.

## Dependencies

- If interpretation of the stored `posesCompleted` changes, this flags a potential SwiftData/schema consideration and must be approved before implementation (see `ForgeData` schema-change invitation in FF-020; coordinate with it).

## Worker work log

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions._

- (empty — planned only; no work performed)

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- All surfaces agree through one tested implementation.
- Acceptance criteria met with automated tests green.
- No schema change without explicit approval.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_
