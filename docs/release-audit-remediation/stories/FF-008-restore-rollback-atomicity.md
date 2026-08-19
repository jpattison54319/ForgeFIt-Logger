# FF-008 — Backup restore lacks rollback, can persist a partial restore

- **Status:** In Review
- **Severity:** P1 — release gate
- **Owner:** Codex direct remediation
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

- **2026-08-11 — DeepSeek V4 Flash 0731 — FF-008 (claim → In Review):**
  First pass used a staged-`[any PersistentModel]` array plus a compensating
  delete-then-save cleanup. **Changes requested by manager:** replace that
  design entirely; do not build on it. `commit` must create a fresh isolated
  `ModelContext` from the caller context's container, perform all
  fetches/inserts and the injected save in that restore context, and on any
  thrown save call `restoreContext.rollback()` before rethrowing — isolating
  rollback so unrelated unsaved caller-context edits survive, and
  guaranteeing a later caller save cannot commit failed-restore residue.
  Do not simulate a save-that-succeeds-then-throws (SwiftData save is the
  transactional boundary). **Fixed as requested** (PlanImportService pattern):
  `commit(_:restorePreferences:in:performSave:)` now wraps `performCommit` in
  `ModelContext(context.container)` with autosave disabled and calls
  `restoreContext.rollback()` on any thrown error before rethrowing;
  preferences stay deferred (UserDefaults) until the isolated store save
  succeeds. Public API and caller behavior unchanged — the caller
  (`WorkoutHistoryImportView.restore`) needed no edits because rollback
  completes inside `commit` before the error surfaces.

  **Files changed:**
  - `ForgeFit/Backup/BackupRestoreService.swift` — isolated-context
    transaction wrapper + `rollback()`; all fetch/insert/save moved into the
    restore context; preferences applied only after the isolated save;
    staged-array/delete-save helpers removed.
  - `ForgeFitTests/BackupRestoreRollbackTests.swift` (new) — deterministic
    failure-injection tests via the `performSave` seam.

  **Tests written — explicitly NOT RUN** (file-edits-only session; no
  build/test was permitted): injected save failure → zero restored rows
  across every restored model kind; later caller save commits no
  failed-restore residue; unrelated unsaved caller model survives failure and
  can subsequently save; retry after failure commits exactly once; success
  persists the full representative graph (workouts, exercises, sets, library
  recreation, cardio graph, batches, microcycle tracking/windows, rest days);
  preferences unchanged on failure and applied on success.

  **Residual risks (real device/store):** cross-context visibility of the
  isolated save to the caller's `mainContext` (on restore success the caller
  enriches by fetching restored workout ids in its own context) is unverified
  on a real device; a real CloudKit-backed save that partially commits before
  reporting failure cannot be undone by `rollback()` — SwiftData save is the
  transaction boundary, so the save result must be treated as authoritative.
  Apple does not document a distributed atomic guarantee for one context save
  spanning ForgeFit's separate SQLite stores. The story's required split-store
  runtime validation (forced failure on a clean device, zero partial rows) has
  NOT been performed.

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
