# AI acceptance testing

ForgeFit's acceptance harness separates deterministic execution from AI
judgment. XCTest owns the actions and functional checkpoints; an external
reviewer receives the saved screenshot, accessibility tree, scenario contract,
and observed state for each checkpoint. This makes a run replayable while
keeping subjective visual and experience review explicit.

The harness is fail-closed about evidence, not merely test exit codes. A green
XCTest result with missing action evidence, an undeclared action contract, a
failed declared checkpoint, an unsupported schema, or a failed evidence gate is
not an acceptance approval.
Legacy flows that have not yet declared expectations are reported as
`unverified` until they are migrated.

Current triage from the latest run is tracked in
[`ai-acceptance-fix-list-2026-08-22.md`](ai-acceptance-fix-list-2026-08-22.md).

## Independent reviewer delegation

Every acceptance run must include a second, independent agent review of the
ordered action evidence. The primary agent still performs the deterministic
rendered-UI replay and owns the final synthesis:

- Model names are exact selections, not role labels. If a task requests Luna,
  Terra, or Sol, spawn the corresponding catalog model (`gpt-5.6-luna`,
  `gpt-5.6-terra`, or `gpt-5.6-sol`) and verify the selected ID with
  `codex debug models --bundled`; writing “you are Luna”, “you are Terra”, or
  “you are Sol” in a prompt while using another model does not satisfy this
  gate. For this acceptance workflow, Codex must spawn `gpt-5.6-luna`.
- Claude must spawn a separate subagent using an explicitly selected Sonnet
  model. Record the provider/model ID in the review notes; naming the agent
  “Sonnet” in the prompt while using another model does not satisfy this gate.

Give the reviewer the run's scenario contracts, screenshots, accessibility
trees, and observed functional results. Ask it to inspect every checkpoint in
order and report functional, visual, accessibility, performance, and
experience concerns with evidence paths. Keep the worker bounded to review and
findings; the primary agent integrates changes, reruns validation, and makes
the release decision.

The primary Codex agent remains responsible for the full replay and final
review. The Luna subagent is an independent second opinion, not a replacement
for running the app or inspecting the saved evidence.

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
Each method is also classified as `acceptance`, `functional`, `performance`,
or `capture`, and action-wrapped methods are marked `declared` or
`legacy-unverified` depending on whether they call `acceptanceExpect` or
`watchAcceptanceExpect`.
The inventory reports contract adoption per simulator suite, including the
unverified percentage, action-wrapper count, expectation count, and setup-gate
count. The checked-in adoption policy requires the representative iPhone and
three Watch journeys to remain fully contracted and fails if any suite's
unverified percentage rises above its baseline.

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

The acceptance runner records the interaction sequence, not just a few
milestone screenshots. When the runner creates its temporary
`/tmp/forgefit-acceptance/.capture-actions` marker, the iPhone and Watch UI
test targets wrap user-facing launches, taps, swipes, text entry, presses, and
drags. After each wrapped action the recorder waits for the app to return to a
foreground, non-busy state and saves:

- a full-viewport PNG of exactly what the agent could see;
- the complete XCUITest accessibility tree at that moment;
- the target identifier, label, frame, source location, and previous
  checkpoint path;
- a machine-readable checkpoint in the scenario's `judge-request.json`.

Every wrapped action must have a one-shot expectation declared immediately
before it:

```swift
acceptanceExpect(
    ["save-routine-button", "routine-detail"],
    visibleLabels: ["Push Day"]
)
saveButton.acceptanceTap()
```

Use `phase: .setup` for fixture/readiness work, `phase: .transition` for an
intermediate animation or navigation state, and `phase: .assertion` for the
product behavior being tested. Use `acceptanceRequire` for setup gates and
`acceptanceAssert` for product claims. Setup failures become `blocked`; an
assertion failure becomes `fail`; an action without a declared contract is
`unverified`, never an automatic pass.

The same vocabulary is available on Watch as `watchAcceptanceExpect` and the
`watchAcceptance...` action wrappers. For persistent or arithmetic behavior,
pass typed `AcceptanceOracle` checks; their pass/fail result is saved beside
the screenshots instead of asking a visual reviewer to infer persistence from
pixels.

The AI judge must inspect those checkpoints in order, including intermediate
screens, and may not review only the final state or a representative sample.
This is what allows it to catch a transient sheet, a duplicated visible row,
a stale label immediately after saving, a failed transition, or a control that
looks present but has an unusable target. The action sequence is evidence of
the seeded simulator state; it is not a substitute for physical-device,
HealthKit, WatchConnectivity, or WidgetKit-face evidence.

Action artifacts from a full run are stored under
`artifacts/acceptance/<git-commit>/<run-id>/agent-evidence/action-evidence/<flow>/<run-id>/`.
The directory is ignored by Git because screenshots, accessibility trees, and
result bundles are generated evidence, while the run records the commit hash
and dirty-worktree bit in its manifest. Focused runs may set
`FORGEFIT_ACCEPTANCE_ROOT` to a temporary directory. Set
`FORGEFIT_ACCEPTANCE_SETTLE_SECONDS=0` only when diagnosing a timing issue;
the default short settle is intentional so the screenshot represents the
post-action UI rather than the first animation frame.

`scripts/acceptance_tree_lint.py` parses the actual indented
`XCUIApplication.debugDescription` format and runs deterministic checks over
every saved tree: empty labels or placeholders on interactive controls,
sub-44-point frames, duplicate identifiers, and likely truncation. Each new
capture also appends a JSONL state snapshot containing `exists`, `hittable`,
`enabled`, and frame data for interactive elements. Touch-target findings are
limited to controls that are live, enabled, and hittable; legacy trees without
state metadata suppress only clearly collapsed dimensions below 10pt. Label
findings include the nearest identified ancestor and a breadcrumb, while SF
Symbol names, same-row subcontrol reuse, and identical repeated-row controls
are not treated as duplicate semantic identifiers. Its parser regression
fixture is run before every acceptance matrix so a format change cannot
silently turn lint into an empty result. The report includes the automated
findings; the AI reviewer handles the remaining visual and experience
judgment. Before/after pairs are the default evidence; video is intentionally
deferred to a small motion-focused pilot so the full matrix does not double
storage and timing pressure on every action.

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

This uses the same persistent runner as the full matrix, focused on the
representative tour. Evidence is written under
`artifacts/acceptance/<git-commit>/full-run.<id>/`.
The directory contains:

- `manifest.json` — environment, outcome, and artifact index.
- `judge-request.json` — complete machine-readable AI review input.
- `screenshots/*.png` — rendered checkpoints.
- `accessibility/*.txt` — XCUITest accessibility trees.

To summarize a run, read the generated report:

```bash
cat artifacts/acceptance/<git-commit>/full-run.<id>/report.md
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

Each full run prints its `RUN_ROOT`, `COMMIT`, `DIRTY`, `REPORT`, `ATTACHMENTS`,
`AGENT_EVIDENCE`, `BOUNDARY_AUDIT`, `SURFACE_INVENTORY`, `ADOPTION_GATE`,
`EVIDENCE_GATE`, and `JUDGE_REQUEST` paths. The report distinguishes `passed`, `failed`, `skipped`,
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

The runner writes a temporary marker because `xcodebuild` does not consistently
forward arbitrary shell environment variables into XCTest. The marker carries
the artifact root, commit, dirty state, rubric, and evidence requirement; it is
restored or removed on exit so repeated runs do not mix evidence. A direct
`xcodebuild` invocation that does not provide `GIT_COMMIT` records no commit
value and sets `commitUnknown: true`; such evidence is visibly unattributed
rather than being mistaken for release evidence.

The runners always require contracts for the checked-in allowlist in
`scripts/acceptance_adoption_policy.json`. Set
`FORGEFIT_ACCEPTANCE_REQUIRE_CONTRACTS=1` to require every legacy flow as well.
Until all flows have migrated to `acceptanceExpect` or `watchAcceptanceExpect`,
the report still exposes the unverified percentage and no unverified
checkpoint is treated as a pass.

## Running an AI judge

The runner creates one aggregate `judge-request.json` at the run root from the
per-scenario requests. It contains the contract, artifact roots, screenshots,
accessibility trees, and the exact JSON response schema. An AI agent can read
that file and inspect the local evidence without any network upload. Save the
agent's single response object to a file and merge it into the report:

```bash
python3 scripts/acceptance_report.py \
  --xcode-log artifacts/acceptance/<git-commit>/full-run.<id>/xcodebuild.log \
  --inventory artifacts/acceptance/<git-commit>/full-run.<id>/inventory.json \
  --attachments artifacts/acceptance/<git-commit>/full-run.<id>/attachments \
  --evidence-root artifacts/acceptance/<git-commit>/full-run.<id>/agent-evidence \
  --boundary-audit artifacts/acceptance/<git-commit>/full-run.<id>/boundary-audit.json \
  --surface-inventory artifacts/acceptance/<git-commit>/full-run.<id>/surface-inventory.json \
  --adoption-gate artifacts/acceptance/<git-commit>/full-run.<id>/adoption-gate.json \
  --evidence-gate artifacts/acceptance/<git-commit>/full-run.<id>/evidence-gate.json \
  --judge-request artifacts/acceptance/<git-commit>/full-run.<id>/judge-request.json \
  --judge-response /path/to/response.json \
  --platform ios \
  --fail-on-incomplete \
  --output artifacts/acceptance/<git-commit>/full-run.<id>/report-with-judge.md
```

`acceptance_report.py` validates the outcome, finding categories, checkpoint
IDs, confidence range, and evidence paths. Invalid responses remain visible as
validation errors; they are never silently treated as a pass. For a single
scenario run, use `make acceptance-report RUN=... RESPONSE=...`; it returns
nonzero when that scenario is not a passing acceptance result.

`scripts/acceptance_rubric.json` is the checked-in rubric and response schema.
`scripts/acceptance_judge.py` injects it into every per-scenario request,
audits before/after artifacts and accessibility trees, and runs the automated
tree lint. `scripts/acceptance_evidence_gate.py` then fails the runner when no
action evidence exists, artifacts are incomplete, requests are out of order,
an assertion checkpoint is `.fail`, or the strict contract mode finds an
uncontracted action. The runners invoke `acceptance_report.py
--fail-on-incomplete`, so the report and the runner both return nonzero when a
gate is incomplete even if XCTest itself exits successfully. The report still
writes the evidence summary before returning that failure.

## AI judge contract

For each deterministic scenario, the judge input is `judge-request.json`. It
contains the scenario purpose, the action and expected state for every
checkpoint, observed identifiers and labels, the screenshot path, and the
accessibility tree path. Action checkpoints also include before/after paths,
oracle results, and automated tree-lint findings. The judge should inspect all checkpoints and return
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

Whenever a new user flow, control, navigation path, gesture, or interaction
behavior is added or changed, add or update its deterministic acceptance test
in the same change. Wrap every user action, declare the expected post-action
state before the wrapper, and use the hardened helpers where applicable:
`acceptanceClearAndType`, `acceptanceTapScoped(in:)`, and
`acceptanceWaitForIdle()`. Queries should be scoped to the sheet/card/container
that owns the control; a bare label is not a stable contract when multiple
surfaces can contain it.

Do not classify a fixture lookup as a product assertion. Put seed/readiness
checks in `acceptanceRequire` or an explicit `.setup` expectation, and put the
behavior under test in `acceptanceAssert` or an `.assertion` expectation. This
keeps missing demo data, permissions, and simulator timing as blocked evidence
instead of false product failures.

If an expectation is declared but no wrapped action consumes it, or a second
expectation replaces it, the recorder writes `declaredButUnused` failure
evidence and fails the scenario. This prevents a conditional or early-returned
action from borrowing the next action's contract.

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
