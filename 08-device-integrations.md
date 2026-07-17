# Device Integrations — Garmin, HRMs & What Was Descoped

_Last updated: July 2026_

## What shipped

### Live heart rate from Bluetooth monitors (Garmin broadcast, straps)

Any monitor speaking the standard BLE Heart Rate profile (GATT service
`0x180D`) can feed live workout HR when no Apple Watch is streaming:

- **Garmin watches** — essentially all modern models — via **Broadcast Heart
  Rate** (Settings → Sensors & Accessories → Wrist Heart Rate; "Broadcast
  During Activity" auto-starts it). The user must enable it; apps cannot
  trigger it remotely.
- Polar / Wahoo watches, chest straps, armbands — broadcast by default.

Architecture:

- `Packages/ForgeCore` — `HeartRateMeasurement` (0x2A37 payload parser) and
  `LiveHRAggregator` (avg/max/time-in-zone/sample buffer; a port of the
  watch's `tickZone` semantics). Pure and unit-tested (`make test-core`).
- `ForgeFit/Devices/BLEHeartRateService.swift` — CoreBluetooth central:
  scan/connect/subscribe, auto-reconnect via never-expiring connect requests,
  remembered peripheral in UserDefaults (device-local; deliberately not
  CloudKit-synced). Created lazily so the Bluetooth permission prompt appears
  on first user action, not launch.
- `ForgeFit/Health/LiveMetricsHub.swift` — single source of truth for live
  metrics. Apple Watch owns the feed while its updates are <15 s old; BLE
  readings otherwise. All former `WatchLink.liveMetrics` consumers read the
  hub.
- At finish, BLE HR fills avg/max/zones (`WorkoutFinisher`), feeds the cardio
  series (`CardioSeriesService`), and is written to Apple Health (downsampled
  to 1/5 s, `healthWriteEnabled`-gated, skipped when the watch already saved
  the session).
- `AppInfo.plist` gained `NSBluetoothAlwaysUsageDescription` and the
  `bluetooth-central` background mode (stream survives phone lock).

Pairing UI: Settings → Heart Rate Monitor (`HRMPairingSheet`).

### Recovery scores for Garmin users (via Garmin Connect → Apple Health)

Garmin Connect natively writes **resting HR, sleep (with stages), heart rate,
steps, energy, and workouts** to Apple Health. ForgeFit's recovery reads are
source-agnostic, so this flows into readiness with no extra work.

**It does NOT write HRV.** Handling:

- `HealthService.detectGarminHRVGap()` — Garmin sleep present + zero HRV
  samples in 7 days → `HealthMetricsStore.hrvGapDetected`, surfaced as an
  explainer card on the recovery screen (readiness re-weights to sleeping HR
  + sleep automatically; bridge apps like HealthFit / RunGap / Health Sync
  can copy HRV over).
- `NocturnalAggregator` requires ≥3 overnight HR samples per night
  (`minSleepingHRSamples`) so Garmin's sparse smart-recording still yields a
  sleeping HR while a single spurious sample can't define a night.

## Descoped (and why)

- **Garmin Health API** — has real HRV/Body Battery, but it's OAuth +
  push-webhooks: requires a backend server ForgeFit doesn't have, and new
  partner access was paused as of 2026. Revisit only if a backend exists.
- **Fitbit** — no client-side path at all: its BLE broadcast (Charge 6+) is
  encrypted/allow-listed rather than standard 0x180D; the Fitbit app doesn't
  write to Apple Health; and the legacy Web API shuts down Sept 2026 in
  favor of the cloud-only Google Health API (backend required).
- **HR-based calorie estimation** (Keytel formula) — deliberately not done;
  BLE strength workouts leave calories to the HealthKit window fill. Honest
  data over invented numbers.

## Future hooks

- **Session HRV from RR intervals** — `HeartRateMeasurement` already parses
  RR intervals (flag bit 4); nothing consumes them yet.
- **CoreBluetooth state restoration** — cold-launch reconnects without
  opening the app.
