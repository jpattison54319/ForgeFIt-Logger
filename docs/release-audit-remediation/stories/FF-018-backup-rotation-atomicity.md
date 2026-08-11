# FF-018 — Backup rotation atomicity

- **ID:** FF-018
- **Title:** Backup rotation atomicity
- **Status:** Planned
- **Severity:** P3
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

Backup rotation moves `latest` to `previous` before the temp file is moved to
`latest`. If the process is interrupted or a failure occurs between the two
moves, there is no `latest` file left at all — the user has no current backup
until the next successful write — even though the previous payload still
exists.

## Confirmed trigger

`ForgeFit/Backup/BackupExporter.swift` `exportNow`:

1. writes a new compressed blob to `temp`;
2. coordinates a write at `latestURL` with `.forReplacing`, inside which it removes any existing `previousURL`, moves `latest → previous`, then moves `temp → latest` (lines ~149–163).

If a process kill or a filesystem/coordination error lands between `move latest→previous` and `move temp→latest`, `latest` is deleted and never replaced, so no recoverable current backup exists.

## User impact

- No current (`latest`) backup after an interrupted rotation; if the old `latest` payload was the only recoverable copy, the user may be left with a stale `previous` or nothing depending on timing.
- A subsequent failed or cancelled export leaves the invariant "a latest always exists" broken until a full successful rotation.

## Source evidence

- `ForgeFit/Backup/BackupExporter.swift`
  - `latestBackupURL()` / `previousBackupURL()` helpers (lines ~118–121 and surrounding).
  - `exportNow(container:)` rotation block — `NSFileCoordinator().coordinate(writingItemAt: latestURL, options: .forReplacing, ...) { if fileExists(url) { removeItem(previousURL); moveItem(url, to: previousURL) } moveItem(temp, to: url) }` (lines ~144–167).
  - `deleteAllBackups()` (lines ~183–193).
- Consumers of the two rotating slots: `ForgeFit/Backup/BackupRestoreService.swift` (`rotation slots that exist ... newest first`).

## Scope

- The two-slot rotation in `ForgeFit/Backup/BackupExporter.swift` and any restore path that depends on it (`BackupRestoreService.swift`).

## Non-goals

- Not changing the backup directory layout or the Files-app-visible naming beyond what is needed for a safe rotation.
- Not changing what data is backed up (that is FF-019/FF-020 territory).

## High-level fix direction

Make rotation a coordinated, atomic replacement that never leaves the system
without at least one recoverable `latest`. Approaches: write the new file as a
candidate `latest`, then promote it only after the candidate is durable
(rename the old `latest` to `previous` after the new file is in place), or
restore/re-link a prior `latest` on any failure of the swap. Add deterministic
failure-injection tests that interrupt the rotation at each move boundary and
assert a valid `latest` (new or prior) always survives.

## Acceptance criteria

- [ ] At every point during rotation a valid backup file exists at `latest` (either the new one or the prior one).
- [ ] Interrupting or failing the rotation at any move boundary never leaves both slots missing and `latest` without a file.
- [ ] A completed rotation yields `latest` = new payload and `previous` = prior payload.
- [ ] `deleteAllBackups` still removes both slots as today.

## Required automated tests

- Failure-injection test throwing at each rotation step (before/after each `moveItem`) and asserting exactly one recoverable file remains and that subsequent restore works from it.
- Happy-path test asserting the final `latest`/`previous` identity after a successful rotate.

## Required runtime/hardware validation

- Manual: trigger a full-backup rotation in a simulator, and separately test cancellation during export; confirm a valid `latest` remains.

## Dependencies

- None blocking; coordinate with FF-020 if rotation/scheduling behavior changes as part of the release work.

## Worker work log

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions._

- (empty — planned only; no work performed)

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- Rotation never leaves the system without a recoverable `latest`, proven by failure-injection tests.
- Acceptance criteria met with automated tests green.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_