#!/bin/zsh
set -e -o pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
git_commit="$(git -C "$repo_root" rev-parse HEAD)"
git_dirty=0
if ! git -C "$repo_root" diff --quiet || ! git -C "$repo_root" diff --cached --quiet; then
  git_dirty=1
fi
acceptance_root="${FORGEFIT_ACCEPTANCE_ROOT:-$repo_root/artifacts/acceptance/$git_commit}"
mkdir -p "$acceptance_root"
run_root="$(mktemp -d "$acceptance_root/full-run.XXXXXX")"
derived_data="$(mktemp -d /tmp/forgefit-acceptance-dd.XXXXXX)"
result_bundle="$run_root/ForgeFitUITests.xcresult"
log_path="$run_root/xcodebuild.log"
inventory_path="$run_root/inventory.json"
report_path="$run_root/report.md"
adoption_gate_path="$run_root/adoption-gate.json"
attachments_path="$run_root/attachments"
agent_evidence_path="$run_root/agent-evidence"
boundary_audit_path="$run_root/boundary-audit.json"
surface_inventory_path="$run_root/surface-inventory.json"
contract_policy="$repo_root/scripts/acceptance_adoption_policy.json"
action_marker="${FORGEFIT_ACCEPTANCE_ACTION_MARKER:-/tmp/forgefit-acceptance/.capture-actions}"
action_marker_preexisting=0
marker_backup=""
if [[ -e "$action_marker" ]]; then
  action_marker_preexisting=1
  marker_backup="$(mktemp /tmp/forgefit-acceptance-marker.XXXXXX)"
  cp "$action_marker" "$marker_backup"
else
  mkdir -p "$(dirname "$action_marker")"
fi
print -r -- "FORGEFIT_ACCEPTANCE_ARTIFACTS=$agent_evidence_path" > "$action_marker"
print -r -- "FORGEFIT_ACCEPTANCE_RUN_ROOT=$run_root" >> "$action_marker"
print -r -- "GIT_COMMIT=$git_commit" >> "$action_marker"
print -r -- "GIT_DIRTY=$git_dirty" >> "$action_marker"
print -r -- "FORGEFIT_ACCEPTANCE_REQUIRE_EVIDENCE=1" >> "$action_marker"
print -r -- "FORGEFIT_ACCEPTANCE_RUBRIC_ID=forgefit-ai-acceptance" >> "$action_marker"
print -r -- "FORGEFIT_ACCEPTANCE_RUBRIC_VERSION=1" >> "$action_marker"

cleanup() {
  if [[ "$action_marker_preexisting" == "1" && -n "$marker_backup" && -f "$marker_backup" ]]; then
    cp "$marker_backup" "$action_marker"
    rm -f "$marker_backup"
  elif [[ -e "$action_marker" ]]; then
    rm -f "$action_marker"
  fi
  if [[ "${FORGEFIT_KEEP_DERIVED_DATA:-0}" != "1" && -d "$derived_data" ]]; then
    find "$derived_data" -depth -delete
  fi
}
trap cleanup EXIT

cd "$repo_root"
python3 scripts/test_acceptance_tree_lint.py
python3 scripts/acceptance_inventory.py --json-out "$inventory_path" --markdown-out "$run_root/inventory.md"
python3 scripts/acceptance_boundary_audit.py --json-out "$boundary_audit_path" --markdown-out "$run_root/boundary-audit.md"
python3 scripts/acceptance_surface_inventory.py --json-out "$surface_inventory_path" --markdown-out "$run_root/surface-inventory.md"
set +e
python3 scripts/acceptance_adoption_gate.py "$inventory_path" --policy "$contract_policy" --output "$adoption_gate_path"
adoption_gate_exit=$?
set -e
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$developer_dir" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  developer_dir=/Applications/Xcode-beta.app/Contents/Developer
fi
test_timeouts_enabled="${FORGEFIT_TEST_TIMEOUTS_ENABLED:-YES}"
default_test_allowance="${FORGEFIT_DEFAULT_TEST_EXECUTION_ALLOWANCE:-180}"
maximum_test_allowance="${FORGEFIT_MAX_TEST_EXECUTION_ALLOWANCE:-240}"
test_selector="${FORGEFIT_ACCEPTANCE_ONLY_TESTING:-ForgeFitUITests}"
set +e
FORGEFIT_ACCEPTANCE_ARTIFACTS="$agent_evidence_path" \
FORGEFIT_ACCEPTANCE_ACTION_MARKER="$action_marker" \
FORGEFIT_ACCEPTANCE_RUBRIC_ID="forgefit-ai-acceptance" \
FORGEFIT_ACCEPTANCE_RUBRIC_VERSION="1" \
GIT_COMMIT="$git_commit" \
GIT_DIRTY="$git_dirty" \
DEVELOPER_DIR="$developer_dir" xcodebuild test \
  -workspace ForgeFit.xcworkspace \
  -scheme ForgeFit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  "-only-testing:$test_selector" \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled "$test_timeouts_enabled" \
  -default-test-execution-time-allowance "$default_test_allowance" \
  -maximum-test-execution-time-allowance "$maximum_test_allowance" > "$log_path" 2>&1
test_exit=$?
set -e

judge_request_path="$run_root/judge-request.json"
judge_request_exit=0
set +e
judge_args=("$run_root" "--output" "$judge_request_path" "--contract-policy" "$contract_policy" "--fail-on-incomplete")
if [[ "${FORGEFIT_ACCEPTANCE_REQUIRE_CONTRACTS:-0}" == "1" ]]; then
  judge_args+=("--require-all-contracts")
fi
python3 scripts/acceptance_judge.py "${judge_args[@]}"
judge_request_exit=$?
set -e

evidence_gate_path="$run_root/evidence-gate.json"
set +e
gate_args=("$run_root" "--output" "$evidence_gate_path")
gate_args+=("--require-contracts" "--contract-policy" "$contract_policy")
if [[ "${FORGEFIT_ACCEPTANCE_REQUIRE_CONTRACTS:-0}" == "1" ]]; then
  gate_args+=("--require-all-contracts")
fi
python3 scripts/acceptance_evidence_gate.py "${gate_args[@]}"
evidence_gate_exit=$?
set -e

attachment_export_exit=0
if [[ -d "$result_bundle" ]]; then
  mkdir -p "$attachments_path"
  set +e
  DEVELOPER_DIR="$developer_dir" xcrun xcresulttool export attachments \
    --path "$result_bundle" \
    --output-path "$attachments_path" \
    --filter '*.png' > "$run_root/attachment-export.log" 2>&1
  attachment_export_exit=$?
  set -e
fi

python3 scripts/acceptance_report.py \
  --xcode-log "$log_path" \
  --inventory "$inventory_path" \
  --attachments "$attachments_path" \
  --evidence-root "$agent_evidence_path" \
  --boundary-audit "$boundary_audit_path" \
  --surface-inventory "$surface_inventory_path" \
  --adoption-gate "$adoption_gate_path" \
  --evidence-gate "$evidence_gate_path" \
  --platform ios \
  --output "$report_path"

final_exit="$test_exit"
if [[ "$final_exit" == "0" && "$adoption_gate_exit" != "0" ]]; then
  final_exit="$adoption_gate_exit"
fi
if [[ "$final_exit" == "0" && "$judge_request_exit" != "0" && "${FORGEFIT_ACCEPTANCE_REQUIRE_CONTRACTS:-0}" == "1" ]]; then
  final_exit="$judge_request_exit"
fi
if [[ "$final_exit" == "0" && "$evidence_gate_exit" != "0" && "${FORGEFIT_ACCEPTANCE_REQUIRE_EVIDENCE:-1}" == "1" ]]; then
  final_exit="$evidence_gate_exit"
fi

printf 'RUN_ROOT=%s\nCOMMIT=%s\nDIRTY=%s\nLOG=%s\nREPORT=%s\nATTACHMENTS=%s\nAGENT_EVIDENCE=%s\nACTION_EVIDENCE=%s\nBOUNDARY_AUDIT=%s\nSURFACE_INVENTORY=%s\nADOPTION_GATE=%s\nEVIDENCE_GATE=%s\nJUDGE_REQUEST=%s\nEXIT_CODE=%s\nATTACHMENT_EXPORT_EXIT=%s\nADOPTION_GATE_EXIT=%s\nJUDGE_REQUEST_EXIT=%s\nEVIDENCE_GATE_EXIT=%s\n' \
  "$run_root" "$git_commit" "$git_dirty" "$log_path" "$report_path" "$attachments_path" "$agent_evidence_path" "$agent_evidence_path/action-evidence" "$boundary_audit_path" "$surface_inventory_path" "$adoption_gate_path" "$evidence_gate_path" "$judge_request_path" "$final_exit" "$attachment_export_exit" "$adoption_gate_exit" "$judge_request_exit" "$evidence_gate_exit"
exit "$final_exit"
