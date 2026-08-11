# FF-005 — Outdoor Interval Split Preservation

**Status:** Planned
**Severity:** P1
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

Completing an outdoor GPS workout deletes the athlete's manually labeled interval
splits and replaces them with auto-generated distance splits. Manual interval
structuring — work/rest or zone labels the user created deliberately — is
destroyed at completion.

## Confirmed trigger

- Start an outdoor GPS workout on a route that includes interval splits.
- The user labels interval splits manually during the session.
- Complete the workout.
- The completion path drops all labeled interval splits and substitutes distance
  splits.

## User impact

The athlete loses their manual interval segmentation and sees a distance-based
split list instead. The labeled structure they relied on for review is gone,
which undermines the whole point of interval workouts and corrupts the recorded
history.

## Source evidence

- Outdoor GPS completion path (audited 2026-08-10): on completion it replaces
  all labeled interval splits with derived distance splits.
- History rendering of the completed workout shows the distance splits instead of
  the manual interval labels.

## Scope

- In scope: preserving manual interval splits through outdoor completion while
  still recording route and distance information.
- Out of scope: changing how GPS routes are captured or stored.

## Non-goals

- Not removing distance-split storage — route/distance info must still be
  recorded.
- Not redesigning the split UI.
- Not altering interval capture during the active session.

## High-level fix direction

Make completion additive rather than destructive for manual intervals:
- Keep the athlete's manual interval splits across all completion routes.
- Store distance/route information alongside rather than replacing the interval
  data.
- Ensure history renders the preserved manual intervals and can still access the
  recorded distance/route.

## Acceptance criteria

- [ ] Completing an outdoor GPS workout preserves all manually labeled interval
      splits.
- [ ] Route and distance information is still stored from the same completion.
- [ ] History shows the preserved manual interval splits (not distance splits
      substituted for them).
- [ ] All outdoor completion routes behave identically with respect to splits.

## Required automated tests

- [ ] Tests across all completion routes (outdoor/aerobic variants): manual
      interval splits are preserved and distance info still present.
- [ ] History test: completed GPS workout renders manual interval labels with
      route/distance data available.

## Required runtime / hardware validation

- [ ] Simulator (pinned `OS=26.5`): complete a simulated GPS workout and confirm
      manual interval labels survive in history.
- [ ] Hardware iPhone (and Watch if applicable): real outdoor completion preserves
      labeled intervals on-device.

## Dependencies

- None new. Independent of FF-001/002/003/004/006; proceeds in Wave C.

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

- (pending)

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