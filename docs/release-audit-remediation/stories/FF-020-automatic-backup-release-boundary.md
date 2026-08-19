# FF-020 — Automatic backup release boundary (P1)

- **ID:** FF-020
- **Title:** Automatic backup release boundary
- **Status:** In Review
- **Severity:** P1 (data durability / privacy / release boundary)
- **Owner:** Codex direct remediation
- **Decision date:** 2026-08-11

## Product decision

The owner explicitly confirmed that automatic iCloud protection is the product
contract: routines must sync automatically, and workout history must be backed
up automatically. The temporary 1.0 release gate that disabled workout-history
scheduling was therefore a regression, not the intended privacy boundary.

The shipping design is now:

- the training-plan store (routines, folders, exercise library, presets, and
  other plan rows) syncs automatically through the user's private CloudKit
  database;
- the local workout-log store remains out of CloudKit and produces a separate
  sanitized iCloud Drive backup automatically;
- Settings exposes backup state, last success, failure details, immediate
  retry, and deletion;
- privacy copy names the automatic behavior, included data, excluded data,
  restore path, and the fact that a later change recreates a deleted backup.

## Implemented remediation

- `BackupAutomationPolicy.isEnabledInThisRelease` is on.
- `BackupScheduler` queues log changes, performs a daily catch-up, defers work
  during a live workout/background transition, persists failure state, and
  coalesces retries.
- Settings → iCloud Backup presents status, last success, **Back up now**, and
  **Delete workout backup** with explicit consequences.
- Two-slot rotation keeps the last usable `latest` file while promoting a new
  one; reset/deletion awaits a structured result instead of swallowing errors.
- Backup DTOs omit direct Health fields. The mapper also excludes entire
  HealthKit-imported workouts, HealthKit-filled distance, and Health-derived
  auto-detected intervals. A local optional distance-provenance field makes
  that shared-property boundary testable without adding provenance to the
  backup payload.
- Restored distance is marked as restored-backup provenance so a later
  automatic backup remains stable.
- In-app and repository privacy policies now describe the automatic behavior
  and precise data boundary.

## Automated evidence

- `BackupSchedulerTests`: automatic change export, visible failure + retry,
  unavailable iCloud state, delete semantics, and live-workout deferral.
- `BackupFormatTests`: allowed-key walk, no direct Health keys/sentinels,
  HealthKit-imported workout exclusion, distance-provenance filtering,
  auto-detected interval exclusion, and user-authored round trip.
- `BackupRotationTests`, `BackupDeletionTests`, and
  `BackupRestoreRollbackTests`: rotation, structured delete outcomes, isolated
  restore, deduplication, and rollback.
- ForgeData full package gate passed after the provenance change on 2026-08-11.

## Acceptance criteria

- [x] Automatic plan sync remains enabled through private CloudKit.
- [x] Automatic workout-history backup scheduling is enabled by default.
- [x] Status, last success, last failure, immediate retry, and deletion are
  visible in Settings.
- [x] A failed or unavailable backup never presents as successful.
- [x] HealthKit-imported workouts and shared fields with HealthKit provenance
  are excluded by tests, in addition to the DTO Health-field allow-list.
- [x] In-app privacy, repository privacy, and submission copy describe the
  decided behavior.
- [ ] A real signed-in iCloud account has produced, deleted, and restored the
  current backup on clean physical installs.
- [ ] The signed stable archive's iCloud/CloudKit entitlements and Production
  environment have been inspected.

## Residual release risk

Apple's App Review Guideline 5.1.3(ii) says apps may not store personal health
information in iCloud. ForgeFit excludes Apple Health-derived content, but the
remaining user-recorded workout log and precise routes are still sensitive
fitness/location data. Sanitization does not by itself establish Apple's policy
interpretation. The product decision is implemented, but this remains an App
Review/legal interpretation risk to resolve before final submission.

## Required runtime validation

1. On a physical iPhone signed into iCloud Drive, make a workout-log change and
   confirm `ForgeFit-Backup-latest.forgefitbackup` appears automatically.
2. Turn off iCloud Drive or sign out, trigger a change, and confirm the visible
   unavailable/failure state and successful retry after recovery.
3. Delete both rotating files from Settings and confirm local workouts and
   CloudKit routines remain intact; then confirm a later log change recreates a
   backup.
4. Restore the latest file on a clean second iPhone and verify workout, set,
   route, microcycle, and rest-marker fidelity while Health-derived fields are
   repopulated only from that device's Apple Health store.

## Final sign-off

- **Manager sign-off:** Pending physical iCloud and stable-archive validation.
- **User product decision:** Automatic routine sync and automatic workout
  history backup confirmed on 2026-08-11.
