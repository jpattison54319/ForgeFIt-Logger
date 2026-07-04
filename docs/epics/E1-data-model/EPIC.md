# E1 — Data Model & Schema 🟡

**Phase:** MVP · **Status:** 🟡 In Progress

`ForgeCore` domain models + deterministic math, `ForgeData` SwiftData models, and the
schema reference DDL. The hardest-to-get-right, highest-value foundation.

## Acceptance criteria
- [x] `ForgeCore` domain models (`SetEntry`, `ExerciseInfo`, set/weight enums)
- [x] Volume/e1RM/unilateral/bodyweight math with golden-vector tests (AC-3…AC-6) — **13 ForgeCore tests green**
- [x] Fractional-set muscle volume: **primary 1.0 / secondary 0.5 / warm-up 0**, with weekly aggregation
- [x] `ForgeData` SwiftData `@Model`s mirroring the schema; workout round-trips locally (AC-7)
- [ ] CloudKit sync: workout created on one device appears on another (AC-8 — FF-013, manual two-device check)
- [x] All math computed on-device via `ForgeCore` (single source of truth — AC-9, no server math to diverge)

## Stories
| Card | Title | Status |
|---|---|---|
| [FF-010](FF-010.md) | ForgeCore models + math | 🟢 |
| [FF-011](FF-011.md) | Golden-vector tests (volume, e1RM, muscle) | 🟢 |
| [FF-012](FF-012.md) | ForgeData SwiftData models + round-trip | 🟢 |
| [FF-013](FF-013.md) | CloudKit sync two-device check | ⚪ |

## Verified math (this epic)
- Unilateral 30 kg DB × 10 × 2 arms = **600** from one 30 kg entry.
- Weighted pullup (BW 80 + 20) × 5 = **500**; assisted dip (BW 80 − 30) × 8 = **400**.
- Partials half-weighted; warm-ups excluded; Epley e1RM(100×5) ≈ **116.67**.
- Weekly muscle volume across 3 working bench/incline sets: chest **3.0**, triceps **1.5**, front_delts **1.5**.
- AC-7 SwiftData round-trip: unilateral working set, drop set, and weighted-bodyweight set reload with computed volume/e1RM intact.
