# Watch complication: why the recovery score disappeared

Root-cause analysis and fix record. Analysed against **build 78** (`main` after
PR #7). An earlier revision of this document was written against `main` at build
50 and was stale in important ways — build 72 had already shipped part of the
fix on an unmerged branch. That correction is kept visible below.

## Verdict

This is a **production** failure, not a delivery or WidgetKit failure.

Build 72 fixed the delivery side properly. The complication expires its own data
(`ForgeFitWidgetSnapshot.isCurrent`), the watch asks the phone for a fresh
context on foreground (`requestContext`), and the phone uses Apple's
complication-priority channel with a change governor
(`transferCurrentComplicationUserInfo` + `WatchComplicationDeliverySignature`).

Those changes made the system **honest**: it stopped showing yesterday's number.
They did not make it **correct**, because nothing ever computed today's number
unless the user opened the phone app to the Home tab. The comment on the
`requestContext` handler says so outright — "readiness the phone hasn't computed
for today comes back absent, which is honest, instead of yesterday's number."

So the dumbbell is the honest answer to a question no one was answering. The
symptom changed from *wrong score* to *no score* because the lie was removed
while the gap behind it was left open.

## What build 72 already fixed — do not re-fix

| Was | Now |
|---|---|
| Complication rendered a stale score forever | `isCurrent()` day gate + a midnight timeline entry + `.after(min(periodic, nextDay))` |
| Watch never re-read on foreground | `scenePhase == .active` → `refreshComplication()` + `requestFreshContext()` |
| Watch could not ask for data | `WatchCommand.requestContext`, answered with a fresh-context publish |
| Application context was the only channel | `transferCurrentComplicationUserInfo`, gated on `isComplicationEnabled` and `remainingComplicationUserInfoTransfers`, deduped by `WatchComplicationDeliverySignature` |
| Context could carry yesterday's readiness | `isReadinessCurrent` / `currentReadiness*` gates on `WatchAppContext` |

## What was still broken at build 78, and what this change does

Defects 1–4 were found by analysis; 5 came out of review, as did the two
lifecycle defects and the account-reset regression noted in the PR. The pattern
worth carrying forward: every one of them was a *surface* that had been missed,
not a mechanism that had been misunderstood.

**1. The background recompute threw its result away.** `ReadinessDelivery` runs a
`BGAppRefreshTask` at 05:45 and `HKObserverQuery` background delivery on sleep +
HRV, and both computed a full `RecoveryEngine.Report` — then used it only to
title a notification. It never reached `RecoverySnapshotStore.recordToday`,
`ReadinessSurfacePublisher.publishFresh`, or `WatchLink.publishState`. Worse,
both notification early-returns (push disabled, already delivered today) skipped
the compute entirely.

*Fixed:* `refreshReadinessSurfacesNow()` computes and publishes independently of
the notification's gating, and hands its report to the notification pass so a
background wake never scores the day twice. It configures and activates the
Watch link first, because a background wake can run in a process that never
presented a scene — without that the publish silently no-ops on a nil context.
This is the change that makes a new day produce a score with the phone pocketed.

**2. Two paths blanked a score that still belonged to today.**
`ContentView.updateWidgetSnapshot`'s else-branch and
`WorkoutFinisher.cancelLiveRuntime` both wrote a bare
`ForgeFitWidgetSnapshot(mode: .idle)`, erasing whatever the background refresh
had published.

*Fixed:* a shared `ReadinessSurfacePublisher.publishIdle()`. It renders from the
dashboard cache when Home has drawn; otherwise it rebuilds from the day's
recorded **acute** index (`RecoverySnapshot.daily`, never the seven-day trend —
see defect 5); otherwise it keeps a current idle snapshot, but only one that is
completely empty (`shouldPreserveCurrentIdleSnapshot`); and only then publishes
an empty one. The middle fallback matters most on the workout-finish path, where
the store holds an `.activeWorkout` snapshot and the readiness fields are already
gone — preserving the snapshot alone would not have worked there.

**3. One logging session burned the day's complication reload budget.**
`WatchStore.publishComplicationSnapshot` called
`WidgetCenter.reloadTimelines` on every applied context. The phone's publish path
fires up to ~3×/s while logging (its own comment says so). Apple budgets 40–70
reloads per widget per 24 h, exempt only while the *containing* app is
foregrounded — which the watch app is not, mid-set.

*Fixed:* the snapshot is always saved (cheap, and keeps `updatedAt` accurate for
the complication's own day gate) but the reload is rationed: skipped when nothing
rendered differently, and mid-workout set progress additionally waits out a
60-second floor. Mode changes and readiness changes always pass, and
`refreshComplication()` forces a reload because foregrounding exists precisely to
retry one the system deferred.

**4. Opening the iPhone app pushed nothing to the wrist.**
`handleScenePhaseChange`'s `.active` branch called `updateWidgetSnapshot()` — the
iPhone's own widget — and never `WatchLink.publishState()`; the only
`publishState` sat in the `.background` branch.

*Fixed:* the `.active` branch publishes. The watch asks on its foreground; the
phone can only answer while running, and foregrounding is that moment.

**5. A seven-day trend was published as today's readiness.** `publishFresh` and
`idleSnapshot` published `RecoveryEngine.Report.displayScore`, which falls back
to the seven-day trend when the acute gate has not passed. Home discloses that
fallback three ways — a `"7-day trend · …"` caption, a grey tint, and no ring
fill — but the widget and complication rendered the same number as `"N% ready"`
over a filled gauge, and the watch app labelled it `"Readiness"` while inventing
its own verdict from the number (`readiness >= 70 ? "Ready to train"`), which the
wire protocol's own comment forbids: "the phone owns the daily verdict so the
watch never reinterprets bands". `WorkoutModel.readinessAtStart` could be stamped
from it too, persisting the claim into training history. This predates the branch
(`c98cc28`), but publishing from the background made it routine rather than rare.

*Fixed:* provenance travels with the number.
`ForgeFitWidgetSnapshot.ReadinessBasis` (`.daily` / `.trend`) and the matching
`WatchAppContext.readinessBasis` are set by every producer, day-gated by
`currentReadinessBasis()` alongside the score, and included in
`WatchComplicationDeliverySignature` so a basis flip earns its transfer. Each
face decides its own presentation from the basis — three-way, because `nil`
means an older producer did not say, and unknown provenance must not become a
"ready" claim. `apply(_:to:)` refuses to stamp anything but `.daily`.

## Ruled out — verified correct, don't spend time here

- **App group and entitlements.** `group.org.xpetsllc.ForgeFit` is in all four
  entitlements files. The `UserDefaults(suiteName:)` fail-soft trap is not
  triggered.
- **Target configuration.** Real WidgetKit extension
  (`NSExtensionPointIdentifier = com.apple.widgetkit-extension`), links ForgeCore,
  sets `CODE_SIGN_ENTITLEMENTS` in both configurations, embedded in the *watch
  app's* Embed Foundation Extensions phase.
- **Family coverage.** All four accessory families declared and rendered.
- **The snapshot codec.** Symmetric JSON, `.secondsSince1970` on both sides.
- **The watch app's own rendering** shares `WatchStore.context` with the
  complication, so the app screen and the face always agree — making the app a
  reliable observation point.

## What the platform guarantees

- `updateApplicationContext(_:)` **does not wake** the counterpart: "the system
  sends context data when the opportunity arises, with the goal of having the
  data ready to use by the time the counterpart wakes up."
- `transferCurrentComplicationUserInfo(_:)` requires `isComplicationEnabled`,
  which is `false` when the widget lives only in the Smart Stack rather than on a
  watch face (per Apple). ~50 transfers/day. An Apple engineer said in 2024 it
  "does not currently work with WidgetKit-based complications"; a July 2026 report
  says it does wake a backgrounded app on watchOS 26.5+. Useful, never sufficient
  alone — which is how build 72 uses it.
- **Reload budget:** "typically 40 to 70 refreshes" per widget per 24 h, exempt
  only when the containing app is foregrounded or on intent/animation/locale
  changes. Timeline entries should be ≥5 min apart.
- **Reference implementation:** LoopKit's `WatchDataManager` picks the channel per
  push and rate-governs the expensive one — the same shape as the fix here.

Sources: Apple docs for `updateApplicationContext(_:)`,
`session(_:didReceiveApplicationContext:)`, `transferCurrentComplicationUserInfo(_:)`,
`isComplicationEnabled`, `WKApplication.scheduleBackgroundRefresh`, and
"WidgetKit · Keeping a widget up to date"; developer.apple.com/forums threads
735352, 745581, 759389, 769864, 789024; LoopKit/Loop `WatchDataManager.swift`
and PRs 832/1217; nightscout/nightguard.

## How to confirm on device

- **Decisive test:** show `updatedAt` next to the score in the watch app. Older
  than the moment the iPhone computed today's score ⇒ the context never arrived.
  Current, but the complication still shows a dumbbell ⇒ the reload was refused.
- Watch the widget process in Console.app, `com.apple.widgetkit` subsystem, on the
  paired watch — budget-exhaustion messages appear there.
- Print `isComplicationEnabled` and `remainingComplicationUserInfoTransfers` from
  the phone: on a face (usable) vs. Smart Stack only (not).
- Reproduce the day boundary: no active workout, clear today's
  `RecoverySnapshotStore` entry, foreground the app, read the app-group snapshot.
- The real end-to-end check for this change: leave the phone untouched overnight
  with morning readiness notifications **off**. Before the fix that turned off the
  only compute path; after it, the 05:45 wake should still populate the wrist.
