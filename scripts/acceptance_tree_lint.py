#!/usr/bin/env python3
"""Deterministic accessibility-tree checks for AI acceptance evidence."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


INTERACTIVE_TYPES = {
    "button",
    "cell",
    "collectionview",
    "datepicker",
    "link",
    "menuitem",
    "picker",
    "searchfield",
    "segmentedcontrol",
    "slider",
    "stepper",
    "switch",
    "securetextfield",
    "textfield",
    "textview",
    "toggle",
}
FIELD_RE = re.compile(
    r"(?P<field>identifier|label|value|placeholderValue):\s*(?P<quote>['\"])(?P<value>.*?)(?P=quote)"
)
NODE_RE = re.compile(
    r"^(?:[→▿▹-]\s*)?(?P<node_type>[A-Za-z][A-Za-z ]*?)(?:,\s|$)"
)
FRAME_RE = re.compile(
    r"(?:Frame:\s*)?\{\{[^,]+,\s*[^}]+\},\s*\{(?P<width>[^,]+),\s*(?P<height>[^}]+)\}\}"
)


def _field(line: str, name: str) -> str:
    for match in FIELD_RE.finditer(line):
        if match.group("field") == name:
            return match.group("value")
    return ""


def _node_type(line: str) -> str:
    """Read the node name from both XCUITest tree formats.

    Older hand-authored fixtures used ``- Button`` while
    ``XCUIApplication.debugDescription`` emits indented lines beginning with
    ``Button`` (and the root can begin with ``→Application``). Parsing the
    actual node prefix keeps the lint useful on captured evidence.
    """

    match = NODE_RE.match(line.lstrip())
    return match.group("node_type").strip() if match else ""


def _normalized_type(node_type: str) -> str:
    return re.sub(r"[\s_-]+", "", node_type).lower()


def lint_tree(path: Path, minimum_touch_target: float = 44.0) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    identifiers: dict[str, list[int]] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        return [{"rule": "tree-unreadable", "message": str(error), "line": 0}]

    for line_number, line in enumerate(lines, start=1):
        stripped = line.lstrip()
        node_type = _node_type(stripped)
        if _normalized_type(node_type) not in INTERACTIVE_TYPES:
            continue

        identifier = _field(stripped, "identifier")
        label = _field(stripped, "label")
        placeholder = _field(stripped, "placeholderValue")
        field_has_placeholder = (
            _normalized_type(node_type) in {"textfield", "securetextfield", "searchfield"}
            and bool(placeholder)
        )
        if identifier:
            identifiers.setdefault(identifier, []).append(line_number)
        if not label and not field_has_placeholder:
            findings.append({
                "rule": "interactive-label",
                "message": f"{node_type} has no accessibility label or placeholder",
                "line": line_number,
                "identifier": identifier,
            })

        frame = FRAME_RE.search(stripped)
        if frame:
            try:
                width = float(frame.group("width"))
                height = float(frame.group("height"))
            except ValueError:
                width = height = minimum_touch_target
            if width < minimum_touch_target or height < minimum_touch_target:
                findings.append({
                    "rule": "touch-target",
                    "message": f"{node_type} frame is {width:g}x{height:g}, below {minimum_touch_target:g}pt",
                    "line": line_number,
                    "identifier": identifier,
                })

        if "…" in label or "..." in label or "truncated" in stripped.lower():
            findings.append({
                "rule": "truncation",
                "message": f"{node_type} label may be truncated: {label}",
                "line": line_number,
                "identifier": identifier,
            })

    for identifier, locations in identifiers.items():
        if len(locations) > 1:
            findings.append({
                "rule": "duplicate-identifier",
                "message": f"Accessibility identifier {identifier!r} appears {len(locations)} times",
                "line": locations[0],
                "identifier": identifier,
                "locations": locations,
            })
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("trees", type=Path, nargs="+")
    parser.add_argument("--minimum-touch-target", type=float, default=44.0)
    parser.add_argument("--strict", action="store_true")
    args = parser.parse_args()

    result = {
        "treeCount": len(args.trees),
        "findings": {
            str(path): lint_tree(path, args.minimum_touch_target)
            for path in args.trees
        },
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    finding_count = sum(len(items) for items in result["findings"].values())
    return 1 if args.strict and finding_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
