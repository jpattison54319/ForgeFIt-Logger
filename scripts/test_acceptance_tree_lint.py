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


if __name__ == "__main__":
    unittest.main()
