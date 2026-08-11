# FF-004 — Onboarding Deep-Link Deferral

**Status:** Planned
**Severity:** P1
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

Non-plan deep links (for example a routine, exercise, or history route) can be
routed and begin work behind the onboarding flow, which is not ready to receive
them yet. Independently, `clearStarterSlate` deletes **all** unfinished workouts
at onboarding dismissal, regardless of whether they were seeded starter data or
live user work-in-progress.

## Confirmed trigger

- A deep link arrives while onboarding is on screen.
- The router starts the linked scene under onboarding instead of holding it.
- On dismissal, `clearStarterSlate` runs and deletes every unfinished workout,
  including any real, user-created in-progress workout that must survive
  onboarding.

## User impact

Deep links can open the wrong state or open behind onboarding and be lost, while
the cleanup step can silently destroy an athlete's unsaved workout. The user sees
either a broken landing or a vanished in-progress routine.

## Source evidence

- Deep-link router (audited 2026-08-10): routes non-plan links immediately rather
  than deferring while onboarding is active.
- `clearStarterSlate` (audited 2026-08-10): at onboarding dismissal it deletes
  unfinished workouts without distinguishing seeded starter data from real user
  work.

## Scope

- In scope: queuing/deferring routes while onboarding is active, replaying them
  safely after dismissal, and narrowing the cleanup to seeded data only.
- Out of scope: redesigning the whole onboarding flow or the deep-link scheme.

## Non-goals

- Not applying the fix to plan-bearing links already handled correctly today.
- Not adding new route types.

## High-level fix direction

Separate routing and cleanup timing from onboarding:
- While onboarding is presenting, queue incoming non-plan deep links instead of
  routing them immediately.
- After onboarding is dismissed, replay the queued routes against the now-ready
  app state, safely (no started work on a half-initialized stack).
- Change the dismissal cleanup so it removes only seeded starter data (tracked/
  identifiable as seeded), leaving real unfinished user workouts intact.

## Acceptance criteria

- [ ] A non-plan deep link arriving during onboarding is queued, not routed.
- [ ] The queued link is replayed correctly after onboarding dismissal.
- [ ] `clearStarterSlate` deletes seeded starter data only.
- [ ] Real, user-created unfinished workouts survive onboarding dismissal.

## Required automated tests

- [ ] UI/state test: deep link arrives during onboarding → queued → replayed after
      dismissal to the correct scene.
- [ ] UI/state test: dismissal cleanup preserves a user-created unfinished
      workout while removing seeded data.

## Required runtime / hardware validation

- [ ] Simulator (pinned `OS=26.5`): trigger a deep link during onboarding and
      confirm correct post-dismissal landing and no loss of real in-progress
      workouts.
- [ ] Hardware iPhone: same flow on-device with a real launch-from-link.

## Dependencies

- None new. Independent of FF-001/002/003/005/006; proceeds in Wave C.

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