# FF-002 — Watch Terminal Command Identity

**Status:** Planned
**Severity:** P1
**Owner:** Unassigned
**Source audit date:** 2026-08-10

## Problem

The Watch→phone terminal commands (finish and discard workout) do not carry the
identifier of the workout they are meant to end. Because Watch↔phone messaging is
asynchronous and order is not guaranteed, a delayed `finishWorkout`/`discardWorkout`
userInfo can arrive after the user has already started a different workout on the
phone, and terminate the wrong session.

## Confirmed trigger

- Start workout A on the phone and mirror it on the Watch.
- End A on the phone and immediately start workout B.
- A previously queued/slow-delivered `WatchCommand.finishWorkout` (or
  `discardWorkout`) for A arrives while B is active.
- B is finished/discarded as a result of A's terminal command.

## User impact

A workout can be prematurely ended or discarded without the user asking for it,
losing logged sets and potentially writing a truncated/short workout to HealthKit.
The async delivery on WCSession makes this intermittent and hard to reproduce,
which is precisely why it is dangerous.

## Source evidence

- `WatchCommand.finishWorkout` / `WatchCommand.discardWorkout` — the terminal
  command cases/messages lack a `workoutID` field (audited 2026-08-10).
- The Watch command handler that unpacks these cases applies the terminal action
  to whatever workout is currently active on the phone, with no ID match against
  the starting/active workout.

## Scope

- In scope: making the terminal command carry the target workout identity and
  having the phone handler reject mismatches.
- Out of scope: unrelated watch protocol messages, and the WatchWorkoutEngine
  identity concern tracked separately in FF-003.

## Non-goals

- Not re-architecting WCSession delivery/ordering guarantees.
- Not changing start/pause/resume command shape unless directly required by
  binding the terminal command.

## High-level fix direction

Bind each terminal command to the identity of the workout it is terminating:
- Add a `workoutID` to `WatchCommand.finishWorkout` and `WatchCommand.discardWorkout`.
- The Watch side stamps the ID of the workout it is bound to at the time it emits
  the command.
- The phone handler compares the carried ID to the currently active workout; on
  mismatch it drops the command (does nothing) rather than terminating the newer
  workout.
- Preserve wire compatibility only if the audit determines an old Watch build can
  still be in the field with a new phone build — otherwise the contract is updated
  in lockstep. Deviation from the current wire shape must be an explicit, recorded
  decision, not assumed.

## Acceptance criteria

- [ ] `finishWorkout` and `discardWorkout` carry the target workout ID.
- [ ] Handler refuses to finish/discard when the carried ID does not match the
      active workout; a newer workout is left untouched.
- [ ] Handler still finishes/discards correctly when the ID matches.
- [ ] Delayed/misordered delivery of a terminal command for a superseded workout
      has no effect on the active workout.
- [ ] Wire compatibility retained (old Watch + new phone) if and only if the
      audit requires it, with the decision recorded; otherwise the contract is
      updated deliberately.

## Required automated tests

- [ ] Protocol tests: encoding/decoding of terminal commands carries the workout
      ID over the wire.
- [ ] Handler tests: matching ID ends the workout; mismatched ID is rejected and
      the newer workout survives; delayed replay of an old command is a no-op.

## Required runtime / hardware validation

- [ ] Simulator watch↔phone: finish A, immediately start B, replay A's finish
      userInfo — B is unaffected.
- [ ] Hardware Apple Watch + iPhone: same scenario with real WCSession delivery,
      including an artificial delay injection if feasible.

## Dependencies

- None new; **precedes FF-003** (Wave A). FF-003's engine identity handling
  depends on this wire contract change.

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