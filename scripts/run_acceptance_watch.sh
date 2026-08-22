#!/bin/zsh
set -e -o pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
acceptance_root="${FORGEFIT_ACCEPTANCE_ROOT:-/tmp/forgefit-acceptance}"
mkdir -p "$acceptance_root"
run_root="$(mktemp -d "$acceptance_root/watch-run.XXXXXX")"
derived_data="$(mktemp -d /tmp/forgefit-acceptance-watch-dd.XXXXXX)"
result_bundle="$run_root/ForgeFitWatch.xcresult"
log_path="$run_root/xcodebuild.log"
inventory_path="$run_root/inventory.json"
report_path="$run_root/report.md"
attachments_path="$run_root/attachments"
agent_evidence_path="$run_root/agent-evidence"
boundary_audit_path="$run_root/boundary-audit.json"
surface_inventory_path="$run_root/surface-inventory.json"
evidence_source="${FORGEFIT_ACCEPTANCE_EVIDENCE_SOURCE:-/tmp/forgefit-acceptance}"
action_marker="${FORGEFIT_ACCEPTANCE_ACTION_MARKER:-/tmp/forgefit-acceptance/.capture-actions}"
action_marker_preexisting=0
if [[ -e "$action_marker" ]]; then
  action_marker_preexisting=1
else
  mkdir -p "$(dirname "$action_marker")"
  touch "$action_marker"
fi

cleanup() {
  if [[ "$action_marker_preexisting" == "0" && -e "$action_marker" ]]; then
    rm -f "$action_marker"
  fi
  if [[ "${FORGEFIT_KEEP_DERIVED_DATA:-0}" != "1" && -d "$derived_data" ]]; then
    find "$derived_data" -depth -delete
  fi
}
trap cleanup EXIT

cd "$repo_root"
python3 scripts/acceptance_inventory.py --json-out "$inventory_path" --markdown-out "$run_root/inventory.md"
python3 scripts/acceptance_boundary_audit.py --json-out "$boundary_audit_path" --markdown-out "$run_root/boundary-audit.md"
python3 scripts/acceptance_surface_inventory.py --json-out "$surface_inventory_path" --markdown-out "$run_root/surface-inventory.md"
mkdir -p "$evidence_source"
preexisting_evidence="$run_root/preexisting-evidence-manifests.txt"
find "$evidence_source" -type f -name manifest.json -print | sort > "$preexisting_evidence"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -d "$developer_dir" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  developer_dir=/Applications/Xcode-beta.app/Contents/Developer
fi
watch_destination="${FORGEFIT_WATCH_DESTINATION:-id=70EA1988-683A-463D-BB8F-30B21B8EC8DC}"
test_timeouts_enabled="${FORGEFIT_TEST_TIMEOUTS_ENABLED:-YES}"
default_test_allowance="${FORGEFIT_DEFAULT_TEST_EXECUTION_ALLOWANCE:-180}"
maximum_test_allowance="${FORGEFIT_MAX_TEST_EXECUTION_ALLOWANCE:-240}"

set +e
FORGEFIT_ACCEPTANCE_ARTIFACTS="$agent_evidence_path" DEVELOPER_DIR="$developer_dir" xcodebuild test \
  -workspace ForgeFit.xcworkspace \
  -scheme 'ForgeFitWatch Watch App' \
  -destination "$watch_destination" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:'ForgeFitWatch Watch AppUITests' \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled "$test_timeouts_enabled" \
  -default-test-execution-time-allowance "$default_test_allowance" \
  -maximum-test-execution-time-allowance "$maximum_test_allowance" > "$log_path" 2>&1
test_exit=$?
set -e

# xcodebuild does not reliably forward arbitrary shell environment variables
# into the XCTest runner. Collect only manifests created during this run from
# the writer's stable fallback directory so repeated runs remain isolated.
mkdir -p "$agent_evidence_path"
while IFS= read -r manifest_path; do
  [[ -z "$manifest_path" ]] && continue
  if ! grep -Fqx "$manifest_path" "$preexisting_evidence"; then
    source_directory="${manifest_path%/manifest.json}"
    relative_directory="${source_directory#"$evidence_source"/}"
    destination_directory="$agent_evidence_path/$relative_directory"
    mkdir -p "$(dirname "$destination_directory")"
    cp -R "$source_directory" "$destination_directory"
  fi
done < <(find "$evidence_source" -type f -name manifest.json -print | sort)

judge_request_path="$run_root/judge-request.json"
judge_request_exit=0
set +e
python3 scripts/acceptance_judge.py "$run_root" --output "$judge_request_path"
judge_request_exit=$?
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
  --platform watch \
  --output "$report_path"

printf 'RUN_ROOT=%s\nLOG=%s\nREPORT=%s\nATTACHMENTS=%s\nAGENT_EVIDENCE=%s\nACTION_EVIDENCE=%s\nBOUNDARY_AUDIT=%s\nSURFACE_INVENTORY=%s\nJUDGE_REQUEST=%s\nEXIT_CODE=%s\nATTACHMENT_EXPORT_EXIT=%s\nJUDGE_REQUEST_EXIT=%s\n' \
  "$run_root" "$log_path" "$report_path" "$attachments_path" "$agent_evidence_path" "$agent_evidence_path/action-evidence" "$boundary_audit_path" "$surface_inventory_path" "$judge_request_path" "$test_exit" "$attachment_export_exit" "$judge_request_exit"
exit "$test_exit"
