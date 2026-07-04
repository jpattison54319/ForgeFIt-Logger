# C — Schema design notes

Companion to [02-schema.sql](02-schema.sql). Explains the non-obvious modeling decisions.

> **Note:** `02-schema.sql` is a **reference DDL** that documents the data shape. It is no longer a live Postgres backend — the app uses SwiftData `@Model` classes in `Packages/ForgeData` (which mirror this schema) with CloudKit sync. The SQL is kept as a canonical schema reference for the SwiftData models.

---

## Identity & sync

- **PKs are client-generated UUIDs**, created on-device. This is the backbone of duplicate prevention: the same logical workout has the same id on Watch and iPhone, and CloudKit's record name provides the true identity for sync.
- **`updated_at`** on every mutable model feeds CloudKit's last-write-wins reconciliation.
- **Soft deletes (`deleted_at`)** so a delete on one device propagates as a tombstone instead of being resurrected by a stale peer.
- **CloudKit sync is automatic** via SwiftData's `cloudKitDatabase: .automatic` — no outbox, no manual sync triggers, no `sync_events` audit table needed.

## Unilateral volume (problem #3 solved here)

The user enters **one implement's weight** and never doubles anything manually:
- `sets.is_unilateral`, `sets.implement_weight` (one dumbbell), `sets.limb_count` (default 2).
- Server computes `effective_load` then `total_volume = effective_load × reps × (is_unilateral ? limb_count : 1)`.
- Because the *raw entry* (`implement_weight`) and the *resolved* (`effective_load`, `total_volume`) are stored separately, **historical volume stays clean** even if we later change the resolution formula — we can recompute from raw inputs.

## Advanced set types (problem #4)

- `set_type` enum covers warmup/working/drop/rest_pause/backoff/amrap/myo_rep/cluster.
- `weight_mode` enum + offset columns handle bodyweight correctly:
  - `bodyweight` → effective load uses `bodyweight_kg` snapshot.
  - `bodyweight_assisted` → `effective_load = bodyweight_kg − assistance_weight`.
  - `bodyweight_added` → `effective_load = bodyweight_kg + added_weight`.
- Modifiers as booleans/ints rather than new rows: `is_eccentric`, `is_paused`, `partial_reps`, `hold_s`, `duration_s`.
- `machine_settings jsonb` captures seat/pin/incline without schema churn per machine.
- Storing `bodyweight_kg` **per set** (snapshot) keeps e1RM/volume correct as the user's bodyweight changes over months.

## Exercise taxonomy (problem #5 — no siloing)

- **One table for global + custom.** Global rows have `owner_id IS NULL`; custom rows set `owner_id`. Under CloudKit, the exercise library is a **bundled seed** copied into each user's private database on first launch — users own and can customize their copy.
- `preferred_weight_unit` is an optional per-exercise display/input override (`kg`/`lb`). Set weights remain canonical and clients convert at display/input boundaries, so historical sets do not need rewrites when an exercise flips units.
- `mapped_global_id` maps a custom exercise to a global movement so its data still rolls up into movement-pattern / muscle analytics (no data island).
- `exercise_aliases` powers fuzzy search.
- `user_exercise_notes` is `unique(user_id, exercise_id)` so the app can one-shot fetch and **auto-surface** setup cues (seat height, grip, pain flag) whenever an exercise loads.

## Cardio: summary in SwiftData, telemetry as arrays (problems #6, #7, #14)

- `cardio_sessions` holds **modality-correct summary metrics** as nullable columns (stairmaster floors, rowing split/stroke, cycling power/cadence/resistance, running power/stride/oscillation, elliptical strides, HIIT intervals/peak/recovery HR, hike elevation). Fast to query for analytics.
- **High-frequency arrays** (per-second HR/power/pace/cadence and GPS routes) are stored as `CardioRoutePointModel` / `CardioSplitModel` in SwiftData (synced via CloudKit). Previously these were planned for a Storage bucket; under CloudKit they live as SwiftData models.
- `hr_zone_seconds int[]` stores `[z1..z5]` seconds for instant zone-distribution charts without re-reading telemetry.

## Recovery & readiness (problem #10)

- `health_metrics` is one row per `(user_id, metric_date)` — the daily biometric snapshot. Holds both `hrv_sdnn_ms` (Apple's first-class HRV) and `hrv_rmssd_ms` (derived from a heartbeat series **only when available**).
- `health_metrics.hrv_sample_count`, `sleep_sample_count`, and `data_quality_flags` keep the score honest about sparse or estimated inputs. Missing/low-quality inputs lower confidence rather than fabricating precision.
- `readiness_scores.used_rmssd` records which path produced the score (heartbeat-series vs SDNN+RHR+sleep fallback), so the UI can be honest about data quality and we can audit fallback frequency.
- `readiness_scores.formula_version`, `confidence`, and `missing_inputs` make every persisted score reproducible and debuggable after formula changes.
- `recommended_action` + `explanation` make every readiness output **explainable**, per the product thesis.
- The 48-hour rule is treated as an action modifier: relevant muscles with 48h+ since direct work are likely trainable unless HRV/RHR/sleep/load red flags stack up. A single low HRV reading after rest should caution training, not force a rest day.

## Progression & load (problems #2, #7)

- `progression_rules` supports `percent_increase`, `fixed_increment`, `rep_target`, `rpe_target`, `manual` — the configurable strategies the user asked for.
- `progression_recommendations` stores the suggestion *and its `rationale`* ("hit 12 vs target 8–10 → +2.5%") plus `status` so the UI can prefill, and we can measure accept/reject rates (a PRD success metric).
- `training_load_daily` stores universal `daily_load`, split `strength_load`/`cardio_load`, `daily_tss`, `ctl` (fitness, ~42-day EWMA), `atl` (fatigue, ~7-day EWMA), and `tsb` (form = ctl − atl). These are computed **on-device** via `ForgeCore` — no server round-trip.
- `acwr`, `monotony`, and `strain` are spike/variation heuristics for coaching explanations. They must not be surfaced as injury probabilities or hard "safe zone" claims.

## Muscle-group volume (fractional sets)

Two different "volumes" are tracked and must not be conflated:
- **Tonnage** = weight × reps (× limbs), in `sets.total_volume`.
- **Set-count volume per muscle** ("fractional sets"), for weekly volume landmarks.

The fractional-set convention (product decision, implemented in `ForgeCore.MuscleVolume`):
- A working set = **1.0 set** to each **primary** muscle, **0.5 set** to each **secondary** (supporting) muscle.
- **Warm-up sets count 0.**
- A muscle listed as both primary and secondary counts once, as primary (no double counting).
- Custom exercises roll up correctly because they carry primary/secondary muscles (and `mapped_global_id` to the global taxonomy).

This is computed from `sets` + `exercise_library.primary_muscles/secondary_muscles` by `ForgeCore.MuscleVolume` for weekly/monthly views — the same logic is unit-tested in `ForgeCore` so client previews and aggregates always agree (single source of truth, no server/client divergence possible).

## Security specifics

- **CloudKit private database** — all user data is isolated per iCloud account. No RLS needed; isolation is enforced by CloudKit's per-user database model. No service-role keys, no server-side secrets.
- **`integrations` tokens are sensitive.** OAuth tokens (e.g. Strava) should be stored securely in the keychain, never in SwiftData. Token refresh happens on-device.
- No Storage bucket — cardio telemetry lives as SwiftData models synced via CloudKit.

## Indexing rationale

- `workouts(user_id, started_at desc)` and the analogous cardio/health/load/readiness indexes serve the dominant query "my recent X."
- `uq_workouts_hk (user_id, hk_workout_uuid)` prevents two devices from creating two workouts for one HealthKit workout.
- Under SwiftData + CloudKit, indexes are managed by the framework; the SQL DDL serves as a reference for the intended query patterns.

## Open follow-ups (tracked as tickets, not blockers)

- `effective_load`/`total_volume`/`est_1rm` are computed on-device via `ForgeCore.VolumeMath` — single source of truth, no server/client divergence possible. `SetModel.recomputeDerivedMetrics()` fills these on save.
- Cardo telemetry (route points, splits) lives as SwiftData models (`CardioRoutePointModel`, `CardioSplitModel`) synced via CloudKit. Monitor CloudKit record size limits if telemetry grows large.
