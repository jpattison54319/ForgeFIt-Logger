# App Store assets

Screenshots and preview videos for the ForgeFit product page, plus the exact
commands that produced them. Metadata copy lives in
[`docs/app-store-submission.md`](../../docs/app-store-submission.md).

Everything here is captured from the **real app**, driven by an XCUITest tour —
there are no mockups, no device frames, and no compositing. If a screen changes,
rerun the harness rather than editing a PNG.

| Directory | Contents |
|---|---|
| `screenshots-6.9/` | The ten submitted screenshots, 1320 × 2868 |
| `previews-6.9/` | Three app previews, H.264 30 fps 1320 × 2868 with a silent audio track |
| `extra-screenshots/` | Alternates not submitted (see the third-party-photo caveat below) |

## Why 6.9" only

1320 × 2868 is the iPhone 17 Pro Max / 6.9" App Store size. Apple scales that
set down to every smaller iPhone, so a second set buys nothing.

## The moving parts

**`ForgeFit/AppStoreDemoSeed.swift`** (`--seed-appstore-demo`, DEBUG only)
builds the demo account: it imports the bundled *Push Pull Legs* and *Hybrid
Engine* programs through the same `RoutineTemplateCatalog` path a user would
tap, then generates ~18 weeks of history *against those routines* — progressive
loads with a deload every third week, runs with pace and zone seconds, rower
sessions with a /500 m split, and vinyasa flows. XP and level come from the real
`XPService` award pipeline, so the profile card can't claim a level the history
doesn't support. `--seed-active-workout` adds a Push Day that is 34 minutes in,
so the logger screenshot shows a session in progress rather than `0s`.

**`HealthMetricsStore.seedAppStoreDemo()`** supplies a clean 70-night Apple
Health series (HRV, sleeping HR, sleep windows, respiratory rate, SpO₂, steps,
body mass). Without it the simulator has no Health data and every recovery
surface honestly renders "Building your baseline" — true, but not a product
page.

**`ForgeFitUITests/AppStoreCaptureUITests.swift`** is the tour. Screenshot
sections and video tours are separate tests, each with its own launch, because
chaining them made later shots depend on whether an earlier back-navigation
landed.

## Regenerating the screenshots

```bash
cd ForgeFit
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild test \
  -workspace ForgeFit.xcworkspace -scheme ForgeFit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -derivedDataPath /tmp/ff-capture-dd \
  -resultBundlePath /tmp/ff-capture.xcresult \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/testCaptureHome \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/testCaptureTrainAndInsights \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/testCaptureProfile \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/testCaptureExerciseDetail \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/testCaptureHistoryAndCardio \
  -only-testing:ForgeFitUITests/AppStoreCaptureUITests/testCaptureLoggerScreenshots \
  CODE_SIGNING_ALLOWED=NO
```

Screenshots arrive as xcresult attachments; export them with:

```bash
xcrun xcresulttool export attachments --path /tmp/ff-capture.xcresult --output-path /tmp/ff-shots
```

`manifest.json` in that directory maps each opaque filename back to its
attachment name.

**Set a clean status bar first** — the capture assumes 6:41, full bars, charged:

```bash
xcrun simctl status_bar <udid> override --time "6:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
```

6:41 rather than Apple's customary 9:41 because Home greets you by time of day,
and "Good evening" over a 9:41 clock is the kind of detail that makes a product
page look assembled rather than captured.

## Regenerating the previews

Two scripts drive this — `record.sh` and `finalize.sh`, both in this directory.
They contain absolute paths from the machine they were written on; adjust `BASE`
and `UDID` before rerunning.

```bash
./record.sh   testPreviewTourTrain preview-1-train
./finalize.sh preview-1-train-raw.mov ForgeFit-preview-1-train.mp4 27.2
```

`record.sh <testName> <outputBase>` starts `simctl io recordVideo`, runs one
tour, and stops recording **the moment the test case reports** — not when
`xcodebuild` exits, because XCTest kills the app first and xcodebuild then
spends ~15 s tearing down, all of it recorded as springboard wallpaper.

`finalize.sh <raw.mov> <out.mp4> <seconds>` finds the cut point by content:
ForgeFit's UI is near-black and the springboard wallpaper is not, so the last
frame whose average luma is dark is the last frame of the app. It then trims the
requested number of seconds ending there and encodes.

Three things in `finalize.sh` are load-bearing and each one cost a wasted
recording to find:

- `-ss` must come **before the video `-i`**. Placed between the two inputs it is
  read as an input option for the silent-audio input, and the video is encoded
  from frame zero — which is the build phase, not the tour.
- `-t` must be an **output** option. A simulator recording emits a frame only
  when the screen changes, so a still screen leaves a long gap with no packets;
  limiting the *input* duration truncates the clip at the last real frame
  instead of letting `fps=30` pad the hold out to full length.
- Ask for a length the source can actually supply. If `-t` exceeds the material
  left after the cut, the video stream comes up short while the synthetic audio
  runs the full length, and the container reports a duration the picture never
  reaches. Encode once, read the video stream's duration, then re-encode at
  exactly that.

## Caveats worth keeping

- **Third-party photos.** Exercise detail and the exercise library show
  photographs from the open-source `free-exercise-db` dataset (attributed in
  Settings → About). None of the ten submitted screenshots or the three previews
  contain them. Keep it that way unless the licence is confirmed to cover
  marketing use.
- **The capture is date-sensitive.** History is generated relative to *today*,
  and the tour deliberately puts a lifting day on "yesterday" so the Insights and
  Profile "this week" headlines aren't `0 lbs`. Recapturing on a different
  weekday shifts those numbers.
- **Onboarding can win the race.** `--reset-store` occasionally re-arms the
  onboarding cover after the shell has rendered. `launchDemoApp` detects the
  welcome screen and relaunches rather than tapping through it, because
  dismissing onboarding also clears the starter slate the fixture depends on.
