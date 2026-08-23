#!/usr/bin/env python3
"""Summarize ForgeFit AI-acceptance evidence without network access.

The script deliberately prepares a judge request; sending it to a model is a
separate, explicit step so screenshots and accessibility trees remain local.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path, nargs="?", help="A scenario run directory")
    parser.add_argument("--xcode-log", type=Path, help="xcodebuild output for a full UI acceptance run")
    parser.add_argument("--inventory", type=Path, help="Inventory JSON from acceptance_inventory.py")
    parser.add_argument("--platform", choices=("ios", "watch", "all"), default="all")
    parser.add_argument("--attachments", type=Path, help="Exported xcresult attachment directory")
    parser.add_argument("--evidence-root", type=Path, help="Action-evidence artifact root")
    parser.add_argument("--boundary-audit", type=Path, help="Boundary audit JSON from acceptance_boundary_audit.py")
    parser.add_argument("--surface-inventory", type=Path, help="Production surface inventory JSON from acceptance_surface_inventory.py")
    parser.add_argument("--adoption-gate", type=Path, help="Contract-adoption gate JSON from acceptance_adoption_gate.py")
    parser.add_argument("--evidence-gate", type=Path, help="Evidence gate JSON from acceptance_evidence_gate.py")
    parser.add_argument("--judge-response", type=Path, help="AI judge response JSON to validate and merge")
    parser.add_argument("--output", type=Path, help="Write a Markdown report here")
    parser.add_argument("--json", action="store_true", help="Print the judge request JSON")
    args = parser.parse_args()

    if args.xcode_log:
        return report_xcode_run(
            args.xcode_log,
            args.inventory,
            args.attachments,
            args.evidence_root,
            args.boundary_audit,
            args.surface_inventory,
            args.adoption_gate,
            args.evidence_gate,
            args.judge_response,
            args.output,
            args.json,
            args.platform,
        )

    if not args.run:
        raise SystemExit("Provide a run directory or --xcode-log.")

    manifest_path = args.run / "manifest.json"
    judge_path = args.run / "judge-request.json"
    if not manifest_path.exists() or not judge_path.exists():
        raise SystemExit(f"Missing manifest.json or judge-request.json in {args.run}")

    manifest = json.loads(manifest_path.read_text())
    judge_request = json.loads(judge_path.read_text())
    if args.json:
        response, errors = load_judge_response(
            args.judge_response,
            checkpoint_ids={checkpoint["id"] for checkpoint in manifest.get("scenario", {}).get("checkpoints", [])},
            run_root=args.run,
        )
        if response is not None:
            judge_request["judgeResponse"] = response
        if errors:
            judge_request["judgeValidationErrors"] = errors
        print(json.dumps(judge_request, indent=2, sort_keys=True))
        return 0

    print(f"Scenario: {manifest['scenario']['title']}")
    print(f"Run:      {manifest['runID']}")
    print(f"Outcome:  {manifest['outcome']}")
    print(f"Evidence: {args.run}")
    print(f"Steps:    {manifest['checkpointCount']} ({manifest['failedCheckpointCount']} failed)")
    print("\nJudge input:")
    print(judge_path)
    if args.judge_response:
        response, errors = load_judge_response(
            args.judge_response,
            checkpoint_ids={checkpoint["id"] for checkpoint in manifest.get("scenario", {}).get("checkpoints", [])},
            run_root=args.run,
        )
        if errors:
            print("\nJudge response validation errors:")
            for error in errors:
                print(f"- {error}")
        elif response:
            print(f"\nJudge outcome: {response['outcome']} ({len(response['findings'])} findings)")
    print("\nReview each checkpoint screenshot and accessibility tree, then write findings using the schema requested in judge-request.json.")
    return 0


def parse_xcode_log(log_path: Path) -> tuple[dict[str, str], list[str], list[str]]:
    text = log_path.read_text(encoding="utf-8", errors="replace")
    results: dict[str, str] = {}
    # xcodebuild qualifies XCTest names with the test bundle/module, e.g.
    # ``-[ForgeFitUITests.ForgeFitUITests testLaunchPerformance]``. The
    # source inventory intentionally uses only ``Class/method`` so the same
    # report works for logs produced by xcodebuild, xctest, and focused runs.
    case_pattern = re.compile(
        r"Test Case '-\[([\w.]+) (test\w+)\]' (passed|failed|skipped)"
    )
    for match in case_pattern.finditer(text):
        class_name = match.group(1).rsplit(".", 1)[-1]
        results[f"{class_name}/{match.group(2)}"] = match.group(3)
    failures = []
    warnings = []
    known_environment_warnings = (
        "debugger version lookup failed",
        'xcrun: error: unable to find utility "simctl"',
    )
    for line in text.splitlines():
        stripped = line.strip()
        lower = stripped.lower()
        if any(warning in lower for warning in known_environment_warnings):
            warnings.append(stripped)
            continue
        if "Test Suite" in stripped and " failed at " in stripped:
            continue
        if stripped in {"** TEST FAILED **", "** TEST SUCCEEDED **"}:
            continue
        if "Test Case" in stripped and (" passed" in stripped or " failed" in stripped or " skipped" in stripped):
            continue
        if "error:" in lower or ("failed" in lower and "Test Case" not in stripped):
            failures.append(stripped)
    return results, failures[-80:], warnings[-40:]


def parse_failure_details(log_path: Path) -> dict[str, list[str]]:
    """Attach the first observed assertion/interaction errors to each flow."""

    details: dict[str, list[str]] = {}
    current_flow: str | None = None
    start_pattern = re.compile(r"Test Case '-\[([\w.]+) (test\w+)\]' started")
    end_pattern = re.compile(r"Test Case '-\[[^]]+ (test\w+)\]' (?:passed|failed|skipped)")
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        start = start_pattern.search(line)
        if start:
            class_name = start.group(1).rsplit(".", 1)[-1]
            current_flow = f"{class_name}/{start.group(2)}"
            details.setdefault(current_flow, [])
            continue
        if current_flow:
            stripped = line.strip()
            lower = stripped.lower()
            is_assertion = "error:" in lower or "failed:" in lower
            is_environment = any(
                marker in lower
                for marker in (
                    "debugger version lookup failed",
                    'unable to find utility "simctl"',
                    "failed to send ca event",
                )
            )
            if is_assertion and not is_environment:
                bucket = details[current_flow]
                if stripped not in bucket:
                    bucket.append(stripped)
            if end_pattern.search(line):
                current_flow = None
    return {flow: messages[:3] for flow, messages in details.items() if messages}


def normalize_test_identifier(identifier: str) -> str:
    """Convert xcresult's ``Class/test()`` name to the source inventory form."""

    return re.sub(r"\(\)$", "", identifier)


def load_visual_evidence(attachments_path: Path | None) -> dict[str, list[dict[str, str]]]:
    if not attachments_path:
        return {}
    manifest_path = attachments_path / "manifest.json"
    if not manifest_path.exists():
        return {}
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}

    evidence: dict[str, list[dict[str, str]]] = {}
    for test in manifest if isinstance(manifest, list) else []:
        test_id = normalize_test_identifier(str(test.get("testIdentifier", "")))
        if not test_id:
            continue
        for attachment in test.get("attachments", []):
            exported = attachment.get("exportedFileName")
            if not exported or not str(exported).lower().endswith(".png"):
                continue
            evidence.setdefault(test_id, []).append(
                {
                    "file": str(attachments_path / str(exported)),
                    "name": str(attachment.get("suggestedHumanReadableName") or exported),
                    "associatedWithFailure": str(bool(attachment.get("isAssociatedWithFailure", False))).lower(),
                }
            )
    return evidence


def load_agent_evidence(evidence_root: Path | None) -> dict[str, int]:
    """Count only complete action-sequence manifests.

    A manifest that contains only named milestone checkpoints is useful
    context, but must not inflate the post-action checkpoint count presented
    as human-like visual evidence.
    """

    if not evidence_root or not evidence_root.exists():
        return {}
    counts: dict[str, int] = {}
    for manifest_path in evidence_root.glob("**/manifest.json"):
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        scenario_id = str(
            manifest.get("scenario", {}).get("id", "")
            or manifest.get("scenarioID", "")
        )
        if scenario_id:
            checkpoints = manifest.get("scenario", {}).get("checkpoints", [])
            action_checkpoints = [
                checkpoint for checkpoint in checkpoints
                if isinstance(checkpoint, dict)
                and str(checkpoint.get("id", "")).startswith("action-")
            ]
            if not action_checkpoints or len(action_checkpoints) != len(checkpoints):
                continue
            checkpoint_count = manifest.get("checkpointCount")
            if checkpoint_count is None:
                checkpoint_count = len(action_checkpoints)
            counts[scenario_id] = counts.get(scenario_id, 0) + int(checkpoint_count)
    return counts


def load_agent_evidence_details(evidence_root: Path | None) -> dict[str, dict[str, int]]:
    """Return action-evidence quality metrics without counting milestone writers."""

    if not evidence_root or not evidence_root.exists():
        return {}
    details: dict[str, dict[str, int]] = {}
    for manifest_path in evidence_root.glob("**/manifest.json"):
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        scenario_id = str(manifest.get("scenario", {}).get("id", "") or manifest.get("scenarioID", ""))
        checkpoints = manifest.get("scenario", {}).get("checkpoints", [])
        action_checkpoints = [
            checkpoint for checkpoint in checkpoints
            if isinstance(checkpoint, dict) and str(checkpoint.get("id", "")).startswith("action-")
        ]
        if not scenario_id or not action_checkpoints or len(action_checkpoints) != len(checkpoints):
            continue
        try:
            judge_request = json.loads((manifest_path.parent / "judge-request.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            judge_request = {}
        evidence = judge_request.get("checkpointEvidence", [])
        unverified = int(manifest.get("unverifiedCheckpointCount", 0))
        if not unverified:
            unverified = sum(item.get("outcome") == "unverified" for item in evidence if isinstance(item, dict))
        contract_gaps = sum(
            not (
                item.get("checkpoint", {}).get("expectedVisibleIdentifiers")
                or item.get("checkpoint", {}).get("expectedVisibleLabels")
                or item.get("checkpoint", {}).get("invariants")
            )
            for item in evidence
            if isinstance(item, dict)
        )
        before_after = sum(
            bool(item.get("beforeScreenshotFile"))
            and bool(item.get("beforeAccessibilityTreeFile"))
            and bool(item.get("screenshotFile"))
            and bool(item.get("accessibilityTreeFile"))
            for item in evidence
            if isinstance(item, dict)
        )
        bucket = details.setdefault(scenario_id, {
            "checkpointCount": 0,
            "beforeAfterCount": 0,
            "unverifiedCheckpointCount": 0,
            "contractGapCount": 0,
        })
        bucket["checkpointCount"] += int(manifest.get("checkpointCount", len(action_checkpoints)))
        bucket["beforeAfterCount"] += before_after
        bucket["unverifiedCheckpointCount"] += unverified
        bucket["contractGapCount"] += contract_gaps
    return details


def load_agent_checkpoint_ids(evidence_root: Path | None) -> set[str]:
    """Return checkpoint IDs accepted by the artifacts in this run."""

    if not evidence_root or not evidence_root.exists():
        return set()
    checkpoint_ids: set[str] = set()
    for manifest_path in evidence_root.glob("**/manifest.json"):
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        for checkpoint in manifest.get("checkpoints", []):
            if isinstance(checkpoint, str):
                checkpoint_ids.add(checkpoint)
            elif isinstance(checkpoint, dict) and checkpoint.get("id"):
                checkpoint_ids.add(str(checkpoint["id"]))
        for checkpoint in manifest.get("scenario", {}).get("checkpoints", []):
            if isinstance(checkpoint, dict) and checkpoint.get("id"):
                checkpoint_ids.add(str(checkpoint["id"]))
    return checkpoint_ids


def load_boundary_audit(path: Path | None) -> dict:
    if not path or not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def load_surface_inventory(path: Path | None) -> dict:
    if not path or not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def load_evidence_gate(path: Path | None) -> dict:
    if not path or not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def load_adoption_gate(path: Path | None) -> dict:
    return load_evidence_gate(path)


JUDGE_OUTCOMES = {"pass", "fail", "suspect", "blocked"}
JUDGE_SEVERITIES = {"blocker", "critical", "major", "minor", "polish"}
JUDGE_CATEGORIES = {
    "functionality",
    "visual",
    "accessibility",
    "copy",
    "interaction",
    "persistence",
    "performance",
    "privacy",
    "watch-sync",
    "reliability",
}


def load_judge_response(
    path: Path | None,
    checkpoint_ids: set[str],
    run_root: Path,
) -> tuple[dict | None, list[str]]:
    """Validate an agent response without requiring a particular model."""

    if not path:
        return None, []
    if not path.exists():
        return None, [f"judge response does not exist: {path}"]
    try:
        response = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        return None, [f"judge response is not valid JSON: {error}"]
    if not isinstance(response, dict):
        return None, ["judge response must be a JSON object"]

    errors: list[str] = []
    outcome = response.get("outcome")
    if outcome not in JUDGE_OUTCOMES:
        errors.append(f"outcome must be one of {sorted(JUDGE_OUTCOMES)}")
    findings = response.get("findings")
    if not isinstance(findings, list):
        errors.append("findings must be an array")
        return response, errors

    for index, finding in enumerate(findings):
        prefix = f"findings[{index}]"
        if not isinstance(finding, dict):
            errors.append(f"{prefix} must be an object")
            continue
        if finding.get("severity") not in JUDGE_SEVERITIES:
            errors.append(f"{prefix}.severity is invalid")
        if finding.get("category") not in JUDGE_CATEGORIES:
            errors.append(f"{prefix}.category is invalid")
        for field in ("observation", "expected", "actual", "checkpointID"):
            if not isinstance(finding.get(field), str) or not finding[field].strip():
                errors.append(f"{prefix}.{field} must be a non-empty string")
        confidence = finding.get("confidence")
        if not isinstance(confidence, (int, float)) or isinstance(confidence, bool) or not 0 <= confidence <= 1:
            errors.append(f"{prefix}.confidence must be a number from 0 to 1")
        checkpoint_id = finding.get("checkpointID")
        if checkpoint_ids and checkpoint_id not in checkpoint_ids:
            errors.append(f"{prefix}.checkpointID is not present in this run: {checkpoint_id}")
        evidence_paths = finding.get("evidencePaths")
        if not isinstance(evidence_paths, list) or not evidence_paths or not all(isinstance(item, str) for item in evidence_paths):
            errors.append(f"{prefix}.evidencePaths must contain at least one path")
            continue
        for evidence_path in evidence_paths:
            candidate = Path(evidence_path)
            if candidate.is_absolute():
                exists = candidate.exists()
            else:
                exists = (run_root / candidate).exists()
                if not exists:
                    # Per-scenario requests describe paths relative to their
                    # artifact directory. Accept that form as well.
                    exists = any(
                        (manifest.parent / candidate).exists()
                        for manifest in run_root.glob("**/manifest.json")
                    )
            if not exists:
                errors.append(f"{prefix}.evidencePaths entry does not exist: {evidence_path}")
    return response, errors


def recommendations(flow: dict, status: str) -> list[str]:
    if status == "passed":
        if flow.get("visualEvidenceCount", 0) == 0 and flow.get("humanActionEvidenceCount", 0) == 0:
            return ["Functional simulator pass only; add action-level screenshots and accessibility checkpoints for visual/experience approval."]
        if flow.get("humanActionEvidenceCount", 0) > 0:
            return ["Review the complete action-by-action screenshot/accessibility sequence; simulator evidence is not physical-device proof."]
        if flow["evidenceTier"] == "simulator-ui":
            return ["Review the final screenshot/accessibility evidence; simulator pass is not physical-device proof."]
        return []
    if status == "skipped":
        return ["The selector was discovered but skipped; decide whether it is intentionally unavailable or restore a deterministic fixture and run it."]
    if status == "not-run":
        return ["Run the exact selector in isolation, then add a deterministic fixture and checkpoint if it remains uncovered."]
    capability = flow["capability"]
    if capability == "settings and data ownership":
        return ["Check persistence from a fresh ModelContext and verify the user-visible failure/recovery path."]
    if capability == "watch":
        return ["Trace phone → WatchConnectivity → Watch app → App Group → WidgetKit and repeat on paired hardware."]
    if capability == "recovery and health":
        return ["Repeat with authorized, denied, unavailable, stale, and missing HealthKit data; verify honest fallback copy."]
    if capability == "strength logging":
        return ["Reproduce from a clean fixture and verify set identity, terminal controls, timer behavior, and fresh-context persistence."]
    return ["Reproduce the selector in isolation, capture the first divergent checkpoint, and compare screenshot/accessibility evidence."]


def report_xcode_run(
    log_path: Path,
    inventory_path: Path | None,
    attachments_path: Path | None,
    evidence_root: Path | None,
    boundary_audit_path: Path | None,
    surface_inventory_path: Path | None,
    adoption_gate_path: Path | None,
    evidence_gate_path: Path | None,
    judge_response_path: Path | None,
    output: Path | None,
    as_json: bool,
    platform: str,
) -> int:
    if not inventory_path or not inventory_path.exists():
        raise SystemExit("--inventory is required for an xcode log report")
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    results, log_failures, environment_warnings = parse_xcode_log(log_path)
    failure_details = parse_failure_details(log_path)
    visual_evidence = load_visual_evidence(attachments_path)
    agent_evidence = load_agent_evidence(evidence_root)
    agent_evidence_details = load_agent_evidence_details(evidence_root)
    checkpoint_ids = load_agent_checkpoint_ids(evidence_root)
    judge_response, judge_validation_errors = load_judge_response(
        judge_response_path,
        checkpoint_ids=checkpoint_ids,
        run_root=log_path.parent,
    )
    boundary_audit = load_boundary_audit(boundary_audit_path)
    surface_inventory = load_surface_inventory(surface_inventory_path)
    adoption_gate = load_adoption_gate(adoption_gate_path)
    evidence_gate = load_evidence_gate(evidence_gate_path)
    flows = []
    for original in inventory["flows"]:
        if platform == "ios" and original["platform"] != "iOS Simulator":
            continue
        if platform == "watch" and original["platform"] != "watchOS Simulator":
            continue
        flow = dict(original)
        status = results.get(flow["id"], "not-run")
        flow["status"] = status
        flow["visualEvidence"] = visual_evidence.get(flow["id"], [])
        flow["visualEvidenceCount"] = len(flow["visualEvidence"])
        flow["humanActionEvidenceCount"] = agent_evidence.get(flow["id"], 0)
        flow["humanActionEvidenceDetails"] = agent_evidence_details.get(flow["id"], {})
        flow["evidenceStatus"] = "action-sequence" if flow["humanActionEvidenceCount"] else ("screenshot" if flow["visualEvidenceCount"] else "functional-only")
        flow["failureEvidence"] = failure_details.get(flow["id"], [])
        flow["recommendations"] = recommendations(flow, status)
        flows.append(flow)
    counts = {}
    for flow in flows:
        counts[flow["status"]] = counts.get(flow["status"], 0) + 1
    report = {
        "schemaVersion": 1,
        "log": str(log_path),
        "inventory": str(inventory_path),
        "counts": dict(sorted(counts.items())),
        "platform": platform,
        "flowCount": len(flows),
        "logFailures": log_failures,
        "environmentWarnings": environment_warnings,
        "failureDetails": failure_details,
        "visualEvidenceFlowCount": sum(flow["visualEvidenceCount"] > 0 for flow in flows),
        "visualEvidenceScreenshotCount": sum(flow["visualEvidenceCount"] for flow in flows),
        "agentEvidenceCheckpoints": sum(agent_evidence.values()),
        "humanActionEvidenceFlowCount": sum(flow["humanActionEvidenceCount"] > 0 for flow in flows),
        "agentEvidenceBeforeAfterCheckpoints": sum(
            flow.get("humanActionEvidenceDetails", {}).get("beforeAfterCount", 0)
            for flow in flows
        ),
        "unverifiedAcceptanceCheckpoints": sum(
            flow.get("humanActionEvidenceDetails", {}).get("unverifiedCheckpointCount", 0)
            for flow in flows
        ),
        "contractGapCount": sum(
            flow.get("humanActionEvidenceDetails", {}).get("contractGapCount", 0)
            for flow in flows
        ),
        "evidenceGate": evidence_gate,
        "adoptionGate": adoption_gate,
        "adoptionBySuite": inventory.get("adoptionBySuite", {}),
        "boundaryAudit": boundary_audit,
        "surfaceInventory": surface_inventory,
        "judgeOutcome": judge_response.get("outcome") if judge_response else None,
        "judgeFindings": judge_response.get("findings", []) if judge_response else [],
        "judgeValidationErrors": judge_validation_errors,
        "flows": flows,
    }
    if as_json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0
    lines = [
        "# ForgeFit AI acceptance run",
        "",
        f"Inventory flows: **{len(flows)}**",
        f"Results: **{counts.get('passed', 0)} passed**, **{counts.get('failed', 0)} failed**, **{counts.get('skipped', 0)} skipped**, **{counts.get('not-run', 0)} not run**.",
        f"Representative visual evidence: **{report['visualEvidenceScreenshotCount']} screenshots** across **{report['visualEvidenceFlowCount']} flows**.",
        f"Human-action visual evidence: **{report['agentEvidenceCheckpoints']} post-action checkpoints** across **{report['humanActionEvidenceFlowCount']} flows**; **{len(flows) - report['humanActionEvidenceFlowCount']} flows** have no action sequence.",
        f"Before/after action pairs: **{report['agentEvidenceBeforeAfterCheckpoints']}**; unverified action contracts: **{report['unverifiedAcceptanceCheckpoints']}**; contract gaps: **{report['contractGapCount']}**.",
        "",
        "## Evidence gate",
        "",
    ]
    if evidence_gate:
        gate_status = "COMPLETE" if evidence_gate.get("complete") else "INCOMPLETE"
        lines.append(f"Action evidence gate: **{gate_status}**.")
        if evidence_gate.get("reason"):
            lines.append(f"Gate reason: {evidence_gate['reason']}")
    else:
        lines.append("No evidence-gate result was supplied; this report is not an acceptance green light.")
    lines.extend(["", "## Contract adoption", ""])
    adoption = inventory.get("adoptionBySuite", {})
    if adoption:
        lines.extend([
            "| Suite | Instrumented flows | Declared contracts | Legacy-unverified | Unverified | Expectation calls | Setup calls |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ])
        for suite, summary in sorted(adoption.items()):
            lines.append(
                f"| `{suite}` | {summary.get('instrumentedFlows', 0)} | "
                f"{summary.get('declaredContractFlows', 0)} | "
                f"{summary.get('legacyUnverifiedFlows', 0)} | "
                f"{float(summary.get('unverifiedPercent', 0.0)):.2f}% | "
                f"{summary.get('expectationCallCount', 0)} | {summary.get('setupCallCount', 0)} |"
            )
    else:
        lines.append("No contract-adoption inventory was supplied.")
    if adoption_gate:
        adoption_status = "PASS" if adoption_gate.get("complete") else "FAIL"
        lines.append("")
        lines.append(f"Contract-adoption gate: **{adoption_status}**.")
        if adoption_gate.get("reason"):
            lines.append(f"Adoption gate reason: {adoption_gate['reason']}")
    lines.extend(["", "## Boundary evidence", ""])
    if boundary_audit:
        boundary_counts = boundary_audit.get("counts", {})
        lines.append(
            "Boundary audit: "
            + ", ".join(
                f"**{status} {boundary_counts.get(status, 0)}**"
                for status in ("covered", "partial", "blocked", "missing")
            )
            + "."
        )
        lines.extend(["", "| Boundary | Status | Limitation |", "|---|---|---|"])
        for boundary in boundary_audit.get("boundaries", []):
            limitation = str(boundary.get("limitation", "")).replace("|", "\\|")
            lines.append(f"| `{boundary.get('id', '')}` | **{boundary.get('status', '')}** | {limitation} |")
    else:
        lines.append("No boundary audit was supplied.")
    lines.extend([
        "",
        "## Production surface coverage",
        "",
    ])
    if not surface_inventory:
        lines.append("No production surface inventory was supplied.")
    else:
        surface_counts = surface_inventory.get("counts", {})
        lines.append(
            "Static source inventory: "
            f"**{surface_counts.get('surfaces', 0)} surfaces**, "
            f"**{surface_counts.get('routeCases', 0)} route cases**, "
            f"**{surface_counts.get('accessibilityContracts', 0)} accessibility contracts**."
        )
        lines.append(
            "Accessibility contracts: "
            f"**{surface_counts.get('sourceCoveredAccessibilityContracts', 0)} referenced**, "
            f"**{surface_counts.get('unreferencedAccessibilityContracts', 0)} unreferenced** by same-platform UI-test source."
        )
        lines.append("This is a source-coverage alarm; it is not proof of reachability or runtime success.")
        route_cases = surface_inventory.get("routeCases", [])
        unreferenced_routes = [route for route in route_cases if route.get("sourceCoverage") == "unreferenced"]
        if unreferenced_routes:
            lines.append("")
            lines.append("Unreferenced route cases: " + ", ".join(f"`{route.get('id', '')}`" for route in unreferenced_routes) + ".")
        unreferenced_ids = surface_inventory.get("unreferencedAccessibilityContracts", [])
        if unreferenced_ids:
            lines.extend(["", "First unreferenced accessibility contracts:"])
            for item in unreferenced_ids[:20]:
                lines.append(f"- `{item.get('identifier', '')}` in `{item.get('source', '')}:{item.get('line', '')}` ({item.get('platform', '')})")
    lines.extend([
        "",
        "## AI judge findings",
        "",
    ])
    if judge_response is None:
        lines.append("No AI judge response was supplied. The run is judge-ready; inspect the aggregate judge request and provide a response JSON.")
    else:
        lines.append(f"Judge outcome: **{judge_response.get('outcome', 'invalid')}**; findings: **{len(judge_response.get('findings', []))}**.")
        for finding in judge_response.get("findings", []):
            lines.append(
                f"- **{finding.get('severity', 'unknown')} / {finding.get('category', 'unknown')}** "
                f"at `{finding.get('checkpointID', 'unknown')}`: {finding.get('observation', '')} "
                f"Expected: {finding.get('expected', '')} Actual: {finding.get('actual', '')} "
                f"(confidence {finding.get('confidence', 0)}; evidence: {', '.join(finding.get('evidencePaths', []))})"
            )
    if judge_validation_errors:
        lines.extend(["", "Judge response validation errors:", ""])
        lines.extend(f"- {error}" for error in judge_validation_errors)
    lines.extend([
        "",
        "## Actionable findings",
        "",
    ])
    problem_flows = [flow for flow in flows if flow["status"] != "passed"]
    if not problem_flows:
        lines.append("No failed or missing selectors were found in the xcodebuild log.")
    else:
        for flow in problem_flows:
            lines.append(
                f"- **{flow['status']}** `{flow['id']}` ({flow['capability']}, {flow['risk']}): "
                + " ".join(flow["recommendations"])
            )
            if flow.get("failureEvidence"):
                lines.append(f"  First evidence: `{flow['failureEvidence'][0]}`")
        capability_counts: dict[str, int] = {}
        for flow in problem_flows:
            if flow["status"] == "failed":
                capability_counts[flow["capability"]] = capability_counts.get(flow["capability"], 0) + 1
        if capability_counts:
            lines.extend(["", "## Failed-flow distribution", "", "| Capability | Failed flows |", "|---|---:|"])
            lines.extend(
                f"| {capability} | {count} |"
                for capability, count in sorted(capability_counts.items(), key=lambda item: (-item[1], item[0]))
            )
    if log_failures:
        lines.extend(["", "## Relevant log lines", "", "```text", *log_failures, "```"])
    if environment_warnings:
        lines.extend(["", "## Environment warnings", "", "```text", *environment_warnings, "```"])
    rendered = "\n".join(lines) + "\n"
    if output:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")
    else:
        print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
