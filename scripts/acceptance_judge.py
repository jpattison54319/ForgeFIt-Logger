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


RESPONSE_SCHEMA = {
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
            "evidencePaths": ["relative/path/to/evidence"],
        }
    ],
}


def audit_request(request_path: Path, request: dict) -> dict:
    """Verify that a judge request contains a complete visual sequence.

    The XCTest process is responsible for creating the artifacts; this audit
    prevents a later report from treating a manifest with missing screenshots,
    trees, or skipped action numbers as equivalent to a human-style replay.
    """

    request_root = request_path.parent
    missing_artifacts: list[str] = []
    sequence_warnings: list[str] = []
    checkpoint_ids: list[str] = []
    for evidence in request.get("checkpointEvidence", []):
        checkpoint = evidence.get("checkpoint", {})
        checkpoint_id = str(checkpoint.get("id", ""))
        checkpoint_ids.append(checkpoint_id)
        for field in ("screenshotFile", "accessibilityTreeFile"):
            relative_path = evidence.get(field)
            if not relative_path:
                missing_artifacts.append(f"{checkpoint_id}: missing {field}")
                continue
            candidate = request_root / str(relative_path)
            if not candidate.is_file():
                missing_artifacts.append(f"{checkpoint_id}: {relative_path}")

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
        "complete": not missing_artifacts and not sequence_warnings,
        "missingArtifacts": missing_artifacts,
        "sequenceWarnings": sequence_warnings,
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
        "schemaVersion": 1,
        "type": "ForgeFitAcceptanceJudgeRequest",
        "runRoot": str(run_root),
        "scenarioCount": len(requests),
        "checkpointCount": checkpoint_count,
        "evidenceAudit": {
            "complete": all(audit["complete"] for audit in audits),
            "scenarioAudits": audits,
            "incompleteScenarioCount": sum(not audit["complete"] for audit in audits),
        },
        "judgeInstructions": (
            "Review every checkpoint in every scenario, including every action-level "
            "checkpoint in a human-like replay. Inspect the screenshot and accessibility "
            "tree at each artifactRoot in order; do not sample or review only the final "
            "screen. Report only observable issues. "
            "If evidenceAudit.complete is false for a scenario, report it as blocked/incomplete "
            "rather than treating the flow as visually passed. "
            "Distinguish confirmed failures from suspects and environmental blockers. "
            "Every finding must name the first divergent checkpoint and the smallest "
            "useful evidence paths. Return one JSON object matching responseSchema."
        ),
        "responseSchema": RESPONSE_SCHEMA,
        "scenarioRequests": requests,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path, help="Full acceptance run directory")
    parser.add_argument("--output", type=Path, help="Aggregate judge request path")
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
