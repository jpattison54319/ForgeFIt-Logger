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
    r"^(?:[→▿▹-]\s*)?(?P<node_type>[A-Za-z][A-Za-z0-9 _()]*?)(?:,\s|$)"
)
FRAME_RE = re.compile(
    r"\{\{\s*(?P<x>[^,]+),\s*(?P<y>[^}]+)\},\s*\{\s*(?P<width>[^,]+),\s*(?P<height>[^}]+)\}\}"
)
STATE_PREFIX = "ForgeFitAcceptanceState:"

# SF Symbol identifiers are implementation names, not semantic identifiers.
# Dotted names cover the general case (``info.circle``); these common
# undotted symbols are included because SwiftUI also emits names such as
# ``minus`` and ``pencil``.
SF_SYMBOL_IDENTIFIERS = {
    "add",
    "arrow.backward",
    "arrow.clockwise",
    "arrow.down",
    "arrow.left",
    "arrow.right",
    "arrow.up",
    "checkmark",
    "chevron.down",
    "chevron.left",
    "chevron.right",
    "chevron.up",
    "circle",
    "ellipsis",
    "ellipsis.circle",
    "gearshape",
    "globe",
    "minus",
    "pencil",
    "plus",
    "trash",
    "trash.fill",
    "xmark",
}


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
    normalized = re.sub(r"[\s_-]+", "", node_type).lower()
    return normalized.removeprefix("xcuielementtype")


def _parse_frame(line: str) -> dict[str, float] | None:
    match = FRAME_RE.search(line)
    if not match:
        return None
    try:
        return {
            key: float(match.group(key))
            for key in ("x", "y", "width", "height")
        }
    except ValueError:
        return None


def _parse_state_records(lines: list[str]) -> list[dict[str, object]]:
    records: list[dict[str, object]] = []
    for line in lines:
        if not line.startswith(STATE_PREFIX):
            continue
        try:
            value = json.loads(line[len(STATE_PREFIX) :].strip())
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        frame = value.get("frame")
        if not isinstance(frame, dict):
            frame = None
        records.append({
            "type": _normalized_type(str(value.get("type", ""))),
            "identifier": str(value.get("identifier", "")),
            "label": str(value.get("label", "")),
            "frame": frame,
            "exists": value.get("exists"),
            "hittable": value.get("hittable"),
            "enabled": value.get("enabled"),
        })
    return records


def _state_for_node(
    node: dict[str, object],
    states: list[dict[str, object]],
) -> dict[str, object] | None:
    """Match a debug-description node to its live XCTest state snapshot."""

    node_frame = node.get("frame")
    for state in states:
        if state.get("type") != node.get("normalized_type"):
            continue
        if state.get("identifier") != node.get("identifier"):
            continue
        if state.get("label") != node.get("label"):
            continue
        state_frame = state.get("frame")
        if isinstance(node_frame, dict) and isinstance(state_frame, dict):
            if any(
                abs(float(node_frame.get(key, 0.0)) - float(state_frame.get(key, 0.0))) > 0.5
                for key in ("x", "y", "width", "height")
            ):
                continue
        return state
    return None


def _is_symbol_identifier(identifier: str) -> bool:
    return (
        identifier in SF_SYMBOL_IDENTIFIERS
        or "." in identifier
        and bool(re.fullmatch(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+", identifier))
    )


def _breadcrumb_part(node: dict[str, object]) -> str:
    node_type = str(node.get("node_type", "element"))
    identifier = str(node.get("identifier", ""))
    label = str(node.get("label", ""))
    if identifier:
        return f"{node_type}[{identifier}]"
    if label:
        return f"{node_type}({label})"
    return node_type


def _finding_context(node: dict[str, object]) -> dict[str, object]:
    ancestors = list(node.get("ancestors", []))
    identified = [ancestor for ancestor in ancestors if ancestor.get("identifier")]
    context: dict[str, object] = {
        "breadcrumb": [_breadcrumb_part(ancestor) for ancestor in ancestors] + [_breadcrumb_part(node)],
    }
    if identified:
        nearest = identified[-1]
        context["ancestorIdentifier"] = nearest.get("identifier", "")
        if nearest.get("label"):
            context["ancestorLabel"] = nearest["label"]
    return context


def _repeated_row_is_tolerated(records: list[dict[str, object]]) -> bool:
    """Ignore repeated controls that are clearly a row template.

    The same semantic action is expected in repeated exercise/history rows. A
    duplicate is useful to report when the same ID is used for different
    semantics, but not when every occurrence has the same node type and label.
    """

    labels = {str(record.get("label", "")) for record in records}
    types = {str(record.get("normalized_type", "")) for record in records}
    return len(types) == 1 and len(labels) == 1 and "" not in labels


def _nested_identifier_reuse_is_tolerated(records: list[dict[str, object]]) -> bool:
    """Ignore one semantic control copied onto its descendants.

    SwiftUI/XCUITest commonly exposes a container, its editor, and a child
    label with the same accessibility identifier. That is different from two
    peer controls sharing an identifier: only the latter is ambiguous to a
    user-like query.
    """

    record_lines = {int(record["line"]) for record in records}
    roots = []
    for record in records:
        ancestor_lines = {
            int(ancestor["line"])
            for ancestor in record.get("ancestors", [])
        }
        if not ancestor_lines.intersection(record_lines):
            roots.append(record)
    return len(roots) <= 1


def _same_row_component_is_tolerated(records: list[dict[str, object]]) -> bool:
    """Ignore IDs reused by sibling subcontrols in one visual row."""

    scopes = []
    centers = []
    for record in records:
        identified = [
            ancestor for ancestor in record.get("ancestors", [])
            if ancestor.get("identifier")
        ]
        scopes.append(str(identified[-1]["identifier"]) if identified else "")
        frame = record.get("frame")
        if not isinstance(frame, dict):
            return False
        centers.append(float(frame["y"]) + float(frame["height"]) / 2.0)
    return (
        len(set(scopes)) == 1
        and bool(scopes[0])
        and max(centers) - min(centers) <= 44.0
    )


def lint_tree(path: Path, minimum_touch_target: float = 44.0) -> list[dict[str, object]]:
    findings: list[dict[str, object]] = []
    identifiers: dict[str, list[dict[str, object]]] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        return [{"rule": "tree-unreadable", "message": str(error), "line": 0}]

    states = _parse_state_records(lines)
    stack: list[dict[str, object]] = []
    for line_number, line in enumerate(lines, start=1):
        stripped = line.lstrip()
        node_type = _node_type(stripped)
        normalized_type = _normalized_type(node_type)
        if not node_type:
            continue

        indent = len(line) - len(stripped)
        while stack and indent <= int(stack[-1]["indent"]):
            stack.pop()
        node: dict[str, object] = {
            "line": line_number,
            "indent": indent,
            "node_type": node_type,
            "normalized_type": normalized_type,
            "identifier": _field(stripped, "identifier"),
            "label": _field(stripped, "label"),
            "placeholder": _field(stripped, "placeholderValue"),
            "frame": _parse_frame(stripped),
            "ancestors": list(stack),
        }
        stack.append(node)

        if normalized_type not in INTERACTIVE_TYPES:
            continue

        identifier = str(node["identifier"])
        label = str(node["label"])
        placeholder = str(node["placeholder"])
        if identifier:
            identifiers.setdefault(identifier, []).append(node)
        field_has_placeholder = normalized_type in {"textfield", "securetextfield", "searchfield"} and bool(placeholder)
        if not label and not field_has_placeholder:
            context = _finding_context(node)
            inside = f" inside {context['ancestorIdentifier']!r}" if context.get("ancestorIdentifier") else ""
            findings.append({
                "rule": "interactive-label",
                "message": f"{node_type} has no accessibility label or placeholder{inside}",
                "line": line_number,
                "identifier": identifier,
                **context,
            })

        frame = node.get("frame")
        if isinstance(frame, dict):
            width = float(frame["width"])
            height = float(frame["height"])
            state = _state_for_node(node, states)
            if state is None:
                # Legacy trees have no hittability metadata. Suppress only
                # clearly collapsed nodes so the fallback cannot hide the
                # 18–20pt controls this check is intended to catch.
                touch_target_eligible = min(width, height) >= 10.0
            else:
                touch_target_eligible = all(
                    state.get(key) is not False
                    for key in ("exists", "hittable", "enabled")
                )
            if touch_target_eligible and (width < minimum_touch_target or height < minimum_touch_target):
                finding: dict[str, object] = {
                    "rule": "touch-target",
                    "message": f"{node_type} frame is {width:g}x{height:g}, below {minimum_touch_target:g}pt",
                    "line": line_number,
                    "identifier": identifier,
                    **_finding_context(node),
                }
                if state is not None:
                    finding["hittable"] = state.get("hittable")
                    finding["enabled"] = state.get("enabled")
                else:
                    finding["stateKnown"] = False
                findings.append(finding)

        if "…" in label or "..." in label or "truncated" in stripped.lower():
            findings.append({
                "rule": "truncation",
                "message": f"{node_type} label may be truncated: {label}",
                "line": line_number,
                "identifier": identifier,
                **_finding_context(node),
            })

    for identifier, records in identifiers.items():
        if (
            len(records) <= 1
            or _is_symbol_identifier(identifier)
            or _repeated_row_is_tolerated(records)
            or _nested_identifier_reuse_is_tolerated(records)
            or _same_row_component_is_tolerated(records)
        ):
            continue
        locations = [int(record["line"]) for record in records]
        finding: dict[str, object] = {
            "rule": "duplicate-identifier",
            "message": f"Accessibility identifier {identifier!r} appears {len(locations)} times",
            "line": locations[0],
            "identifier": identifier,
            "locations": locations,
        }
        finding["breadcrumbs"] = [
            _finding_context(record).get("breadcrumb", []) for record in records
        ]
        findings.append(finding)
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
