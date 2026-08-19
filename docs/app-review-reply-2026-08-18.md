# Reply to App Review — 1.0 (59) rejection, 2026-08-18

Submission ID `5bd534d8-1577-41f8-b489-a9cd772002fa`. Paste the block below into
the App Store Connect message thread once build 74 is uploaded, with the two
video links filled in.

**Before sending:**

1. Record the two clips described in `docs/app-store-submission.md` §12.
2. Upload them somewhere Apple can reach without an account, and replace the
   `<LINK>` placeholders.
3. Paste the §9 review notes into App Review Information → Notes as well — the
   reply and the Notes field are read at different times.

---

```
Thank you for the detailed review. Build 74 addresses all four items.


GUIDELINE 5.1.1(iv) — HEALTHKIT PERMISSION REQUEST

Both issues are fixed. The Apple Health screen in onboarding now has a single
button labelled "Continue", and it always presents the system permission sheet.
The "Continue without Health" button has been removed entirely, so there is no
longer any way to dismiss the explanation without proceeding to the request.

The screen itself still explains what Health data is used for and states that
the data stays on device, but it no longer makes the choice on the user's
behalf — allowing or declining now happens only in Apple's own sheet, and both
outcomes continue into the app.


GUIDELINE 2.5.4 — bluetooth-central

Removed from UIBackgroundModes in build 74.

ForgeFit does contain a Core Bluetooth implementation for chest-strap heart rate
monitors, but we do not currently have the hardware to record it working as you
requested. Rather than declare a background mode we cannot demonstrate, we have
removed the background mode and hidden the pairing feature in this version. The
app no longer creates a CBCentralManager at all and never requests Bluetooth
permission. We will reintroduce the feature with a screen recording in a future
update.


GUIDELINE 2.5.4 — audio

This background mode is in active use, and we have attached a screen recording
made on a physical iPhone: <LINK>

ForgeFit speaks coaching cues during cardio sessions — split announcements
("Kilometer 3. Split 5 minutes 12 seconds."), pace-band cues, and heart-rate
zone cues. These are specifically for athletes who are running or riding with
the phone pocketed or on an armband, so they must be audible while the app is in
the background. The recording shows a cardio session in progress, then the Home
Screen, with the cues continuing to play.

The audio session is activated only around each spoken cue and released
immediately afterwards, with .duckOthers so the user's music returns to full
volume. There is no silent keep-alive.

To reproduce: start a cardio session on the Workout tab with an outdoor running
modality, then return to the Home Screen. Split announcements are enabled by
default and are spoken as each kilometre or mile completes.


GUIDELINE 2.1 — RECOVERY SCORE

The recovery score is in the binary. It is at: Home tab → the "Recovery" tile,
top-left of the four-tile grid. Tapping that tile opens "Recovery Today", which
shows the score, the HRV, sleeping-heart-rate and sleep readings behind it, and
a data-coverage row. The same score appears as per-day rings on Profile →
Calendar and on the Apple Watch complication.

The reason it was not visible during review is that ForgeFit deliberately
withholds the score until the user's own baseline can support it. It requires:

  - Apple Health access, and
  - at least 21 comparable overnight readings spanning at least 28 calendar
    days, across two signal domains, one of which must be autonomic (heart rate
    variability or resting heart rate).

Until those conditions are met, the tile reads "Building" and the detail screen
states exactly what is outstanding: "Baseline building — needs 21 comparable
readings spanning at least 28 days." A review device or simulator cannot meet
that condition, so the score correctly reads "Building" there. This is
intentional: the app does not display a health-related number it cannot support
with the user's own measured data.

The calculation lives in:

  - RecoveryIndexV2.swift — the index math that combines the signal domains
  - RecoveryScores.swift — the HRV, heart-rate and sleep assessments and their
    evidence gates, including the 21-reading / 28-day baseline requirement
  - RecoveryEngine.swift — report assembly and the displayed score

We have attached a screen recording made on a physical iPhone with real Health
history, showing the populated recovery score and the readings behind it:
<LINK>

Note also that the 5.1.1(iv) fix above means reviewers now always reach the
Health permission sheet during onboarding, so the Recovery tile will be present
as soon as access is granted.


Please let us know if anything further would help.
```
