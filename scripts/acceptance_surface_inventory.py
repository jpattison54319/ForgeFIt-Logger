#!/usr/bin/env python3
"""Inventory production UI surfaces and compare them with UI-test evidence.

This is intentionally a static companion to ``acceptance_inventory.py``.  A
test method can pass while a newly added sheet, route, or accessibility
contract has never been exercised.  This inventory makes that gap visible
without pretending that source matching is runtime proof.

The script reads Swift source only.  It does not build, launch, send data to a
model, or mutate the application.  Runtime status is merged separately by
``acceptance_report.py``.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


PRODUCTION_ROOTS = {
    "iOS Simulator": Path("ForgeFit"),
    "watchOS Simulator": Path("ForgeFitWatch Watch App"),
}
TEST_ROOTS = {
    "iOS Simulator": Path("ForgeFitUITests"),
    "watchOS Simulator": Path("ForgeFitWatch Watch AppUITests"),
}
ROUTE_ENUMS = {
    "HomeRoute",
    "WorkoutRoute",
    "InsightsRoute",
    "ProfileRoute",
    "SettingsRoute",
}

VIEW_RE = re.compile(
    r"(?m)^\s*(?:(?:public|internal|private|fileprivate|final|@MainActor)\s+)*"
    r"(?:struct|class)\s+(\w+)[^\n{]*:\s*[^\n{]*\bView\b"
)
ACCESSIBILITY_ID_RE = re.compile(r"\.accessibilityIdentifier\(\s*\"([^\"]+)")
PRESENTATION_RE = re.compile(
    r"\.(sheet|fullScreenCover|popover|alert|confirmationDialog|dialog|navigationDestination)\b"
)
CONTAINER_RE = re.compile(r"\b(NavigationStack|NavigationSplitView|TabView|NavigationLink)\b")
ROUTE_ENUM_RE = re.compile(r"\b(?:private\s+|fileprivate\s+|internal\s+|public\s+)?enum\s+(\w+)\b[^\n{]*\{")
CASE_RE = re.compile(r"^\s*case\s+(.+?)\s*$")


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def strip_comments(source: str) -> str:
    """Remove comments while preserving line breaks for useful line numbers."""

    without_blocks = re.sub(
        r"/\*.*?\*/",
        lambda match: "".join("\n" if char == "\n" else " " for char in match.group(0)),
        source,
        flags=re.DOTALL,
    )
    return re.sub(r"//[^\n]*", "", without_blocks)


def matching_brace(source: str, opening_offset: int) -> int | None:
    depth = 0
    for offset in range(opening_offset, len(source)):
        character = source[offset]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return offset
    return None


def split_top_level(value: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    for index, character in enumerate(value):
        if character in "([{<":
            depth += 1
        elif character in ")]}>" and depth:
            depth -= 1
        elif character == "," and depth == 0:
            parts.append(value[start:index].strip())
            start = index + 1
    parts.append(value[start:].strip())
    return [part for part in parts if part]


def case_names(case_body: str) -> list[str]:
    names: list[str] = []
    for part in split_top_level(case_body):
        match = re.match(r"([A-Za-z_]\w*)", part)
        if match:
            names.append(match.group(1))
    return names


def source_files(root: Path) -> list[Path]:
    return sorted(path for path in root.rglob("*.swift") if path.is_file())


def test_corpus(root: Path, platform: str) -> list[dict[str, str]]:
    test_root = root / TEST_ROOTS[platform]
    corpus: list[dict[str, str]] = []
    if not test_root.exists():
        return corpus
    for path in source_files(test_root):
        corpus.append(
            {
                "source": str(path.relative_to(root)),
                "text": path.read_text(encoding="utf-8", errors="replace"),
            }
        )
    return corpus


def references_for_identifier(identifier: str, corpus: list[dict[str, str]]) -> list[str]:
    references: list[str] = []
    static_prefix = identifier.split("\\(", 1)[0]
    for item in corpus:
        text = item["text"]
        if identifier in text:
            references.append(item["source"])
        elif static_prefix and static_prefix != identifier and static_prefix in text:
            references.append(item["source"])
    return sorted(set(references))


def route_case_inventory(
    source: str,
    relative_source: str,
    platform: str,
    corpus: list[dict[str, str]],
    referenced_ids_by_source: dict[str, list[str]],
) -> list[dict[str, object]]:
    clean = strip_comments(source)
    entries: list[dict[str, object]] = []
    for match in ROUTE_ENUM_RE.finditer(clean):
        enum_name = match.group(1)
        if enum_name not in ROUTE_ENUMS:
            continue
        opening = clean.find("{", match.start(), match.end())
        closing = matching_brace(clean, opening)
        if closing is None:
            continue
        body = clean[opening + 1 : closing]
        body_start_line = line_number(clean, opening + 1)
        for body_line_offset, body_line in enumerate(body.splitlines(), start=0):
            case_match = CASE_RE.match(body_line)
            if not case_match:
                continue
            names = case_names(case_match.group(1))
            for name in names:
                direct_references = [
                    item["source"]
                    for item in corpus
                    if re.search(rf"(?<![A-Za-z0-9_]){re.escape(name)}(?![A-Za-z0-9_])", item["text"])
                ]
                same_file_ids = referenced_ids_by_source.get(relative_source, [])
                evidence: list[str] = []
                if direct_references:
                    evidence.append("route-case-token-in-ui-test-source")
                if same_file_ids:
                    evidence.append("same-file-accessibility-contract-reference")
                entries.append(
                    {
                        "id": f"{enum_name}.{name}",
                        "enum": enum_name,
                        "case": name,
                        "platform": platform,
                        "source": relative_source,
                        "line": body_start_line + body_line_offset,
                        "sourceReferences": sorted(set(direct_references)),
                        "sameFileReferencedAccessibilityIDs": same_file_ids,
                        "sourceCoverage": "referenced" if evidence else "unreferenced",
                        "coverageEvidence": evidence,
                        "coverageBasis": "heuristic source matching; runtime execution is reported separately",
                    }
                )
    return entries


def inventory(root: Path) -> dict[str, object]:
    all_surfaces: list[dict[str, object]] = []
    route_cases: list[dict[str, object]] = []
    test_corpora: dict[str, list[dict[str, str]]] = {
        platform: test_corpus(root, platform) for platform in PRODUCTION_ROOTS
    }
    referenced_ids_by_source: dict[str, list[str]] = {}

    for platform, relative_root in PRODUCTION_ROOTS.items():
        production_root = root / relative_root
        corpus = test_corpora[platform]
        if not production_root.exists():
            continue
        for path in source_files(production_root):
            source = path.read_text(encoding="utf-8", errors="replace")
            relative_source = str(path.relative_to(root))
            clean = strip_comments(source)
            ids_in_file: list[str] = []
            for match in ACCESSIBILITY_ID_RE.finditer(source):
                identifier = match.group(1)
                ids_in_file.append(identifier)
                references = references_for_identifier(identifier, corpus)
                all_surfaces.append(
                    {
                        "id": f"accessibility:{platform}:{relative_source}:{identifier}",
                        "kind": "accessibility-contract",
                        "platform": platform,
                        "source": relative_source,
                        "line": line_number(source, match.start()),
                        "identifier": identifier,
                        "dynamic": "\\(" in identifier,
                        "testReferences": references,
                        "sourceCoverage": "referenced" if references else "unreferenced",
                        "coverageBasis": "exact identifier or dynamic-prefix match in same-platform UI-test source",
                    }
                )
                if references:
                    referenced_ids_by_source.setdefault(relative_source, []).append(identifier)

            for match in VIEW_RE.finditer(clean):
                all_surfaces.append(
                    {
                        "id": f"view:{platform}:{relative_source}:{match.group(1)}",
                        "kind": "view-declaration",
                        "platform": platform,
                        "source": relative_source,
                        "line": line_number(clean, match.start()),
                        "name": match.group(1),
                        "sameFileReferencedAccessibilityIDs": sorted(
                            set(referenced_ids_by_source.get(relative_source, []))
                        ),
                        "coverageBasis": "a rendering surface is considered source-covered only when its file has a referenced accessibility contract",
                    }
                )

            for match in PRESENTATION_RE.finditer(clean):
                all_surfaces.append(
                    {
                        "id": f"presentation:{platform}:{relative_source}:{line_number(clean, match.start())}:{match.group(1)}",
                        "kind": "presentation-seam",
                        "platform": platform,
                        "source": relative_source,
                        "line": line_number(clean, match.start()),
                        "modifier": match.group(1),
                        "sameFileReferencedAccessibilityIDs": sorted(
                            set(referenced_ids_by_source.get(relative_source, []))
                        ),
                        "coverageBasis": "a presentation seam is considered source-covered only when its file has a referenced accessibility contract",
                    }
                )
            for match in CONTAINER_RE.finditer(clean):
                all_surfaces.append(
                    {
                        "id": f"container:{platform}:{relative_source}:{line_number(clean, match.start())}:{match.group(1)}",
                        "kind": "navigation-container",
                        "platform": platform,
                        "source": relative_source,
                        "line": line_number(clean, match.start()),
                        "container": match.group(1),
                        "sameFileReferencedAccessibilityIDs": sorted(
                            set(referenced_ids_by_source.get(relative_source, []))
                        ),
                        "coverageBasis": "a navigation container is considered source-covered only when its file has a referenced accessibility contract",
                    }
                )

            route_cases.extend(
                route_case_inventory(
                    source,
                    relative_source,
                    platform,
                    corpus,
                    referenced_ids_by_source,
                )
            )

    # View and presentation entries are created before all files have been
    # scanned.  Recompute their same-file evidence from the completed map.
    for surface in all_surfaces:
        if surface["kind"] not in {"view-declaration", "presentation-seam", "navigation-container"}:
            continue
        ids = sorted(set(referenced_ids_by_source.get(str(surface["source"]), [])))
        surface["sameFileReferencedAccessibilityIDs"] = ids
        surface["sourceCoverage"] = "referenced" if ids else "unreferenced"

    surfaces_by_kind: dict[str, int] = {}
    coverage_by_kind: dict[str, dict[str, int]] = {}
    for surface in all_surfaces:
        kind = str(surface["kind"])
        surfaces_by_kind[kind] = surfaces_by_kind.get(kind, 0) + 1
        coverage = str(surface.get("sourceCoverage", "unreferenced"))
        coverage_by_kind.setdefault(kind, {})[coverage] = coverage_by_kind.setdefault(kind, {}).get(coverage, 0) + 1
    coverage_by_kind["route-case"] = {}
    for route in route_cases:
        coverage = str(route["sourceCoverage"])
        coverage_by_kind["route-case"][coverage] = coverage_by_kind["route-case"].get(coverage, 0) + 1

    accessibility = [surface for surface in all_surfaces if surface["kind"] == "accessibility-contract"]
    unreferenced_ids = [
        {
            "platform": surface["platform"],
            "source": surface["source"],
            "line": surface["line"],
            "identifier": surface["identifier"],
            "dynamic": surface["dynamic"],
        }
        for surface in accessibility
        if surface.get("sourceCoverage") == "unreferenced"
    ]

    return {
        "schemaVersion": 1,
        "source": "production Swift UI surfaces compared with same-platform UI-test source",
        "targets": {
            platform: {
                "productionRoot": str(relative_root),
                "testRoot": str(TEST_ROOTS[platform]),
                "productionSwiftFiles": len(source_files(root / relative_root)),
                "testSwiftFiles": len(test_corpora[platform]),
            }
            for platform, relative_root in PRODUCTION_ROOTS.items()
        },
        "counts": {
            "surfaces": len(all_surfaces),
            "routeCases": len(route_cases),
            "accessibilityContracts": len(accessibility),
            "unreferencedAccessibilityContracts": len(unreferenced_ids),
            "sourceCoveredAccessibilityContracts": len(accessibility) - len(unreferenced_ids),
            "byKind": dict(sorted(surfaces_by_kind.items())),
            "coverageByKind": {
                kind: dict(sorted(counts.items())) for kind, counts in sorted(coverage_by_kind.items())
            },
        },
        "routeCases": sorted(route_cases, key=lambda item: (str(item["platform"]), str(item["source"]), int(item["line"]), str(item["id"]))),
        "surfaces": sorted(all_surfaces, key=lambda item: (str(item["platform"]), str(item["source"]), int(item["line"]), str(item["id"]))),
        "unreferencedAccessibilityContracts": sorted(
            unreferenced_ids,
            key=lambda item: (str(item["platform"]), str(item["source"]), int(item["line"]), str(item["identifier"])),
        ),
        "limitations": [
            "Source matching is a coverage alarm, not proof that a surface is reachable or that its runtime flow passed.",
            "A file with one referenced accessibility contract is not proof that every view or presentation seam in that file is covered.",
            "Dynamic accessibility identifiers are matched by their static prefix and should receive explicit data-fixture coverage.",
            "Physical Watch face, WidgetKit rendering, HealthKit authorization, notifications, and external integrations remain separate evidence boundaries.",
        ],
    }


def markdown(result: dict[str, object]) -> str:
    counts = result["counts"]
    lines = [
        "# ForgeFit production acceptance surface inventory",
        "",
        "This is static source coverage evidence, not a runtime pass claim.",
        "",
        f"Surfaces: **{counts['surfaces']}**; route cases: **{counts['routeCases']}**; accessibility contracts: **{counts['accessibilityContracts']}**.",
        f"Referenced accessibility contracts: **{counts['sourceCoveredAccessibilityContracts']}**; unreferenced: **{counts['unreferencedAccessibilityContracts']}**.",
        "",
        "## Counts",
        "",
        "| Kind | Total | Referenced | Unreferenced |",
        "|---|---:|---:|---:|",
    ]
    coverage_by_kind = counts["coverageByKind"]
    for kind, total in sorted(counts["byKind"].items()):
        coverage = coverage_by_kind.get(kind, {})
        lines.append(f"| {kind} | {total} | {coverage.get('referenced', 0)} | {coverage.get('unreferenced', 0)} |")
    lines.extend(["", "## Unreferenced accessibility contracts", ""])
    unreferenced = result["unreferencedAccessibilityContracts"]
    if not unreferenced:
        lines.append("No unreferenced contracts were found by the static matcher.")
    else:
        lines.extend(["| Platform | Identifier | Source | Line |", "|---|---|---|---:|"])
        for item in unreferenced[:100]:
            identifier = str(item["identifier"]).replace("|", "\\|")
            lines.append(f"| {item['platform']} | `{identifier}` | `{item['source']}` | {item['line']} |")
        if len(unreferenced) > 100:
            lines.append(f"| … | {len(unreferenced) - 100} more | See JSON inventory | |")
    lines.extend(["", "## Limitations", ""])
    lines.extend(f"- {limitation}" for limitation in result["limitations"])
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()
    result = inventory(args.root)
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")
    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_out.write_text(markdown(result), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
