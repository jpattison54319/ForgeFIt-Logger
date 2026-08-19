# ForgeFit 1.0 (56) — Final Release Review

**Review date:** 2026-08-11
**Branch:** `agent/liquid-glass-quick-action`
**Reviewed scope:** build 56 release worktree on top of `9f7c538`
**Verdict:** **GO for the stable Xcode Cloud gate; not yet cleared for App Review selection.**
**Source and automated-test gate:** **PASS, subject to the runtime boundaries below.**

The audit found and remediated the source-level defects tracked as FF-001 through
FF-020. The final pass also hardened startup persistence recovery, required
backup exclusion, HealthKit query cancellation/callback limits, Yoga terminal
save retry, and Watch workout recovery retry. No currently reproducible source
or automated-test failure remains in the audited paths.

The source release is ready to hand to the stable cloud archive gate. The
hosted privacy policy is current, and the audited app was signed, installed,
launched, and smoke-checked on the owner's physical iPhone. Stable-Xcode cloud
archive/processing, launch support copy, real iCloud file behavior, and the
hardware-specific iPhone/Watch paths remain separate submission checks.

## User hotspots covered

- Workout start/finish/discard exactly-once behavior, XP, Watch messages, and
  deferred HealthKit enrichment.
- Watch workout identity, terminal-command attribution, recovery serialization,
  and outdoor route restart/stale-location rejection.
- Yoga partial holds, finished-flow resume, logical pose count, checkpoints, and
  failed terminal-save retry.
- Health authorization denial/timeout recovery and cancellable, chunked,
  off-main 730-day aggregation with practical callback caps.
- Workout history time-zone/midnight filtering and outdoor interval splits.
- Backup deletion, rotation, allowed-key coverage, restore isolation/dedup, and
  the 1.0 automatic-backup privacy boundary.
- Startup store migration/failure handling: unreadable or unprotected stores are
  preserved behind a recoverable UI instead of deleted or crashing the app.

## Verification ledger

| Evidence layer | Result | Exact boundary |
|---|---|---|
| Static review | PASS | `git diff --check` clean; no production `fatalError`, `preconditionFailure`, or non-preview `try!` found in the audited trees. |
| ForgeCore | PASS | 418 tests / 38 suites; `/tmp/forgefit-forgecore-full.log`. |
| ForgeData | PASS | Latest pass: 50 XCTest tests plus 91 Swift Testing tests / 13 suites; `/tmp/forgefit-forgedata-backup-provenance.log`. Earlier full pass remains in `/tmp/forgefit-forgedata-full.log`. |
| ForgeFit app units | PASS | 896 tests / 134 suites; `** TEST SUCCEEDED **`; `/tmp/forgefit-final-unit-only.log`. |
| Latest focused regressions | PASS | Backup scheduling, Health provenance, and workout lifecycle: 18 tests / 3 suites; `** TEST EXECUTE SUCCEEDED **`; `/tmp/forgefit-backup-automation-focused.log`. Persistence/privacy 6/6; Health auth/query 18/18; Yoga retry 19/19; Health bounds 8/8 also passed. |
| Simulator UI | PARTIAL PASS | Persistence recovery XCUITest passed. Prior focused locale/UI evidence remains recorded in the stories. The broad 88-case UI/screenshot catalog was intentionally stopped after the 896-unit gate and one capture case passed; it is not claimed as a full UI-suite pass. |
| Generic/device builds | PASS WITH WARNINGS | iPhone + embedded Watch compiled and signed under Xcode 27 beta; `/tmp/forgefit-device-build.log`. This is not a stable release archive. |
| Physical iPhone | PARTIAL PASS | The audited build was installed and launched on James's iPhone 16 Pro Max; the owner reported the visible smoke check looked good. This does not prove the hardware-specific paths below. |
| Physical Watch / sensors | NOT RUN | No claim for GPS, WatchConnectivity terminal races, haptics/audio, Bluetooth, or paired recovery. |
| Stable archive/signing | NOT RUN | Only Xcode 27 beta is installed. No stable-Xcode archive or signed-entitlement inspection exists. |
| Upload / Apple processing / review | NOT RUN | No upload or App Store Connect state change was authorized or performed. |

The simulator emitted expected no-iCloud-account CloudKit and unpaired
WatchConnectivity messages. Xcode 27 also reports existing Swift 6 migration
and iOS 26 deprecation warnings while the project remains in Swift 5 mode.
Neither is represented as physical-device evidence.

## Submission blockers

1. **Stable release toolchain and archive.** Apple's July 2026 App Store Connect
   release notes say Xcode 27 beta builds are TestFlight-only. Install supported
   stable Xcode 26.6, archive 1.0 (56), validate the archive, and inspect the
   signed CloudKit entitlement/environment before selecting it for review. A
   stable-Xcode Xcode Cloud build is the chosen path because only Xcode 27 beta
   is installed locally. See Apple's
   [App Store Connect release notes](https://developer.apple.com/help/app-store-connect/release-notes/)
   and [submission requirements](https://developer.apple.com/app-store/submitting/).
2. **Public launch/support copy.** The live marketing page still says TestFlight
   beta; the support page provides only GitHub Issues and still uses beta
   language. Update both before submission. The privacy page is current and was
   deployed from site commit `e20b60d` on 2026-08-11. Apple's guidelines require
   complete/accurate metadata, an accessible support contact, and an accurate
   privacy policy: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
3. **Hardware-specific first-impression pass.** The physical iPhone install and
   owner smoke check passed. Still run Health permission denial/retry,
   background/kill recovery, outdoor GPS route, and Watch terminal races on a
   paired iPhone and Apple Watch.
4. **Persistence and iCloud evidence.** On a clean signed-in device, exercise
   automatic backup creation/deletion and restore against the real split-store
   configuration, then confirm startup migration/data preservation. Confirm the
   signed archive points at CloudKit Production.
5. **App Review policy interpretation.** The automatic backup excludes
   HealthKit-imported workouts and Health-derived fields, but it still contains
   user-entered fitness history and precise routes. Guideline 5.1.3(ii)'s iCloud
   health-information restriction should be resolved before review rather than
   assumed safe from DTO filtering alone.

## Residual risks that remain intentionally open

- Restore uses one isolated context and one save attempt, and deterministic
  pre-commit failures roll back cleanly in tests. Apple does not document a
  distributed atomic guarantee across multiple SQLite persistent stores, so a
  forced split-store device test remains required before FF-008 can be closed.
- Watch HealthKit builder termination and route recovery are hardware-dependent;
  simulator compilation and policy tests cannot prove system callback timing.
- The broad UI catalog was not completed in this final run. Its absence is not
  hidden by the green 896-test unit result.

## Final reviewer decision

The code gate is green and the owner-approved product behavior is implemented.
Proceed with build 56's stable Xcode Cloud archive, but do **not** select it for
App Review until the cloud build has succeeded and processed, signed
entitlements are confirmed, and the support/policy items above are resolved.
The public privacy correction was committed, pushed, deployed, and live-checked;
the physical development build was installed and launched successfully.
