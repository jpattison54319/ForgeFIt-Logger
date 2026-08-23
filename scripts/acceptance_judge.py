#!/usr/bin/env python3
"""Collect per-scenario evidence into one local AI-judge request.

This command intentionally does not call a model or upload artifacts. Any
agent can read the generated JSON, inspect the referenced local files, and
write a response JSON that acceptance_report.py validates and merges.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from acceptance_tree_lint import inspect_tree


RUBRIC_PATH = Path(__file__).with_name("acceptance_rubric.json")
RUBRIC = json.loads(RUBRIC_PATH.read_text(encoding="utf-8"))
RESPONSE_SCHEMA = RUBRIC["responseSchema"]
REQUEST_SCHEMA_VERSION = 3


def audit_request(
    request_path: Path,
    request: dict,
    required_contract_flows: set[str] | None,
) -> dict:
    """Verify that a judge request contains a complete visual sequence.

    The XCTest process is responsible for creating the artifacts; this audit
    prevents a later report from treating a manifest with missing screenshots,
    trees, or skipped action numbers as equivalent to a human-style replay.
    """

    request_root = request_path.parent
    missing_artifacts: list[str] = []
    sequence_warnings: list[str] = []
    contract_warnings: list[str] = []
    required_contract_warnings: list[str] = []
    checkpoint_failure_warnings: list[str] = []
    state_capture_warnings: list[str] = []
    schema_warnings: list[str] = []
    tree_lint: dict[str, list[dict[str, object]]] = {}
    tree_state_capture: dict[str, dict[str, object]] = {}
    checkpoint_ids: list[str] = []
    scenario_id = str(request.get("scenario", {}).get("id", ""))
    if request.get("schemaVersion") != REQUEST_SCHEMA_VERSION:
        schema_warnings.append(
            f"request schemaVersion is {request.get('schemaVersion')!r}; expected {REQUEST_SCHEMA_VERSION}"
        )
    if request.get("rubricID") not in (None, RUBRIC["id"]):
        schema_warnings.append(f"request rubricID is not {RUBRIC['id']!r}")
    if request.get("rubricVersion") not in (None, RUBRIC["version"]):
        schema_warnings.append(f"request rubricVersion is not {RUBRIC['version']}")
    request_root = request_root.resolve()
    for evidence in request.get("checkpointEvidence", []):
        if not isinstance(evidence, dict):
            schema_warnings.append("checkpointEvidence contains a non-object entry")
            continue
        checkpoint = evidence.get("checkpoint", {})
        if not isinstance(checkpoint, dict):
            schema_warnings.append("checkpointEvidence contains a checkpoint with the wrong shape")
            continue
        checkpoint_id = str(checkpoint.get("id", ""))
        if not checkpoint_id:
            schema_warnings.append("checkpoint has no id")
        elif checkpoint_id in checkpoint_ids:
            sequence_warnings.append(f"duplicate checkpoint id: {checkpoint_id}")
        checkpoint_ids.append(checkpoint_id)
        if evidence.get("outcome") == "fail":
            details: list[str] = []
            missing_identifiers = evidence.get("missingIdentifiers") or []
            missing_labels = evidence.get("missingLabels") or []
            if missing_identifiers:
                details.append("missing identifiers: " + ", ".join(map(str, missing_identifiers)))
            if missing_labels:
                details.append("missing labels: " + ", ".join(map(str, missing_labels)))
            oracle_results = evidence.get("oracleResults", [])
            oracle_results = oracle_results if isinstance(oracle_results, list) else []
            oracle_failures = [
                result.get("message", result.get("id", "oracle failed"))
                for result in oracle_results
                if isinstance(result, dict) and result.get("outcome") != "pass"
            ]
            if oracle_failures:
                details.append("oracle: " + "; ".join(map(str, oracle_failures)))
            suffix = f" ({'; '.join(details)})" if details else ""
            checkpoint_failure_warnings.append(
                f"{checkpoint_id}: declared checkpoint outcome is fail{suffix}"
            )
        fields = ["screenshotFile", "accessibilityTreeFile"]
        if checkpoint_id.startswith("action-"):
            fields.extend(["beforeScreenshotFile", "beforeAccessibilityTreeFile"])
        for field in fields:
            relative_path = evidence.get(field)
            if not relative_path:
                missing_artifacts.append(f"{checkpoint_id}: missing {field}")
                continue
            relative = str(relative_path)
            candidate = (request_root / relative).resolve()
            try:
                candidate.relative_to(request_root)
            except ValueError:
                missing_artifacts.append(f"{checkpoint_id}: unsafe evidence path {relative}")
                continue
            if not candidate.is_file():
                missing_artifacts.append(f"{checkpoint_id}: {relative}")
            elif field.lower().endswith("accessibilitytreefile"):
                evidence_key = f"{checkpoint_id}:{field}"
                inspection = inspect_tree(candidate)
                tree_lint[evidence_key] = list(inspection["findings"])
                tree_state_capture[evidence_key] = {
                    key: value
                    for key, value in inspection.items()
                    if key != "findings"
                }
                if checkpoint_id.startswith("action-") and not inspection["stateCaptureComplete"]:
                    warnings = inspection.get("stateCaptureWarnings", [])
                    detail = "; ".join(map(str, warnings)) or "unknown state-capture failure"
                    state_capture_warnings.append(f"{evidence_key}: {detail}")

        if checkpoint_id.startswith("action-"):
            declared = (
                checkpoint.get("expectedVisibleIdentifiers")
                or checkpoint.get("expectedVisibleLabels")
                or checkpoint.get("invariants")
            )
            if not declared:
                warning = f"{checkpoint_id}: no expected identifiers, labels, or invariants"
                contract_warnings.append(warning)
                if required_contract_flows is None or scenario_id in required_contract_flows:
                    required_contract_warnings.append(warning)
            if evidence.get("outcome") == "pass" and not declared:
                warning = f"{checkpoint_id}: pass outcome has no declared contract"
                contract_warnings.append(warning)
                if required_contract_flows is None or scenario_id in required_contract_flows:
                    required_contract_warnings.append(warning)
        if evidence.get("outcome") == "pass" and (
            evidence.get("missingIdentifiers") or evidence.get("missingLabels")
        ):
            warning = f"{checkpoint_id}: pass outcome contains missing expectations"
            contract_warnings.append(warning)
            if required_contract_flows is None or scenario_id in required_contract_flows:
                required_contract_warnings.append(warning)

    action_numbers = []
    for checkpoint_id in checkpoint_ids:
        match = re.fullmatch(r"action-(\d+)", checkpoint_id)
        if match:
            action_numbers.append(int(match.group(1)))
    if action_numbers:
        expected = list(range(1, len(action_numbers) + 1))
        if sorted(action_numbers) != expected:
            sequence_warnings.append(
                f"action checkpoints are not contiguous from action-0001: {action_numbers}"
            )

    return {
        "scenarioID": scenario_id,
        "checkpointCount": len(checkpoint_ids),
        "complete": not missing_artifacts and not sequence_warnings and not contract_warnings and not checkpoint_failure_warnings and not state_capture_warnings and not schema_warnings,
        "releaseComplete": not missing_artifacts and not sequence_warnings and not required_contract_warnings and not checkpoint_failure_warnings and not state_capture_warnings and not schema_warnings,
        "artifactComplete": not missing_artifacts,
        "contractComplete": not contract_warnings,
        "requiredContractComplete": not required_contract_warnings,
        "checkpointFailureComplete": not checkpoint_failure_warnings,
        "stateCaptureComplete": not state_capture_warnings,
        "schemaComplete": not schema_warnings,
        "missingArtifacts": missing_artifacts,
        "sequenceWarnings": sequence_warnings,
        "contractWarnings": contract_warnings,
        "requiredContractWarnings": required_contract_warnings,
        "checkpointFailureWarnings": checkpoint_failure_warnings,
        "stateCaptureWarnings": state_capture_warnings,
        "schemaWarnings": schema_warnings,
        "treeLint": tree_lint,
        "treeStateCapture": tree_state_capture,
    }


def collect(
    run_root: Path,
    contract_policy_path: Path | None = None,
    require_all_contracts: bool = False,
) -> dict:
    required_contract_flows: set[str] | None
    if require_all_contracts or contract_policy_path is None:
        required_contract_flows = None
    else:
        policy = json.loads(contract_policy_path.read_text(encoding="utf-8"))
        required_contract_flows = {
            str(flow_id) for flow_id in policy.get("requiredContractFlows", [])
        }
    requests = []
    audits = []
    for path in sorted(run_root.glob("**/judge-request.json")):
        if path == run_root / "judge-request.json":
            continue
        try:
            request = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue
        if not isinstance(request, dict) or "scenario" not in request:
            continue
        request = dict(request)
        request["artifactRoot"] = str(path.parent.relative_to(run_root))
        audit = audit_request(path, request, required_contract_flows)
        request["rubricID"] = RUBRIC["id"]
        request["rubricVersion"] = RUBRIC["version"]
        request["rubric"] = RUBRIC
        request["judgeInstructions"] = RUBRIC["instructions"]
        request["responseSchema"] = RESPONSE_SCHEMA
        request["evidenceAudit"] = audit
        audits.append(audit)
        requests.append(request)

    if not requests:
        raise SystemExit(f"No per-scenario judge-request.json files found below {run_root}")

    checkpoint_count = sum(
        len(request.get("checkpointEvidence", []))
        for request in requests
    )
    return {
        "schemaVersion": REQUEST_SCHEMA_VERSION,
        "type": "ForgeFitAcceptanceJudgeRequest",
        "runRoot": str(run_root),
        "scenarioCount": len(requests),
        "checkpointCount": checkpoint_count,
        "evidenceAudit": {
            "complete": all(audit["complete"] for audit in audits),
            "releaseComplete": all(audit["releaseComplete"] for audit in audits),
            "artifactComplete": all(audit["artifactComplete"] for audit in audits),
            "contractComplete": all(audit["contractComplete"] for audit in audits),
            "requiredContractComplete": all(audit["requiredContractComplete"] for audit in audits),
            "checkpointFailureComplete": all(audit["checkpointFailureComplete"] for audit in audits),
            "stateCaptureComplete": all(audit["stateCaptureComplete"] for audit in audits),
            "schemaComplete": all(audit["schemaComplete"] for audit in audits),
            "sequenceComplete": all(not audit["sequenceWarnings"] for audit in audits),
            "scenarioAudits": audits,
            "incompleteScenarioCount": sum(not audit["complete"] for audit in audits),
            "uncontractedCheckpointCount": sum(len(audit["contractWarnings"]) for audit in audits),
            "requiredUncontractedCheckpointCount": sum(
                len(audit["requiredContractWarnings"]) for audit in audits
            ),
            "checkpointFailureCount": sum(
                len(audit["checkpointFailureWarnings"]) for audit in audits
            ),
            "checkpointFailureWarnings": [
                warning
                for audit in audits
                for warning in audit["checkpointFailureWarnings"]
            ],
            "stateCaptureWarningCount": sum(
                len(audit["stateCaptureWarnings"]) for audit in audits
            ),
            "stateCaptureWarnings": [
                warning
                for audit in audits
                for warning in audit["stateCaptureWarnings"]
            ],
            "stateCaptureTreeCount": sum(
                len(audit["treeStateCapture"]) for audit in audits
            ),
            "stateRecordCount": sum(
                int(tree.get("stateRecordCount", 0))
                for audit in audits
                for tree in audit["treeStateCapture"].values()
            ),
            "touchTargetCandidateCount": sum(
                int(tree.get("touchTargetCandidateCount", 0))
                for audit in audits
                for tree in audit["treeStateCapture"].values()
            ),
            "conservativeStateRecordCount": sum(
                int((tree.get("stateSummary") or {}).get("conservativeRecordCount", 0))
                for audit in audits
                for tree in audit["treeStateCapture"].values()
                if isinstance(tree.get("stateSummary"), dict)
            ),
            "stateCaptureDurationMilliseconds": sum(
                int((tree.get("stateSummary") or {}).get("durationMilliseconds", 0))
                for audit in audits
                for tree in audit["treeStateCapture"].values()
                if isinstance(tree.get("stateSummary"), dict)
            ),
            "automatedFindingCount": sum(
                len(finding)
                for audit in audits
                for finding in audit["treeLint"].values()
            ),
        },
        "rubricID": RUBRIC["id"],
        "rubricVersion": RUBRIC["version"],
        "contractPolicy": str(contract_policy_path) if contract_policy_path else None,
        "rubric": RUBRIC,
        "judgeInstructions": RUBRIC["instructions"],
        "responseSchema": RESPONSE_SCHEMA,
        "scenarioRequests": requests,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path, help="Full acceptance run directory")
    parser.add_argument("--output", type=Path, help="Aggregate judge request path")
    parser.add_argument("--fail-on-incomplete", action="store_true")
    parser.add_argument("--contract-policy", type=Path)
    parser.add_argument("--require-all-contracts", action="store_true")
    args = parser.parse_args()

    run_root = args.run.resolve()
    if not run_root.is_dir():
        raise SystemExit(f"Run directory does not exist: {run_root}")
    output = args.output or run_root / "judge-request.json"
    contract_policy = args.contract_policy.resolve() if args.contract_policy else None
    request = collect(run_root, contract_policy, args.require_all_contracts)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(request, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"JUDGE_REQUEST={output}")
    print(f"SCENARIOS={request['scenarioCount']}")
    print(f"CHECKPOINTS={request['checkpointCount']}")
    return 1 if args.fail_on_incomplete and not request["evidenceAudit"]["releaseComplete"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
