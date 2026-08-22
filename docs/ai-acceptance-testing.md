# AI acceptance testing

ForgeFit's acceptance harness separates deterministic execution from AI
judgment. XCTest owns the actions and functional checkpoints; an external
reviewer receives the saved screenshot, accessibility tree, scenario contract,
and observed state for each checkpoint. This makes a run replayable while
keeping subjective visual and experience review explicit.

Current triage from the latest run is tracked in
[`ai-acceptance-fix-list-2026-08-22.md`](ai-acceptance-fix-list-2026-08-22.md).

## Coverage model

The source inventory is the coverage contract for the current application. It
scans every `XCTestCase` method in `ForgeFitUITests` and
`ForgeFitWatch Watch AppUITests`, classifies each flow by capability and risk,
and does not call a source test covered merely because it exists.

```bash
make acceptance-inventory
```

The inventory currently includes the iPhone UI suite and the Watch UI suite.
Its `limitations` field is intentional: source coverage, a simulator pass, a
rendered screenshot, and physical-device behavior are separate evidence states.

The companion production-surface inventory scans the shipping Swift targets
for view declarations, navigation/presentation seams, route cases, and
accessibility identifiers. It compares those contracts with same-platform UI
test source and reports unreferenced contracts as coverage gaps:

```bash
make acceptance-surfaces
```

This is deliberately a coverage alarm rather than a green-light metric. A
single referenced identifier does not prove every view in its file is covered,
and a dynamic identifier is matched by prefix. Runtime status still comes from
the pinned XCTest run.

The normal acceptance sequence is:

1. Generate the source-backed inventory.
2. Launch each deterministic XCTest flow from a pinned simulator state.
3. Export screenshots and accessibility trees from the result bundle.
4. Join test outcomes to the inventory and produce actionable recommendations.
5. Review every saved checkpoint with an AI judge and keep confirmed defects,
   suspects, and environmental blockers separate.

## Human-like replay contract

The acceptance runner now records the interaction sequence, not just a few
milestone screenshots. When the runner creates its temporary
`/tmp/forgefit-acceptance/.capture-actions` marker, the iPhone and Watch UI
test targets wrap user-facing launches, taps, swipes, text entry, presses, and
drags. After each wrapped action the recorder waits briefly for the rendered
state to settle, then saves:

- a full-viewport PNG of exactly what the agent could see;
- the complete XCUITest accessibility tree at that moment;
- the target identifier, label, frame, source location, and previous
  checkpoint path;
- a machine-readable checkpoint in the scenario's `judge-request.json`.

The AI judge must inspect those checkpoints in order, including intermediate
screens, and may not review only the final state or a representative sample.
This is what allows it to catch a transient sheet, a duplicated visible row,
a stale label immediately after saving, a failed transition, or a control that
looks present but has an unusable target. The action sequence is evidence of
the seeded simulator state; it is not a substitute for physical-device,
HealthKit, WatchConnectivity, or WidgetKit-face evidence.

Action artifacts are stored under
`<run-root>/agent-evidence/action-evidence/<flow>/<run-id>/` by the full
runners. During focused iteration they remain under
`/tmp/forgefit-acceptance/action-evidence/`. Set
`FORGEFIT_ACCEPTANCE_SETTLE_SECONDS=0` only when diagnosing a timing issue;
the default short settle is intentional so the screenshot represents the
post-action UI rather than the first animation frame.

A failed assertion is reviewed against the last post-action screenshot and
tree before it is called a product defect. If the screenshot shows an empty,
loading, or otherwise invalid seeded state, the result is recorded as a
fixture/readiness failure. If the screenshot shows the correct user-visible
state but the assertion counted accessibility wrappers or used an unstable
selector, the test is repaired rather than changing product behavior.

The repository-level boundary audit is part of every full run. It checks that
the WidgetKit/complication targets, app-group entitlements, privacy manifests,
and cross-surface policy tests exist, while explicitly labeling physical-face,
real-HealthKit, and device-settings checks as `blocked` or `partial` until
those surfaces are exercised:

```bash
make acceptance-boundaries
```

## Run the representative tour

Use the pinned release simulator and the beta toolchain currently installed on
the development machine:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  make test-acceptance
```

Evidence is written under `/tmp/forgefit-acceptance/<scenario>/<run-id>/`.
The directory contains:

- `manifest.json` — environment, outcome, and artifact index.
- `judge-request.json` — complete machine-readable AI review input.
- `screenshots/*.png` — rendered checkpoints.
- `accessibility/*.txt` — XCUITest accessibility trees.

To summarize a run:

```bash
make acceptance-report RUN=/tmp/forgefit-acceptance/representative-app-tour/<run-id>
```

Use `--json` to print the judge request. Sending that request to a model is a
separate explicit operation; this local workflow never uploads screenshots or
application data by itself.

## Run the complete simulator matrix

Run both platforms and preserve separate run roots:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  make test-acceptance-all
```

`test-acceptance-all` runs the ForgeCore Watch/snapshot contract suite first,
then the iPhone and Watch UI runners. A contract failure and either UI
platform failure both fail the aggregate command, while the platform runners
still execute so the evidence remains useful.

Or run one platform while iterating:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  ./scripts/run_acceptance_all.sh       # iPhone, all ForgeFitUITests

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  ./scripts/run_acceptance_watch.sh     # Watch, all Watch UI tests
```

Each full run prints its `RUN_ROOT`, `REPORT`, `ATTACHMENTS`,
`AGENT_EVIDENCE`, `BOUNDARY_AUDIT`, `SURFACE_INVENTORY`, and `JUDGE_REQUEST`
paths. The report distinguishes `passed`, `failed`, `skipped`,
and `not-run`; it also reports how many flows have exported screenshots versus
functional-only evidence. Runner-created DerivedData is removed on exit to
keep repeated matrices from exhausting disk space; set
`FORGEFIT_KEEP_DERIVED_DATA=1` when build products are needed for debugging. A
failure in one platform does not prevent the other platform from running under
`test-acceptance-all`.

The runners enable Xcode's per-test timeout behavior by default so an app
main-thread hang becomes a recorded test failure instead of blocking the entire
matrix. The default allowance is 180 seconds and the hard maximum is 240
seconds; tune them for a slower environment with
`FORGEFIT_DEFAULT_TEST_EXECUTION_ALLOWANCE` and
`FORGEFIT_MAX_TEST_EXECUTION_ALLOWANCE`, or set
`FORGEFIT_TEST_TIMEOUTS_ENABLED=NO` only when investigating the timeout itself.

The XCTest evidence writer and action recorder use a stable fallback directory because
`xcodebuild` does not consistently forward arbitrary shell environment
variables into UI-test runners. The runner snapshots the pre-run manifests and
copies only manifests created by that run into its own `AGENT_EVIDENCE` folder,
so repeated runs do not mix evidence.

## Running an AI judge

The runner creates one aggregate `judge-request.json` at the run root from the
per-scenario requests. It contains the contract, artifact roots, screenshots,
accessibility trees, and the exact JSON response schema. An AI agent can read
that file and inspect the local evidence without any network upload. Save the
agent's single response object to a file and merge it into the report:

```bash
python3 scripts/acceptance_report.py \
  --xcode-log /tmp/forgefit-acceptance/full-run.<id>/xcodebuild.log \
  --inventory /tmp/forgefit-acceptance/full-run.<id>/inventory.json \
  --attachments /tmp/forgefit-acceptance/full-run.<id>/attachments \
  --evidence-root /tmp/forgefit-acceptance/full-run.<id>/agent-evidence \
  --boundary-audit /tmp/forgefit-acceptance/full-run.<id>/boundary-audit.json \
  --surface-inventory /tmp/forgefit-acceptance/full-run.<id>/surface-inventory.json \
  --judge-response /path/to/response.json \
  --platform ios \
  --output /tmp/forgefit-acceptance/full-run.<id>/report-with-judge.md
```

`acceptance_report.py` validates the outcome, finding categories, checkpoint
IDs, confidence range, and evidence paths. Invalid responses remain visible as
validation errors; they are never silently treated as a pass. For a single
scenario run, use `make acceptance-report RUN=... RESPONSE=...`.

## AI judge contract

For each deterministic scenario, the judge input is `judge-request.json`. It
contains the scenario purpose, the action and expected state for every
checkpoint, observed identifiers and labels, the screenshot path, and the
accessibility tree path. The judge should inspect all checkpoints and return
the schema included in that file:

```json
{
  "outcome": "pass | fail | suspect | blocked",
  "findings": [
    {
      "severity": "blocker | critical | major | minor | polish",
      "category": "functionality | visual | accessibility | copy | interaction | persistence | performance | privacy | watch-sync | reliability",
      "observation": "What was observed",
      "expected": "What the contract or platform convention requires",
      "actual": "What the evidence shows",
      "confidence": 0.0,
      "checkpointID": "checkpoint id",
      "evidencePaths": ["relative/path/to/evidence"]
    }
  ]
}
```

The agent must report observable evidence, not speculate about implementation.
Use `suspect` when the screenshot or interaction is concerning but does not
prove a defect; use `blocked` for an environmental or missing-permission gate.
Every finding should be actionable: reproduce the selector, identify the first
divergent checkpoint, name the expected behavior, and attach the smallest
useful evidence set.

## Adding a journey

Add a scenario contract to `AcceptanceScenarioCatalog`, then add a focused
XCTest method that performs its actions using stable accessibility identifiers.
Keep one scenario independent per launch. Seed data through existing DEBUG
fixtures and assert persistence from a fresh context when the journey changes
stored data. Simulator evidence does not establish physical iPhone, Watch,
HealthKit, or WidgetKit-face behavior.

When a flow changes persistent data, the contract should include a relaunch or
fresh-context checkpoint. When it crosses devices, record each boundary
separately: phone state, WatchConnectivity delivery, Watch app state, App Group
snapshot, WidgetKit timeline, and finally the rendered physical face. A correct
upstream snapshot is not proof that the user saw the correct complication.

The full matrix includes action-level simulator UI coverage for the app and
Watch, plus
contract evidence for snapshot serialization, calendar-day expiry, content-only
reload decisions, Watch identity, and interruption/relaunch behavior. It does
not claim that a WidgetKit timeline was scheduled, that a real HealthKit
permission was granted or revoked, or that a complication rendered on a
physical Watch. Those are explicit boundary gates in `boundary-audit.md`.

## Accessibility and visual review rules

The deterministic layer verifies interaction and state. The AI visual layer
must additionally inspect hierarchy, clipping, contrast, dynamic type, touch
targets, keyboard/focus behavior, loading/empty/error states, destructive
confirmation copy, and whether every important action has a visible path.
Hidden gestures may be noted as shortcuts but cannot be the only route to a
core action. Review screenshots at the actual target viewport; do not infer
physical-device rendering from a simulator-only image.

For a visual finding, cite the first action checkpoint where the rendered
state diverges and include the preceding action so the result is repeatable.
Do not infer a hidden defect from an accessibility count alone: compare unique
stable row identifiers with the screenshot and the accessibility tree. A
chart test, for example, is only a chart visual check when its deterministic
fixture contains the chart's persisted metric points; an intentional empty
state must be reported as such.
