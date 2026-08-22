#!/usr/bin/env python3
"""Audit acceptance boundaries that XCTest cannot prove by itself.

The UI matrix is intentionally not the whole acceptance contract. This audit
records the extension targets, shared-container/privacy declarations, pure
cross-surface contracts, and the gates that require real Apple surfaces. It
does not turn source presence into a runtime pass; it makes the remaining
evidence boundary explicit in the same run artifact.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
from pathlib import Path


APP_GROUP = "group.org.xpetsllc.ForgeFit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def exists(root: Path, relative: str) -> bool:
    return (root / relative).exists()


def contains(root: Path, relative: str, pattern: str) -> bool:
    return re.search(pattern, read(root / relative), re.MULTILINE) is not None


def check_file_set(root: Path, relative_paths: list[str]) -> tuple[str, list[str]]:
    missing = [relative for relative in relative_paths if not exists(root, relative)]
    return ("covered" if not missing else "missing", missing)


def parse_entitlement_group(root: Path, relative: str) -> tuple[str, str]:
    path = root / relative
    if not path.exists():
        return "missing", f"{relative} does not exist"
    try:
        payload = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        return "missing", f"{relative} is not a valid plist: {error}"
    groups = payload.get("com.apple.security.application-groups", [])
    if APP_GROUP in groups:
        return "covered", relative
    return "missing", f"{relative} does not declare {APP_GROUP}"


def audit(root: Path) -> dict:
    project = root / "ForgeFit.xcodeproj/project.pbxproj"
    ui_files = sorted((root / "ForgeFitUITests").glob("*.swift")) if (root / "ForgeFitUITests").exists() else []
    watch_ui_files = sorted((root / "ForgeFitWatch Watch AppUITests").glob("*.swift")) if (root / "ForgeFitWatch Watch AppUITests").exists() else []

    boundaries: list[dict] = []

    def add(boundary_id: str, surface: str, status: str, evidence: str, limitation: str = "") -> None:
        boundaries.append({
            "id": boundary_id,
            "surface": surface,
            "status": status,
            "evidence": evidence,
            "limitation": limitation,
        })

    add(
        "ios-ui-matrix",
        "iPhone UI journeys",
        "covered" if ui_files else "missing",
        f"{len(ui_files)} Swift UI-test files under ForgeFitUITests",
        "Runtime pass/fail is supplied by xcodebuild, not this source audit.",
    )
    add(
        "watch-ui-matrix",
        "Watch UI journeys",
        "covered" if watch_ui_files else "missing",
        f"{len(watch_ui_files)} Swift UI-test files under ForgeFitWatch Watch AppUITests",
        "Simulator interaction does not prove a paired physical Watch.",
    )

    widget_files = [
        "ForgeFitWidgets/ForgeFitLauncherWidget.swift",
        "ForgeFitWidgets/ForgeFitWidgetsBundle.swift",
        "ForgeFitWidgets/ForgeFitWidgets.entitlements",
        "ForgeFitWidgets/PrivacyInfo.xcprivacy",
    ]
    status, missing = check_file_set(root, widget_files)
    add(
        "widgetkit-target",
        "iPhone WidgetKit extension",
        status,
        "ForgeFitWidgets target sources, entitlement, and privacy manifest",
        ", ".join(missing) if missing else "",
    )

    complication_files = [
        "ForgeFitWatchComplication/ForgeFitWatchComplication.swift",
        "ForgeFitWatchComplication/ForgeFitWatchComplication.entitlements",
        "ForgeFitWatchComplication/PrivacyInfo.xcprivacy",
    ]
    status, missing = check_file_set(root, complication_files)
    add(
        "watch-widget-target",
        "Watch WidgetKit complication extension",
        status,
        "ForgeFitWatchComplication target sources, entitlement, and privacy manifest",
        ", ".join(missing) if missing else "",
    )

    target_names = (read(project) if project.exists() else "")
    add(
        "extension-target-registration",
        "Xcode target registration",
        "covered" if all(name in target_names for name in ("ForgeFitWidgets", "ForgeFitWatchComplication")) else "missing",
        "ForgeFitWidgets and ForgeFitWatchComplication PBXNativeTarget entries",
        "The project file must register both extension targets." if project.exists() else "project.pbxproj is missing",
    )

    entitlement_paths = [
        "ForgeFit/ForgeFit.entitlements",
        "ForgeFitWidgets/ForgeFitWidgets.entitlements",
        "ForgeFitWatch Watch App/ForgeFitWatch.entitlements",
        "ForgeFitWatchComplication/ForgeFitWatchComplication.entitlements",
    ]
    entitlement_results = [parse_entitlement_group(root, path) for path in entitlement_paths]
    entitlement_status = "covered" if all(status == "covered" for status, _ in entitlement_results) else "missing"
    entitlement_details = "; ".join(
        detail for (status, detail) in entitlement_results if status != "covered"
    )
    add(
        "app-group-contract",
        "Phone → Watch/widget shared container",
        entitlement_status,
        f"All four app and extension entitlements declare {APP_GROUP}",
        entitlement_details,
    )

    privacy_paths = [
        "ForgeFit/PrivacyInfo.xcprivacy",
        "ForgeFitWidgets/PrivacyInfo.xcprivacy",
        "ForgeFitWatch Watch App/PrivacyInfo.xcprivacy",
        "ForgeFitWatchComplication/PrivacyInfo.xcprivacy",
    ]
    privacy_ok = True
    privacy_details: list[str] = []
    for relative in privacy_paths:
        path = root / relative
        try:
            payload = plistlib.loads(path.read_bytes())
            if payload.get("NSPrivacyTracking") is not False:
                privacy_ok = False
                privacy_details.append(f"{relative} does not set NSPrivacyTracking=false")
        except (OSError, plistlib.InvalidFileException) as error:
            privacy_ok = False
            privacy_details.append(f"{relative}: {error}")
    add(
        "privacy-manifests",
        "Privacy declarations",
        "covered" if privacy_ok else "missing",
        "App, WidgetKit, Watch app, and complication privacy manifests parse with tracking disabled",
        "; ".join(privacy_details),
    )

    widget_contract = "Packages/ForgeCore/Tests/ForgeCoreTests/WatchSyncTests.swift"
    widget_contract_ok = all(
        contains(root, widget_contract, pattern)
        for pattern in (
            r"WidgetSnapshotStore",
            r"idleWidgetSnapshotExpiresAtCalendarDayBoundary",
            r"rendersSameContent",
        )
    )
    add(
        "widget-snapshot-contract",
        "Snapshot encoding, day-gating, and reload-content policy",
        "covered" if widget_contract_ok else "missing",
        "ForgeCore WatchSyncTests exercise app-group snapshot round-trip and freshness policy",
        "Source contract is present; record the current-toolchain test result separately." if widget_contract_ok else "Expected WatchSyncTests coverage was not found",
    )

    interruption_ok = any(
        ".terminate()" in read(path) or ".activate()" in read(path)
        for path in ui_files + watch_ui_files
    )
    add(
        "interruption-relaunch",
        "Relaunch, foreground, and interrupted-session journeys",
        "partial" if interruption_ok else "missing",
        "UI sources contain explicit terminate/activate or relaunch checks",
        "This is partial coverage; each persistent journey must still assert fresh-context state.",
    )

    add(
        "widgetkit-rendered-face",
        "Rendered iPhone widget and physical Watch face",
        "blocked",
        "No deterministic local test can force WidgetKit scheduling or observe a physical face",
        "Requires WidgetKit-host rendering review and a paired physical Watch, including stale-day and active-workout transitions.",
    )
    add(
        "healthkit-real-data",
        "Real HealthKit authorization, samples, and revocation",
        "blocked",
        "Simulator fixtures and unit contracts can exercise fallback states",
        "Requires an authorized physical device and explicit denied/unavailable/revoked permission passes.",
    )
    add(
        "accessibility-device-settings",
        "VoiceOver, Dynamic Type, contrast, and touch behavior",
        "partial",
        "Accessibility trees and source-level identifiers are captured for UI flows",
        "Requires device-settings passes at large text, VoiceOver focus order, reduced motion, and both Watch sizes.",
    )

    return {
        "schemaVersion": 1,
        "appGroup": APP_GROUP,
        "boundaries": boundaries,
        "counts": {
            status: sum(boundary["status"] == status for boundary in boundaries)
            for status in ("covered", "partial", "blocked", "missing")
        },
        "limitations": [
            "A covered boundary means the repository contains the named contract or evidence path; it is not a runtime pass.",
            "Blocked boundaries require external Apple surfaces or permissions and must remain visible in release decisions.",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--markdown-out", type=Path)
    args = parser.parse_args()

    result = audit(args.root)
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(encoded, encoding="utf-8")
    else:
        print(encoded, end="")

    if args.markdown_out:
        args.markdown_out.parent.mkdir(parents=True, exist_ok=True)
        lines = [
            "# ForgeFit acceptance boundary audit",
            "",
            "This audit separates repository-backed contracts from Apple-surface evidence that the simulator cannot establish.",
            "",
            "| Boundary | Surface | Status | Evidence | Limitation |",
            "|---|---|---|---|---|",
        ]
        for boundary in result["boundaries"]:
            limitation = boundary["limitation"].replace("|", "\\|")
            evidence = boundary["evidence"].replace("|", "\\|")
            lines.append(
                f"| `{boundary['id']}` | {boundary['surface']} | **{boundary['status']}** | {evidence} | {limitation} |"
            )
        args.markdown_out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
