# E2 — Exercise Library & Taxonomy 🟢

**Phase:** MVP · **Status:** 🟢 Completed

Seeded global exercise library, aliases, typo-tolerant search, custom→global mapping,
and per-exercise setup notes that can be surfaced whenever an exercise loads.

## Acceptance criteria
- [x] Core seed includes requested cable/machine/Smith variants and aliases
- [x] Search finds exercises by alias and tolerates common typos
- [x] Custom exercise maps to a global movement pattern and rolls up in muscle analytics
- [x] Per-exercise setup-note lookup returns the cue needed on exercise load
- [x] Local persistence/repository layer seeds global exercises and aliases into SwiftData
- [x] Routine builder/logger UI auto-surfaces setup notes on load

## Stories
| Card | Title | Status |
|---|---|---|
| [FF-020](FF-020.md) | Core taxonomy seed + alias search | 🟢 |
| [FF-021](FF-021.md) | SwiftData seed repository | 🟢 |
| [FF-022](FF-022.md) | Notes surface in routine/logger UI | 🟢 |

## Verified
- `ExerciseLibraryTests` cover `RDL` alias search, typo search for `bayseian curl`,
  required seed variants, custom→global analytics resolution, and setup-note lookup.
- `ExerciseSeedRepositoryTests` prove the seed is idempotent and can rebuild a searchable
  snapshot from SwiftData.
- `ForgeFitUITests/testExerciseSetupNoteAppearsInLoggerAndRoutineBuilder` proves the
  workout logger and routine builder show a saved setup note.
