# Watch complication: why the recovery score disappeared

Root-cause analysis, 19 Aug 2026. Analysed at `9e95467`. Nothing was compiled —
the analysis container is Linux with no Swift toolchain.

## Verdict

The complication code is not the bug. Entitlements, app group, target
embedding, and family coverage are all correct. When it draws a dumbbell it is
taking the `else` branch at `ForgeFitWatchComplication.swift:68` — "the snapshot
has no readiness score." That is a truthful report of its input.

Seven defects sit upstream, in three groups:

1. The score is **overwritten with `nil`** on the iPhone.
2. The score is **only ever produced while HomeView is on screen**.
3. Even a good score **cannot reach the watch face** — the only delivery channel
   needs the watch app running, and the wrist has spent its daily WidgetKit
   reload budget during the last workout.

"Always outdated score" and "dumbbell today" are the same bug at two stages.
Commit `c98cc28` fixed the stale number by clearing it, without adding any
mechanism to produce a fresh one. Absence replaced staleness.

## The seven defects

### Stage 1 — Produce

**1. The iPhone overwrites the score with `nil` when today's dashboard cache is
empty.** `ContentView.updateWidgetSnapshot()` (`ForgeFit/ContentView.swift`
:1444–1456) reads `RecoverySnapshotStore`, which is strictly same-day by design.
On a new day the `else` branch publishes a bare `ForgeFitWidgetSnapshot(mode:
.idle)` — every readiness field `nil`. It runs on `onAppear` (:1302), on every
`scenePhase == .active` (:989), and on reset (:1719). Before `c98cc28` this
function always built a live `ReadinessReportFactory.report(...)` and always had
a number. **Direct cause of the dumbbell.**

**2. Finishing a workout wipes it again, and the watch push reads the wiped
value.** `WorkoutFinisher.cancelLiveRuntime()` (:379) saves the same all-`nil`
idle snapshot. `finish()` (:317–318) issues the watch push *before* that
cleanup — but `publishState()` defaults to `.interactionDeferred`, debounced
500 ms (`DeferredInteractionWork.swift:12`). The wipe lands first; 500 ms later
`buildContext` reads the blanked store and sends `readiness: nil`. Same ordering
in `discard()` (:338–339) and `AccountResetService.swift:76–77`.

**3. The watch's readiness has exactly one source, and it only runs on the Home
tab.** `WatchLink.buildContext` (`ForgeFit/Health/WatchLink.swift`:196–199) does
not compute readiness — it reads it back out of the iPhone's app-group snapshot.
That snapshot gets a real score only from `ReadinessSurfacePublisher.publishFresh`
(`ReadinessSurfacePublisher.swift`:27–34), whose only caller is
`HomeView.refreshDashboardAnalytics` (`HomeView.swift`:297–298), driven by
`.task(id: analyticsRequestKey)` (:560). No Home tab, no score — anywhere.

**4. The phone already recomputes readiness in the background every morning and
throws the result away.** `ReadinessDelivery` runs a `BGAppRefreshTask` at 05:45
(:102–112) *and* `HKObserverQuery` background delivery on sleep + HRV (:126–151).
Both call `refreshMorningNotificationNow()`, which calls `computeReport()` (:200,
:260–272) and gets a complete `RecoveryEngine.Report` for today. That report
titles a notification and is then discarded — it never reaches
`RecoverySnapshotStore.recordToday`, never reaches `publishFresh`, never triggers
`WatchLink.publishState()`. Two early returns make it worse: if morning readiness
notifications are off (:171) or a readiness was already delivered today (:194),
`computeReport()` is never called at all. **Highest-leverage fix.**

### Stage 2 — Deliver

**5. One logging session burns the entire day's WidgetKit reload budget.**
`WatchStore.publishComplicationSnapshot` (`ForgeFitWatch Watch App/WatchStore.swift`
:449–473) calls `WidgetCenter.shared.reloadTimelines(ofKind:)` on every applied
context. `apply(context:)` (:414) runs on every `didReceiveApplicationContext`
(:593) and every `didReceiveMessage` carrying a context (:600). WatchLink's own
comment (`WatchLink.swift:124`) puts the publish rate at "up to ~3×/s during
logging." Apple's budget is 40–70 reloads per widget per 24 h, exempt only while
the *containing app* is in the foreground. Once spent, WidgetKit stops honouring
reloads — which is exactly "it never updates to the new day's score, even after
opening the watch app."

**6. Opening the watch app cannot pull a fresh context.** `WatchStore.activate()`
(:32–43) is called from `.task` on the root view — once per process. The received
application context is read only inside `activationDidCompleteWith` (:572–580),
which fires once per activation; `activate()` on an already-activated session
does nothing. The `scenePhase == .active` handler
(`ForgeFitWatchApp.swift`:22–30) only calls `recoverOrStartWorkoutSession()`.
`didReceiveUserInfo` (:610) handles commands only. And `WatchCommand` has no
state-request case, so the wrist cannot ask the phone for anything.

### Stage 3 — Render

**7. The complication never expires its own claim.** `ForgeFitWidgetSnapshot`
carries `updatedAt`; `getTimeline`
(`ForgeFitWatchComplication/ForgeFitWatchComplication.swift`:31–39) ignores it —
one entry, `.after(1 h)`, same number forever. This produced the original "always
outdated score." Under the honest-framing invariant, yesterday's number presented
as today's readiness is a false claim; the correct render is the no-score state.

## Ruled out — verified correct

- **App group and entitlements.** `group.org.xpetsllc.ForgeFit` is in all four
  entitlements files (iOS app, iOS widgets, watch app, watch complication). The
  `UserDefaults(suiteName:)` fail-soft trap is not triggered.
- **Target configuration.** Real WidgetKit extension
  (`NSExtensionPointIdentifier = com.apple.widgetkit-extension`), links ForgeCore
  via `packageProductDependencies` + a Frameworks build file, sets
  `CODE_SIGN_ENTITLEMENTS` in both configurations, and is embedded in the *watch
  app's* Embed Foundation Extensions phase.
- **Family coverage.** All four accessory families declared and rendered; the
  `default:` arm is unreachable.
- **The snapshot codec.** Symmetric JSON, `.secondsSince1970` on both sides.
- **The watch app's own rendering** shares `WatchStore.context`, so the app screen
  and the complication always agree — making the app a reliable observation point.

## What the platform guarantees

- `updateApplicationContext(_:)` **does not wake** the counterpart: "the system
  sends context data when the opportunity arises, with the goal of having the
  data ready to use by the time the counterpart wakes up." It is ForgeFit's only
  phone→watch channel, so the complication cannot update while the watch app is
  closed.
- `transferCurrentComplicationUserInfo(_:)` — the API for this job — appears
  nowhere in the codebase. It requires `WCSession.isComplicationEnabled` (false
  when the widget is only in the Smart Stack, per Apple), carries ~50
  transfers/day, and an Apple engineer stated in 2024 it "does not currently work
  with WidgetKit-based complications." A July 2026 report says it does wake a
  backgrounded watch app on watchOS 26.5+. Worth adopting; never as the only
  mechanism.
- **Reference implementation:** LoopKit's `WatchDataManager` picks the channel per
  push — `transferCurrentComplicationUserInfo` when `isComplicationEnabled` and a
  change/elapsed-time governor says so, `updateApplicationContext` otherwise.
- **Watch-side background refresh** (`WKApplication.scheduleBackgroundRefresh`) is
  real but budgeted, allows only one scheduled task at a time, and has open
  reports of `reloadAllTimelines()` no longer taking effect inside
  `WKRefreshBackgroundTask` on watchOS 11.1+ (FB16283024/FB16387355).
- **Reload budget:** "typically 40 to 70 refreshes" per widget per 24 h, exempt
  only when the containing app is foregrounded or on intent/animation/locale
  changes. Timeline entries should be ≥5 min apart.

Sources: Apple docs for `updateApplicationContext(_:)`,
`session(_:didReceiveApplicationContext:)`, `transferCurrentComplicationUserInfo(_:)`,
`isComplicationEnabled`, `WKApplication.scheduleBackgroundRefresh`, and
"WidgetKit · Keeping a widget up to date"; developer.apple.com/forums threads
735352, 745581, 759389, 769864, 789024; LoopKit/Loop `WatchDataManager.swift`
and PRs 832/1217; nightscout/nightguard.

## Fix plan

| Step | Change | Closes | Notes |
|---|---|---|---|
| A | Expire the score in `getTimeline`: no score when `updatedAt` isn't today; end the timeline at next local midnight instead of `.after(1 h)` | 7 | Needs no other process; satisfies honest framing at the surface making the claim |
| B | Stop publishing all-`nil` idle snapshots — preserve readiness fields, change only `mode`; reorder `finish()`/`discard()` so cleanup precedes the debounced publish (or make it `.immediate`) | 1, 2 | Safe once A judges staleness |
| C | Wire the existing background recompute into the surfaces: hoist `computeReport()` above the notification gating, then `recordToday(...)` + `publishFresh(report)` + `publishState(policy: .immediate)` | 3, 4 | Highest value — makes a new day produce a new score with the phone pocketed |
| D | Govern the wrist's `reloadTimelines`: reload only on real content change (normalise `updatedAt`, as `ReadinessSurfacePublisher.publish` already does) plus a hard floor between reloads | 5 | Without this the budget stays exhausted and every other fix is invisible |
| E | Re-apply `WCSession.default.receivedApplicationContext` on `scenePhase == .active` when its `updatedAt` beats what's held | 6 | Makes "open the watch app" finally do something |
| F | Add a watch→phone `requestState` `WatchCommand`, answered with `publishState(policy: .immediate)` | 6 | Closes the loop when the watch app opens and the phone is reachable |
| G | Adopt `transferCurrentComplicationUserInfo` Loop-style: gate on `isComplicationEnabled`, add a change+time governor, fall back to `updateApplicationContext`, teach `didReceiveUserInfo` to accept a context payload | latency | Last — least reliable link, and the likeliest place earlier attempts stalled |

## How to confirm on device

- Show `readiness` and `updatedAt` from `WatchStore.context` in a temporary watch
  app row — separates "the phone sent `nil`" from "the extension can't read the
  app group."
- Add `updatedAt` to the rectangular complication temporarily. Timestamp days old
  while the watch app shows a current one ⇒ the break is the reload budget.
- Watch the widget process in Console.app, `com.apple.widgetkit` subsystem, on the
  paired watch — budget-exhaustion messages appear there.
- Print `isComplicationEnabled` and `remainingComplicationUserInfoTransfers` from
  the phone before writing step G: on a face (usable) vs. Smart Stack only (not).
- Reproduce the day boundary directly: no active workout, clear today's
  `RecoverySnapshotStore` entry, foreground the app, read the app-group snapshot.
  That is defect 1 in isolation and should reproduce every time.
