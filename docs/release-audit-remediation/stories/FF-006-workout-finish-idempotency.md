# FF-006 — Workout Finish Idempotency

**Status:** Planned
**Severity:** P1-risk
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

A rapid Save (double-tap / save fired twice before the UI settles) can invoke
`WorkoutFinisher.finish` twice for the same workout. There is no in-flight gate at
the UI layer and no idempotency at the service layer, so the second invocation
creates duplicate HealthKit workouts for one user action.

## Confirmed trigger

- Complete a workout and tap Save twice in quick succession (or the save action
  is triggered twice before the UI disables the control).
- `WorkoutFinisher.finish` runs both times.
- Two HealthKit workouts are recorded for the single workout.

## User impact

The athlete sees a duplicated workout in HealthKit and dependencies (Watch,
Activity, XP/streaks) because one logical completion wrote two records. The
duplicate is confusing, inflates volume/XP, and is painful to delete.

## Source evidence

- `WorkoutFinisher.finish` (audited 2026-08-10): no idempotency guard — calling it
  twice for the same workout writes HealthKit twice.
- Save action/button path (audited 2026-08-10): no in-flight state preventing a
  second finish while the first is still resolving.

## Scope

- In scope: UI in-flight state plus service-level idempotency so finish is
  exactly-once.
- Out of scope: other writes to HealthKit outside the finisher path.

## Non-goals

- Not changing what data is written to HealthKit — only ensuring it happens once.
- Not deduplicating historical duplicates already in the database (out of scope;
  noted as residual risk).

## High-level fix direction

Two layers, defense-in-depth:
- **UI in-flight state:** disable the Save control / reject the second tap while a
  finish is pending so a double-tap cannot re-enter.
- **Service-level idempotency:** `WorkoutFinisher.finish` records that the workout
  has been finished and ignores a subsequent identical call, so even a
  re-entered/retried path cannot double-write.

Together these yield exactly-once behavior across HealthKit, Watch, and XP paths.

## Acceptance criteria

- [ ] A second immediate Save cannot re-enter the finisher (UI gate).
- [ ] Calling `WorkoutFinisher.finish` twice for the same workout writes exactly
      one HealthKit workout (service gate).
- [ ] Watch and XP side effects fire exactly once per workout completion.
- [ ] A legitimate re-run on a distinct workout still finishes normally.

## Required automated tests

- [ ] exactly-once HealthKit test: two finish calls produce a single
      HKWorkout/record.
- [ ] Watch-path exactly-once test: finish is relayed once.
- [ ] XP exactly-once test: volume/streak increments once.
- [ ] UI test (or state test): double-tap Save cannot re-enter the finisher once
      in-flight.

## Required runtime / hardware validation

- [ ] Simulator (pinned `OS=26.5`): rapid double-tap Save on a completed workout
      results in a single HealthKit workout and single XP/streak increment.
- [ ] Hardware iPhone: same check on-device while a Watch session is mirroring.

## Dependencies

- None new. **Blocks with FF-001** in Wave B but is file-independent of it; may
  proceed in parallel.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |

### Files changed

- (pending)

### Tests requested / run

- (pending)

### Residual risks

- Historical duplicates already present in a user's HealthKit are not
  deduplicated by this change (out of scope today).

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| — | — | — | — |

## Definition of Done

- [ ] All acceptance criteria checked.
- [ ] Required automated tests added and passing via the named command.
- [ ] Required runtime / hardware validation executed and results recorded.
- [ ] Worker work log completed (status, owner, files changed, tests,
      residual risks).
- [ ] `Status` moved through Planned → In Progress → In Review → Changes
      Requested / Verified → Done.

## Final sign-off

> **Done and sign-off are set by the manager alone.** Workers never mark a story
> Done or sign it off.

- **Verified by (technically):**
- **Done set by (manager):**
- **Date:**
- **Release gate:** this story is / is not a blocker for the remediation release.