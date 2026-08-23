#!/usr/bin/env python3
"""Regression tests for acceptance evidence outcomes and release gates."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_ROOT))

from acceptance_evidence_gate import audit as audit_evidence_gate  # noqa: E402
from acceptance_judge import audit_request, collect  # noqa: E402
from acceptance_report import load_agent_evidence_details  # noqa: E402


class AcceptanceOutcomeGateTests(unittest.TestCase):
    def _request(self, root: Path, outcome: str = "pass") -> dict:
        for relative in (
            "screenshots/action-0001-before.png",
            "screenshots/action-0001-after.png",
            "accessibility/action-0001-before.txt",
            "accessibility/action-0001-after.txt",
        ):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("Attributes: Application, 0x1, label: 'ForgeFit'\n", encoding="utf-8")
        checkpoint = {
            "id": "action-0001",
            "title": "After save",
            "action": "Perform tap on save",
            "expectedVisibleIdentifiers": ["saved-routine"],
            "expectedVisibleLabels": [],
            "invariants": [],
        }
        evidence = {
            "checkpoint": checkpoint,
            "outcome": outcome,
            "missingIdentifiers": ["saved-routine"] if outcome == "fail" else [],
            "missingLabels": [],
            "screenshotFile": "screenshots/action-0001-after.png",
            "accessibilityTreeFile": "accessibility/action-0001-after.txt",
            "beforeScreenshotFile": "screenshots/action-0001-before.png",
            "beforeAccessibilityTreeFile": "accessibility/action-0001-before.txt",
            "oracleResults": [],
        }
        return {
            "schemaVersion": 3,
            "rubricID": "forgefit-ai-acceptance",
            "rubricVersion": 1,
            "scenario": {"id": "ExampleFlow", "title": "Example flow"},
            "checkpointEvidence": [evidence],
        }

    def test_failed_declared_checkpoint_is_release_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            request = self._request(root, outcome="fail")
            audit = audit_request(root / "judge-request.json", request, required_contract_flows=None)

            self.assertFalse(audit["checkpointFailureComplete"])
            self.assertFalse(audit["releaseComplete"])
            self.assertTrue(any("action-0001" in warning for warning in audit["checkpointFailureWarnings"]))

    def test_aggregate_collect_preserves_checkpoint_failure_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scenario_root = root / "ExampleFlow"
            scenario_root.mkdir()
            (scenario_root / "judge-request.json").write_text(
                json.dumps(self._request(scenario_root, outcome="fail")),
                encoding="utf-8",
            )

            aggregate = collect(root, require_all_contracts=True)

            self.assertFalse(aggregate["evidenceAudit"]["checkpointFailureComplete"])
            self.assertFalse(aggregate["evidenceAudit"]["releaseComplete"])
            self.assertEqual(aggregate["evidenceAudit"]["checkpointFailureCount"], 1)

    def test_evidence_gate_fails_when_checkpoint_failed_even_without_strict_contract_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            request = {
                "scenarioRequests": [{
                    "checkpointEvidence": [{"checkpoint": {"id": "action-0001"}}],
                }],
                "evidenceAudit": {
                    "artifactComplete": True,
                    "schemaComplete": True,
                    "sequenceComplete": True,
                    "checkpointFailureComplete": False,
                    "scenarioAudits": [{"sequenceWarnings": []}],
                    "contractComplete": True,
                    "requiredContractComplete": True,
                },
            }
            (root / "judge-request.json").write_text(json.dumps(request), encoding="utf-8")

            result = audit_evidence_gate(root, require_contracts=False, contract_policy_path=None, require_all_contracts=False)

            self.assertFalse(result["complete"])
            self.assertIn("declared checkpoints failed", result["reason"])

    def test_report_loads_tree_lint_from_the_aggregate_judge_request(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence_root = root / "agent-evidence"
            flow_root = evidence_root / "ExampleFlow" / "run"
            flow_root.mkdir(parents=True)
            (flow_root / "manifest.json").write_text(json.dumps({
                "scenario": {
                    "id": "ExampleFlow",
                    "checkpoints": [{"id": "action-0001"}],
                },
                "checkpointCount": 1,
                "unverifiedCheckpointCount": 0,
            }), encoding="utf-8")
            (flow_root / "judge-request.json").write_text(json.dumps({
                "checkpointEvidence": [{
                    "outcome": "pass",
                    "checkpoint": {"id": "action-0001", "expectedVisibleIdentifiers": ["save"]},
                    "beforeScreenshotFile": "before.png",
                    "beforeAccessibilityTreeFile": "before.txt",
                    "screenshotFile": "after.png",
                    "accessibilityTreeFile": "after.txt",
                }],
            }), encoding="utf-8")
            aggregate_path = root / "judge-request.json"
            aggregate_path.write_text(json.dumps({
                "evidenceAudit": {
                    "scenarioAudits": [{
                        "scenarioID": "ExampleFlow",
                        "treeLint": {"action-0001:accessibilityTreeFile": [{
                            "rule": "touch-target",
                            "line": 4,
                            "message": "Button frame is 20x20",
                        }]},
                    }],
                },
            }), encoding="utf-8")

            details = load_agent_evidence_details(evidence_root, aggregate_path)

            self.assertEqual(details["ExampleFlow"]["treeLintFindingCount"], 1)


if __name__ == "__main__":
    unittest.main()
