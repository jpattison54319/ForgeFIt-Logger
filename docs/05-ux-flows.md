# F — UX Flows

> Design principles: fast, low-friction, native-feeling, reliable, accessible, minimal taps during active training, excellent on Watch, privacy-first. The flagship requirement: **logging faster than Hevy.**

---

## 1. Routine creation

1. **Routines tab → "New routine"** → name + optional folder.
2. **Add exercises** via search (typo-tolerant, alias-aware: "RDL" → Romanian Deadlift; "Bayesian curl" found). Recent/most-used surface first.
3. For each exercise: set **planned sets** with `set_type`, **target rep range** (e.g. 8–10), optional target weight/RPE, and a **progression rule** (default inherited, overridable).
4. **Supersets:** select 2+ exercises → "Group" → shared `superset_group`.
5. **Reorder** by drag; **duplicate** a routine as a template.
6. Save → routine drives the runner with prefilled targets.

*Low-friction touches:* defaults pre-filled from the exercise's last use; one tap to clone last week's session into a new routine.

---

## 2. Start workout

- **From a routine:** Routines → tap routine → **"Start".** Creates a `workouts` row with a **client UUID** (the dedup key).
- **Empty/freestyle:** Home → "Start empty workout" → add exercises on the fly.
- **From iPhone with Watch:** "Start" sends a WatchConnectivity request; the **Watch** launches/prepares the `HKWorkoutSession` and mirrors back ([04](04-watch-implementation.md)). UI shows "Connected to Watch · recording."
- **From Watch directly:** start on Watch; iPhone receives the mirror when in range.
- Per-exercise **notes auto-surface** on load (seat height, grip, pain flag) from `user_exercise_notes`.

---

## 3. Log a strength set — the fast-entry spec (flagship)

**Goal:** ≤ 3 taps and ≤ 2.5s median per working set; faster than Hevy.

Layout per active set row: `[ Weight ] [ Reps ] [ RPE/RIR ] [✓]`, with the **previous session's values shown as ghost placeholders** ("prev: 60×10 @8").

**Auto field progression (the core interaction):**
1. Tap **Weight** → numeric keypad. Field is pre-filled with the suggested/last weight; user edits only if needed.
2. **"Next"** (keyboard) → focus jumps to **Reps** via `@FocusState`. (No reaching for another field.)
3. **"Next"** → focus jumps to **RPE/RIR** (optional; skippable).
4. **"Next" / "Done"** → **completes the set** (writes to SwiftData instantly, marks ✓, starts the rest timer) and **advances focus to the next set's Weight**.

So a full set can be: type weight → Next → type reps → Done. Often **just reps** (weight carried over) → Done.

**Affordances:**
- **One-tap "repeat previous"**: a ✓ with no edits logs the same as last time.
- **Plate math / quick steppers** for weight (±2.5/±5) without opening the keypad.
- **Rest timer** auto-starts on completion; glanceable countdown; configurable per exercise.
- **Advanced set types** chosen via a compact segmented control on the row (warmup/drop/rest-pause/…); drop sets reveal an inline "+ drop" to chain sub-loads; partials/holds/eccentric/paused are toggles.
- **Unilateral:** when `is_unilateral`, the field label reads **"per dumbbell"** and the row footer shows computed total volume — the user never doubles anything.
- **Bodyweight:** weighted/assisted toggles reveal `added_weight`/`assistance_weight`; bodyweight snapshot pulled automatically.
- **Offline-first:** every completion is a local SwiftData write; a sync indicator is informational only and never blocks input.

**Accessibility:** large targets, Dynamic Type, VoiceOver labels per field, haptic confirmation on set completion.

---

## 4. Using Apple Watch during the workout

- **Glanceable set card:** current exercise, target, set N of M, big ✓.
- **Input Lock on by default during sets:** Crown spam / wrist flexion can't corrupt weight/reps/rest/complete. To edit: **arm the field (deliberate gesture) → Crown adjusts → confirm tap.** Auto-relocks.
- Complete a set on Watch → haptic + rest timer; the set mirrors to iPhone (no dup).
- Live HR/energy shown from the builder; **keeps collecting wrist-down.**
- Reconnect after a drop is invisible to the user; queued sets reconcile.

---

## 5. Finish workout

1. Tap **Finish** (iPhone or Watch).
2. Watch: `endCollection` → `finishWorkout()` → real `HKWorkout` (non-zero energy) saved to HealthKit; `hk_workout_uuid` linked.
3. Canonical `workouts` row finalized **once** (shared UUID); `total_volume`/PRs computed on-device via `ForgeCore`.
4. Optional quick notes / session RPE.
5. Transition straight into the **post-workout summary.**

---

## 6. Post-workout summary (strength)

- **Headline:** duration, total volume, sets, est. energy.
- **PRs detected** (e1RM, rep, volume) with celebratory but non-intrusive callouts.
- **Per-exercise breakdown:** volume, top set, e1RM, vs last time (▲/▼).
- **Volume by muscle group** (from taxonomy) — even custom exercises roll up via `mapped_global_id`.
- **Next-time suggestions** appear here (see §9) so progression feels continuous.
- **Readiness impact:** how this session adds to today's load (links to load/readiness).

---

## 7. Recovery / readiness screen (morning home)

- **One trusted number: Readiness 0–100**, color-banded, with a one-line verdict ("Recovered — good to push").
- **Components shown honestly:** HRV (and whether **RMSSD** or **SDNN-fallback** was used), RHR vs baseline, sleep vs baseline — each as a small delta-from-baseline chart (Swift Charts).
- **Recommendation card:** maintain / push / reduce volume / deload, **with a plain-language explanation** ("HRV 18% below your 30-day baseline and sleep short → reduce volume today").
- **Trend:** 14/30/60-day readiness + HRV/RHR trend.
- **Graceful absence:** if overnight data is missing, the screen says so and offers a manual check-in rather than faking a score.

---

## 8. Cardio workout summary

- **Modality-correct headline:** e.g. rowing → distance, avg split/500m, stroke rate, avg power; running → pace, distance, running power, cadence; stairmaster → floors, steps, steps/min.
- **HR-zone distribution** bar (z1–z5) + time in each; session **polarized read** (where it sits vs 80/20).
- **Telemetry charts** (ADV): power/pace/HR over time; **route map** for outdoor runs/rides.
- **"What this improved"**: a short, honest classification (aerobic base / threshold / VO₂max / recovery) derived from zone distribution + duration + intensity.
- **Load contribution:** session TSS and its effect on CTL/ATL/form.

---

## 9. Progression recommendation flow

1. After a session (and overnight readiness recompute), `ForgeCore` computes next-session targets per exercise on-device.
2. **Where it appears:** in the post-workout summary *and* prefilled when the user next starts that routine.
3. **Each suggestion is explained:** "Last time you hit **12** reps vs target **8–10** at RPE 8 → **+2.5%** (62.5 kg) next time."
4. **Auto-regulation:** if today's readiness is low, suggestions are tempered ("readiness low → hold weight, drop one set") — also explained.
5. **User control:** accept (prefills), reject (keeps current; logged for accuracy metrics), or edit. Rules are user-configurable (%-step, fixed jump, rep/RPE target).
6. **Mesocycle awareness (ADV):** within a deload block, suggestions reduce load/volume automatically and say why.

---

## Cross-cutting UX rules
- **Never block on network.** CloudKit sync and HealthKit writes are background; input is always instant.
- **Explain every recommendation.** No black-box numbers.
- **Honest about data quality.** Show when a metric used a fallback or is estimated.
- **Privacy visible.** Clear, staged permission prompts; a single screen to export or delete all data.
