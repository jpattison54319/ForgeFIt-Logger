#!/usr/bin/env python3
"""Build a source-backed inventory of ForgeFit's user-flow UI tests.

This deliberately uses only the repository's Swift source. It is a coverage
index, not a claim that a test passed; runtime status is merged from an
xcodebuild log by acceptance_report.py.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


TEST_ROOTS = ("ForgeFitUITests", "ForgeFitWatch Watch AppUITests")
CLASS_RE = re.compile(r"final\s+class\s+(\w+)\s*:\s*XCTestCase")
METHOD_RE = re.compile(r"^\s+(?:@MainActor\s+)?func\s+(test\w+)\s*\(", re.MULTILINE)
ID_RE = re.compile(r"accessibilityIdentifier\(\"([^\"]+)")
ARG_RE = re.compile(r"\"(--[a-zA-Z0-9_-]+)\"")
ACTION_WRAPPER_RE = re.compile(r"\.(?:acceptance|watchAcceptance)[A-Z]")


CAPABILITY_RULES = [
    ("onboarding", ("onboarding",)),
    ("strength logging", ("routine", "set", "logger", "myo", "quickincrement", "overflow", "incomplete")),
    ("cardio", ("cardio", "conditioning", "interval")),
    ("yoga", ("yoga",)),
    ("exercise library", ("exercise", "pose")),
    ("history", ("history", "calendar")),
    ("recovery and health", ("sleep", "freshness", "dashboard", "readiness", "health")),
    ("insights and coaching", ("insight", "coach", "experiment")),
    ("microcycles", ("microcycle",)),
    ("social", ("social", "hearts")),
    ("settings and data ownership", ("settings", "backup", "privacy", "persistence", "reset", "export")),
    ("visual and accessibility", ("capture", "theme", "touch", "launch", "appbar")),
    ("watch", ("watch",)),
]

RISK_RULES = [
    ("critical", ("persistence", "incomplete", "finish", "watch", "backup", "reset", "relaunch", "delete")),
    ("high", ("routine", "logger", "cardio", "yoga", "sleep", "history", "insight", "coach", "social")),
]


def classify(*parts: str) -> tuple[str, str]:
    haystack = " ".join(parts).lower()
    capability = "other"
    for candidate, tokens in CAPABILITY_RULES:
        if any(token in haystack for token in tokens):
            capability = candidate
            break
    risk = "normal"
    for candidate, tokens in RISK_RULES:
        if any(token in haystack for token in tokens):
            risk = candidate
            break
    return capability, risk


def inventory(root: Path) -> dict:
    flows: list[dict] = []
    files_seen = 0
    for relative_root in TEST_ROOTS:
        test_root = root / relative_root
        if not test_root.exists():
            continue
        for path in sorted(test_root.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            class_matches = list(CLASS_RE.finditer(source))
            method_matches = list(METHOD_RE.finditer(source))
            if not class_matches or not method_matches:
                continue
            files_seen += 1
            identifiers = sorted(set(ID_RE.findall(source)))
            launch_arguments = sorted(set(ARG_RE.findall(source)))
            for method_match in method_matches:
                owning_class = next(
                    (
                        class_match
                        for class_match in reversed(class_matches)
                        if class_match.start() < method_match.start()
                    ),
                    None,
                )
                if owning_class is None:
                    continue
                class_name = owning_class.group(1)
                method = method_match.group(1)
                capability, risk = classify(path.stem, class_name, method)
                flows.append({
                    "id": f"{class_name}/{method}",
                    "selector": f"{relative_root}/{path.relative_to(test_root).with_suffix('')}/{method}",
                    "platform": "watchOS Simulator" if "Watch" in relative_root else "iOS Simulator",
                    "class": class_name,
                    "method": method,
                    "source": str(path.relative_to(root)),
                    "capability": capability,
                    "risk": risk,
                    "launchArguments": launch_arguments,
                "sourceIdentifiers": identifiers,
                "evidenceTier": "simulator-ui",
                "humanActionInstrumentation": "source-wrapped" if ACTION_WRAPPER_RE.search(source) else "missing",
                "status": "not-run",
            })

    capabilities = {}
    for flow in flows:
        capabilities.setdefault(flow["capability"], 0)
        capabilities[flow["capability"]] += 1
    return {
        "schemaVersion": 1,
        "source": "repository Swift UI test files",
        "testFiles": files_seen,
        "flowCount": len(flows),
        "capabilities": dict(sorted(capabilities.items())),
        "flows": flows,
        "limitations": [
            "Inventory proves source coverage only; runtime status must come from an xcodebuild log.",
            "Simulator UI evidence does not prove physical Watch, HealthKit, or WidgetKit-face behavior.",
            "Human-like acceptance runs wrap user actions and capture a rendered screenshot plus accessibility tree after every action; flows without those wrappers remain functional-only.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()
    result = inventory(args.root)
    encoded = json.dumps(result, indent=2, sort_keys=True)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(encoded + "\n", encoding="utf-8")
    else:
        print(encoded)
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# ForgeFit acceptance flow inventory",
            "",
            f"Source-backed UI flows: **{result['flowCount']}** across **{result['testFiles']}** test files.",
            "",
            "| Capability | Flows |",
            "|---|---:|",
        ]
        lines.extend(f"| {name} | {count} |" for name, count in result["capabilities"].items())
        lines.extend(["", "| Flow | Capability | Risk | Evidence |", "|---|---|---|---|"])
        lines.extend(
            f"| `{flow['id']}` | {flow['capability']} | {flow['risk']} | {flow['evidenceTier']} |"
            for flow in result["flows"]
        )
        args.markdown_out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
