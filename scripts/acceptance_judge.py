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

from acceptance_tree_lint import lint_tree


RUBRIC_PATH = Path(__file__).with_name("acceptance_rubric.json")
RUBRIC = json.loads(RUBRIC_PATH.read_text(encoding="utf-8"))
RESPONSE_SCHEMA = RUBRIC["responseSchema"]
REQUEST_SCHEMA_VERSION = 3


def audit_request(request_path: Path, request: dict) -> dict:
    """Verify that a judge request contains a complete visual sequence.

    The XCTest process is responsible for creating the artifacts; this audit
    prevents a later report from treating a manifest with missing screenshots,
    trees, or skipped action numbers as equivalent to a human-style replay.
    """

    request_root = request_path.parent
    missing_artifacts: list[str] = []
    sequence_warnings: list[str] = []
    contract_warnings: list[str] = []
    schema_warnings: list[str] = []
    tree_lint: dict[str, list[dict[str, object]]] = {}
    checkpoint_ids: list[str] = []
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
                tree_lint[f"{checkpoint_id}:{field}"] = lint_tree(candidate)

        if checkpoint_id.startswith("action-"):
            declared = (
                checkpoint.get("expectedVisibleIdentifiers")
                or checkpoint.get("expectedVisibleLabels")
                or checkpoint.get("invariants")
            )
            if not declared:
                contract_warnings.append(
                    f"{checkpoint_id}: no expected identifiers, labels, or invariants"
                )
            if evidence.get("outcome") == "pass" and not declared:
                contract_warnings.append(f"{checkpoint_id}: pass outcome has no declared contract")
        if evidence.get("outcome") == "pass" and (
            evidence.get("missingIdentifiers") or evidence.get("missingLabels")
        ):
            contract_warnings.append(f"{checkpoint_id}: pass outcome contains missing expectations")

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
        "scenarioID": str(request.get("scenario", {}).get("id", "")),
        "checkpointCount": len(checkpoint_ids),
        "complete": not missing_artifacts and not sequence_warnings and not contract_warnings and not schema_warnings,
        "artifactComplete": not missing_artifacts,
        "contractComplete": not contract_warnings,
        "schemaComplete": not schema_warnings,
        "missingArtifacts": missing_artifacts,
        "sequenceWarnings": sequence_warnings,
        "contractWarnings": contract_warnings,
        "schemaWarnings": schema_warnings,
        "treeLint": tree_lint,
    }


def collect(run_root: Path) -> dict:
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
        audit = audit_request(path, request)
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
            "artifactComplete": all(audit["artifactComplete"] for audit in audits),
            "contractComplete": all(audit["contractComplete"] for audit in audits),
            "schemaComplete": all(audit["schemaComplete"] for audit in audits),
            "sequenceComplete": all(not audit["sequenceWarnings"] for audit in audits),
            "scenarioAudits": audits,
            "incompleteScenarioCount": sum(not audit["complete"] for audit in audits),
            "uncontractedCheckpointCount": sum(len(audit["contractWarnings"]) for audit in audits),
            "automatedFindingCount": sum(
                len(finding)
                for audit in audits
                for finding in audit["treeLint"].values()
            ),
        },
        "rubricID": RUBRIC["id"],
        "rubricVersion": RUBRIC["version"],
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
    args = parser.parse_args()

    run_root = args.run.resolve()
    if not run_root.is_dir():
        raise SystemExit(f"Run directory does not exist: {run_root}")
    output = args.output or run_root / "judge-request.json"
    request = collect(run_root)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(request, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"JUDGE_REQUEST={output}")
    print(f"SCENARIOS={request['scenarioCount']}")
    print(f"CHECKPOINTS={request['checkpointCount']}")
    return 1 if args.fail_on_incomplete and not request["evidenceAudit"]["complete"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
