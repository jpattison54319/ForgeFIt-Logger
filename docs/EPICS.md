# ForgeFit — Epic Tracker (living)

> The single source of truth for "are we done?". Every epic E0–E17 is listed with scope and **acceptance criteria**. Update the status as work lands. When all are 🟢, the epics sum to the finished, polished app.
> Status legend: ⚪ Not Started (default) · 🟡 In Progress · 🟢 Completed.
> Per-epic story cards live in [epics/](epics/README.md) (visual board).
> Phases: **MVP** = E0–E9 · **MVP+** = E10–E13 · **ADV** = E14–E17.
> _Status sync 2026-07-09: E7, E8, E10, E11, E13, E14 moved ⚪→🟡 per the code audit in [user-value-action-plan.md](user-value-action-plan.md) — substantial implementation exists in the working tree (readiness pipeline, watch live sessions, cardio analytics, telemetry/routes); acceptance criteria are not yet fully verified, so none move to 🟢._

| Epic | Title | Phase | Status |
|---|---|---|---|
| E0 | Project Foundation & Tooling | MVP | 🟡 |
| E1 | Data Model & Schema | MVP | 🟡 |
| E2 | Exercise Library & Taxonomy | MVP | 🟢 |
| E3 | Strength Logging UX (flagship) | MVP | 🟡 |
| E4 | Routine Builder | MVP | 🟡 |
| E5 | CloudKit Sync | MVP | 🟡 |
| E6 | HealthKit Write & Workout History | MVP | 🟡 |
| E7 | Apple Watch Companion Logging | MVP | 🟡 |
| E8 | Watch ⇄ iPhone Mirroring & Reliability | MVP | 🟡 |
| E9 | Progression Engine v1 | MVP | 🟡 |
| E10 | HealthKit Biometric Ingestion | MVP+ | 🟡 |
| E11 | Readiness / Recovery | MVP+ | 🟡 |
| E12 | Cardio Modality Logging | MVP+ | 🟡 |
| E13 | Cardio Analytics & Training Load | MVP+ | 🟡 |
| E14 | High-Res Telemetry | ADV | 🟡 |
| E15 | Mesocycle Planning & Auto-Regulation | ADV | ⚪ |
| E16 | Integrations & Data Ownership | ADV | ⚪ |
| E17 | Polish, Accessibility, Privacy & Launch | ADV | ⚪ |

---

## E0 — Project Foundation & Tooling 🟡  → [board](epics/E0-foundation/EPIC.md)
Scope: Xcode workspace (iOS + watchOS + shared packages), SwiftData container, CloudKit sync, design tokens, app shell, CI.
- [x] Repo + `.gitignore` + `Packages/` layout; `ForgeCore`, `ForgeData`, `ForgeHealth`, `ForgeWorkoutSession`, `ForgeUI` packages build (`make test`)
- [x] Both apps launch to a shell *(Xcode iOS/watch targets build locally — FF-002)*
- [ ] `swift build` + unit tests pass in CI *(local package gate ✅; CI not wired — FF-004)*
- [x] CloudKit sync configured (`cloudKitDatabase: .automatic` + entitlements — FF-003)

## E1 — Data Model & Schema 🟡  → [board](epics/E1-data-model/EPIC.md)
Scope: `ForgeCore` domain + math, `ForgeData` SwiftData models, schema reference DDL.
- [x] Volume/e1RM golden-vector tests pass (AC-3…AC-6) — **13 tests green**
- [x] Fractional-set muscle volume: **primary 1.0 / secondary 0.5 / warm-up 0** + weekly aggregation
- [x] Workout with unilateral + drop + weighted-bodyweight sets persists locally & round-trips (AC-7 — FF-012)
- [ ] CloudKit sync: workout created on one device appears on another (AC-8 — manual two-device check)
- [x] All math computed on-device via `ForgeCore` (single source of truth — AC-9)

## E2 — Exercise Library & Taxonomy 🟢  → [board](epics/E2-exercise-library/EPIC.md)
Scope: seed global library (incl. Bayesian cable curl, overhead cable triceps ext, chest-supported T-bar row, Smith/machine variants), aliases, custom→global mapping, auto-surfacing notes.
- [x] Search finds exercise by alias (typo-tolerant) in `ForgeCore`
- [x] Custom exercise maps to a movement pattern & rolls up in analytics in `ForgeCore`
- [x] Global exercise + alias seed persists idempotently into SwiftData
- [x] Per-exercise notes auto-display on load *(routine + workout surfaces with UI test — FF-022)*

## E3 — Strength Logging UX (flagship) 🟡  → [board](epics/E3-strength-logging/EPIC.md)
Scope: routine runner + fast set entry (`@FocusState` weight→reps→RPE→complete), prev-value ghosts, all advanced set types, unilateral entry, offline-first.
- [x] Seeded routine can be started, logged with a working set, completed, and shown in recent workouts locally
- [x] Routine target sets load into the runner as pending sets and only count toward volume after completion
- [x] Logged workout sets can be edited or deleted, with volume recomputed after changes
- [x] Completed strength workouts render in local History list/detail
- [ ] Median set logged < Hevy in documented timed comparison (≥25% faster), ≤3 taps
- [ ] Works fully in airplane mode
- [ ] Every advanced set type enterable; unilateral never requires doubling

## E4 — Routine Builder 🟡  → [board](epics/E4-routine-builder/EPIC.md)
Scope: create/edit/reorder routines, targets + progression rule per exercise, supersets, duplicate/templating.
- [x] Create/edit routines locally with persisted exercises and target sets
- [x] A built routine drives the runner with prefilled target sets
- [x] Saved routines can be duplicated with exercises, notes, and target sets copied
- [x] Routine, exercise, and target-set reorder controls persist positions locally
- [ ] Supersets group/run correctly

## E5 — CloudKit Sync ⬜
Scope: SwiftData CloudKit sync (`cloudKitDatabase: .automatic`), private database, automatic push/pull, graceful degradation when offline.
- [x] CloudKit sync configured (ModelContainer + entitlements)
- [ ] Two devices with same iCloud account: workout created on one appears on the other
- [ ] Offline creates sync automatically when connectivity returns
- [ ] Deletes propagate (no resurrection via tombstones)

## E6 — HealthKit Write & Workout History 🟡  → [board](epics/E6-healthkit-history/EPIC.md)
Scope: write completed strength workouts (correct activity type/energy/duration), history list/detail, basic Swift Charts.
- [ ] Finished workout appears in Apple Health with **non-zero calories** & correct activity type
- [x] Local History list/detail renders completed strength and cardio workouts
- [ ] Basic volume/frequency charts render

## E7 — Apple Watch Companion Logging 🟡 *(live mirror sessions shipped; standalone logging + Input Lock outstanding)*
Scope: native watchOS logging with HKWorkoutSession/LiveWorkoutBuilder/DataSource, glanceable UI, Input Lock, wrist-down collection.
- [ ] Watch-only session records non-zero calories/HR; survives wrist-down
- [ ] Accidental Crown turns don't corrupt weight/reps/rest/complete
- [ ] Sets persist to watch cache instantly

## E8 — Watch ⇄ iPhone Mirroring & Reliability 🟡  *(phone-authoritative WC mirroring shipped w/ session recovery; dup/disconnect test matrix outstanding)*
Scope: Watch-primary mirroring, iPhone start-request via WC, bidirectional set deltas, dup prevention, disconnect/crash recovery.
- [ ] Every start permutation yields **exactly one** workout
- [ ] Set logged on either device appears on the other; no dup
- [ ] Forced BT drop mid-session recovers with no data loss
- [ ] Full [Watch test matrix](04-watch-implementation.md#9-test-matrix) green on devices

## E9 — Progression Engine v1 🟡 *(v1 shipped 2026-07-10: double progression/fixed/percent, explained suggestions, accept/edit/reject persisted; RPE rules + on-device verification outstanding)*
Scope: progression_rules (%/fixed/rep-target/rpe), recommendations + rationale, e1RM trend, computed on-device via `ForgeCore`.
- [x] Exceeding a rep target produces an **explained** weight-increase suggestion
- [x] Suggestion prefills the next session; accept/reject tracked *(ProgressionSuggestionModel; needs on-device verification)*
- [x] e1RM trend chart renders *(ExerciseDetailView, pre-existing)*

## E10 — HealthKit Biometric Ingestion 🟡 *(HRV/RHR/sleep/resp/SpO₂/VO₂max ingestion + nocturnal aggregation shipped; background delivery + sleep stages outstanding)*
Scope: read HRV(SDNN), RHR, sleep(+stages), respiratory rate, wrist temp, SpO₂, body mass, VO₂max; background delivery; persisted anchors.
- [ ] Nightly metrics ingest automatically into `health_metrics`/`body_metrics`
- [ ] Denied/partial authorization handled gracefully (no crash, clear reprompt)

## E11 — Readiness / Recovery 🟡  *(ln-space baselines, daily+systemic scores, honest building states, coach-adjusted starts shipped; formula docs + verification outstanding)*
Scope: 0–100 readiness vs rolling 30–60d baseline; RMSSD enrichment when heartbeat series exists, SDNN+RHR+sleep fallback; explained maintain/push/reduce/deload.
- [ ] Readiness computes daily with a documented formula
- [ ] Degrades gracefully without RMSSD (`used_rmssd=false`), UI honest about it
- [ ] Recommendation has a plain-language explanation and feeds training

## E12 — Cardio Modality Logging 🟡  → [board](epics/E12-cardio-logging/EPIC.md)
Scope: modality-correct metrics (stairmaster/row/cycle/run/elliptical/walk/hike/HIIT) on iPhone + Watch with correct HKWorkoutConfiguration; HR-zone capture.
- [x] Run/ride/row quick-starts create local cardio workouts and save duration/distance/effort notes
- [x] Local SwiftData cardio sessions persist structured duration, distance, energy, HR, cadence/stroke, power, and effort fields
- [x] Cardio exercises are tagged as cardio with cardiovascular muscles and modality-specific metric labels
- [x] Cardio routine entries start linked cardio sessions instead of strength sets/set types
- [ ] Each modality records its correct metric set
- [ ] Writes a valid HealthKit workout with non-zero energy

## E13 — Cardio Analytics & Training Load 🟡 *(zone distribution, 80/20 framing, EF, critical-pace shipped; measured time-in-zone fix + CTL/ATL curve outstanding)*
Scope: time-in-zone + distribution (workout/week/month), polarized 80/20, TSS-like, CTL/ATL/TSB computed on-device, Swift Charts.
- [ ] A week of cardio yields zone totals + 80/20 readout
- [ ] CTL/ATL/form trend chart renders from `training_load_daily`

## E14 — High-Res Telemetry 🟡 *(GPS routes, per-10s HR series, maps + telemetry charts shipped; zone-seconds from series + GPX in/out outstanding)*
Scope: quantity-series + route queries, cardio telemetry as SwiftData models (`CardioRoutePointModel`, `CardioSplitModel`), route maps + telemetry charts.
- [ ] A run stores route + per-second HR/power data linked to its session
- [ ] Map + telemetry chart render; telemetry synced via CloudKit

## E15 — Mesocycle Planning & Auto-Regulation ⬜
Scope: accumulation/intensification/realization/deload/strength/hypertrophy blocks; readiness-driven auto-regulation; deload/fatigue detection.
- [ ] A mesocycle plan adjusts targets based on readiness
- [ ] Deload flagged with rationale; suggestions reduce load/volume in-block

## E16 — Integrations & Data Ownership ⬜
Scope: harden Apple Health first; Strava OAuth 2.0 export; FIT/TCX export + granular per-field controls (continuous HR, no branded payloads); full export + deletion.
- [ ] Export a workout to Strava and to FIT/TCX with chosen fields
- [ ] User can export **and** delete all their data (SwiftData rows + CloudKit records)
- [ ] OAuth tokens stored in keychain, never in SwiftData

## E17 — Polish, Accessibility, Privacy & Launch ⬜
Scope: Dynamic Type/VoiceOver/contrast/touch targets, performance, onboarding, privacy audit, App Store readiness; web/iPad dashboard & social as post-reliability stretch.
- [ ] Accessibility audit passes (WCAG-aligned, touch targets, Dynamic Type, VoiceOver)
- [ ] Privacy review signs off; data export/delete verified
- [ ] App is submission-ready (crash-free ≥99.8%, perf budget met)

---

### Completion rule
All boxes checked + CI green + no open Sev-1/2 reliability bugs ⇒ epic ✅. All 18 epics ✅ ⇒ finished, polished ForgeFit.
