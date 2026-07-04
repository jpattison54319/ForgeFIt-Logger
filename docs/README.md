# ForgeFit — Documentation Index

ForgeFit is a native iOS/watchOS **training operating system** for hybrid athletes — strength + cardio + recovery in one system, deeply integrated with HealthKit/watchOS, synced across the user's Apple devices via CloudKit. Target OS floor: **iOS 26 / watchOS 26**.

## Deliverables

| # | Doc | What's inside |
|---|---|---|
| A | [00-PRD.md](00-PRD.md) | Vision, target user, core problems, features, MVP vs phases, non-goals, success metrics |
| B | [01-architecture.md](01-architecture.md) | iOS/watchOS architecture, HealthKit plan, CloudKit sync, offline-first, error handling, privacy/security |
| C | [02-schema.sql](02-schema.sql) + [02-schema-notes.md](02-schema-notes.md) | Schema reference DDL (mirrored by SwiftData `@Model`s) + design rationale |
| D | [03-healthkit-feasibility.md](03-healthkit-feasibility.md) | Verified HealthKit/watchOS feasibility: types, permissions, possible/limited/verify, fallbacks |
| E | [04-watch-implementation.md](04-watch-implementation.md) | Watch-primary session lifecycle, mirroring, Input Lock, disconnect recovery, dup prevention, calories fix |
| F | [05-ux-flows.md](05-ux-flows.md) | Routine creation, fast set-entry spec, Watch-during-workout, summaries, readiness, progression |
| G | [06-roadmap-epics.md](06-roadmap-epics.md) | Milestones, testing strategy, sample tickets, risk register |
| H | [07-starter-implementation.md](07-starter-implementation.md) | Project structure, first Swift models, first migration, E0/E1 acceptance criteria |
| — | [EPICS.md](EPICS.md) | **Living tracker** — all epics E0–E17 with acceptance criteria |

## Three verified API findings driving the design
1. **RMSSD is feasible** via `HKHeartbeatSeriesQuery` but coverage is opportunistic → SDNN+RHR+sleep is the primary readiness path; RMSSD is enrichment.
2. **Watch mirroring is Watch-primary** (`startMirroringToCompanionDevice`) → the iPhone "Start" is a request, not the canonical start. Foundation for no-dup / non-zero-calorie workouts.
3. **Cardio power/gait metrics are real** (`runningPower`/`cyclingPower`/stride/oscillation) and safe on the iOS 26 floor.

## Build order
M0 Foundations (E0–E1) → M1 Fastest logger (E2–E4) → M2 Cloud+intelligence (E5,E6,E9) → M3 Watch reliable (E7–E8) → M4 Recovery (E10–E11) → M5 Cardio (E12–E13) → M6 Depth & coaching (E14–E15) → M7 Ownership & launch (E16–E17).

Start at [07-starter-implementation.md](07-starter-implementation.md) §4.
