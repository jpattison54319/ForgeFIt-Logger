# FF-001 — Localized Weight Parsing

**Status:** In Review
**Severity:** P1
**Owner:** DeepSeek V4 Flash 0731 — FF-001
**Source audit date:** 2026-08-10

## Problem

Weight input typed by the user is not parsed in a locale-safe, deterministic
way. Numeric parsing that naively strips commas misreads the decimal comma used
in many locales, so a legitimate fractional weight is corrupted to a much larger
integer.

## Confirmed trigger

- Set the device region to a locale that uses the comma as the decimal separator
  (for example `de_DE`).
- Type `72,5` into the strength-logging weight field (runner fast set entry) or
  into the quick-increment weight control.
- The entered value is stored/displayed as `725` instead of `72.5`.

## User impact

Strength weight logged or incremented is off by 100× whenever a decimal comma is
used. The athlete silently records the wrong load, which corrupts tonnage,
volume, and estimated 1RM, and can persist to CloudKit and HealthKit workouts.
Because weights are never auto-converted for display, the stored `725` is shown
as-is, and is very hard for the user to notice and correct.

## Source evidence

- `Fmt.loadKilograms` — the shared formatter/parser used by strength logging and
  quick increment. It strips the comma character as grouping noise instead of
  recognizing a decimal comma, per the audit.
- Strength logging runner weight field + quick-increment weight control call
  this parser, so both entry paths inherit the corruption.

## Scope

- In scope: the shared weight parser and both calling entry paths (runner fast
  set entry, quick increment), plus their tests.
- Out of scope: changing how weights are stored or displayed, or any kg↔lb
  conversion.

## Non-goals

- Not converting between display units (kg vs lb) anywhere — the invariant that
  "stored/display weight is already in the selected display unit" is preserved.
- Not redesigning the weight entry UI.
- Not changing the formatting output of `Fmt`, only its input parsing.

## High-level fix direction

Replace the comma-stripping parse with a locale-aware, deterministic parser that:
- accepts a decimal comma and a decimal point interchangeably as the decimal
  separator for a single fractional value,
- still honors valid digit-grouping separators so `1,000` stays `1000` and does
  not become `1.000`,
- produces the same numeric result regardless of device region (no dependence on
  the ambient `Locale.current` for the core identity),
- is unit-agnostic: it returns the numeric value only; display-unit selection
  remains untouched.

The parser must live in the shared formatting layer so both entry paths converge
on one code path. Wire it behind the existing `Fmt` entry points used by strength
logging and quick increment.

## Acceptance criteria

- [x] `72,5` (decimal comma) parses and stores/display as `72.5` in the selected
      display unit.
- [x] `72.5` (decimal point) parses to the same `72.5`.
- [x] `1,000` (digit grouping) still parses to `1000`, not a fractional value.
- [x] Stored/display weight remains in the user's selected display unit — no
      kg↔lb conversion introduced.
- [x] Parser yields identical results across representative decimal-comma and
      decimal-point locales.

## Required automated tests

- [x] Targeted parser tests for decimal comma, decimal point, grouping, and edge
      inputs, pinned to multiple locales (ForgeCore package tests).
- [x] Live-logger test: entering `72,5` in the runner weight field persists
      `72.5` (app-target or UI test as appropriate).

## Required runtime / hardware validation

- [x] Simulator (pinned `OS=26.5`) with a decimal-comma region: strength logging
      and quick increment both record the correct weight for typed `72,5`.
      (Satisfied by the corrected XCUITest rerun pinning `-AppleLocale de_DE` on a
      clean iOS 26.5 simulator — app-level locale; see residual note on device-region
      equivalence.)
- [ ] Hardware iPhone with the same region: same checks pass on-device.
      (Explicitly outstanding: `devicectl` reports James iPhone unavailable.)

## Dependencies

- None. Independent of FF-002 through FF-006; proceeds in Wave B.

## Worker work log

> Workers must update: status, owner, work log entries, files changed, tests
> requested AND run, and residual risks. Concede nothing is fixed without a
> running, named test or runtime check below.

### Work log

| Date | Status | Owner | Entry |
|------|--------|-------|-------|
| 2026-08-10 | Planned | Unassigned | Story filed. |
| 2026-08-11 | In Progress | DeepSeek V4 Flash 0731 — FF-001 | Claimed. Root cause confirmed in `Fmt.loadKilograms` (comma strip before `Double`). Both strength entry paths traced to it: runner weight field (`ActiveWorkoutLoggerView.commitWeightDraft`, `quickWeightBase`) and myo/activation block field + quick increment (`SetTypeBlocks`). Adding deterministic `WeightInputParser` to ForgeCore; `Fmt.loadKilograms` delegates to it with the unit conversion untouched. Tests added, **not executed** (file-edit worker, no shell). |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-001 | Implementation complete for manager review. `WeightInputParser` (ForgeCore) wired behind `Fmt.loadKilograms`; display-unit conversion untouched; ForgeCore parser suite and app-target entry-path suite added. Story sections (files changed, tests, residual risks) completed below. **No test, build, or runtime run of any kind was performed by the worker** — all commands below are requested, not executed. |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-001 | Adversarial-review rework applied: (1) finite guard added to the no-separator parse branch — digit strings that overflow `Double` now return `nil` so infinity can never reach model metrics, with overflow tests pinning it; (2) silent 1000× ambiguity removed — a single separator with exactly three trailing digits now returns `nil` for every shape except the acceptance-pinned round thousand `1,000`/`1.000` (one non-zero digit + three zeros), and `0,500`/`72,500`/`2,500`/`1,234` plus point twins are pinned to `nil`; (3) real-field XCUITest added in existing `ForgeFitUITests` that types the literal `72,5` into the production Weight field, commits, asserts the rendered `72.5`, then quick-increments the committed base; (4) `RoutineEditorView.OptionalDecimalField` inspected — callers are distance/climb/pace only (`IntervalPlanBuilderView`), not weight, confirmed out of FF-001 and unchanged; (5) story counts/logs/commands/residual risks updated. **Still no test, build, or runtime run by the worker.** |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-001 | Manager correction applied: `isPinnedRoundThousand` tightened to leading digit exactly `1` — the claim that only `1,000`/`1.000` is pinned is now true, and `2,000`–`9,000` plus point twins are rejected (`nil`) with comma and point test pins added. Rule-4 doc phrasing clarified ("trailing digit count other than exactly three is the decimal separator"). Corrected the recounted `WeightInputParserTests` total from 11 to **10** @Test functions in Files changed and the test command note. UI test and app-target tests untouched. **Still no test, build, or runtime run by the worker.** |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-001 | Manager executable review: combined targeted xcodebuild rerun **FAILED before tests** — exit 65, tests cancelled. Log `/tmp/forgefit-wave1-targeted-rerun.log`; result bundle `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1Rerun.xcresult`. Cause: `ForgeFitTests/LocalizedWeightEntryTests.swift` called `ModelContext.insert`/`save` without importing the defining module `SwiftData` (Member Import Visibility) — lines 24/43/82 (`insert`) and 30/48/89 (`save`). Fix applied: added `import SwiftData`. **Rerun required; no pass claimed.** |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-001 | Manager executable review: the FF-001 XCUITest **FAILED at its first post-blur assertion** — exit 65, one assertion failure. Log `/tmp/forgefit-ff001-ui.log`; result bundle `/tmp/forgefit-wave1-dd2.q3FBrz/FF001DecimalCommaUI.xcresult`; screen recording shows the production field visibly containing `72,5` after keyboard dismissal. Root cause is a test-oracle defect, not production: the shared `numericValue` helper strips commas as grouping, so the valid decimal-comma display read as 725 and the quick-increment step was never reached. Correction applied (test only, no production change): pinned the app to a decimal-comma locale (`-AppleLanguages (en) -AppleLocale de_DE`), added a FF-001-only decimal-comma-aware oracle (`decimalCommaValue`/`waitForDecimalCommaValue`) that does not touch the global helper, asserted the raw post-blur field text is a valid 72.5 representation and explicitly not `725`, added a refocus/reseed pass that re-sources the field from the committed model value, then runs the real quick-increment gesture requiring `75` (the legacy comma-strip parser would store 725 and land on 727.5). **Rerun required; no pass claimed.** |
| 2026-08-11 | In Review | DeepSeek V4 Flash 0731 — FF-001 | Manager execution evidence — all automated suites PASSED: (1) `DEVELOPER_DIR beta make -e test` exit 0, log `/tmp/forgefit-wave1-make-test-final.log` — ForgeCore **400 tests in 38 suites** passed, ForgeData **87 tests in 13 suites** passed, ForgeHealth/ForgeWorkoutSession/ForgeUI builds passed; (2) targeted app run on iOS 26.5 clean simulator exit 0 — **39 tests in 7 suites** passed, log `/tmp/forgefit-wave1-targeted-clean-sim.log`, result `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult` (includes `LocalizedWeightEntryTests`); (3) corrected FF-001 XCUITest rerun on iOS 26.5 with de_DE app locale exit 0 — **one test passed in 24.113 s**, log `/tmp/forgefit-ff001-ui-rerun.log`, result `/tmp/forgefit-wave1-dd2.q3FBrz/FF001DecimalCommaUIRerun.xcresult` — it typed `72,5`, blurred, refocused from the model, and quick-incremented to `75`; (4) iPhone simulator build exit 0, log `/tmp/forgefit-wave1-build-ios-rerun.log` (after an earlier no-space failure); (5) Watch simulator build exit 0, log `/tmp/forgefit-wave1-build-watch.log`. **Physical iPhone validation explicitly outstanding** — `devicectl` shows James iPhone and Apple Watch unavailable; **no hardware pass claimed.** |

### Files changed

Production:
- `Packages/ForgeCore/Sources/ForgeCore/WeightInputParser.swift` — **new**. Deterministic, locale-independent weight-input parser (unit-agnostic `parse(_:) -> Double?`). Rules documented in-file: whitespace trim + optional leading sign; ASCII digits/`,`/`.` only (rejects `1e3`, `nan`, `inf`, mid-string signs); **ambiguous single-separator three-digit shapes are rejected visibly with `nil`** — only the acceptance-pinned `1,000`/`1.000` (leading digit exactly `1`, then three zeros) is accepted as grouping; every other three-digit single-separator tail (`72,500`, `2,500`, `2,000`–`9,000`, `1,234`, `0,500`, and point twins) returns `nil` instead of guessing; any other trailing digit count is the decimal separator (`72,5` → 72.5, `72.5` → 72.5, `1,25` → 1.25); mixed separators → rightmost is decimal, every other must group exactly 3 digits or input is rejected (`1,234.5` → 1234.5, `1.234,5` → 1234.5, `72,5,3` → nil); multiple same-kind 3-digit groupings keep their integer reading (`1,234,567` → 1234567). **Both parse branches (separator and no-separator) reject non-finite results** — overflow digit strings return `nil`, so infinity can never reach model metrics. No `Locale.current` dependency.
- `ForgeFit/DesignSystem/Format.swift` — `Fmt.loadKilograms(from:unit:)` now delegates to `WeightInputParser.parse` and keeps the unchanged `unit.kilograms(fromDisplayValue:)` conversion. No other `Fmt` function, no formatting output, and no kg↔lb behavior changed; both strength entry callers are untouched and converge on this one entry point.
- `ForgeFitUITests/ForgeFitUITests.swift` — **modified**. Added `testTypedDecimalCommaCommitsAs72Point5AndQuickIncrements` (see Tests below).

Tests:
- `Packages/ForgeCore/Tests/ForgeCoreTests/WeightInputParserTests.swift` — **new**. 10 Swift Testing cases: decimal comma, decimal point equivalence, grouped thousands in both conventions (pinned `1,000`/`1.000` → 1000, `1,234,567` → 1234567), ambiguous single-separator three-digit rejection (`0,500`, `72,500`, `2,500`, `1,234`, `2,000`, `9,000` and their point twins → nil), integer-overflow rejection (400-digit strings, signed and separator forms → nil), mixed-separator rightmost-decimal rule, sign prefix-only, whitespace/whole numbers, malformed-input rejection (`72,5,3`, `72.5.3`, `12,34.5`, `,000`, `,`, `1 000`, `1e3`, `nan`, `inf`, `abc`), cross-convention determinism.
- `ForgeFitTests/LocalizedWeightEntryTests.swift` — **new**. 5 Swift Testing cases exercising the exact entry-path pipeline against a real `SetModel` via `TestStore.make()`: decimal-comma draft persists `modeWeight` 72.5 with `effectiveLoad` 72.5 / `totalVolume` 725 / e1RM ≈ 96.67 (tonnage and 1RM see 72.5, not 725); grouped `1,000` persists 1000; quick-increment base (`quickWeightBase` expression) parses `72,5` → 72.5 and `1,000` → 1000; lb display keeps the pre-existing `kilograms(fromDisplayValue:)` conversion for both separators; malformed `72,5,3` cannot persist a corrupted load. Kept unchanged per review.
- `ForgeFitUITests/ForgeFitUITests.swift` (test method above) — 1 XCUITest, corrected after the first failed run: launches the seeded live logger in kg pinned to a decimal-comma region (`--reset-store --seed-block-prefill-history --skip-onboarding --auto-start-routine -weightUnitRaw kg -AppleLanguages (en) -AppleLocale de_DE`), focuses the production Weight text field, clears its draft, types the literal `72,5`, dismisses keyboard to commit, asserts the RAW field text is a valid 72.5 kg representation (comma-aware oracle `decimalCommaValue`, accepting "72,5" or "72.5") and explicitly not `725`, refocuses once to force a model-backed reseed and re-asserts, then press-drags the quick-increment fan's middle positive band (+2.5 kg) and asserts the committed base advances to `75` (the legacy comma-strip parser would store 725 and land on 727.5, so this step discriminates). The global `numericValue`/`waitForNumericValue` helpers are unchanged and unused here because they strip commas as grouping.

Story:
- `docs/release-audit-remediation/stories/FF-001-localized-weight-parsing.md` — status/owner/work log/files/tests/residual risks updated (this file).
- Out-of-scope inspection (no change): `RoutineEditorView.OptionalDecimalField` (and its twin `OptionalIntField`) is used only by `IntervalPlanBuilderView` for cardio goal inputs — `goalDistance` (distance), `goalClimbMeters` (climb), and pace low/high; it is never a weight input. FF-001 leaves it alone; its own `,`→`.` replace parse is a separate, non-weight path.

### Tests requested / run

**Run by the worker: none.** The worker is a file-edit agent with no shell/build/test
permission; no test, build, or simulator run was executed by the worker, and no result is
claimed by the worker.

**Actual run (manager, 2026-08-11) — FAILED before tests:**
- Command: combined targeted xcodebuild rerun (ForgeCore + app-target + UI suites).
- Result: **exit 65**, tests cancelled; build failed before any test executed.
- Log: `/tmp/forgefit-wave1-targeted-rerun.log`
- Result bundle: `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1Rerun.xcresult`
- Cause: `ForgeFitTests/LocalizedWeightEntryTests.swift` used `ModelContext.insert` /
  `save` without importing the defining module `SwiftData` (Member Import Visibility) —
  `insert` at lines 24/43/82 and `save` at lines 30/48/89 reported "member APIs unavailable".
- Fix applied: added `import SwiftData` to that file.
- **Rerun required; no pass claimed.**

**Actual run (manager, 2026-08-11) #2 — FAILED at one UI assertion:**
- Command: FF-001 XCUITest on iOS 26.5 (`-only-testing:ForgeFitUITests/ForgeFitUITests/testTypedDecimalCommaCommitsAs72Point5AndQuickIncrements`).
- Result: **exit 65**, one assertion failure at `ForgeFitUITests.swift` (the first post-blur assertion); the quick-increment step was never reached.
- Log: `/tmp/forgefit-ff001-ui.log`
- Result bundle: `/tmp/forgefit-wave1-dd2.q3FBrz/FF001DecimalCommaUI.xcresult`
- Evidence: the screen recording showed only the field display — `72,5` visible after
  keyboard dismissal. The committed model was not yet established by that run; it was
  established on the corrected rerun by the successful refocus (production re-seed from
  the model value) and the quick-increment landing on `75`.
- Root cause is a test-oracle defect, not production: the shared `numericValue` helper strips commas as grouping, so the valid `72,5` read as 725.
- Fix applied (test only; no production change): pinned the app to a decimal-comma region (`-AppleLanguages (en) -AppleLocale de_DE`), added FF-001-only decimal-comma-aware helpers (`decimalCommaValue` / `waitForDecimalCommaValue`) that leave the global comma-stripping helpers untouched, assert the raw field text is a valid 72.5 representation and explicitly not `725`, refocus once for a model-backed reseed, then run the real quick-increment gesture requiring `75`.
- **Rerun required; no pass claimed.**

**Final runs (manager, 2026-08-11) — ALL PASSED:**
- `DEVELOPER_DIR beta make -e test` — **exit 0**. Log `/tmp/forgefit-wave1-make-test-final.log`.
  ForgeCore **400 tests in 38 suites** passed; ForgeData **87 tests in 13 suites** passed;
  ForgeHealth, ForgeWorkoutSession, ForgeUI builds passed.
- Targeted app run on iOS 26.5 clean simulator — **exit 0**, **39 tests in 7 suites** passed.
  Log `/tmp/forgefit-wave1-targeted-clean-sim.log`; result
  `/tmp/forgefit-wave1-dd2.q3FBrz/ForgeFitWave1CleanSim.xcresult`. Includes
  `LocalizedWeightEntryTests`.
- Corrected FF-001 XCUITest rerun on iOS 26.5 with de_DE app locale — **exit 0**,
  **one test passed in 24.113 seconds**. Log `/tmp/forgefit-ff001-ui-rerun.log`; result
  `/tmp/forgefit-wave1-dd2.q3FBrz/FF001DecimalCommaUIRerun.xcresult`. It typed `72,5`,
  blurred (committed), refocused from the model value, and quick-incremented to `75`.
- iPhone simulator build — **exit 0** (after an earlier no-space failure). Log
  `/tmp/forgefit-wave1-build-ios-rerun.log`.
- Watch simulator build — **exit 0**. Log `/tmp/forgefit-wave1-build-watch.log`.
- **Physical-device validation outstanding:** `devicectl` shows James iPhone and Apple
  Watch unavailable, so no hardware pass is claimed.

Requested for the manager (run in this order, from the repo root as defined in `AGENTS.md`):

1. ForgeCore package suite (fast, pure Swift — includes the new parser tests):
   `make test`
   - Runs `Packages/ForgeCore/Tests/ForgeCoreTests/WeightInputParserTests` (10 cases) alongside the
     existing ForgeCore guards and the ForgeData suites (`CloudKitCompatTests` is the
     schema guard — no schema change was made, so it must stay green).
2. ForgeFit app-target suite (builds the app; needs an installed simulator):
   `xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
     -only-testing:ForgeFitTests/LocalizedWeightEntryTests`
3. FF-001 XCUITest (real weight field + quick increment, requires an installed simulator):
   `xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
     -only-testing:ForgeFitUITests/ForgeFitUITests/testTypedDecimalCommaCommitsAs72Point5AndQuickIncrements`
   - Note: reset-store UI tests intermittently crash in CloudKit `ModelContainer` init
     (AGENTS.md known noise) — retry the failing test in isolation first.
4. Regression checks on the pre-existing weight formatting tests:
   `xcodebuild test -workspace ForgeFit.xcworkspace -scheme ForgeFit \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
     -only-testing:ForgeFitTests/ForgeFitTests`
   - `weightUnitFormatsAndParsesCanonicalKilograms` must still pass: `"220.5"` as lb →
     100 kg (parse of the decimal point is unchanged).
5. If any failure appears, first confirm it also fails on an unmodified checkout before
   treating it as a regression (AGENTS.md known-noise rules apply: ignore CloudKit
   account spam; keep the destination pinned to `OS=26.5`).

Test output reading note: app-target suites use Swift Testing — results appear as
`✔ Test run with N tests`, not "Executed N tests"; do not pipe through grep/tail and read
`$?` (that reads the pipe's exit code).

### Residual risks

- **Automated suites PASS (manager-run evidence, 2026-08-11):** ForgeCore 400 tests in
  38 suites and ForgeData 87 tests in 13 suites via `DEVELOPER_DIR beta make -e test`
  (exit 0); targeted app run on a clean iOS 26.5 simulator — 39 tests in 7 suites
  including `LocalizedWeightEntryTests` (exit 0); corrected FF-001 XCUITest rerun on
  iOS 26.5 with de_DE app locale — one test passed in 24.113 s (typed `72,5` → blur →
  refocus from model → quick-increment to 75); iPhone and Watch simulator builds exit 0.
  The two earlier failures (missing `import SwiftData`; UI test comma-stripping oracle)
  are resolved and now pass.
- **Physical-device validation outstanding:** `devicectl` reports James iPhone and Apple
  Watch unavailable, so the hardware iPhone check below is not satisfied and **no
  hardware pass is claimed**.
- **Simulator region nuance:** the decimal-comma simulator check was executed via
  `-AppleLocale de_DE` launch-argument pinning on a clean iOS 26.5 simulator, not by
  setting the device region in Settings. Functionally equivalent for the app's
  `Locale.current`; if the manager requires the device-region configuration instead, a
  region-set simulator run is still needed.
- **Amended evidence note:** the failed UI run's recording showed only the field display
  (`72,5` after dismissal); the committed model was established by the corrected rerun's
  refocus/reseed and quick-increment assertions.
- **Remaining runtime / hardware validation** (story's Required runtime / hardware
  validation): the simulator decimal-comma check is satisfied via the de_DE-locale XCUITest
  rerun (see the region-nuance bullet above); the **hardware iPhone check remains
  outstanding** — `devicectl` reports no reachable iPhone, so it must be run when a device
  is available.
- **Deliberate ambiguity policy (decision, not defect):** a single separator with exactly
  three trailing digits is ambiguous between the comma/point conventions and returns `nil`
  except for the acceptance-pinned `1,000`/`1.000` (leading digit exactly `1` + three
  zeros) which reads as 1000. `2,000`–`9,000` and point twins, `72,500`, `0.500`, and
  `1,234` are all rejected visibly. A user who types e.g. `1.234` or `2,500` (intending
  1.234 / 2.5 in one convention or 1234 / 2500 in the other) gets a rejected input and
  must retype unambiguously — a silent guess either way would 1000×-corrupt the load. Three
  trailing decimals never occur in real weight entry (plates step 0.25 kg / 0.5 lb; fields
  never seed 3 decimals), but this policy should be confirmed during review.
- **Stricter input acceptance:** `1e3` now parses to `nil` (previously 1000 via `Double`),
  and `nan`/`inf` now parse to `nil` (previously NaN/±inf could reach `setModeWeight`).
  These are deliberate no-coercion rules; flag if any flow ever feeds such text.
- **UI test locale / oracle (test-only design, production untouched):** the corrected
  XCUITest pins `-AppleLocale de_DE` with English UI (`-AppleLanguages (en)`) and reads the
  raw field text with a comma-aware oracle, because the app's `Fmt.load` renders weights
  through the ambient locale — in `de_DE` the committed 72.5 kg field legitimately reads
  `72,5`. The test accepts `72,5` or `72.5` and explicitly rejects `725`. The app's
  quick-increment band labels are hardcoded period strings (`"+2.5"` etc.) and do not
  localize, so a de_DE pinned run shows comma-formatted field values next to
  period-formatted fan labels — cosmetic coexistence, not a defect; confirm during review.
  The "Dismiss keyboard" toolbar button is a hardcoded-English custom control, so locale
  pinning does not break the dismiss query.
- **Out-of-scope callers inherit the parse:** `PlateCalculatorView`, `RoutineEditorView`,
  and `LogWeightSheet` also route through `Fmt.loadKilograms`. No regression identified by
  inspection, but none of the new suites covers them directly.
- **Status discipline:** the acceptance-criteria and required-automated-tests boxes above are
  checked from the manager's recorded passing evidence; Status stays **In Review**, and the
  DoD checkboxes, Verified, and Done below remain open until the manager completes the
  outstanding hardware validation and signs off. Workers never mark Verified or Done.

## Reviewer log

| Date | Reviewer | Verdict | Notes |
|------|----------|---------|-------|
| — | — | — | — |

## Definition of Done

- [ ] All acceptance criteria checked.
- [ ] Required automated tests added and passing via the named command.
- [ ] Required runtime / hardware validation executed and results recorded.
- [ ] Worker work log completed (status, owner, files changed, tests,
      residual risks).
- [ ] `Status` moved through Planned → In Progress → In Review → Changes
      Requested / Verified → Done.

## Final sign-off

> **Done and sign-off are set by the manager alone.** Workers never mark a story
> Done or sign it off.

- **Verified by (technically):**
- **Done set by (manager):**
- **Date:**
- **Release gate:** this story is / is not a blocker for the remediation release.