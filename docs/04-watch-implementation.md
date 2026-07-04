# E — Apple Watch Implementation Plan

> Native watchOS. Watch is the **workout owner**; iPhone mirrors. Reliability over features.
> Floor: watchOS 26 / iOS 26 (mirroring APIs unconditionally available).

---

## 1. Roles & the core correction

Per the feasibility review ([03](03-healthkit-feasibility.md) §4), Apple's mirrored-workout model is **Watch-primary**:
- The **Watch** creates and owns the `HKWorkoutSession` + `HKLiveWorkoutBuilder`, collects biometrics/energy, and calls `startMirroringToCompanionDevice()`.
- The **iPhone** receives the mirror via `HKHealthStore.workoutSessionMirroringStartHandler` and gets a read/companion `HKWorkoutSession`; it can display live stats and send control data back.
- **WatchConnectivity (`WCSession`)** carries *intent/control* messages (start request, routine payload, set-logged events). Live biometrics ride HealthKit mirroring, not WC.

**Implication:** an iPhone "Start workout" button is a **request**, not the canonical start. It tells the Watch (via WC) to launch/prepare the session, which then mirrors back. This is the foundation for no-duplicates and non-zero calories.

---

## 2. Workout session lifecycle (state machine)

```
idle
  └─(start intent: from watch UI OR WC request from iPhone)─► preparing
        prepare(): create HKWorkoutConfiguration(activityType, locationType)
                   create HKWorkoutSession + HKLiveWorkoutBuilder
                   builder.dataSource = HKLiveWorkoutDataSource(...)
                   session.prepare()                       (state -> .prepared)
                   session.startMirroringToCompanionDevice()
  └─► running
        session.startActivity(at:) ; builder.beginCollection(at:)
        live energy/HR accumulate; sets logged locally + via WC/mirror
  └─(pause)─► paused  (session.pause()/.resume())
  └─(end)─► ending
        builder.endCollection(at:) ; builder.finishWorkout()  -> HKWorkout
        finalize ForgeFit workout row (shared UUID); stop mirroring
  └─► saved  ─► idle
recovery: any unexpected disconnect/suspension re-enters via persisted session state
```

- **`HKWorkoutConfiguration.activityType`** is set correctly per modality (`.traditionalStrengthTraining`, `.running`, `.cycling`, `.rowing`, `.elliptical`, `.stairClimbing`, `.hiking`, `.highIntensityIntervalTraining`, `.walking`). `locationType` set for outdoor cardio.
- All session/builder objects are created **once** and owned by a single `WorkoutSessionController` (in `ForgeWorkoutSession`) shared by both targets.

---

## 3. Live workout builder & non-zero calories

- `HKLiveWorkoutDataSource` is configured to collect **`heartRate` + `activeEnergyBurned`** (plus distance/power for cardio) for the chosen configuration.
- `builder.beginCollection(at: startDate)` at activity start; the builder's delegate (`workoutBuilder(_:didCollectDataOf:)`) streams live energy/HR into the UI and the mirror.
- On finish: `endCollection` → `finishWorkout()` yields the persisted `HKWorkout` with **real** energy. We then set `workouts.hk_workout_uuid` and reconcile.
- **Rule:** never create a summary from elapsed time alone. The builder owns collection so calories/HR are genuine. (Directly answers the "calories should not be zero" requirement.)

---

## 4. Mirroring strategy & state synchronization

- **Watch → iPhone:** `startMirroringToCompanionDevice()`; live `HKWorkout` data mirrors automatically; custom payloads (current exercise, set list deltas) via `sendToRemoteWorkoutSession(data:)`.
- **iPhone → Watch:** the companion sends control data (e.g. "advance to next exercise", "user edited target") back over the mirrored session and/or WC.
- **Set logging is bidirectional:** a set logged on either device is written locally to SwiftData with the **shared workout UUID + set UUID**, then broadcast; the peer **upserts by id** (idempotent), so the same set never duplicates.
- **Sequencing guard:** never `sendToRemoteWorkoutSession` before `prepare()` + remote delegate setup (avoids *"Remote session delegate is not set up"*). The controller queues outgoing payloads until `.prepared`.
- **Single source for the canonical record:** at finish, exactly one `workouts` row (keyed by the shared UUID) is upserted; `uq_workouts_hk` and the shared id prevent a second.

---

## 5. Input Lock (problem #9)

A watch-UI state machine that makes the screen **glanceable and hard to corrupt** during push-ups/burpees/wrist-flexion/sweat:
- **Locked by default during active sets.** While locked, Digital Crown rotation and incidental taps **do not** mutate weight/reps/rest/complete.
- **Deliberate confirmation to edit:** entering edit mode for a critical value requires an explicit gesture (e.g. firm tap on the field → "Edit" affordance, or a two-step Crown-press-then-rotate). The Crown only adjusts a value **after** the field is explicitly armed; committing requires a confirm tap.
- **Auto-relock** after commit or a short idle timeout.
- **Critical values guarded:** weight, reps, rest-timer, set-completion. Non-critical glances (scrolling the set list) remain free.
- **Visual language:** a lock glyph + subdued controls when locked; armed field is high-contrast and unmistakable.
- **Accessibility:** lock state announced via VoiceOver; large tap targets.

---

## 6. Disconnect recovery & no data loss

- **Persist in-progress session state + every logged set to the watch SwiftData cache immediately.** Nothing depends on connectivity to be durable.
- **WC transfer choice:** time-sensitive control uses `sendMessage` (with reply) when reachable; everything else uses `transferUserInfo`/`updateApplicationContext` which **queue and deliver later** — so a logged set survives a dropped link and syncs on reconnect.
- **Session continues wrist-down:** workout-processing background mode keeps `HKLiveWorkoutBuilder` collecting HR/energy when the wrist lowers (so biometrics don't gap).
- **Reconnect reconciliation:** on link restore, both devices exchange outstanding set deltas keyed by UUID and **upsert**, converging without dupes or loss.
- **Crash/relaunch:** the controller can re-attach to an ongoing `HKWorkoutSession` (system keeps it alive) and rebuild UI from the persisted cache.
- **iPhone offline at finish:** Watch finalizes locally; the canonical row syncs to CloudKit later automatically (SwiftData handles this when iCloud becomes available).

---

## 7. Duplicate prevention (explicit)

Three independent guarantees stack:
1. **Shared workout UUID** generated once at session start and used by both devices.
2. **Idempotent upserts** (`on conflict (id)`) for workout/exercise/set rows.
3. **`uq_workouts_hk (user_id, hk_workout_uuid)`** so one HealthKit workout maps to one ForgeFit workout.

Result: every start permutation (Watch-only, iPhone-request→Watch, both apps open) yields **exactly one** workout.

---

## 8. Battery considerations

- Prefer **mirroring + HealthKit collection** over chatty WC messaging; batch set deltas rather than per-keystroke sends.
- Use `updateApplicationContext` (coalesced) for non-urgent state; reserve live `sendMessage` for genuinely interactive control.
- Throttle UI refresh from the builder delegate (e.g. 1 Hz for energy/HR display).
- Don't keep GPS/route building on for indoor modalities; set `locationType` accordingly.
- Stop collection promptly on finish; release session/builder to avoid lingering background work.

---

## 9. Test matrix (feeds E7/E8 acceptance + risk spikes)

| Scenario | Expected |
|---|---|
| Watch-only strength session | non-zero energy + HR; sets persist; one workout |
| iPhone "Start" → Watch | Watch session launches/prepares; mirrors back; one workout |
| Log set on Watch | appears on iPhone within seconds; no dup |
| Log set on iPhone | appears on Watch; no dup |
| Wrist down mid-set | HR/energy keep collecting |
| Force BT off mid-session, then on | no data loss; deltas reconcile by UUID |
| Watch app crash + relaunch | re-attaches to session; UI rebuilt from cache |
| iPhone offline at finish | Watch finalizes; CloudKit syncs later; still one workout |
| Crown spam during push-ups (locked) | no value corruption |
| Arm field → edit → confirm | value updates deliberately only |
