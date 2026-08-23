#!/usr/bin/env python3
"""Fail acceptance when contract adoption regresses or required flows drift."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from acceptance_inventory import adoption_by_suite


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def audit(inventory_path: Path, policy_path: Path, require_all_contracts: bool) -> dict:
    inventory = load_json(inventory_path)
    policy = load_json(policy_path)
    flows = inventory.get("flows", [])
    adoption = inventory.get("adoptionBySuite") or adoption_by_suite(flows)
    failures: list[str] = []
    suite_results: dict[str, dict[str, object]] = {}

    for suite, baseline in policy.get("suites", {}).items():
        current = adoption.get(suite)
        if current is None:
            failures.append(f"suite is missing from the inventory: {suite}")
            continue
        current_instrumented = int(current.get("instrumentedFlows", 0))
        current_legacy = int(current.get("legacyUnverifiedFlows", 0))
        baseline_instrumented = int(baseline.get("baselineInstrumentedFlows", 0))
        baseline_legacy = int(baseline.get("baselineLegacyUnverifiedFlows", 0))
        baseline_percent = (
            baseline_legacy * 100.0 / baseline_instrumented
            if baseline_instrumented
            else 0.0
        )
        current_percent = float(current.get("unverifiedPercent", 0.0))
        increased = current_percent > baseline_percent + 0.0001
        if increased:
            failures.append(
                f"{suite} unverified adoption rose from {baseline_percent:.4f}% to {current_percent:.4f}%"
            )
        suite_results[suite] = {
            "baselineInstrumentedFlows": baseline_instrumented,
            "baselineLegacyUnverifiedFlows": baseline_legacy,
            "baselineUnverifiedPercent": round(baseline_percent, 4),
            "currentInstrumentedFlows": current_instrumented,
            "currentLegacyUnverifiedFlows": current_legacy,
            "currentUnverifiedPercent": current_percent,
            "increased": increased,
        }

    flow_map = {str(flow.get("id")): flow for flow in flows}
    required_flows = [str(value) for value in policy.get("requiredContractFlows", [])]
    required_results: list[dict[str, object]] = []
    for flow_id in required_flows:
        flow = flow_map.get(flow_id)
        present = flow is not None
        declared = bool(
            present
            and flow.get("humanActionInstrumentation") == "method-wrapped"
            and flow.get("acceptanceContract") == "declared"
            and int(flow.get("expectationCallCount", 0)) > 0
        )
        required_results.append({"id": flow_id, "present": present, "declared": declared})
        if not present:
            failures.append(f"required contract flow is missing: {flow_id}")
        elif not declared:
            failures.append(f"required contract flow is not declared: {flow_id}")

    if require_all_contracts:
        legacy = [
            str(flow.get("id"))
            for flow in flows
            if flow.get("humanActionInstrumentation") == "method-wrapped"
            and flow.get("acceptanceContract") != "declared"
        ]
        if legacy:
            failures.append(f"{len(legacy)} instrumented flows remain uncontracted")

    return {
        "schemaVersion": 1,
        "complete": not failures,
        "reason": "; ".join(failures),
        "policy": str(policy_path),
        "requiredContractFlows": required_results,
        "suites": suite_results,
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inventory", type=Path)
    parser.add_argument(
        "--policy",
        type=Path,
        default=Path(__file__).with_name("acceptance_adoption_policy.json"),
    )
    parser.add_argument("--require-all-contracts", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    result = audit(args.inventory.resolve(), args.policy.resolve(), args.require_all_contracts)
    output = args.output or args.inventory.with_name("adoption-gate.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
