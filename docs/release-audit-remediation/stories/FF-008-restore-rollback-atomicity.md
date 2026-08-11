# FF-008 — Backup restore lacks rollback, can persist a partial restore

- **Status:** Planned
- **Severity:** P1 — release gate
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

`BackupRestoreService` stages a batch of bulk inserts in memory, then performs a
single save. When that save fails, the caller shows an error but does not roll
back — so a later save can persist a partially-restored dataset. The user is left
with inconsistent or incomplete data that was never presented as resulting from
a failed restore.

## Confirmed trigger

A backup restore whose bulk save fails partway (e.g. a single model fails
CloudKit/SwiftData validation or a transient store error). The caller surfaces an
error, but any already-persisted rows remain, and a subsequent save within the
same context can commit the remainder — yielding a partial restore.

## User impact

The user believes the restore failed and nothing changed, yet partial data has
been written. Subsequent operations can commit more of the partial restore.
There is no transactional guarantee, so the restore is not atomic.

## Source evidence

Repository-relative paths and symbols:

- `BackupRestoreService` — stages bulk inserts then saves; no rollback path on
  save failure (in `ForgeFit/` backup/restore sources).
- The caller — shows an error after save failure without issuing a rollback.

## Scope

- `BackupRestoreService` staging/save/rollback behavior.
- The caller's error path.

## Non-goals

- No change to the backup file format.
- No change to what is backed up.

## High-level fix direction

- Make restore transactional: on save failure, roll back any partially persisted
  inserts before surfacing the error.
- Add failure injection so the save-failure branch is deterministic to test.
- Ensure retry safety so a retried restore cannot double-apply committed data.

## Acceptance criteria

- [ ] A failed restore rolls back all partially-persisted inserts.
- [ ] The caller surfaces an error only after rollback completes.
- [ ] No later save can commit a partial restore from a failed attempt.
- [ ] Retrying a restore after a clean failure does not double-apply data.
- [ ] The failure path is deterministically testable via injection.

## Required automated tests

- Save failure mid-batch → no rows persist from the failed restore.
- No rows from a partial restore survive into a later save.
- Retry after failure does not duplicate committed data.
- Success path remains fully intact.

## Required runtime/hardware validation

- Restore a realistic backup on a clean device; force a failure and confirm
  zero partial rows remain.

## Dependencies

- SwiftData/`ModelContext` transaction and rollback semantics.
- Caller error-propagation flow.

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