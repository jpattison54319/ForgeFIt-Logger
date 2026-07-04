# G — Development Roadmap

> Reliability-first sequencing. Epics E0–E17 sum to the finished, polished app.
> Phase rollups: **MVP** = E0–E9 · **MVP+** = E10–E13 · **ADV** = E14–E17.
> The live checklist is [EPICS.md](EPICS.md); this file adds milestones, testing strategy, sample tickets, and risks.

---

## 1. Milestones

| Milestone | Epics | Outcome |
|---|---|---|
| **M0 — Foundations** | E0, E1 | Workspace builds; SwiftData models + CloudKit sync; a workout round-trips locally with correct unilateral/advanced-set math. |
| **M1 — Fastest logger** | E2, E3, E4 | Exercise library + routine builder + the flagship fast set-entry, offline-first. Timed beat-Hevy demo. |
| **M2 — Cloud + intelligence v1** | E5, E6, E9 | CloudKit sync (no dup/loss), HealthKit write (non-zero calories), progression suggestions with explanations. |
| **M3 — Watch reliable** | E7, E8 | Native Watch logging + Watch-primary mirroring; the full test matrix in [04](04-watch-implementation.md) green. **Risk spike gate.** |
| **M4 — Recovery** | E10, E11 | Biometric ingestion + readiness v1 (RMSSD enrichment + fallback), recommendations feed training. |
| **M5 — Cardio** | E12, E13 | Modality-correct cardio + zones + training load (CTL/ATL). |
| **M6 — Depth & coaching** | E14, E15 | Telemetry + route maps; mesocycle planning + auto-regulation. |
| **M7 — Ownership & launch** | E16, E17 | Strava/FIT/TCX export, data export/delete; a11y + privacy review + App Store. |

---

## 2. Testing strategy

- **`ForgeCore` unit tests (highest value):** golden-vector tests for unilateral volume, bodyweight modes, e1RM, TSS, CTL/ATL, readiness. `ForgeCore` is the single source of truth for all math — no server/client divergence possible.
- **Persistence tests:** SwiftData round-trips for workouts with every set type; migration tests.
- **CloudKit sync tests:** two-device manual check — create a workout on one device, confirm it appears on the other (requires same iCloud account). CloudKit sync itself cannot be unit-tested without an iCloud account.
- **HealthKit tests:** on-device/simulator coverage where possible; explicit handling of denied/partial auth; the §6 "calories" assertion (non-zero energy on a finished workout).
- **Watch tests:** the [04 test matrix](04-watch-implementation.md#9-test-matrix) run on real devices — the only reliable way to validate mirroring/disconnect.
- **UI/interaction tests:** XCUITest for the set-entry focus chain; a scripted **timed comparison vs Hevy** captured as a metric.
- **CI:** build both targets + run `ForgeCore`/data suites on every PR; device-lab Watch tests pre-release.

**Risk spikes happen BEFORE feature work in their epic:** E8 (mirroring/disconnect) and E11 (RMSSD quality) get a spike + test plan first.

---

## 3. Sample tickets (representative, not exhaustive)

**E0 — Foundation**
- FF-001 Create Xcode workspace + iOS/watchOS targets + `ForgeCore/Data/Health/WorkoutSession/Network/UI` packages.
- FF-002 Add SwiftData `ModelContainer`; app shell navigation; design tokens in `ForgeUI`.
- FF-003 Enable iCloud + CloudKit capability; configure `cloudKitDatabase: .automatic` on the ModelContainer.
- FF-004 CI: build both targets + run unit tests.

**E1 — Data model**
- FF-010 Define `ForgeCore` domain models + `ForgeData` `@Model`s mirroring the schema.
- FF-011 Implement volume/e1RM/unilateral resolution in `ForgeCore` + golden-vector tests.
- FF-012 SwiftData round-trip test: workout with unilateral + drop + weighted-bodyweight sets persists correctly.

**E3 — Fast logging**
- FF-030 Set-entry row with `@FocusState` weight→reps→RPE→complete chain.
- FF-031 Prev-value ghosts + repeat-previous one-tap.
- FF-032 Advanced set-type control (drop/rest-pause/partials/holds/eccentric/paused).
- FF-033 Unilateral "per dumbbell" entry + live total-volume footer.
- FF-034 XCUITest + timed beat-Hevy benchmark harness.

**E8 — Watch mirroring**
- FF-080 `WorkoutSessionController` in `ForgeWorkoutSession`: prepare→mirror→collect→finish.
- FF-081 WC control-plane: iPhone start-request → Watch launch/prepare.
- FF-082 Bidirectional set deltas keyed by UUID; idempotent upsert.
- FF-083 Disconnect/reconnect reconciliation + crash re-attach.
- FF-084 Run full Watch test matrix on devices; fix to green.

**E11 — Readiness**
- FF-110 Readiness computation in `ForgeCore`: baseline + components + action + explanation.
- FF-111 Heartbeat-series RMSSD computation + quality gating (`used_rmssd`).
- FF-112 SDNN+RHR+sleep fallback path; honest UI labeling.

*(Each remaining epic gets a comparable ticket cluster during M-planning; tracked in EPICS.md.)*

---

## 4. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Watch mirroring edge cases (dup/loss/zero-cal) | High | High | E8 spike first; shared-UUID + full device test matrix is a gate. |
| RMSSD coverage too sparse | High | Med | Fallback is the *primary* path; RMSSD is enrichment only; quality-gated; UI honest. |
| HealthKit metric absence (SpO₂/temp/VO₂max/power) | High | Med | Every consumer tolerates absence; documented fallbacks ([03](03-healthkit-feasibility.md) §7). |
| CloudKit sync issues | Low | Med | Automatic sync; degrades to local-only gracefully; no manual sync code to break. |
| CloudKit record size limits | Low | Med | Cardio telemetry as SwiftData models; monitor if telemetry grows large. |
| Battery drain on Watch | Med | Med | Batch WC; throttle UI; correct `locationType`; release session promptly. |
| Scope creep delaying reliability | Med | High | Phase gates; social/web explicitly post-E16. |

---

## 5. Definition of done (per epic)
Every epic is "done" only when: its acceptance criteria in [EPICS.md](EPICS.md) pass, relevant tests are green in CI, no Sev-1/2 reliability bugs are open, and (for Watch/Health epics) the device test matrix is green. EPICS.md is updated on completion so the epics provably sum to the finished product.
