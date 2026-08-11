# FF-003 — Watch Engine Workout Identity

**Status:** Planned
**Severity:** P1
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

The Watch workout engine's active session is not bound to a specific workout
identity. During recovery, a stale active snapshot can be resumed under a newer
workout context, so a recovered workout A can stream live data labeled as
workout B.

## Confirmed trigger

- Workout A is active on the Watch and the engine is interrupted/recovered
  (e.g. app relaunch or glacial WCSession state while a mirror is being rebuilt).
- A newer phone workout B is either started or its snapshot is selected as the
  current context.
- The engine resumes/starts streaming under snapshot B while still carrying
  session/workout A's identity — data for A is attributed to B.

## User impact

Heart rate, distance, and activity for workout A can be attributed to workout B,
corrupting both HealthKit workouts and the on-device history. Because this only
surfaces under recovery/relaunch timing, it is hard for users to detect and is
silently wrong data.

## Source evidence

- `WatchWorkoutEngine` active-session state (audited 2026-08-10): the engine
  tracks an active session but does not record which workoutID that session
  belongs to, so recovery re-binds to whatever snapshot is current rather than
  the workout the live session was started for.
- Recovery path: on restart/interruption the engine rebuilds from the current
  mirror snapshot without verifying it matches the session's originating workout.

## Scope

- In scope: recording workout identity on the engine's active session and
  restarting/ending the session when the identity mismatches the current context.
- Out of scope: the phone-side terminal command identity in FF-002 (separate
  story, though it lands first in Wave A).

## Non-goals

- Not reworking the whole recovery model — only adding identity binding and the
  mismatch response.
- Not changing live-workout streaming semantics for the correct-identity case.

## High-level fix direction

Record the workout identity at the moment the engine starts a live session, and
carry it through interrupts:
- The engine stores the originating workoutID alongside the active session.
- On recovery, the engine compares the originating identity to the current mirror
  snapshot/context; if they differ, it restarts or ends the session bound to the
  wrong identity rather than streaming under the new one.
- Data is only attributed to a workout when the identity matches.

## Acceptance criteria

- [ ] Active engine session records the workoutID it was started for.
- [ ] On recovery with a mismatched snapshot, the engine restarts or ends the
      stale session instead of streaming under the newer identity.
- [ ] On recovery with a matching identity, streaming resumes normally.
- [ ] No live data is attributed to a workout the session was not started for.

## Required automated tests

- [ ] Recovery/context test: recover engine against snapshot B while the active
      session belongs to A; assert the session is restarted/ended, not resumed
      under B.
- [ ] Context test: matching identity recovers and resumes without restart.

## Required runtime / hardware validation

- [ ] Hardware A-to-B validation on real Apple Watch + iPhone: start A, force a
      recovery/interrupt, start B, and confirm the recovered session is ended not
      misattributed; capture real HKWorkoutSession/HealthKit records for both A
      and B.

## Dependencies

- **Depends on FF-002** (Wave A, order FF-002 → FF-003) for the wire contract the
  engine interacts with.

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