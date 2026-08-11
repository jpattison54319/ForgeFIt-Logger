# FF-020 — Automatic backup release boundary (P1)

- **ID:** FF-020
- **Title:** Automatic backup release boundary
- **Status:** Planned
- **Severity:** P1 (release boundary / compliance)
- **Owner:** Unassigned
- **Source audit date:** 2026-08-10

## Problem

ForgeFit's automatic iCloud Drive workout backup runs without a visible
opt-in, status, off switch, or failure path, and the backup contains detailed
workout history and precise outdoor routes. The prior audit policy
interpretation that backed this behavior must be refreshed: the product is
described as "optional" but writes automatically whenever iCloud Drive is
available. This is a release-blocking compliance/trust decision (Apple App
Review Guideline 5.1.3(ii) plus Developer Program License Agreement limits on
sensitive personal health information in iCloud; see audit section 2).

## Confirmed trigger

- `BackupScheduler` (see below) schedules automatic exports on log-data
  changes, live-workout close, foreground, and a once-per-day catch-up whenever
  iCloud Drive is available, with no visible on/off, status, "Back up now",
  failure, or delete control outside Reset/Files.
- The emitted file contains detailed fitness records and precise route points
  (`audit` found 3,716 route points, 308 workouts, notes, effort/RPE,
  conditioning/yoga plan JSON in the deployed 1.0 backup).
- HealthKit-derived fields are structurally excluded, but the remaining
  personal fitness data plus the CloudKit `painFlag` make an unconditional
  5.1.3(ii)-compliant claim unsafe without Apple's interpretation.

## User impact

- Users who sign into iCloud can receive automatic backup writes without seeing
  what was written, whether it succeeded, or how to disable or delete it.
- Precise route and workout detail reside in the user's iCloud, contrary to the
  apparent "optional" framing.
- Release risk: potential App Store guideline non-conformance; a rejected or
  "flagged for review" 1.0.

## Source evidence

- `ForgeFit/Backup/BackupScheduler.swift` — `BackupScheduler`, `shared`, scheduling triggers (post-foreground, live-close, log-change, once-per-day catch-up).
- `ForgeFit/Backup/BackupExporter.swift` — `exportNow`, two-slot rotation (`ForgeFit-Backup-latest*/previous*`), `deleteAllBackups`, triggers on finish/import/delete/background + daily.
- `ForgeFit/Backup/BackupRestoreService.swift` — restore of the rotating slots.
- `Packages/ForgeData/Sources/ForgeData/Backup/BackupFormat.swift` / `BackupMapper.swift` — sanitized (health-stripped) payload.
- `ForgeFit/Settings/PrivacyPolicyView.swift` and `docs/privacy-policy.md` — describe the backup as "optional".
- `docs/app-store-submission.md` — iCloud Drive backup claims (auto, no status/off visible).
- Audit: `artifacts/release-audit-2026-08-09/FINAL-AUDIT.md` section 2 ("Automatic iCloud Drive training-log backup", "When the backup writes", "Compliance and trust assessment").
- CloudKit `painFlag` on exercise notes (planning layer) — referenced in audit (flagged elsewhere; see findings).

## Scope

- Automatic scheduling, opt-in/off, status, last-success/failure reporting,
  "Back up now", deletion, content minimization, and end-to-end clean restore.
- Refreshing the privacy policy copy and Settings disclosure (all mirrored
  surfaces) to match the chosen behavior.
- Explicit user-directed export/import must be preserved.

## Non-goals

- Not removing explicit user-directed export/import.
- Not changing CloudKit plan sync behavior except where the `painFlag`
  localization decision is separately approved.

## High-level fix direction (proposed, pending manager/user decision)

**Safest 1.0 direction:** disable the automatic iCloud Drive backup scheduling
until the following are in place:

- explicit user opt-in with visible Settings setup/`off` toggle and "Back up now";
- status and last-success/failure reporting with a user-visible failure path;
- user-visible deletion of backups;
- content minimization (confirm whether precise routes and health-adjacent
  notes/effort fields belong);
- clean end-to-end restore of the actual latest file (reliably, per FF-018 atomicity);
- a refreshed review of current Apple policy for iCloud/CloudKit handling of
  this data, and any needed written Apple clarification.

Preserve the explicit user-directed export/import flow throughout. Any SwiftData
schema change — including localizing the sync `painFlag` (moving it out of the
CloudKit plan store) — is a one-way production migration and REQUIRES manager
and user approval before implementation; it must not be bundled silently into
this story.

## Acceptance criteria

- [ ] Automatic scheduling is disabled (gated behind explicit opt-in) unless the manage/user decision re-enables it.
- [ ] If enabled, there is a visible opt-in, off toggle, "Back up now", status, last-success, last-failure, and delete control surfaced in Settings.
- [ ] Failure produces a visible outcome rather than staying silent.
- [ ] Explicit user-directed export/import continue to work unchanged.
- [ ] A restore of the actual latest file into a clean install is verified end-to-end.
- [ ] Privacy copy is updated in both `PrivacyPolicyView.swift` and `docs/privacy-policy.md` (they mirror; change both or neither).
- [ ] No SwiftData/schema change (including `painFlag` localization) is made without manager + user approval recorded in the work log.
- [ ] App Store submission doc reflects the decided behavior and policy interpretation.

## Required automated tests

- Tests asserting automatic scheduling does not fire absent opt-in (or, if re-enabled, only fires per the gated policy).
- Status/failure transitions are tested with injected outcomes.
- Export/import flow tests still pass (regression guard for preserved behavior).
- Any new preference key is added to `AppPreferenceKeys` single source and covered by reset.
- Coordinate with FF-018 (rotation atomicity) and FF-019 (allowed-key coverage) so any retained backup path stays safe and exhaustive.

## Required runtime/hardware validation

- Manual end-to-end on a fresh install: opt-in (if enabled), trigger backup, confirm Files shows `ForgeFit-Backup-latest*` with the selected content, restore into a clean device, confirm workout history is recovered.
- Manual failure injection: disable iCloud Drive / revoke access and confirm the visible failure path and that no automatic silent write occurs.
- Confirm automatic writes do not occur without opt-in on a signed-in iCloud simulator.

## Dependencies

- FF-018 (rotation atomicity) and FF-019 (allowed-key coverage) if any automatic/retained backup path ships.
- Manager + user approval for any SwiftData schema change (painFlag localization).
- Product decision on disable-vs-gate with full controls.

## Worker work log

_To be updated by the implementing worker as work proceeds: status transitions, notes, decisions, files changed, tests requested/run, and residual risks._

- (empty — planned only; no work performed)

## Reviewer log

_To be updated by the reviewing party after code review._

- (empty)

## Definition of Done

- Manager/user decision on disable-vs-gate with controls is recorded.
- Automatic behavior matches the decided policy, with visible controls, status, failure, delete, and clean restore verified end-to-end.
- Privacy mirror updated in both surfaces; submission doc updated.
- No unauthorized schema change; any `painFlag` localization is separately approved.
- Acceptance criteria met with tests green.

## Final sign-off

- **Set by manager only.** Workers update Status/Owner/work log, files changed, tests requested/run, and residual risks; the manager alone sets Done and signs off below.
- **Status set to Done by:** _Unassigned_
- **Manager sign-off (name/date):** _Unassigned_
- **User approval for any schema change (painFlag) recorded:** _Not yet requested / Unassigned_