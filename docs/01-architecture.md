# B — Technical Architecture

> Native Apple front end + CloudKit sync. Offline-first. Privacy-first. iOS 26 / watchOS 26 floor.
> Apple ecosystem only — no web, Android, or non-Apple backend.

---

## 0. System overview

```
┌─────────────────────────┐         ┌─────────────────────────┐
│   Apple Watch (watchOS)  │  WCSession (control plane)        │
│  - HKWorkoutSession (OWNS │◄───────►│   iPhone (iOS)          │
│    the live workout)      │  Workout mirroring (HealthKit)    │
│  - HKLiveWorkoutBuilder   │◄───────►│  - Mirrored HKWorkout-  │
│  - Input Lock UI          │         │    Session (read live)   │
│  - WatchStore (WC mirror) │         │  - SwiftData (source of  │
└─────────────────────────┘         │    truth on device)      │
                                      │  - HealthKit read/write  │
                                      │  - CloudKit sync (auto)  │
                                      └───────────┬─────────────┘
                                                  │ CloudKit (private DB)
                                                  ▼
                           ┌────────────────────────────────────────┐
                           │              iCloud / CloudKit          │
                           │  Private database (per-user)            │
                           │  Automatic SwiftData mirroring          │
                           │  No server-side logic · No RLS needed   │
                           └────────────────────────────────────────┘
```

**Source-of-truth rule.** On-device **SwiftData is the source of truth** for the user's own data; CloudKit is the durable, multi-device mirror. Identity is the user's iCloud account — no login screen, no auth tokens. The Watch holds a non-persisting mirror and is the *live-workout* owner only during an active session. This keeps the gym experience fully offline.

**CloudKit scope:** private database only. No shared zones, no public database. The exercise library is a bundled seed each user owns (not a shared public DB). All sync is automatic via SwiftData's `cloudKitDatabase: .automatic`.

---

## 1. iOS architecture

**Pattern: MV + `@Observable` services (no heavyweight VIPER/MVVM ceremony).**
- SwiftUI views observe lightweight `@Observable` *store* objects (e.g. `WorkoutStore`, `LibraryStore`, `ReadinessStore`).
- Stores depend on **repositories** that wrap SwiftData (`ModelContext`). Views never touch SwiftData directly.
- **Modular Swift package layout** so the watch app and iOS app share models/logic:

```
ForgeFit/                      (Xcode workspace)
├── App-iOS/                    iOS app target (SwiftUI entry, navigation)
├── App-Watch/                  watchOS app target
├── Packages/
│   ├── ForgeCore/             pure Swift: domain models, volume/e1RM math,
│   │                          readiness & load formulas (no UI, fully unit-tested)
│   ├── ForgeData/             SwiftData @Model definitions + repositories
│   ├── ForgeHealth/           HealthKit wrappers (read/write/observe), HK type catalog
│   ├── ForgeWorkoutSession/   HKWorkoutSession/Builder/mirroring abstraction (shared)
│   └── ForgeUI/               shared SwiftUI components, design tokens, Swift Charts views
```

- **ForgeCore is platform-free and deterministic** — all the math (true unilateral volume, e1RM, TSS, CTL/ATL, readiness) lives here and is covered by unit tests, so correctness never depends on UI or network.
- **Concurrency:** Swift 6 strict concurrency. Repositories expose `async` APIs; HealthKit observer queries and sync run off the main actor; stores publish to the main actor.

**Key iOS modules**
- `WorkoutStore` — drives the routine runner and set entry; writes to SwiftData synchronously (instant). CloudKit syncs automatically.
- `LibraryStore` — exercise search (local index over SwiftData), taxonomy, notes.
- `HealthIngestStore` — schedules HK reads / background delivery, maps samples → `health_metrics`.
- `ReadinessStore` — computes/caches the daily readiness score (computed on-device via `ForgeCore`; no server round-trip).

---

## 2. watchOS architecture

- **The Watch owns the live workout.** Apple's mirroring model is Watch-primary (see [04-watch-implementation.md](04-watch-implementation.md)). The watch app creates the `HKWorkoutSession` + `HKLiveWorkoutBuilder`, begins collection, and calls `startMirroringToCompanionDevice()`.
- **Shared logic via `ForgeCore`/`ForgeWorkoutSession`/`ForgeHealth`** so set math, set types, and session handling are identical to iPhone.
- **Local watch cache (SwiftData)** persists in-progress sets so a disconnect or app suspension never loses reps.
- **Control plane = WatchConnectivity (`WCSession`).** Used for *intent* messages (start/stop requests, routine payloads, "I logged set X"). Live biometrics flow through HealthKit mirroring, not WC.
- **Input Lock** is a watch-UI state machine (see Deliverable E) requiring deliberate confirmation before Digital Crown edits commit.
- **Independence:** the watch app can run a full session with no iPhone nearby and reconcile later.

---

## 3. HealthKit integration plan

(Full feasibility + type catalog in [03-healthkit-feasibility.md](03-healthkit-feasibility.md).)

- **`ForgeHealth` is the only module that imports HealthKit.** It exposes typed read/write/observe APIs; the rest of the app deals in domain models.
- **Authorization:** request the minimal set per phase; never assume granted. Every read path tolerates `denied`/`notDetermined`/partial authorization and degrades gracefully.
- **Write path (E6):** completed workouts written via `HKWorkoutBuilder` with correct `HKWorkoutActivityType`, energy, distance, and metadata. The live builder (Watch) is the canonical source for active-session energy so calories are never zero.
- **Read path (E10):** `HKAnchoredObjectQuery` + **background delivery** (`enableBackgroundDelivery`) for HRV(SDNN), RHR, sleep, respiratory rate, wrist temp, SpO₂, body mass, VO₂max. Anchors persisted so we never re-ingest.
- **Telemetry (E14):** `HKQuantitySeriesSampleQuery` for high-frequency series; `HKWorkoutRouteQuery` for GPS; `HKHeartbeatSeriesQuery` for beat-to-beat → RMSSD enrichment.
- **No invented capabilities:** RMSSD is computed from a heartbeat series when present; otherwise the SDNN+RHR+sleep fallback is used.

---

## 4. CloudKit sync architecture

- **SwiftData + CloudKit (`cloudKitDatabase: .automatic`)** — SwiftData mirrors every `@Model` in the schema to a CloudKit record type in the user's private database. Sync is fully automatic: push, pull, debouncing, and zone management are handled by the framework. No outbox, no manual sync triggers.
- **Identity = iCloud account.** No auth UI, no login screen, no tokens. The user's iCloud account is the identity. Each user's data lives in their private CloudKit database, visible only to them across their Apple devices.
- **Private database only.** No shared zones (`CKShare`), no public database. The exercise library is a bundled seed copied into each user's private store on first launch — users own and can customize their copy freely.
- **No server-side logic.** CloudKit has no triggers, no Edge Functions, no RLS, no computed columns. Everything that was previously server-side (progression, readiness, training load, volume-by-muscle) is computed **on-device** via `ForgeCore`, which is the single source of truth for all math.
- **`@Attribute(.unique)` is unsupported by CloudKit** — all model IDs use plain `UUID` properties (client-generated, collision-free in practice). CloudKit's record name provides the true identity.
- **Conflict resolution:** CloudKit uses last-writer-wins per field. Acceptable for a single-user private database where concurrent edits across devices are rare and non-destructive.

---

## 5. Sync strategy

**Goal: a gym session is never lost, never duplicated, and reconciles across the user's Apple devices.**

- **Local write-through:** every user action writes to SwiftData immediately. UI reflects local state instantly. CloudKit syncs in the background automatically — no outbox, no manual sync triggers.
- **Stable IDs:** all rows use **client-generated UUIDs** as primary keys, created on-device. This is the backbone of duplicate prevention — the same logical workout has the same id everywhere, so Watch and iPhone converge on one row.
- **Automatic CloudKit mirroring:** SwiftData's `cloudKitDatabase: .automatic` handles push, pull, debouncing, and zone management. Existing local records are uploaded to the user's private CloudKit database on first launch when iCloud is available.
- **Graceful degradation:** when iCloud is unavailable (signed out, no network, airplane mode), the store works fully local. Sync resumes automatically when iCloud becomes available.
- **Conflict resolution:** CloudKit uses **last-writer-wins per field**. Acceptable for a single-user private database where concurrent edits across devices are rare.
- **Watch ⇄ iPhone:** the watch is a non-persisting mirror via WatchConnectivity (`WCSession`). The phone owns SwiftData + CloudKit sync. During a live session the shared workout UUID + HealthKit mirroring keep both in sync; the post-session canonical record is written on the phone.
- **Soft deletes:** deletes use `deletedAt` (tombstones) and sync via CloudKit, so a delete on one device propagates without resurrection.

---

## 6. Error-handling strategy

- **Typed errors per layer:** `ForgeHealthError`, `NetworkError`, `WorkoutSessionError`. No stringly-typed failures.
- **Fail safe, never lose user input:** any HealthKit failure during logging is non-blocking — the set is already in SwiftData; the failure only delays the HealthKit write and is retried. CloudKit sync failures are handled silently by the framework and retried automatically.
- **HealthKit authorization is always checked at call sites**, never assumed; missing permissions produce a clear, recoverable in-app prompt, not a crash.
- **Watch session recovery:** session state transitions and disconnects are handled by an explicit state machine (Deliverable E) with auto-resume; collected data is reconciled by workout id.
- **Observability:** structured logging via `OSLog` categories per module; privacy-redacted (health values never logged in the clear). Optional opt-in crash reporting that excludes health payloads.

---

## 7. Privacy & security model

- **Health data is treated as highly sensitive by default.** Principle of least privilege everywhere.
- **CloudKit private database** — all user data lives in the user's private iCloud database. No other user can access it. No RLS needed; isolation is enforced by CloudKit's per-user database model. Apple manages encryption at rest and in transit.
- **No broad client queries over health data** — reads are scoped and column-minimized.
- **On-device:** SwiftData store benefits from iOS Data Protection (file encryption at rest); HealthKit data stays in HealthKit and is read transiently.
- **No third-party backend** — data never leaves Apple's infrastructure. No Supabase, no external servers, no certificate pinning needed.
- **Data ownership:** full **export** (all rows) and **deletion** (cascade delete in SwiftData + CloudKit) are first-class features (E16), not afterthoughts.
- **Consent & transparency:** granular HealthKit permission requests staged by feature; clear in-app explanation of what each share enables; nothing exported to third parties (Strava) without explicit per-field user action.
- **Logging hygiene:** analytics (if any) are aggregate and opt-in; raw HRV/RHR/sleep/weight values are never sent to analytics.
