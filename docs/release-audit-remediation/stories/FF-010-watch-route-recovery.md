# FF-010 — Recovered outdoor session does not restart route collection

- **Status:** Planned
- **Severity:** P2
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

`recoverSessionIfNeeded` restores an interrupted outdoor session but does not
restart outdoor route/location collection. After recovery, the session continues
without its route, so the recorded route is incomplete or absent while the user
believes tracking is still active.

## Confirmed trigger

An outdoor workout session is interrupted (process kill, watch restart) and then
recovered via `recoverSessionIfNeeded`. The session model is restored but the
route builder / location collection is not resumed, so subsequent movements are
not appended to the route.

## User impact

Users lose route continuity for recovered outdoor sessions. The route is
missing or truncated, and there is no visible indication that location tracking
stopped — interaction mechanics are not communicated by the UI.

## Source evidence

Repository-relative paths and symbols:

- `recoverSessionIfNeeded` — recovers the outdoor session without resuming the
  route builder / location collection (in `ForgeFit/` session recovery sources).

## Scope

- `recoverSessionIfNeeded` outdoor recovery path.
- Route builder / location collection resume logic on the watch.

## Non-goals

- No change to route recording for non-recovered sessions.

## High-level fix direction

- Resume the route builder / location collection safely after a recovered
  outdoor session.
- Add a unit seam so the resume behavior is testable without hardware.
- Provide a physical route-continuity smoke test.

## Acceptance criteria

- [ ] After recovery, the route builder / location collection resumes for the
      recovered outdoor session.
- [ ] Resumption is safe (no duplicate/overlapping segments, no crash).
- [ ] The resume path is exercised through a unit seam.
- [ ] A physical route-continuity smoke test passes.

## Required automated tests

- Unit test: recovered outdoor session resumes the location/route manager.
- Test that resumption does not duplicate existing route segments.
- Test that non-outdoor recovered sessions are unaffected.

## Required runtime/hardware validation

- Physical watch run: start an outdoor session, kill/restart, recover, confirm
  the route continues continuously.

## Dependencies

- Watch route builder / location manager internals.
- `recoverSessionIfNeeded`.

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