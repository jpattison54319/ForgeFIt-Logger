# ForgeFit — Agent Guide

Native iOS/watchOS training app for hybrid athletes: strength, cardio, yoga,
and recovery in one system. SwiftUI + SwiftData, deep HealthKit/watchOS
integration, CloudKit sync. OS floor: iOS 26 / watchOS 26.

**Directory check:** the git root is THIS folder — the inner `ForgeFit/`
containing `ForgeFit.xcworkspace` and `.git`. The parent folder some sessions
launch in is *not* a repository. Run git and every command below from here.

## Commands

Package tests (fast, pure Swift — ForgeCore is domain math, ForgeData is the
SwiftData schema):

```bash
make test
```

App-target unit tests (builds the app; needs an installed iPhone simulator):

```bash
make test-app
```

Prefer single suites while iterating:

```bash
xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:ForgeFitTests/DailyReadinessTests
```

Build only: `make build-ios` / `make build-watch`. Watch **test** destinations
must use a simulator UDID (`platform=watchOS Simulator,id=<udid>`) — name-based
watch destinations often fail to resolve.

### Reading test output (traps)

- App tests use Swift Testing (`@Test`); results do NOT appear in the XCTest
  "Executed N tests" lines. Look for `✔ Test run with N tests` and
  `** TEST SUCCEEDED / FAILED **`, or trust the exit code.
- Don't pipe xcodebuild through `grep`/`tail` and then read `$?` — that's the
  pipe's exit code, not xcodebuild's. Redirect to a log file, capture the exit
  code, then grep the log. `-quiet` also swallows Swift Testing result lines.

### Known test noise (don't chase as regressions)

- `[CloudKit] ... CKAccountStatusNoAccount` spam in test logs is normal —
  simulators have no iCloud account.
- Keep simulator destinations pinned to a release OS (`OS=26.5`). A bare
  `name=iPhone 17 Pro` resolves to the newest installed runtime — the iOS
  27.0 beta — where full-suite runs stall 600 s in "collecting diagnostics"
  after the tests already passed, and have failed with "test runner never
  established connection". Targeted single-suite runs usually dodge it,
  which made the hang look suite-specific when it wasn't.
- Reset-store UI tests intermittently crash in CloudKit ModelContainer init.
  Retry the failing test in isolation before treating it as a regression.
- Before chasing any failure, confirm it also fails on an unmodified checkout.

## Writing code

- New Swift files under a target's folder compile automatically
  (file-system-synchronized groups). Never edit `project.pbxproj` to add files.
- New tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not
  XCTest. For SwiftData, use `TestStore.make()` from
  `ForgeFitTests/TestStore.swift` — never construct a raw `ModelConfiguration`
  in app tests (the factory carries the required `cloudKitDatabase: .none` and
  the container keep-alive rule).
- UI matches the existing Hevy-style design system: theme colors via
  `@Environment(\.theme)`, spacing/radii via `Space`/`Radius` tokens, `Card`
  containers, `PrimaryButton`/`SecondaryButton`. Fixed point font sizes are the
  project convention. Give interactive controls accessibility identifiers
  (kebab-case with context, e.g. `start-suggested-routine-<name>`).
- Comment style: doc comments state design intent and invariants, never
  narration of what the next line does.

## Hard invariants (never break)

- **Weights are already in the user's display unit.** Never convert kg↔lb for
  display; formatting goes through `Fmt` / `HistoricalSetPresentation`.
- **Every `@Model` must stay CloudKit-compatible**: inline default values on
  attributes, optional relationships. After ANY schema change, run the
  ForgeData package tests (`CloudKitCompatTests` is the guard). Ask before
  changing schema — CloudKit migrations are one-way in production. Not every
  model has `deletedAt`; check before filtering on it.
- **Health data never enters synced or backup payloads.** Heart rate, sleep,
  readiness, body weight, and check-ins stay on-device; CloudKit sync carries
  the training plan, and the iCloud Drive backup carries only logged training
  data. This is a privacy-policy promise, not a preference.
- **Coaching preview == start.** The dose shown in any coach review sheet must
  be exactly what starts when the user taps Start. Never fork those paths.
- **Honest framing.** User-facing scores appear only when evidence backs them
  (`Report.baselineReady`, measured-vs-estimated zone labels, "a coaching
  guide, not injury prediction"). Don't soften caveats away, and don't add
  false authority.
- `ForgeFit/Settings/PrivacyPolicyView.swift` mirrors `docs/privacy-policy.md`
  — change both or neither.

## Copy voice

- Confirmations state consequences, not reassurance.
- Setup instructions live where the action happens (Settings rows), never in
  onboarding or value props.
- One card answers one question. Info sheets: ~2-sentence explanation; keep
  their takeaway + evidence sections.

## More context

- `docs/01-architecture.md` — system architecture and data flow.
- `docs/EPICS.md` + `docs/epics/` — the epic board.
- `docs/user-value-action-plan.md` — current product priorities.
- `README.md` — human-facing overview (some sections lag the code).
