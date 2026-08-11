# FF-007 — Reset backup deletion is unstructured and can fail silently

- **Status:** Planned
- **Severity:** P1 — release gate
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

`AccountResetService` fires backup deletion in an unstructured `Task` with no
awaiting of the result. `BackupExporter` swallows delete/coordinator failures
and sets state to idle, while the privacy copy promises the user that their
backup has been removed. The user can be told "backup deleted" even when the
deletion failed or was interrupted.

## Confirmed trigger

Performing a full account reset while an iCloud Drive / CloudKit backup exists,
under conditions where the backup export coordinator's `delete` fails or is
interrupted (offline, coordinator failure). The reset flow returns/than proceeds
without propagating the failure to the user.

## User impact

The user receives a reset confirmation stating their private backup data was
deleted when it was not. This contradicts the privacy-policy promise that only
logged training data reaches iCloud. Because confirmation text is reassuring
rather than consequence-stated, the user has no way to detect the failure.

## Source evidence

Repository-relative paths and symbols:

- `AccountResetService` — launches backup deletion in an unstructured `Task`
  and does not await/observe its result (see `ForgeFit/` activity/reset sources).
- `BackupExporter` — `delete`/coordinator failures are swallowed; the exporter
  sets its state to idle regardless of the deletion outcome.
- Privacy copy that promises backup removal — mirrored pair
  `ForgeFit/Settings/PrivacyPolicyView.swift` and `docs/privacy-policy.md`.

## Scope

- `AccountResetService` backup-deletion path.
- `BackupExporter` deletion/error states and idle-state transitions.
- The confirmation/error messaging surfaced to the user during reset.
- The mirrored privacy copy so promises match actual guarantees.

## Non-goals

- No change to the CloudKit sync / iCloud Drive payload contents.
- No change to what the backup contains (still logged training data only).

## High-level fix direction

- Await the `BackupExporter` deletion result before declaring reset complete.
- Introduce an explicit failure state and user consequence messaging: the
  confirmation must state the failure and the resulting state, not reassurance.
- Keep `ForgeFit/Settings/PrivacyPolicyView.swift` and
  `docs/privacy-policy.md` mirrored if any wording changes.
- Make the path injectable so tests can drive offline and failure scenarios
  deterministically.

## Acceptance criteria

- [ ] Reset awaits the awaited backup-deletion result before showing its
      confirmation.
- [ ] A failed/interrupted deletion surfaces an explicit failure state with a
      consequence-stated user message (no pure reassurance).
- [ ] `BackupExporter` no longer reports idle on a failed delete.
- [ ] Privacy copy and `docs/privacy-policy.md` remain mirrored and match the
      actual guarantees.
- [ ] Failures are fully automated-testable via injection.

## Required automated tests

- Delete succeeds → reset completes and confirms deletion.
- Delete fails (coordinator failure) → failure state surfaced, idle not set.
- Delete interrupted/offline → explicit user consequence.
- Confirm privacy copy mirrors `docs/privacy-policy.md` on any wording change.

## Required runtime/hardware validation

- Manual reset on a device with a real iCloud account, online and offline.
- Verify the confirmation/error matches the actual backup state.

## Dependencies

- `BackupExporter` deletion API and error surfaces.
- Reset flow state handling.

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