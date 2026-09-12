# Custom quick increments — September 11, 2026

Settings → Training → Quick increments now edits three increasing amounts for
reps, pounds, and kilograms. Each amount supplies both its positive and negative
fan choice. Save commits all groups; Reset to defaults restores the draft for
review before Save. Invalid groups show an inline error and disable Save.

| Group | Shipped defaults | Custom acceptance values |
| --- | --- | --- |
| Reps | 1, 2, 3 | 2, 6, 11 |
| Pounds | 2.5, 5, 7.5 | 0.25, 1.75, 12.25 |
| Kilograms | 1.25, 2.5, 3.75 | 0.1, 0.75, 4.5 |

Reps accept whole numbers; weights accept hundredths. Amounts must be positive,
distinct, increasing, and at most 1,000. Existing installs retain the shipped
defaults. The nine scalar preferences participate in the existing training
backup and account reset. There is no schema or health-data change.

The shared modifier reads the appropriate three AppStorage values. A recognized
hold still freezes its amounts, geometry, displayed base, and callback until
release. Drag tracking performs no preference writes or database work. Regular
sets, partial reps, block inputs, and guided Myo-Reps use the same preferences.
Ordinary Myo stepper buttons retain their existing single-tap behavior.

Pound load formatting now retains two decimal places, matching kilograms. This
prevents a custom quarter-pound adjustment from being rounded during the
existing display → draft → kilogram persistence path.

## Validation

- 23 focused app tests passed: controller behavior, custom arithmetic, preference
  reload/reset, invalid values, localized entry, and fresh-context weight/rep
  persistence. Log: `/tmp/forgefit-quick-tests.log`.
- 38 adjacent app tests passed: app formatting, weight modes, incomplete-set
  history, and Myo set flow. Log: `/tmp/forgefit-quick-replay.log`.
- Accessibility XXXL settings replay passed on the final build in 170 seconds:
  invalid-value feedback, disabled Save, Reset, all nine defaults after relaunch,
  and at least 44-point input heights.
- Existing ghost-base/keyboard/unit-switch and scroll-from-field UI regressions
  passed. Guided Myo-Reps custom weight and rep fan adjustments passed.
- Final settings persistence and 18-band logger replay passed in 305 seconds:
  all nine settings survived relaunch; all six options for each of kg, lb, and
  reps produced the expected value; a rep decrement stopped at zero. Log:
  `/tmp/forgefit-quick-complete.log`. Both final settings tests completed with
  zero failures; result bundle: `/tmp/forgefit-quick-complete.xcresult`.
- All three new scenarios are discovered by `scripts/acceptance_inventory.py`.
  The inventory is `/tmp/forgefit-quick-inventory.md`. The 15 acceptance-tool
  lint/outcome checks and `git diff --check` passed.

Every wrapped UI action records before/after screenshots and accessibility
trees under `/tmp/forgefit-quick-evidence/action-evidence/`. Tests run on the
iPhone 17 Pro simulator, iOS 26.5, with Xcode beta. Source and available action
evidence received the required independent `gpt-5.6-luna` review, including the
final custom-flow completion screenshots and accessibility checkpoints. It
found no production defect or acceptance finding. In total, 61 app tests and
five UI scenarios passed.

## Resolved verification issues and limits

The first UI attempt used a helper that center-tapped a right-aligned number
before deleting, placing the caret before the old digits. The helper now taps
the trailing edge. A later persistence attempt incorrectly relaunched with
`--reset-store`, which intentionally clears the canonical preferences; normal
relaunches now omit it. These were test setup failures.

Xcode's failure diagnostics exhausted disk space and interrupted result-bundle
finalization and a subsequent signing step. The separate logs and action
evidence were retained. Inactive September 8 iPhone build caches, compiler
module caches, and incomplete test bundles were removed. The final replay uses
`test-without-building`, disables verbose failure diagnostics, and sets a
600-second execution allowance (900-second maximum) for the screenshot-heavy
settings → relaunch → every-band scenario. It began with 2.1 GiB free and
finished with 2.0 GiB free.
Source, release archives, simulators, and unrelated microcycle edits were kept.

At this feature's acceptance run, the physical iPhone and Watch were unavailable.
The [build 99 follow-up](watch-sync-recovery-acceptance-2026-09-12.md) records the
subsequent iPhone installation and remaining device launch/Watch limitations.
Physical interaction, VoiceOver operation, and Instruments frame-time
measurements are not verified.
