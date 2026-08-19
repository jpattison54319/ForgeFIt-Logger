# FF-011 — Health authorization denial and stalled requests can no-op silently

- **Status:** In Review
- **Severity:** P2
- **Owner:** Codex direct remediation
- **Source audit date:** 2026-08-10

## Problem

The HealthKit authorization denial result is discarded. Later, Connect silently
no-ops, and the onboarding connecting state can remain disabled on a stalled
request. There is no explicit state machine, so denial and timeout are
indistinguishable from success and the user receives no actionable path.

## Confirmed trigger

The user denies HealthKit authorization, or an authorization request stalls
(cancellation/timeout). The denial result is unused; a subsequent Connect
attempt silently does nothing; the onboarding connecting control can stay
disabled indefinitely on a stalled request.

## User impact

The user cannot connect HealthKit after a denial, with no explanation and no
visible route to fix it in Health settings. Controls can be stuck disabled with
no affordance to recover. The UI does not communicate the state or the required
action.

## Source evidence

Repository-relative paths and symbols:

- HealthKit authorization request path — denial result discarded.
- `Connect` action — silently no-ops when authorization is denied.
- Onboarding connecting state — can remain disabled on a stalled request.

## Scope

- HealthKit authorization request and its completion handling.
- `Connect` behavior under denial/stall.
- Onboarding, Home, and Settings authorization-state UI.

## Non-goals

- No change to what HealthKit data is collected once authorized.

## High-level fix direction

- Introduce an explicit authorization state machine.
- Handle cancellation/timeout recovery so a stalled request cannot leave the
  controls permanently disabled.
- Surface a visible, actionable path to Health settings — affordance-based, not
  interaction-instruction-only copy.
- Add onboarding/Home/Settings tests.

## Acceptance criteria

- [ ] Denial is recorded in an explicit state, not discarded.
- [ ] `Connect` does not silently no-op after denial/stall; it gives actionable
      state feedback.
- [ ] A stalled/cancelled request recovers so controls are never permanently
      disabled.
- [ ] The UI surfaces a visible actionable path to Health settings (affordance,
      not instruction-only copy).
- [ ] Onboarding/Home/Settings authorization-state tests pass.

## Required automated tests

- Denial path → explicit denied state and actionable UI.
- Timeout/cancellation → recovery, controls re-enabled.
- Connect after denial does not no-op silently.
- Settings/onboarding/Home state transitions.

## Required runtime/hardware validation

- Manual test on simulator/device: deny authorization, confirm actionable
  recovery; stall a request, confirm recovery.

## Dependencies

- HealthKit authorization completion handling.
- Home/Settings/onboarding authorization state UI.

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
