# Watch retry presentation and cardio audio

The reported Watch retry flashes and persistent Home banner had concrete lifecycle causes in the code. A temporary WatchConnectivity failure was immediately exposed to the UI, and canceling a retry did not clear its error. Cardio speech also had an audio-session race: asynchronous activation could outlive Stop, while completion/cancellation paths could miss deactivation or interfere with another announcer. These are source findings; no recording of the original physical incidents was available.

## Changed behavior

- Transient Watch transport failures get ten seconds of automatic recovery before showing Retry Sync. Success clears the pending presentation, so a delayed callback cannot flash it afterward. Protocol, payload, and storage failures remain actionable immediately.
- A new phone handoff from an already verified Home screen creates its own provisional workout and recovery window. Brief automatic HealthKit recorder retries stay quiet; permission problems, another workout, and retry exhaustion still need action.
- Finish, discard, Stop, and authoritative idle context clear the recovery error and invalidate pending callbacks. Sleeping-phone refresh failures remain quiet on Home. Idle retry exhaustion preserves actionable configuration errors while stopping background requests.
- Duplicate terminal commands and uncorrelated active snapshots for known-ended workouts are ignored using the existing bounded, persisted terminal ledger. They cannot restart recovery after finishing or interrupt the current workout. Fresh correlated replies still carry current configuration and storage errors.
- A reconnect expedites transient retry backoff without replacing a healthy pending request. An unchanged correlated snapshot can clear a failure, reverify context, and restart liveness monitoring; an older revision cannot do so.
- The retry loop publishes observable state only when presentation changes or a request is due. It uses the existing bounded retry clock; no view timer, additional polling stream, persistence operation, or unbounded queue was added.
- Heart-rate, pace, split, and goal speech now use `WorkoutCueSpeech` with `AVSpeechSynthesizer.usesApplicationAudioSession = false`. Enqueue, replacement, and Stop are synchronous. These callers no longer activate/deactivate the shared app session or depend on delegate callback timing to release it. Apple documents the system's management of speech interruptions, mixing, ducking, and session lifetime in [the API reference](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession) and [WWDC's speech synthesis session](https://developer.apple.com/videos/play/wwdc2020/10022/).
- Existing zone/pace haptics, quiet initial classification, debounce, split settings, and queued split/goal wording remain. Activating a new guard clears previous speech and its debounce window. Workout terminal cleanup continues to stop all three speech callers.

The change adds no schema, CloudKit payload, health-data log, backup field, or network service.

## Verification

Evidence root: `/tmp/forgefit-watch-audio-20260914`.

| Check | Result | Evidence |
| --- | --- | --- |
| ForgeCore | 514 tests, 48 suites passed | `/tmp/forgefit-watch-audio-core-tests.log` |
| ForgeData | 110 tests, 13 suites passed | `/tmp/forgefit-watch-audio-package-rest.log` |
| ForgeHealth, ForgeWorkoutSession, ForgeUI | Package builds passed | Same package log |
| iPhone app tests, iOS 26.5 | 1,389 tests, 197 suites passed | `phone-verified.xcresult` |
| Watch recovery integration, watchOS 26.5 | 25 test functions passed, including five terminal-path cases | `verified/watch.xcresult` and `verified/xcodebuild.log` |
| Watch UI acceptance, watchOS 26.5 | Six scenarios, 24 actions passed | `verified/watch.xcresult` |
| Screenshot/AX and contract gate | Complete for all 24 actions | `verified/evidence-gate.json` |
| Acceptance inventory | Six recovery scenarios declared | `verified/inventory.json` and `.md` |
| iPhone companion and Watch | Simulator compilation/linking passed | Final Watch and phone build logs |
| Source consistency | Changed source/test SHA-256 recorded; diff whitespace check passed | `tested-source-sha256.json` |

Recovery tests cover brief and sustained failures, successful quiet recovery, late callbacks after finish/discard/Stop, the fresh Home handoff, reconnect backoff, equal/older revisions, permission/configuration errors, and recorder retry exhaustion. Existing tests still cover stale starts, quarantined HR identity, terminal ordering, and delayed HealthKit saves.

The five speech tests exercise the production HR and pace guards, actual split and goal entry points, replacement/Stop without any completion callback, caller isolation, no late queued activation, and the native synthesizer's system-session configuration. They do not simulate another app's audio output.

UI replay covers quiet startup with an automatically supplied workout graph, quiet idle Home, finish through summary back to Home, persistent failure with Retry, confirmed Stop/Resume, and a pending Health save. Every wrapped action has before/after screenshots and accessibility state. Primary inspection confirmed quiet startup, visible exercises after recovery, usable persistent recovery controls, and readiness without a stale recovery banner after finishing.

Initial simulator attempts executed zero tests because Xcode's Watch service hub and the phone test-manager socket were stale. Restarting the affected simulators/services restored execution. Those attempts are not test passes. The first UI replay caught an incorrect screen expectation in the new swipe-down test; the final test explicitly visits Metrics and returns to Exercises, asserts the exercise is hittable, and passes in the complete replay.

## Review and limits

Independent acceptance review uses the repository-required `gpt-5.6-luna`, verified in the local model catalog. Its findings about reconnect backoff and known-ended messages restarting recovery were addressed with regression coverage. The reviewer inspected screenshots and accessibility evidence for quiet startup, clean Home, pending-save visibility, Retry, and Stop/Resume; no new control accessibility or visual defect was found in those flows.

The review recorded an existing cosmetic concern: the large Exercises navigation title touches the rest-pill border. It is visible in settled normal-workout screenshots as well as recovery screenshots; the AX frames meet at the navigation boundary. This layout was not changed here and does not block the recovery controls or exercise navigation. It remains a separate polish item.

Physical paired WatchConnectivity, locked-phone/earbud speech, YouTube ducking restoration, route interruptions, and ProMotion/Instruments traces remain unverified. Simulator and injected-transport results establish the app's state transitions and cancellation behavior; they do not establish radio timing, sensor delivery, Bluetooth output, or physical frame pacing. These changes have not been uploaded to TestFlight in this pass.

## Disk recovery

Removed the regenerable Xcode support cache at `/Users/jamespattison/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,2 27.0 (24A435)` (about 6.6 GB), then the task's temporary DerivedData at `/tmp/forgefit-watch-audio-derived` (about 1.8 GB) after validation finished. Source, simulator data, installed apps, personal files, test results, and acceptance screenshots were preserved. Final available space measured 9.8 GiB.
