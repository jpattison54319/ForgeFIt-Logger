# ForgeFit — Epic Board

Visual status board for every epic. Each epic has its own folder with an `EPIC.md`
(overview + acceptance criteria) and **story cards** (`FF-xxx.md`) for the work items.

## Status legend
| Badge | Meaning |
|---|---|
| ⚪ | **Not Started** (default) |
| 🟡 | **In Progress** |
| 🟢 | **Completed** (all acceptance criteria met + tests green) |

> Rule: an epic only goes 🟢 when every acceptance criterion in its `EPIC.md` is checked,
> its tests are green, and no Sev-1/2 reliability bug is open. Until then it is 🟡 or ⚪.

## Board

| Epic | Title | Phase | Status | Folder |
|---|---|---|---|---|
| E0 | Project Foundation & Tooling | MVP | 🟡 | [E0-foundation](E0-foundation/EPIC.md) |
| E1 | Data Model & Schema | MVP | 🟡 | [E1-data-model](E1-data-model/EPIC.md) |
| E2 | Exercise Library & Taxonomy | MVP | 🟢 | [E2-exercise-library](E2-exercise-library/EPIC.md) |
| E3 | Strength Logging UX (flagship) | MVP | 🟡 | [E3-strength-logging](E3-strength-logging/EPIC.md) |
| E4 | Routine Builder | MVP | 🟡 | [E4-routine-builder](E4-routine-builder/EPIC.md) |
| E5 | Auth, Sync & Offline-First Engine | MVP | ⚪ | _pending_ |
| E6 | HealthKit Write & Workout History | MVP | 🟡 | [E6-healthkit-history](E6-healthkit-history/EPIC.md) |
| E7 | Apple Watch Companion Logging | MVP | 🟡 | _pending_ |
| E8 | Watch ⇄ iPhone Mirroring & Reliability | MVP | 🟡 | _pending_ |
| E9 | Progression Engine v1 | MVP | ⚪ | _pending_ |
| E10 | HealthKit Biometric Ingestion | MVP+ | 🟡 | _pending_ |
| E11 | Readiness / Recovery | MVP+ | 🟡 | _pending_ |
| E12 | Cardio Modality Logging | MVP+ | 🟡 | [E12-cardio-logging](E12-cardio-logging/EPIC.md) |
| E13 | Cardio Analytics & Training Load | MVP+ | 🟡 | _pending_ |
| E14 | High-Res Telemetry | ADV | 🟡 | _pending_ |
| E15 | Mesocycle Planning & Auto-Regulation | ADV | ⚪ | _pending_ |
| E16 | Integrations & Data Ownership | ADV | ⚪ | _pending_ |
| E17 | Polish, Accessibility, Privacy & Launch | ADV | ⚪ | _pending_ |

**Progress:** 1 / 18 epics 🟢 · 12 🟡 · 5 ⚪

> _Status sync 2026-07-09 per the code audit in [../user-value-action-plan.md](../user-value-action-plan.md): E7, E8, E10, E11, E13, E14 moved ⚪→🟡 — substantial implementation exists in the working tree; acceptance criteria not yet fully verified._

> Epic folders are created when work on that epic begins. The high-level acceptance
> criteria for not-yet-started epics live in [../EPICS.md](../EPICS.md).

## Story card status
Story cards use the same badges in their header. A card also carries:
`Epic`, `Owner`, `Status`, and a short **Acceptance** list.
