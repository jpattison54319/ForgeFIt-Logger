#!/usr/bin/env python3
"""Regression tests for parsing real XCUITest accessibility trees."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPT_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_ROOT))

from acceptance_tree_lint import lint_tree  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
