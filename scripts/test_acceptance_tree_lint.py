#!/usr/bin/env python3
"""Regression tests for parsing real XCUITest accessibility trees."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_ROOT))

from acceptance_tree_lint import inspect_tree, lint_tree  # noqa: E402


class AcceptanceTreeLintTests(unittest.TestCase):
    def test_real_debug_description_nodes_are_linted(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_lint_known_issues.txt"

        findings = lint_tree(fixture)

        rules = {finding["rule"] for finding in findings}
        self.assertIn("touch-target", rules)
        self.assertIn("interactive-label", rules)
        self.assertTrue(
            any(
                finding.get("identifier") == "tiny-button"
                and finding["rule"] == "touch-target"
                for finding in findings
            )
        )
        self.assertTrue(
            any(
                finding.get("identifier") == "empty-button"
                and finding["rule"] == "interactive-label"
                for finding in findings
            )
        )

    def test_canonical_text_field_names_and_placeholders_are_recognized(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_lint_known_issues.txt"

        findings = lint_tree(fixture)

        self.assertFalse(
            any(
                finding.get("identifier") in {"name-field", "search-field"}
                for finding in findings
            )
        )

    def test_live_state_filters_collapsed_controls_but_keeps_real_small_targets(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_lint_known_issues.txt"

        findings = lint_tree(fixture)

        self.assertTrue(any(
            finding.get("identifier") == "small-button"
            and finding["rule"] == "touch-target"
            and finding.get("hittable") is True
            for finding in findings
        ))
        self.assertFalse(any(
            finding.get("identifier") == "collapsed-button"
            and finding["rule"] == "touch-target"
            for finding in findings
        ))

    def test_label_findings_include_the_nearest_identified_ancestor(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_lint_known_issues.txt"

        findings = lint_tree(fixture)

        unlabeled = next(
            finding for finding in findings
            if finding.get("rule") == "interactive-label"
            and finding.get("ancestorIdentifier") == "history-sort-menu"
        )
        self.assertIn("history-sort-menu", unlabeled["message"])
        self.assertTrue(any("history-sort-menu" in item for item in unlabeled["breadcrumb"]))

    def test_duplicate_identifier_lint_ignores_symbols_and_repeated_rows(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_lint_known_issues.txt"

        findings = lint_tree(fixture)

        duplicates = {
            finding.get("identifier")
            for finding in findings
            if finding["rule"] == "duplicate-identifier"
        }
        self.assertIn("same-id", duplicates)
        self.assertNotIn("row-action", duplicates)
        self.assertNotIn("info.circle", duplicates)

    def test_live_state_summary_proves_capture_is_complete(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_state_capture.txt"

        inspection = inspect_tree(fixture)

        self.assertTrue(inspection["stateCaptureComplete"])
        self.assertEqual(inspection["stateRecordCount"], 1)
        self.assertEqual(inspection["matchedStateNodeCount"], 1)
        self.assertEqual(inspection["matchedStateCandidateCount"], 1)

    def test_prelaunch_tree_is_not_a_state_capture_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary) / "tree.txt"
            tree.write_text("Application not running", encoding="utf-8")

            inspection = inspect_tree(tree)

            self.assertTrue(inspection["stateCaptureComplete"])
            self.assertFalse(inspection["stateCaptureApplicable"])
            self.assertFalse(inspection["applicationRunning"])

    def test_labeled_outer_button_suppresses_duplicate_inner_wrapper_label_finding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary) / "tree.txt"
            tree.write_text(
                "\n".join([
                    " →Application, 0x1, label: 'ForgeFit'",
                    "    Button, 0x2, {{10.0, 10.0}, {44.0, 44.0}}, label: 'Options'",
                    "      Button, 0x3, {{10.0, 10.0}, {44.0, 44.0}}",
                    "ForgeFitAcceptanceStateSummary: {\"schemaVersion\":1,\"candidateCount\":0,\"recordCount\":0,\"serializationErrorCount\":0}",
                ]),
                encoding="utf-8",
            )

            findings = lint_tree(tree)

            self.assertFalse(any(finding["rule"] == "interactive-label" for finding in findings))

    def test_new_capture_with_unmatched_eight_point_button_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary) / "tree.txt"
            tree.write_text(
                "\n".join([
                    "Attributes: Application, 0x1, label: 'ForgeFit'",
                    "Element subtree:",
                    " →Application, 0x1, label: 'ForgeFit'",
                    "    Button, 0x2, {{10.0, 10.0}, {8.0, 8.0}}, identifier: 'eight-point', label: 'Tiny'",
                    "ForgeFitAcceptanceStateSummary: {\"schemaVersion\":1,\"candidateCount\":1,\"recordCount\":0,\"serializationErrorCount\":0,\"queryCount\":1,\"queriedTypes\":[\"Button\"],\"durationMilliseconds\":1}",
                ]),
                encoding="utf-8",
            )

            inspection = inspect_tree(tree)

            self.assertFalse(inspection["stateCaptureComplete"])
            self.assertTrue(any(
                finding.get("identifier") == "eight-point"
                and finding["rule"] == "touch-target"
                for finding in inspection["findings"]
            ))

    def test_anonymous_label_finding_includes_frame_location(self) -> None:
        fixture = SCRIPT_ROOT / "test_fixtures" / "acceptance_tree_lint_known_issues.txt"

        findings = lint_tree(fixture)
        anonymous = next(
            finding for finding in findings
            if finding.get("rule") == "interactive-label"
            and not finding.get("identifier")
            and not finding.get("ancestorIdentifier")
        )

        self.assertIn("frame", anonymous)
        self.assertIn("tree line", anonymous["message"])


if __name__ == "__main__":
    unittest.main()
