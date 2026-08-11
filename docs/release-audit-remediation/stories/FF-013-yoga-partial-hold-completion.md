# FF-013 — Completing mid-yoga-hold does not record the current partial hold

- **Status:** Planned
- **Severity:** P2
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

Complete mid-yoga-hold stops the runner without recording the current partial
hold, whereas Skip records it. This yields inconsistent partial-credit semantics
across splits, pose count, exposure, and history, depending on how the workout
ends.

## Confirmed trigger

Ending a yoga session mid-hold via **Complete** does not record the current
partial hold, while ending via **Skip** does. The two exit paths therefore
aggregate different numbers of poses/holds into splits, pose count, exposure,
and history.

## User impact

Pose count, splits, exposure, and history differ depending on whether the user
ends the current hold with Complete or Skip. The partial-credit semantics are
inconsistent and not communicated by the UI.

## Source evidence

Repository-relative paths and symbols:

- Yoga Complete path — stops the runner without recording the current partial
  hold (in `ForgeFit/` yoga session sources).
- Yoga Skip path — records the current partial hold.

## Scope

- Yoga Complete vs Skip partial-hold handling.
- Aggregation across splits, pose count, exposure, and history.

## Non-goals

- No change to the yoga pose catalog or coaching dose.

## High-level fix direction

- Choose and apply one consistent partial-credit semantic across both Complete
  and Skip paths, and make splits, pose count, exposure, and history use it
  uniformly.
- Test the Complete, Skip, and background exit paths.

## Acceptance criteria

- [ ] Complete and Skip apply the same partial-hold semantics.
- [ ] Splits, pose count, exposure, and history all derive from the chosen
      semantic consistently.
- [ ] The Complete, Skip, and background paths converge on identical aggregate
      results for an equivalent mid-hold ending.
- [ ] UI communicates the partial-credit behavior.

## Required automated tests

- Complete mid-hold → current partial hold recorded.
- Skip mid-hold → matches Complete for an equivalent session.
- Background/termination exit path → consistent semantics.
- Split/pose-count/exposure/history aggregation equivalence across exit paths.

## Required runtime/hardware validation

- Manual watch run: end the same mid-hold yoga session via Complete and via
  Skip; confirm identical pose count, splits, exposure, and history.

## Dependencies

- Yoga session runner Complete/Skip/background exit paths.
- Splits, pose count, exposure, and history aggregation.

## Worker work log

_Workers: update Status, Owner, work log, files changed, tests
requested/run, and residual risks. The manager alone sets Done and signs off._

- (empty — no work claimed)

## Reviewer log

- (empty — no review claimed)

## Definition of Done

All acceptance criteria pass; required automated tests exist and pass; required
runtime/hardware validation is documented; reviewer log has a sign-off by the
manager.

## Final sign-off

- **Done set by (manager):** _unset_
- **Date:** _unset_
- **Sign-off notes:** _unset_