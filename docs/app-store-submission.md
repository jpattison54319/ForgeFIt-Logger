# ForgeFit — App Store submission pack

Updated 2026-08-11 for ForgeFit **1.0 (56)**, bundle `org.xpetsllc.ForgeFit`,
iPhone only (`TARGETED_DEVICE_FAMILY = 1`).

Everything below is copy-and-paste ready for App Store Connect. Character
counts are given against Apple's limits; each field is already inside its
limit. Assets live in [`artifacts/appstore/`](../artifacts/appstore/).

> **Read the open items in the last section before you submit.** Stable cloud
> archive/processing, launch support copy, and signed-in iCloud/hardware
> verification remain separate release checks.

---

## 1. App information

| Field | Value |
|---|---|
| **Name** (30 max) | `ForgeFit: Lift, Run, Recover` — 29 |
| **Subtitle** (30 max) | `Training log with readiness` — 27 |
| **Primary category** | Health & Fitness |
| **Secondary category** | Sports |
| **Primary language** | English (U.S.) |
| **Age rating** | 4+ (see §7) |
| **Price** | Free, no in-app purchases |
| **Availability** | All territories (see §9 open items) |

### Alternate name/subtitle options

If `ForgeFit: Lift, Run, Recover` reads as too broad next to Hevy and Strong:

- `ForgeFit — Hybrid Training Log` (30) / `Lift, run, and recover as one` (29)
- `ForgeFit: Workout & Recovery` (28) / `Strength, cardio, yoga, readiness` (32 — **over**, don't use)
- `ForgeFit Training Log` (21) / `Strength, cardio, and recovery` (30)

---

## 2. Promotional text (170 max)

Editable without a new build — use it for whatever is newest.

```
Now with guided yoga flows, rower /500m splits, and interval pace bands. Your
readiness, training load, and every session you have ever logged — in one app,
on your device.
```
164 characters.

**Alternate (launch week):**

```
One app for people who lift and run. Log faster than a spreadsheet, see the
readiness behind today's session, and keep every workout on your own device.
```
150 characters.

---

## 3. Description (4000 max)

```
ForgeFit is the training log for people who lift AND run, row, ride, or flow —
instead of one app for lifting, another for cardio, and Health for everything
else.

FAST, HONEST LOGGING
Your last session's weights and reps are already in the row, greyed out, waiting
to be tapped. Warm-up ramps, drop sets, myo-reps, rest-pause, clusters,
unilateral work, assisted and added-bodyweight sets are all first-class — not
notes you type into a comment field. A rest timer runs between sets, a plate
calculator does the arithmetic, and supersets stay grouped.

CARDIO THAT KNOWS WHAT MACHINE YOU'RE ON
A rower gets /500m splits and stroke rate. A bike gets power and cadence. A
stair climber gets floors. An outdoor run gets pace, route, and elevation. Build
interval plans with work and rest steps, session goals, and pace bands, and get
a spoken cue when you drift outside them.

YOGA, INCLUDED
Guided flows with pose art, Sanskrit names, hold timers, and optional voice
guidance — logged as real sessions with time under stretch by body region, not
as a 40-minute "other" entry.

READINESS, IN CONTEXT
ForgeFit reads HRV, resting and sleeping heart rate, sleep, respiratory rate,
blood oxygen, and VO2 max from Apple Health and turns them into one daily
recovery score — and then shows its work. Every score opens to the readings
behind it, how they compare to your own rolling baseline, and how much data it
actually had. When there isn't enough evidence, it says so instead of inventing
a number.

TRAINING LOAD YOU CAN ARGUE WITH
Weekly load compared against your own prior weeks. Volume, sets, and reps by
muscle group. Estimated 1RM trends per lift. Personal records. A calendar where
every day carries its recovery ring and that day's strain. Build your own
insight charts to compare any two things you track.

APPLE WATCH
Start on the watch or the iPhone and keep both in sync. Live heart rate, zones,
and calories. Input Lock so a sweaty wrist can't corrupt a set. Bluetooth chest
straps and broadcasting watches work too.

BUILT AROUND PROGRAMS
Import a full program — Push/Pull/Legs, Upper/Lower, Hybrid Engine, and more —
or build routines from a library of 900+ exercises with photos and instructions.
Track a repeating microcycle and see where you are in the week.

YOUR DATA STAYS YOURS
No account. No ads. No analytics. No servers. Your workouts live in a database
on your iPhone. iCloud syncs your training plan across your devices through your
own private CloudKit database and automatically keeps a sanitized workout-history
backup in your iCloud Drive. Apple Health data is processed on-device and is
excluded from that sync and backup. Export everything to JSON or CSV whenever
you want, and import your history from Hevy, Strong, or CSV on day one.

ForgeFit is a training tool, not a medical device. Its scores and
recommendations describe your own recorded data; they do not diagnose, treat, or
predict injury. Talk to a qualified professional about medical decisions.

Requires iPhone with iOS 26. Apple Watch app requires watchOS 26. Apple Health
and location access are optional — ForgeFit works without either.
```

2,922 characters.

---

## 4. Keywords (100 max, comma-separated, no spaces after commas)

```
workout,gym,lifting,strength,log,tracker,hevy,cardio,running,rowing,yoga,hrv,recovery,readiness,1rm
```
99 characters.

Notes:
- No spaces after commas — Apple counts them and they buy nothing.
- Words already in the **name** and **subtitle** are indexed, so `ForgeFit`,
  `training`, `run`, `recover`, and `readiness` need no keyword slot. (`readiness`
  is kept anyway because it is the single strongest differentiator term.)
- `hevy` is a competitor brand term. Apple permits competitor keywords, but a
  trademark holder can complain; drop it if you would rather not have that
  conversation. Replacing it with `interval` is the cheapest swap.

**Alternate set without competitor terms (98):**
```
workout,gym,lifting,strength,log,tracker,interval,cardio,running,rowing,yoga,hrv,recovery,sleep,1rm
```

---

## 5. What's New (4000 max) — for 1.0

```
First release.

ForgeFit brings strength, cardio, yoga, and recovery into one training log:
prefilled sets from your last session, modality-correct cardio metrics, guided
yoga flows, an Apple Watch companion, and a daily readiness score built from
your own Apple Health baselines — with the readings behind it always one tap
away.

Your history remains local-first and a sanitized copy is backed up privately to
your iCloud Drive. Import from Hevy, Strong, or CSV to start with everything you
have already logged.
```

---

## 6. URLs

| Field | URL | Status |
|---|---|---|
| **Support URL** (required) | `https://jpattison54319.github.io/forgefit-site/support.html` | Live page exists; **needs a contact method Apple accepts — see §9** |
| **Marketing URL** (optional) | `https://jpattison54319.github.io/forgefit-site/` | Live; remove the "In beta on TestFlight" pill before launch |
| **Privacy Policy URL** (required) | `https://jpattison54319.github.io/forgefit-site/privacy.html` | Live and aligned with the 1.0 source policy as of site commit `e20b60d` (2026-08-11) |
| **EULA** | Leave blank — Apple's standard licence applies | — |

The site source is the `forgefit-site` repo, served by GitHub Pages. If a custom
domain is added later, update all three fields *and* the in-app links in
`ForgeFit/Settings/`.

---

## 7. Age rating questionnaire

Answer **None / No** to every content question. The two that need thought:

| Question | Answer | Why |
|---|---|---|
| Unrestricted web access | **No** | The only outbound links are the fixed support/privacy/attribution URLs. |
| Medical/Treatment information | **No** | ForgeFit describes your own recorded training and Health data. It gives no diagnosis, dosage, or treatment guidance, and the description and in-app copy say so explicitly. |
| Contests / gambling / user-generated content | **No** | Community is disabled in 1.0 (`FeatureFlags.social`), so there is no UGC, no profiles, and no public database. |

Result: **4+**.

---

## 8. App Privacy ("nutrition label")

**Recommended answer: "Data Not Collected."**

The reasoning you should be able to defend if asked:

- ForgeFit operates no servers and embeds no third-party SDKs — the 1.0 archive
  audit found no third-party frameworks and no analytics.
- Training data is written to a local database on device.
- iCloud sync uses the user's **private** CloudKit database. Data in a user's
  own private CloudKit database is not accessible to the developer and is not
  "collected" under Apple's definition.
- ForgeFit automatically writes a sanitized workout-history backup to the
  user's own iCloud Drive. The developer does not receive or have access to
  those private files, so this does not change the "Data Not Collected"
  recommendation under Apple's developer-access definition.
- Apple Health data is processed on device. HealthKit-imported workouts,
  HealthKit-filled distance, Health-derived automatic intervals, heart rate,
  energy, readiness, body weight, and other Health data are excluded from
  automatic iCloud sync and backup.
- Community, the only feature that ever used the **public** CloudKit database,
  is off in 1.0.

**Before you tick that box, confirm both:**
1. `FeatureFlags.social` is `false` in the shipping build (no public database
   writes), and
2. the shipping build's `com.apple.developer.icloud-container-environment` is
   `Production` (see §9).

If either is not true, the honest answer changes.

### Permission strings already in `AppInfo.plist`
All four read well and match what the app does — no edits needed:

- `NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`
- `NSLocationWhenInUseUsageDescription` (outdoor cardio routes, saved on device)
- `NSBluetoothAlwaysUsageDescription` (heart-rate monitors)
- `NSPhotoLibraryAddUsageDescription` (saving share images)

### Accessibility declarations on the product page
Answer these **honestly** — the 1.0 audit is explicit that ForgeFit does not
qualify for the Larger Text declaration:

- **Larger Text** — do **not** claim. Dynamic Type is deliberately *clamped* to
  Accessibility 1; the project uses fixed point sizes throughout.
- **VoiceOver** — do **not** claim app-wide. iPhone coverage is real but partial
  and the watch app has two labels.
- **Dark Interface** — safe to claim; ForgeFit is dark by design.
- **Sufficient Contrast / Differentiate Without Colour** — review before
  claiming; charts and recovery rings lean on colour.
- **Audio Descriptions / Captions** — not applicable.

---

## 9. Review notes (App Review Information → Notes)

```
ForgeFit needs no account and no sign-in. Everything is usable immediately.

Apple Health and Location are both optional. On the "Apple Health" onboarding
screen, "Continue without Health" reaches the full app. A simulator or a device
with no Health history will show "Building your baseline" instead of a recovery
score — that is the intended honest-evidence behaviour, not an error.

To see the app with data, tap "Import or restore data" on the welcome screen and
import any Hevy, Strong, or CSV export, or use Explore on the Workout tab to
install a bundled program and log a session.

The Apple Watch app is a companion for logging and live heart rate. It is not
required.

There is no user-generated content, no social feed, and no public database in
this version.

ForgeFit is a training tool, not a medical device. Recovery and training-load
scores describe the user's own recorded data and are labelled as descriptive; no
screen offers diagnosis, treatment, or injury prediction.
```

**Demo account:** not applicable — leave "Sign-in required" unchecked.

---

## 10. Export compliance & content rights

- **Uses encryption:** Yes → **only exempt encryption** (HTTPS/ATS and Apple
  platform encryption). Answer the follow-up "Does your app qualify for any of
  the exemptions?" → **Yes**, so no CCATS/ERN is required. Consider adding
  `ITSAppUsesNonExemptEncryption = false` to `AppInfo.plist` so App Store Connect
  stops asking on every upload.
- **Content rights:** the app displays third-party exercise photographs and
  instructions from the open-source
  [`free-exercise-db`](https://github.com/yuhonas/free-exercise-db) dataset,
  attributed in Settings → About and in `docs/exercise-image-attribution.md`.
  Answer "Yes, it contains, shows, or accesses third-party content" and be ready
  to point at that attribution.
  **None of the ten submitted screenshots or the preview videos show those
  photographs** — that was deliberate. Keep it that way unless the licence is
  confirmed to cover marketing use.

---

## 11. Assets

All captured on an **iPhone 17 Pro Max simulator (iOS 26.5)** at native
**1320 × 2868**, which is the required 6.9" App Store size. Apple scales this
set down to every other iPhone size, so no second set is needed.

### Screenshots — `artifacts/appstore/screenshots-6.9/`

| # | File | What it sells |
|---|---|---|
| 1 | `01-home-readiness.png` | The morning glance: one recovery score, sleep, strain, health bands, and today's call |
| 2 | `02-recovery-detail.png` | The receipts — HRV, sleep, sleeping HR vs your own median, and data coverage |
| 3 | `03-live-logger.png` | Mid-session logging with last session's numbers prefilled and the rest timer running |
| 4 | `04-routines.png` | Programs, not a pile of routines |
| 5 | `05-cardio-detail.png` | Modality-correct cardio: /500m split, power, zone distribution, "started at 77% ready" |
| 6 | `06-insights.png` | 12 weeks of volume, switchable to duration or reps |
| 7 | `07-insights-records.png` | Weekly volume by muscle + estimated 1RM records |
| 8 | `08-history.png` | 108 sessions — lifts, runs, rows, and yoga — searchable and filterable |
| 9 | `09-calendar.png` | Recovery rings on every day, with that day's numbers below |
| 10 | `10-sleep-detail.png` | Sleep against your target, with the timing that produced it |

`artifacts/appstore/extra-screenshots/` holds alternates (exercise detail,
statistics, exercise library, profile) if you want to swap one out. Note that
the exercise-detail and exercise-library shots contain third-party photos — see
§10.

### Apple Watch screenshots — `artifacts/appstore/screenshots-watch/`

**Required, not optional.** The binary embeds a watchOS app, so App Store
Connect refuses the submission without at least one Watch screenshot
("Your binary indicates support for Apple Watch").

Captured on an **Apple Watch Series 11 (46mm), watchOS 26.5** at native
**416 × 496** — one of Apple's accepted Watch sizes, so no resampling.

| # | File | What it sells |
|---|---|---|
| 1 | `01-watch-readiness.png` | Today's readiness on the wrist, then start a routine from it |
| 2 | `02-watch-live-workout.png` | Mid-session: rest countdown, live heart rate with session average, set progress per exercise |

A size warning worth knowing: the Apple Watch **Ultra 3 (49mm)** simulator
renders at **422 × 514**, which is *not* on Apple's accepted list (the Ultra
entry is 410 × 502). Capture Watch assets on a 46mm device unless you have
confirmed App Store Connect accepts the newer Ultra size.

### App previews — `artifacts/appstore/previews-6.9/`

H.264, 30 fps, 1320 × 2868, silent AAC track, all inside Apple's 15–30 s window.

| File | Length | Arc |
|---|---|---|
| `ForgeFit-preview-1-train.mp4` | 27.2 s | Readiness on Home → the routine library → start Push Day → log sets with the rest timer running |
| `ForgeFit-preview-2-recover.mp4` | 27.9 s | Recovery score and the readings behind it → sleep detail → a calendar of recovery rings |
| `ForgeFit-preview-3-progress.mp4` | 28.5 s | Profile and level → searchable history across lifts, runs, rows and yoga → volume trend and weekly volume by muscle |

**Poster frames:** App Store Connect picks a frame automatically; override each
one to a moment with a headline number on screen (roughly 0:03 for preview 1,
0:02 for preview 2, 0:04 for preview 3).

### Regenerating

Everything above is produced by the capture harness, not by hand:

```bash
cd ForgeFit
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test \
  -workspace ForgeFit.xcworkspace -scheme ForgeFit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests
```

See `artifacts/appstore/README.md` for the full loop, including video recording
and the trim/encode step.

---

## 12. Still open before you press Submit

Carried forward from `artifacts/release-audit-2026-08-09/FINAL-AUDIT.md`, plus
what this pass found:

1. **Support contact.** Apple requires a support URL where a user can reach you.
   The live support page currently points at a GitHub Issues tracker, which
   requires a GitHub account. Reviewers have rejected apps for that. Add a plain
   `mailto:` support address to `support.html` — that is a decision only you can
   make, since it publishes an address.
2. **Marketing site still says beta.** `index.html` leads with an "In beta on
   TestFlight" pill and `support.html` opens with TestFlight instructions.
   Both need launch copy before the URLs go on the product page.
3. **Build toolchain.** The only locally installed Xcode is 27.0 beta
   (`27A5228h`).
   Apple's July 2026 App Store Connect release notes allow Xcode 27 beta builds
   for TestFlight, not App Store submission. Build 56 therefore needs a
   successful stable-Xcode Xcode Cloud archive before it is selected for review.
4. **CloudKit environment.** The source entitlement intentionally no longer
   hardcodes `Development`; signing should inject the provisioning profile's
   environment. Inspect the stable archive's signed entitlements and confirm
   `Production` before upload—source configuration alone is not archive proof.
5. **Automatic iCloud Drive backup.** Source tests cover scheduling, visible
   success/failure and retry state, two-slot rotation, deletion, restore
   isolation, and Health-provenance filtering. A signed-in clean-install test
   still must confirm automatic file creation, failure recovery, deletion, and
   restore on a second iPhone before this is called device-verified.
6. **Hardware-specific pass.** Build 55 was signed, installed, and launched on
   James's iPhone 16 Pro Max, and the owner reported the visible smoke check
   looked good. That does not by itself prove paired-Watch terminal races,
   HealthKit delivery, GPS routes, haptics, alarms, audio, or BLE.

Resolved: the hosted privacy page was deployed from site commit `e20b60d` and
live-checked against the automatic CloudKit plan sync and sanitized iCloud Drive
workout-backup behavior.

Resolved in source during the final audit: persistence startup no longer calls
`fatalError`, no longer replaces a failed store with an empty one, and blocks
on a recovery screen if either data preservation or required backup exclusion
cannot be established. This still needs clean-install/update testing from the
stable archive on a physical iPhone.
