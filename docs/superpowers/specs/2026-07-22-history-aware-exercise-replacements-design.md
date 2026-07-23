# History-Aware Exercise Replacements Design

**Date:** 2026-07-22

## Goal

Make the one-tap replacement list in live workouts and routine editing favor the exercises a lifter is actually using in their current training block, without allowing familiarity to turn a biomechanically inappropriate exercise into a valid substitute.

## Product principles

- Movement compatibility is an eligibility boundary. Personal history ranks valid substitutes; it does not validate an incompatible one.
- Recent and repeated use both matter because lifters commonly keep an exercise in rotation for several weeks.
- Old history fades instead of accumulating permanent influence.
- One completed workout occurrence counts as one use. Set count must not make a five-set exercise appear five times as familiar as a one-set exercise.
- The behavior remains local-first and deterministic. No schema change, network service, or learned model is required.
- Live-workout and routine-editor replacement use the same engine and explanations.

## Current limitations being addressed

The existing `ExerciseSwapSuggester` uses exact primary-muscle overlap, raw movement-pattern equality, equipment, mechanic, force, a bounded equipment preference, and a Boolean `trainedBefore` near-tie break. It does not distinguish one use from twenty, yesterday from last year, or completed cardio sessions from unused cardio rows. Much of the large seeded strength catalog also stores the same push/pull/static value in both `movementPattern` and `force`, allowing one concept to receive two bonuses.

## Architecture

The change has three focused units:

1. `ExerciseMovementFamily` in ForgeCore normalizes candidate metadata into `push`, `pull`, `legs`, `core`, `cardio`, or no confident family.
2. `ExerciseUsageProfile` in ForgeCore represents completed session dates and produces deterministic recency and frequency scores at a caller-supplied reference date.
3. `ExerciseSwapSuggester` keeps semantic scoring and explanations, applies the family boundary, then adds the bounded usage affinity.

`ExerciseSwapSheet` remains the adapter between SwiftData models and the pure engine. It builds one usage profile per exercise from the supplied workout history and turns match facets into concise row captions.

## Movement-family inference

Inference uses normalized, case-insensitive tokens. Underscores, hyphens, and repeated whitespace are treated equivalently.

Order matters:

1. Cardio patterns resolve to `cardio`.
2. A lower-body primary muscle resolves to `legs`, even when legacy force metadata says `push` or `pull`.
3. A precise stored pattern resolves directly:
   - Push: horizontal push, vertical push, push, press, elbow extension.
   - Pull: horizontal pull, vertical pull, pull, row, elbow flexion.
   - Legs: squat, hinge, lunge, knee extension/flexion, hip extension/flexion, calf raise.
   - Core: anti-extension, anti-rotation, rotation, trunk flexion/extension, carry.
4. When the pattern is missing or generic, unambiguous primary muscles provide the fallback:
   - Push: chest, triceps, front delts, side delts.
   - Pull: lats, upper/middle back, traps, rear delts, biceps, forearms.
   - Legs: quadriceps, hamstrings, glutes, calves, adductors, abductors.
   - Core: abdominals, obliques, transverse abdominis, spinal erectors.
5. Ambiguous or mixed metadata produces no family rather than guessing.

Muscle names use the app's existing taxonomy normalization and legacy aliases. If both target and candidate have confident families and the families differ, the candidate is excluded. If either family is unknown, the existing shared-primary-muscle requirement remains the conservative fallback.

An exact normalized movement-pattern match remains stronger than a broad family match. A `force` bonus is not applied when it duplicates the movement-pattern value on both sides.

## What counts as exercise usage

Only nondeleted workouts with `endedAt != nil` contribute.

- Strength: the workout-exercise must contain at least one set with `completedAt != nil`.
- Cardio: the workout-exercise must have an associated cardio session with `endedAt != nil`.
- Yoga remains outside the quick replacement pool in this iteration.
- The same exercise ID contributes at most once per workout, even if duplicate rows exist.
- The usage date is the completed workout's `endedAt`.
- The active, unfinished workout never contributes to its own recommendations.

The adapter produces `[UUID: ExerciseUsageProfile]`, where each profile carries unique completed-session dates. No usage aggregates are persisted; they are derived from the history already supplied to the sheet.

## Personal relevance scoring

All calculations use whole-day age clamped to zero so clock skew or a future timestamp cannot produce a supernormal bonus.

Recency:

```text
recency = 1.2 * 2^(-daysSinceLastUse / 28)
```

Frequency first computes a recency-weighted use total with a slower 56-day half-life:

```text
weightedUses = sum(2^(-daysSinceUse / 56))
frequency = 1.4 * (1 - exp(-weightedUses / 3))
```

The combined personal affinity is therefore bounded below 2.6 points. Repeated current-block use can overcome small equipment or metadata differences and can overtake a never-used close alternative. It cannot bypass primary-muscle overlap, modality filtering, in-use exclusion, or a known movement-family mismatch.

The existing semantic score retains these signals:

- Primary-muscle overlap.
- Target primary muscles appearing as candidate secondary muscles.
- Exact movement pattern and complete primary match.
- Same broad movement family.
- Mechanic.
- Nonduplicated force.
- Same equipment or a machine-to-free-weight alternative.
- The explicit equipment preference chip.

The old Boolean history-band reorder is removed once personal affinity is active. Final ties remain alphabetical for deterministic output. Empty history preserves the current semantic ordering.

## User interface

The quick sheet continues to show at most six one-tap replacements before `Search all exercises`.

History explanations become specific:

- `5 sessions in 90d`
- `Last used 6d ago`
- `Last used today`

The row keeps biomechanical reasons first, followed by at most one compact usage phrase so the existing two-line caption does not become a history report. VoiceOver receives the same meaningful explanation. Raw scores and formulas are not shown.

The existing consequence copy is replaced with: `Set structure stays for similar exercises. Unfinished values and exercise-specific targets reset; completed sets remain logged.` This describes both callers honestly and remains consequence copy, not interaction instructions.

The broad search fallback is not converted into a second recommender in this scope. It will, however, receive replacement context so it can use the `Replace Exercise` title, preselect the current modality while allowing the user to clear it, and exclude the current and already-in-use exercise IDs. Selecting a row remains the visible one-tap action.

## Data flow

1. Live workout or routine editor opens `ExerciseSwapSheet` with the current exercise, library, in-use IDs, and history.
2. The sheet derives deduplicated completed-session dates by exercise ID.
3. The sheet maps library rows into lightweight candidates and calls the pure suggester with a single reference date.
4. ForgeCore filters invalid candidates, computes semantic and personal relevance, and returns the top six with explanation facets.
5. Selecting a row follows the existing caller-specific replacement behavior.

## Edge cases and failure behavior

- No target primary muscles: no quick suggestions; broad search remains available.
- Unknown movement family: fall back to primary-muscle compatibility instead of emptying the list.
- No history: current metadata-only behavior remains deterministic.
- Very old history: its influence approaches zero but the date remains available for diagnostics.
- Imported or duplicate history: one exercise use per completed workout.
- Deleted workouts, unfinished workouts, and uncompleted strength rows: ignored.
- Cardio without an ended cardio session: ignored.
- Missing exercise library row: existing direct-picker fallback remains available.

## Testing

ForgeCore tests use a fixed reference date and prove:

- A recently and frequently used compatible exercise outranks a close never-used alternative.
- A single recent use and repeated recent uses receive distinct scores.
- Old frequency decays and does not permanently dominate.
- A wrong known movement family is excluded despite heavy usage.
- Unknown-family candidates can still qualify through shared primary muscles.
- Lower-body muscles override legacy `push` force metadata.
- Duplicated movement-pattern/force metadata receives one conceptual bonus.
- Empty history preserves metadata ordering.
- Equipment preferences still rerank compatible candidates without becoming filters.

App-target tests prove:

- Multiple completed sets in one workout count as one use.
- Duplicate exercise rows in one workout count once.
- Unfinished/deleted workouts do not count.
- A completed cardio session counts even though it has no strength sets.
- Live and routine callers produce the same usage profiles from the same history.
- Replacement search excludes current/in-use IDs and presents replacement-specific copy.

## Out of scope

- Injury, pain, readiness, or fatigue inference.
- Cloud-synced recommendation aggregates.
- Machine learning or server-side personalization.
- Routine-position, rep-range, or adjacent-exercise modeling.
- Yoga-pose replacement recommendations.
