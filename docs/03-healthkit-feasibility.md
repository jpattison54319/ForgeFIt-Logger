# D — HealthKit Feasibility Review

> Skeptical, verified review. Findings checked against Apple Developer documentation and forums (June 2026).
> OS floor is **iOS 26 / watchOS 26**, so every iOS 13–17-era API below is unconditionally available — but availability ≠ data presence, which is the recurring caveat.

---

## Legend
- ✅ **Definitely possible** — public API, reliable.
- ⚠️ **Possible but limited** — API exists; data presence/coverage depends on hardware, user behavior, or what the system recorded.
- 🔬 **Needs verification in-app** — must be validated on-device during the relevant epic.
- ❌ **Not available** — do not design around it.

---

## 1. Required HealthKit types

### Write (workouts we create)
| Capability | Type / API | Status |
|---|---|---|
| Save completed strength workout | `HKWorkoutBuilder` / `HKWorkout`, `HKWorkoutActivityType.traditionalStrengthTraining` | ✅ |
| Save cardio workouts | `HKWorkoutActivityType.running/cycling/rowing/elliptical/stairClimbing/hiking/highIntensityIntervalTraining/walking` | ✅ |
| Active energy on workout | `HKQuantityType(.activeEnergyBurned)` added to builder | ✅ (must be collected by the live builder — see §6) |
| Distance | `.distanceWalkingRunning`, `.distanceCycling` | ✅ |
| Route | `HKWorkoutRouteBuilder` | ✅ (needs `CLLocation` / Location permission) |

### Read — biometrics (recovery)
| Metric | Type | Status |
|---|---|---|
| HRV (SDNN) | `.heartRateVariabilitySDNN` | ✅ first-class quantity |
| Resting HR | `.restingHeartRate` | ✅ |
| Heart rate (live + samples) | `.heartRate` | ✅ |
| Sleep + stages | `HKCategoryType(.sleepAnalysis)` (`asleepREM/Core/Deep/Unspecified`, `awake`, `inBed`) | ⚠️ stages only on supported Watch + watchOS sleep tracking; otherwise only inBed/asleep |
| Respiratory rate | `.respiratoryRate` | ⚠️ recorded mainly during sleep on supported Watch |
| Wrist temperature | `.appleSleepingWristTemperature` | ⚠️ Series 8+/Ultra only; nightly, relative baseline |
| Blood oxygen | `.oxygenSaturation` | ⚠️ hardware/region-dependent; SpO₂ feature was disabled on some US units for a period — treat as optional |
| Body mass | `.bodyMass` | ✅ |
| Body fat / lean mass | `.bodyFatPercentage`, `.leanBodyMass` | ⚠️ present only if a scale/app writes them |
| VO₂max | `.vo2Max` | ⚠️ estimated by Apple from outdoor walk/run/hike; not every user has it |

### Read — cardio performance metrics
| Metric | Type | iOS since | Status |
|---|---|---|---|
| Running power | `.runningPower` | 16 | ✅ |
| Running speed | `.runningSpeed` | 16 | ✅ |
| Running stride length | `.runningStrideLength` | 16 | ✅ |
| Running vertical oscillation | `.runningVerticalOscillation` | 16 | ✅ |
| Running ground contact time | `.runningGroundContactTime` | 16 | ✅ |
| Cycling power | `.cyclingPower` | 17 | ⚠️ needs a paired power meter / supported sensor |
| Cycling cadence | `.cyclingCadence` | 17 | ⚠️ needs cadence sensor |
| Cycling speed/distance | `.cyclingSpeed`, `.distanceCycling` | 17 / earlier | ✅ |
| Stairs / floors | `.flightsClimbed` | earlier | ✅ (whole-day metric; per-workout floors are inferred) |
| Cross-trainer / elliptical distance | `.distanceCrossCountrySkiing`/general — elliptical exposes limited native quantities | — | ⚠️ elliptical has few first-class quantities; capture HR + energy + time, derive the rest |

### Read — beat-to-beat / RMSSD
| Capability | Type / API | Status |
|---|---|---|
| Beat-to-beat timestamps | `HKHeartbeatSeriesSample` + `HKHeartbeatSeriesQuery` | ⚠️ **see §3** |
| RMSSD | derived from heartbeat series | 🔬 compute & validate per §3 |
| Raw continuous RR stream on demand | — | ❌ no API to force collection of RR/heartbeat series at will |

---

## 2. Authorization & permission strings

- Request **per-phase, least-privilege** bundles, not everything up front:
  - E6 (write): workout + active energy + distance (+ location for routes later).
  - E10 (recovery read): SDNN, RHR, sleep, respiratory rate, wrist temp, SpO₂, body mass, VO₂max.
  - E12/E14 (cardio read): running/cycling performance quantities, heartbeat series, route.
- **Never assume granted.** HealthKit deliberately does **not** reveal read-authorization status (to avoid leaking that data exists). So: attempt the query, handle empty/denied gracefully, and show a clear re-prompt path. Write status *is* queryable via `authorizationStatus(for:)`.
- Info.plist: `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, `NSLocationWhenInUseUsageDescription` (routes), `NSMotionUsageDescription` if using CoreMotion fallbacks. Watch app needs `WKBackgroundModes` workout-processing for wrist-down collection.

---

## 3. The RMSSD / beat-to-beat finding (verified)

**Claim under test:** can ForgeFit compute RMSSD (preferred for morning parasympathetic readiness) rather than only SDNN?

**Verdict: ⚠️ feasible, conditionally.**
- `HKHeartbeatSeriesSample` stores a **series of heartbeat timestamps**; `HKHeartbeatSeriesQuery` enumerates per-beat times measured from the series start, and flags when a beat was *preceded by a gap* (possible missing beats). From consecutive timestamps you derive **RR/IBI intervals**, then compute **RMSSD** directly. (Apple introduced this representation at WWDC19; it underpins the ECG/HRV pipeline.)
- **The catch:** heartbeat series are recorded **opportunistically** by the Watch (e.g. around the background HRV measurements that produce SDNN, and during ECG). There is **no public API to command the Watch to record a heartbeat series on demand** for a morning reading. So coverage is **not guaranteed every morning**, and the gap-flag means some series are too sparse for a trustworthy RMSSD.

**Design consequence (already in the schema & readiness epic):**
1. **Primary path = robust fallback:** readiness is computed from **SDNN + RHR + sleep** against a rolling baseline — always available when the user wore the Watch overnight.
2. **Enrichment when present:** if a usable heartbeat series exists for the morning window, compute **RMSSD**, store it in `health_metrics.hrv_rmssd_ms`, set `readiness_scores.used_rmssd = true`, and weight it into the HRV component.
3. **Honesty in UI:** show whether the score used RMSSD or the fallback; never imply RMSSD precision we didn't have.
4. **Validate quality** (🔬, E11): minimum beat count, reject series with gap flags above a threshold, sanity-bound RMSSD before use.

**Do not** assume any way to read a continuous RR interval stream outside heartbeat series — that does not exist publicly. ❌

---

## 4. The Watch mirroring finding (verified) — corrects the prompt's assumption

**Claim under test:** "starting a workout on iPhone should reliably mirror to Watch."

**Verdict: the supported model is the reverse — Watch-primary.**
- watchOS 10/iOS 17 introduced **mirrored workout sessions**: the **Apple Watch is the primary device** that owns the `HKWorkoutSession`; the **iPhone receives the mirror**. APIs: `HKWorkoutSession.startMirroringToCompanionDevice()`, `sendToRemoteWorkoutSession(data:)` / `sendToRemoteWorkoutSession` for bidirectional data, and `HKHealthStore.workoutSessionMirroringStartHandler` on the iPhone side to receive the mirrored session. The two devices each hold their own `HKWorkoutSession` object and exchange data.
- A common pitfall: sending data before `session.prepare()` / before the remote delegate is set throws *"Remote session delegate is not set up."*

**Design consequence (in Deliverable E):** treat the **Watch as the workout owner**. An iPhone "Start" button does **not** create the canonical session on iPhone; it sends a **WatchConnectivity request** that launches/prepares the Watch session, which then mirrors back to iPhone. This is the single most important architecture correction in the project and the foundation for "no duplicate workouts" and "no zero calories."

---

## 5. What's definitely possible vs limited vs needs verification (summary)

**Definitely possible (✅):** writing correctly-typed workouts with non-zero energy; reading SDNN, RHR, heart rate, body mass; running power/speed/stride/oscillation/GCT; distance metrics; routes; Watch-primary mirroring; background delivery of biometrics.

**Possible but limited (⚠️):** sleep stages, respiratory rate, wrist temp, SpO₂, VO₂max, body composition, cycling power/cadence — all **hardware/behavior dependent**; design every consumer to tolerate absence. Heartbeat series presence for RMSSD.

**Needs in-app verification (🔬):** RMSSD quality gating; per-workout floors/steps derivation for stairmaster; elliptical metric derivation; exact background-delivery latency for overnight metrics; that mirrored-session energy lands correctly on both devices.

**Not available (❌):** on-demand RR/heartbeat-series capture; iPhone-primary→Watch mirroring as the canonical model; reading HealthKit *read*-authorization status.

---

## 6. The "calories = 0" root cause (and fix)

Zero-calorie workouts happen when an app creates an `HKWorkout` record **without** an active `HKLiveWorkoutBuilder`/`HKWorkoutSession` actually collecting `activeEnergyBurned` during the session. The fix, enforced in Deliverable E:
- The **Watch** runs `HKWorkoutSession` + `HKLiveWorkoutBuilder` with `HKLiveWorkoutDataSource` configured to collect heart rate **and** active energy for the chosen `HKWorkoutConfiguration.activityType`.
- `builder.beginCollection(at:)` is called at session start; energy accumulates live; `builder.endCollection` + `builder.finishWorkout` persist it.
- Never synthesize a workout summary from wall-clock time alone — always let the builder own collection so energy/HR are real.

---

## 7. Fallbacks for unavailable metrics

| Missing | Fallback |
|---|---|
| RMSSD (no heartbeat series) | SDNN + RHR + sleep readiness path; mark `used_rmssd=false` |
| Sleep stages | Use total asleep duration only; readiness sleep component degrades gracefully |
| VO₂max | Hide VO₂max trend; exclude from aerobic-base view; never fabricate |
| Cycling power/cadence (no sensor) | Use speed/distance/HR; show "power unavailable — pair a sensor" |
| SpO₂ / wrist temp / respiratory rate | Optional readiness inputs; absent → simply not weighted |
| Per-workout floors (stairmaster) | Derive from `flightsClimbed` delta over the session window; flag as estimated |
| Elliptical detail | Capture HR + energy + duration; derive intensity from HR zones |
| Body composition | Weight-only trend; composition shown only if a source writes it |
