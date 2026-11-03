#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN" "$TEST_DIR/state"
trap 'rm -rf -- "$TEST_DIR"' EXIT

export USBAM_CONFIG_PATH="$TEST_DIR/missing.conf"
export USBAM_STATE_DIR="$TEST_DIR/state"
export USBAM_TTL_FILE="$TEST_DIR/state/ttl.json"
export USBAM_CLOCK_STATE_FILE="$TEST_DIR/state/clock_state.json"
export USBAM_RESTORE_JOURNAL_FILE="$TEST_DIR/state/restore_journal.json"
export USBAM_LOCK_FILE="$TEST_DIR/lock"
export USBAM_DAEMON_CONFIG_PATH="$TEST_DIR/usbguard-daemon.conf"
export USBAM_COMMAND_LOG="$TEST_DIR/commands.log"
touch "$USBAM_LOCK_FILE" "$TEST_DIR/rules.conf"
chmod 600 "$USBAM_LOCK_FILE"
printf 'RuleFile=%s\n' "$TEST_DIR/rules.conf" > "$USBAM_DAEMON_CONFIG_PATH"

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$USBAM_COMMAND_LOG"
case "$*" in
  "list-devices --blocked")
    printf '3: block id 1234:5678 name "Test device"\n'
    ;;
  "list-devices")
    printf '3: block id 1234:5678 name "Test device"\n'
    ;;
  "list-rules")
    printf '1: allow id 1d6b:0002\n'
    ;;
  *)
    printf 'unexpected USBGuard command: %s\n' "$*" >&2
    exit 64
    ;;
esac
MOCK

cat > "$FAKE_BIN/pgrep" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "-x usbguard-daemon" ]]
MOCK
chmod 700 "$FAKE_BIN/usbguard" "$FAKE_BIN/pgrep"
export PATH="$FAKE_BIN:$PATH"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

if bash "$PROJECT_ROOT/scripts/usb-approve.sh" --help >/dev/null; then
  pass "help is available without contacting USBGuard"
else
  fail "help failed"
fi

output="$(
  bash "$PROJECT_ROOT/scripts/usb-approve.sh" \
    --device 3 --type temporary --ttl 600 --dry-run
)"
jq -e '
  .result_state == "SUCCESS" and
  .exit_code == 0 and
  .policy_result.status == "not_applicable" and
  .audit_result.status == "not_applicable" and
  (.items | length) == 1
' <<< "$output" >/dev/null || fail "dry-run output is not a valid no-change result"
[[ ! -e "$USBAM_TTL_FILE" ]] || fail "dry-run created TTL state"
[[ "$(wc -l < "$USBAM_COMMAND_LOG")" == "1" ]] ||
  fail "dry-run performed more than the initial read-only device query"
pass "dry-run reports a plan without changing policy, TTL, or Audit"

set +e
output="$(bash "$PROJECT_ROOT/scripts/usb-approve.sh" \
  --device 3 --device 3 --type temporary --dry-run 2>&1)"
status=$?
set -e
[[ "$status" -eq 7 ]] || fail "duplicate device IDs were accepted"
[[ "$output" == *"duplicate --device IDs"* ]] ||
  fail "duplicate device rejection was not reported"
pass "duplicate IDs are rejected before any approval operation"

set +e
output="$(bash "$PROJECT_ROOT/scripts/usb-approve.sh" \
  --device 99 --type permanent --dry-run 2>&1)"
status=$?
set -e
[[ "$status" -eq 7 ]] || fail "unknown device ID was accepted"
[[ "$output" == *"not currently blocked"* ]] ||
  fail "unknown device rejection was not reported"
pass "only IDs from the current blocked-device list are accepted"

set +e
output="$(bash "$PROJECT_ROOT/scripts/usb-approve.sh" \
  --device 3 --type temporary --ttl 59 --dry-run 2>&1)"
status=$?
set -e
[[ "$status" -eq 7 ]] || fail "out-of-range TTL was accepted"
pass "TTL limits are validated before planning"

(
  source "$PROJECT_ROOT/scripts/usb-approve.sh"
  SELECTED_DEVICES=(3 4 5)
  BATCH_FAILED=0
  BATCH_UNCERTAIN=0
  BATCH_AUDIT_FAILED=0
  BATCH_SUCCEEDED=0
  result_start

  process_device() {
    [[ "$1" == "3" ]] || fail "batch continued after an uncertain result"
    result_add_item "$1" "$RESULT_RECOVERY_REQUIRED" "$EXIT_INCONSISTENT" \
      "recovery required" unknown not_applicable
    BATCH_UNCERTAIN=1
  }

  process_selected_devices
  [[ "${#RESULT_ITEM_JSON[@]}" -eq 3 ]] ||
    fail "batch results do not include unprocessed devices"
  jq -e '.item_id == "4" and .policy_result.detail_code == "batch_stopped_for_recovery"' \
    <<< "${RESULT_ITEM_JSON[1]}" >/dev/null ||
    fail "unprocessed device was not marked as skipped"
  jq -e '.item_id == "5" and .policy_result.detail_code == "batch_stopped_for_recovery"' \
    <<< "${RESULT_ITEM_JSON[2]}" >/dev/null ||
    fail "later unprocessed device was not marked as skipped"
)
pass "batch stops after an uncertain result and records remaining devices as skipped"

(
  source "$PROJECT_ROOT/scripts/usb-approve.sh"
  APPROVAL_TYPE=temporary
  SELECTED_DEVICES=(3 4 5)
  SELECTED_RULES=(
    [3]="allow id 1111:2222"
    [4]="allow id abcd:ef04"
    [5]="allow id abcd:ef05"
  )

  list_active_rules() {
    USBAM_ACTIVE_RULES=('1: block id 1111:2222')
  }
  usbguard_rule_is_persistent() {
    [[ "$1" == "allow id abcd:ef05" ]]
  }

  preflight_selected_devices
  [[ "${SELECTED_BLOCK_REASONS[3]}" == "precedence_conflict" ]] ||
    fail "preflight missed block-before-allow precedence"
  [[ -z "${SELECTED_BLOCK_REASONS[4]}" ]] ||
    fail "preflight blocked a rule without a conflict"
  [[ "${SELECTED_BLOCK_REASONS[5]}" == "persistent_overlap" ]] ||
    fail "preflight missed persistent overlap"

  summary="$(approval_summary)"
  [[ "$summary" == *"earlier block/reject rule takes precedence"* ]] ||
    fail "approval summary omitted precedence warning"
  [[ "$summary" == *"matching permanent rule exists"* ]] ||
    fail "approval summary omitted persistent overlap warning"

  BATCH_FAILED=0
  BATCH_UNCERTAIN=0
  BATCH_AUDIT_FAILED=0
  BATCH_SUCCEEDED=0
  BATCH_FAILURE_RC=0
  result_start
  process_device() {
    [[ "$1" == "4" ]] || fail "preflight-blocked device reached policy processing"
    result_add_item "$1" "$RESULT_SUCCESS" "$EXIT_OK" \
      "approval verified" applied written
    BATCH_SUCCEEDED=$((BATCH_SUCCEEDED + 1))
  }
  process_selected_devices
  [[ "$BATCH_SUCCEEDED" -eq 1 && "$BATCH_FAILED" -eq 1 ]] ||
    fail "preflight batch did not preserve eligible approvals"
  [[ "${#RESULT_ITEM_JSON[@]}" -eq 3 ]] ||
    fail "preflight batch omitted a selected device result"
)
pass "approval preflight warns on precedence and persistent overlap while preserving eligible batch items"

(
  source "$PROJECT_ROOT/scripts/usb-approve.sh"
  result_start
  BATCH_UNCERTAIN=0
  BATCH_AUDIT_FAILED=0
  BATCH_FAILED=1
  BATCH_SUCCEEDED=1
  BATCH_FAILURE_RC=7
  finalize_batch_result
  [[ "$RESULT_EXIT_CODE" -eq "$EXIT_PARTIAL" ]] ||
    fail "mixed success/failure batch did not return EXIT_PARTIAL"
  [[ "$RESULT_STATE" == "$RESULT_PARTIAL" ]] ||
    fail "mixed success/failure batch has the wrong result state"

  result_start
  BATCH_UNCERTAIN=0
  BATCH_AUDIT_FAILED=1
  BATCH_FAILED=1
  BATCH_SUCCEEDED=1
  finalize_batch_result
  [[ "$RESULT_EXIT_CODE" -eq "$EXIT_AUDIT" ]] ||
    fail "Audit failure did not take priority over partial failure"

  result_start
  BATCH_UNCERTAIN=1
  BATCH_AUDIT_FAILED=1
  BATCH_FAILED=1
  BATCH_SUCCEEDED=1
  finalize_batch_result
  [[ "$RESULT_EXIT_CODE" -eq "$EXIT_INCONSISTENT" ]] ||
    fail "uncertain outcome did not take priority over Audit failure"
)
pass "batch exit-code precedence follows recovery, Audit, and partial-result priority"

printf 'All usb-approve checks passed\n'
