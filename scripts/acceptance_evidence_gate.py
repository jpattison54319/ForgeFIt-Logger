#!/usr/bin/env python3
"""Fail an acceptance run when its action evidence was not actually captured."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def audit(
    run_root: Path,
    require_contracts: bool,
    contract_policy_path: Path | None,
    require_all_contracts: bool,
) -> dict:
    request_path = run_root / "judge-request.json"
    if not request_path.is_file():
        return {
            "complete": False,
            "reason": "aggregate judge-request.json is missing",
            "actionCheckpointCount": 0,
        }

    request = json.loads(request_path.read_text(encoding="utf-8"))
    scenario_requests = request.get("scenarioRequests", [])
    action_checkpoint_count = sum(
        1
        for scenario in scenario_requests
        for evidence in scenario.get("checkpointEvidence", [])
        if str(evidence.get("checkpoint", {}).get("id", "")).startswith("action-")
    )
    evidence_audit = request.get("evidenceAudit", {})
    sequence_complete = all(
        not audit.get("sequenceWarnings")
        for audit in evidence_audit.get("scenarioAudits", [])
    )
    complete = bool(
        scenario_requests
        and action_checkpoint_count > 0
        and evidence_audit.get("artifactComplete", False)
        and evidence_audit.get("schemaComplete", False)
        and evidence_audit.get("sequenceComplete", False)
        and sequence_complete
        and (
            not require_contracts
            or evidence_audit.get(
                "contractComplete" if require_all_contracts or contract_policy_path is None
                else "requiredContractComplete",
                False,
            )
        )
    )
    reasons: list[str] = []
    if not scenario_requests:
        reasons.append("no per-scenario evidence requests were captured")
    if action_checkpoint_count == 0:
        reasons.append("no action-level checkpoints were captured")
    if not evidence_audit.get("artifactComplete", False):
        reasons.append("one or more before/after screenshots or accessibility trees are missing")
    if not evidence_audit.get("schemaComplete", False):
        reasons.append("one or more evidence requests use an unsupported schema or rubric version")
    if not sequence_complete:
        reasons.append("one or more action checkpoint sequences are incomplete or reordered")
    if require_contracts:
        contract_key = "contractComplete" if require_all_contracts or contract_policy_path is None else "requiredContractComplete"
        if not evidence_audit.get(contract_key, False):
            if require_all_contracts or contract_policy_path is None:
                reasons.append("one or more action checkpoints have no declared expectation or invariant")
            else:
                reasons.append("one or more allowlisted flows have no declared expectation or invariant")
    return {
        "complete": complete,
        "reason": "; ".join(reasons),
        "actionCheckpointCount": action_checkpoint_count,
        "scenarioCount": len(scenario_requests),
        "contractPolicy": str(contract_policy_path) if contract_policy_path else None,
        "requireAllContracts": require_all_contracts,
        "evidenceAudit": evidence_audit,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run", type=Path)
    parser.add_argument("--require-contracts", action="store_true")
    parser.add_argument("--contract-policy", type=Path)
    parser.add_argument("--require-all-contracts", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    contract_policy = args.contract_policy.resolve() if args.contract_policy else None
    result = audit(
        args.run.resolve(),
        args.require_contracts,
        contract_policy,
        args.require_all_contracts,
    )
    output = args.output or args.run / "evidence-gate.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
