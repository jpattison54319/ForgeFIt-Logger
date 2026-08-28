# ForgeFit App Intents Phased Plan

Last reconciled: August 27, 2026

This roadmap uses modern App Intents throughout. Siri speech recognition supplies text and ForgeFit resolves that text against stable, local workout entities. Health data, workout history, notes, and authored targets stay out of App Group snapshots, intent donations, and logs.

## Phase 1 — Starting and Finding Workouts (ForgeFit 1.3)

Status: implemented.

- Start a named saved routine, cardio modality, built-in or saved yoga flow, built-in or saved conditioning preset, or an empty workout.
- Resolve conversational routine-name forms such as `AX400`, `A X four hundred`, `axe four hundred`, and `AX four zero zero` without substituting the next tracked routine.
- Ask the user to choose when multiple workouts are equally good matches.
- Start the next incomplete workout in the active tracked microcycle, including alternating partners and completed-cycle rotation.
- Resume the active workout.
- Open a saved routine or exercise by name.
- Publish searchable workout, routine, and exercise entities to Siri, Shortcuts, and Spotlight.
- Provide Control Center controls for Start Workout, Start Next, and Resume.
- Provide an Apple Watch start intent for Next Tracked Workout or Empty Workout, requiring a reachable iPhone and never queueing a delayed start.
- Preserve authored workout targets, bypass parked progression behavior, and never silently replace an active workout.

Current Siri boundary: include `ForgeFit` in the initial spoken request. Siri's generic, app-less workout chooser is system-controlled and does not reliably list ForgeFit even though ForgeFit's app-qualified commands work.

## Phase 2 — Maximum Hands-Free Live Workouts

Status: core active-workout controls implemented for ForgeFit 1.3; universal next-action and additional system surfaces remain planned.

Implemented:

- Resolve strength order from visible workout order, logical superset rounds, member order, and parent-before-drop ordering.
- Get the exact next set target and active-workout status, including ordinary rest remaining.
- Complete an exact eligible ordinary set after conversationally collecting missing reps, load, and RPE or RIR and confirming the final values.
- Update or reopen an identity-bound set without silently advancing a different set.
- Get Remaining Rest, Skip Rest, Add 15 Seconds, and Subtract 15 Seconds for ordinary rest timers.
- Revalidate workout identity, set identity, and the full set revision after every Siri prompt so a delayed answer cannot overwrite a newer iPhone or Watch edit.
- Keep myo-rep, rest-pause, cluster, AMRAP, cardio, yoga, and other stateful flows in their dedicated UI when one voice action cannot represent them safely.

Still planned:

- Add `Perform Next Workout Action` with a deterministic priority:
  1. Skip an active ordinary rest.
  2. Complete the exact eligible ordinary set.
  3. Advance the exact cardio segment, conditioning round or interval, or other typed live task.
  4. Open the specialized active control when structured input is required.
- Donate the currently valid next action to Apple Watch Ultra as workout state changes.
- Add interactive Live Activity and Control Center actions where ForgeFit can complete them truthfully.

## Phase 3 — Finish, Capture, and Training Information

Status: safe Siri workout finish implemented for ForgeFit 1.3; capture and training-information actions remain planned.

Implemented:

- Finish a substantive workout only after collecting whole-session CR10 exertion, presenting completed and incomplete work, and receiving explicit confirmation.
- Discard an empty workout only after explicit destructive confirmation so it does not create workout history or Health data.
- Revalidate the complete workout revision after confirmation and refuse to finish if sets, exercises, sessions, or blocks changed meanwhile.
- Reuse the existing validation, HealthKit, enrichment, awards, history, backup, Live Activity, and Watch teardown pipeline.
- Save today's performed workout without changing the reusable routine.

Still planned:

- Log morning check-in tags.
- Log body weight to Apple Health with explicit units and honest authorization failures.
- Mark or remove a rest day.
- Record a workout note or durable exercise setup note with an explicit destination.
- Add an exercise or ordinary set to the active workout, foregrounding ForgeFit for unresolved equipment or weight-mode choices.
- Extend workout starts with cardio goals and saved interval presets.
- Add authenticated, structured questions for readiness, weekly progress, personal records, previous exercise performance, training load, and bounded workout history.
- Export routine plans and share completed-workout artifacts through existing privacy-safe export contracts.

Sequencing recommendation: pull the read-only questions at the end of this phase forward before the more mutation-heavy Phase 2 actions. The first three should be “What's my workout today?”, “How am I doing this week?”, and concise readiness/progress answers.

## Phase 4 — Deferred Capabilities

Status: blocked on broader product foundations.

- Add explicit Pause Workout and Resume Workout actions only after durable whole-runtime pause works across iPhone, Watch, HealthKit, timers, routes, relaunch, and completed history.
- Keep discard and delete intents absent or undiscoverable.
- Keep coach-driven changes, automatic progression, and broad voice routine creation out of scope until those product areas are deliberately resumed.

## Rules Across Every Phase

- Bind mutations to durable workout and set identity; retries must be idempotent.
- Never invent missing values or report a failed persistence or HealthKit write as successful.
- Never silently replace or discard an active workout.
- If an action cannot safely mutate app data in the background, foreground ForgeFit and finish through the app-owned runtime.
- Require authentication for sensitive readiness, body-weight, note, history, record, and health-derived results.
- Keep Health data out of App Group snapshots, CloudKit plan data, intent donations, logs, and backup payloads.
