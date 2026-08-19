# FF-007 — Reset backup deletion is unstructured and can fail silently

- **Status:** In Review
- **Severity:** P1 — release gate
- **Owner:** Codex direct remediation
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

- **2026-08-11 — DeepSeek V4 Flash 0731 — FF-007 (worker).** Implemented the
  awaited, structured backup deletion:
  - `BackupExporter` gains an injectable `BackupDeleting` seam and returns a
    structured `BackupDeletionResult` (`deleted` / `unavailable` / `cancelled`
    / `failed(reason)`); coordinator and removal errors are surfaced, never
    swallowed; the success stamp is cleared and status returns to `.idle` only
    on `.deleted`. Unavailable (signed out / offline / inaccessible container)
    is treated as UNRESOLVED, not success — the backup may still exist, and
    stamp and status stay untouched. Failure and cancellation also leave stamp
    and status untouched.
  - `AccountResetService.resetAllAppData` is `async` and awaits the deletion
    before deciding the outcome; it posts `forgeFitAccountResetDidComplete`
    only when deletion succeeded, and otherwise returns a consequence outcome
    (`backupDeletionFailed` / `backupDeletionCancelled` /
    `backupDeletionUnavailable`). `finishResetAfterBackupDeletionFailure`
    releases the onboarding transition only after the user acknowledges the
    consequence.
  - `ResetDataSheet` runs the reset asynchronously with a duplicate-tap guard,
    cancels its task on disappear, and renders consequence-stated copy
    ("backup … may still exist … delete it in Files → iCloud Drive → ForgeFit →
    Backups") with a visible Continue-to-onboarding action after
    acknowledgement; Cancel is hidden and interactive dismiss disabled while a
    consequence is pending.
  - Privacy copy updated in both `ForgeFit/Settings/PrivacyPolicyView.swift`
    and `docs/privacy-policy.md` (mirrored): reset "also removes the backup
    and tells you if it couldn't be deleted".

- **Files changed:**
  - `ForgeFit/Backup/BackupExporter.swift`
  - `ForgeFit/Settings/AccountResetService.swift`
  - `ForgeFit/Settings/ResetDataSheet.swift`
  - `ForgeFit/Settings/PrivacyPolicyView.swift`
  - `docs/privacy-policy.md`
  - `ForgeFitTests/BackupDeletionTests.swift` (new)

- **Tests: authored but explicitly NOT run** (file-edits-only session; no
  shell/builds). `ForgeFitTests/BackupDeletionTests.swift` covers: delete
  success → reset completes and posts completion; unavailable/failed/cancelled
  → completion held until acknowledged; notification-ordering (incl. the
  unavailable acknowledgement path); exporter success/failure/cancellation
  status + stamp semantics against a temp-directory override; consequence
  copy; and the mirrored privacy wording. Run with `xcodebuild test
  -workspace ForgeFit.xcworkspace -scheme ForgeFit -destination
  'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
  -only-testing:ForgeFitTests/BackupDeletionTests` (redirect to a log file,
  then check the exit code).

- **Residual simulator/iCloud/device boundaries:** simulators have no iCloud
  account, so the real ubiquity-container `.unavailable` path and real
  `NSFileCoordinator` behavior against iCloud Drive are covered only via the
  injected stub — device validation with a real iCloud account (online,
  offline, signed-out) per the runtime/hardware section is still required. The
  privacy-mirror test reads repo files through `#filePath` host paths, so it
  needs a runner with repo access (simulator/CI) and would fail on a physical
  device. Full-reset tests transiently clear process-wide defaults and `Fmt`
  units, mitigated by a snapshot/restore helper and a serialized suite.

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
