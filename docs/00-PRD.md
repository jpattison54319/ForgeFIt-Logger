# A — Product Requirements Document

> ForgeFit — a native iOS/watchOS training operating system for hybrid athletes.
> Target OS floor: **iOS 26 / watchOS 26**. Sync: **CloudKit** (Apple ecosystem only). Status: pre-build (greenfield).

---

## 1. Vision

ForgeFit is an all-in-one **training operating system** for people who lift, do cardio, and care about recovery. It replaces the fragmented stack of **Hevy** (strength) + **Athlytic/Bevel/Whoop** (recovery/readiness) + **Strava/Garmin** (cardio analytics) with a single native app that turns Apple Watch and Apple Health data into *actionable* coaching.

ForgeFit does not merely record workouts. It **interprets** them — surfacing training load, recovery, progression, and adaptation. The north star: *"a hybrid athlete opens ForgeFit in the morning, sees one readiness number they trust, trains a session that auto-adjusts to it, logs faster than Hevy, and finishes with a summary that explains what the session actually improved."*

### Positioning vs Hevy
Hevy is a strong strength-training ledger but architecturally limited: it is a passive log, weak on cardio, blind to recovery, and not natively integrated with HealthKit/watchOS. ForgeFit is **the product Hevy would be if it were native Swift, deeply integrated with HealthKit/watchOS, and designed for strength + cardio + recovery as one system.** We do not clone Hevy; we exceed it on logging speed and surround it with cardio + recovery + coaching.

---

## 2. Target user

**Primary persona — "The Hybrid Athlete" (Jordan).**
- Lifts 3–5×/week *and* runs/rows/cycles 2–4×/week. Trains for both strength and aerobic capacity.
- Owns an Apple Watch + iPhone; already generates HRV, RHR, sleep, VO₂max data that sits unused.
- Currently juggles Hevy + a recovery app + Strava/Garmin and hates the fragmentation and double-logging.
- Wants fast in-gym logging (sweaty, fatigued, high HR) and *decisions* ("should I push or back off today?").
- Privacy-conscious about health data; wants to own and export it.

**Secondary personas.**
- **Strength-focused lifter** who wants the fastest logger + real progression, and may grow into cardio/recovery.
- **Endurance-leaning athlete** who wants serious cardio analytics (zones, load, polarized) but also strength accessory tracking.

**Explicitly not the target (for now):** casual step-counters, bodybuilding-only users uninterested in cardio/recovery, non-Apple-ecosystem users.

---

## 3. Core problems we solve

1. **Strength logging is too clunky during real training.** Too much tapping while fatigued/sweaty. → *Fastest-in-class set entry* (weight→reps→RPE/RIR→complete auto-progression, minimal taps).
2. **Apps are passive ledgers, not coaches.** → *Progression engine + mesocycle planning + auto-regulation* with plain-language explanations.
3. **Unilateral tracking is broken.** Users manually double dumbbell weights, corrupting volume history. → *First-class unilateral model* (enter one implement's weight; correct total volume computed server-side).
4. **Set schema is too thin.** No drop sets, rest-pause, eccentrics, holds, partials, assisted/added bodyweight. → *Rich set-type schema.*
5. **Exercise libraries are shallow and siloed.** Custom exercises lose metadata; no per-exercise setup memory. → *Global taxonomy + aliases + custom mapping + auto-surfacing per-exercise notes.*
6. **Cardio is treated as a time/distance note.** → *Modality-correct metrics* (stairmaster floors, rowing splits/watts, cycling power/cadence, running power/gait, elliptical, walk/hike, HIIT intervals).
7. **Cardio analytics are absent.** → *HR-zone distribution, polarized 80/20, TSS-like load, CTL/ATL fitness/fatigue, telemetry charts, "what this session improved" summaries.*
8. **Apple Watch integrations are fragile.** Zero-calorie workouts, lost data on disconnect, duplicate workouts, broken mirroring. → *Native HKWorkoutSession/HKLiveWorkoutBuilder with Watch-primary mirroring done correctly.*
9. **Accidental Watch input.** Digital Crown corrupts weight/reps during push-ups/burpees/sweat. → *Input Lock mode + deliberate confirmation.*
10. **Recovery data is unused.** → *Readiness score (0–100) from rolling baselines, with workout recommendations and explanations.*

---

## 4. Main features

### Strength (MVP core)
- Fastest-in-class set logging with `@FocusState` field progression and minimal taps.
- Routine builder + routine runner with prefilled targets from last session.
- Full advanced set-type support (warmup/working/drop/rest-pause/eccentric/paused/partials/holds/bodyweight/assisted/added-weight/unilateral/machine settings).
- First-class unilateral volume.
- Exercise library with taxonomy, aliases, custom exercises, and auto-surfacing per-exercise notes (seat height, grip, pain notes).
- Progression engine v1 with explanations; estimated-1RM trends.

### Cardio (MVP+ → ADV)
- Modality-specific live logging (iPhone + Watch) with correct `HKWorkoutConfiguration`.
- HR-zone capture; zone distribution per workout / week / month; polarized 80/20.
- TSS-like load, CTL (fitness) / ATL (fatigue), training-load trend.
- High-resolution telemetry (per-second HR/power/pace/cadence + GPS route), route maps, telemetry charts.
- Post-workout summaries that explain what improved (base / threshold / VO₂max / recovery).

### Recovery (MVP+)
- HealthKit biometric ingestion (HRV SDNN, RHR, sleep + stages, respiratory rate, wrist temp, SpO₂, body mass, VO₂max).
- Readiness score 0–100 vs rolling 30–60-day baseline; RMSSD enrichment when a heartbeat series exists, SDNN+RHR+sleep fallback otherwise.
- Readiness-driven recommendations: maintain / push / reduce volume / deload — each explained.

### Apple Watch
- Native watchOS logging; correct biometrics + non-zero calories.
- Watch-primary mirroring with iPhone; bidirectional set updates; duplicate prevention; disconnect recovery.
- Input Lock; glanceable, hard-to-corrupt UI; continues collecting wrist-down.

### Coaching (ADV)
- Mesocycle planning: accumulation / intensification / deload / strength / hypertrophy blocks.
- Auto-regulation driven by readiness; deload & fatigue detection; explained recommendations.

### Platform & data ownership
- Offline-first logging (never lose a gym session).
- Automatic iCloud sync via CloudKit (private database, Apple ecosystem only).
- Granular export (Apple Health read/write first; Strava OAuth; FIT/TCX); full data export + deletion.

---

## 5. MVP vs later phases

**MVP (shippable strength app, E0–E9):** native strength logging, fast set entry, routine builder, exercise library, unilateral support, advanced set types, HealthKit write of completed workouts, basic Watch companion logging, workout history, progression suggestions v1, CloudKit sync, basic charts.

**MVP+ (E10–E13):** HealthKit biometric ingestion, readiness score v1, cardio modality-specific logging, HR-zone charts, better Watch mirroring, exercise notes surfaced everywhere, volume by muscle group, estimated-1RM trends, offline-first sync hardening.

**Advanced (E14–E17):** full cardio telemetry ingestion, route maps, CTL/ATL training load, Strava export, RMSSD investigation/implementation, adaptive mesocycle planning, advanced coaching, web/iPad dashboard, and social/community **only after** core reliability is excellent.

(Full epic detail in [06-roadmap-epics.md](06-roadmap-epics.md) and [EPICS.md](EPICS.md).)

---

## 6. Non-goals

- **Not** a cross-platform app. Native Apple only — no React Native/Flutter/Catalyst workarounds for the watch.
- **Not** a social-first app. Community features are gated behind excellent core reliability (post-E16).
- **Not** a nutrition tracker in the MVP (may integrate later; out of initial scope).
- **Not** inventing HealthKit capabilities. RMSSD stays *derived* (never read directly); mirroring stays *Watch-primary*.
- **Not** a coaching marketplace / human-coach platform.
- **Not** Android, Wear OS, or web-app-first. (Web/iPad is a read-mostly dashboard, ADV-phase.)
- **Not** chasing feature breadth over reliability — every phase gates on the prior phase's reliability bar.

---

## 7. Success metrics

**Logging speed (the flagship claim).**
- Median time to log a standard working set ≤ **2.5s** and **< Hevy** in a documented head-to-head (target ≥ 25% faster).
- Median taps per logged set ≤ **3**.

**Reliability (the trust bar).**
- **0** zero-calorie completed Watch workouts in QA matrix.
- **0** duplicate workouts across iPhone/Watch start permutations.
- **100%** of sessions logged offline reconcile without data loss after reconnect.
- Crash-free sessions ≥ **99.8%**.

**Engagement / value.**
- ≥ **60%** of active users open the readiness screen on training mornings.
- ≥ **40%** of strength sessions use a progression suggestion (accept or informed-reject).
- Day-30 retention ≥ **35%** for users who complete onboarding + 3 workouts.

**Recovery accuracy (directional).**
- Readiness score available on ≥ **90%** of mornings for users with overnight Watch wear (via fallback when RMSSD/heartbeat series absent).

**Data ownership.**
- 100% of user data exportable and deletable on request (privacy/GDPR-style guarantee).
