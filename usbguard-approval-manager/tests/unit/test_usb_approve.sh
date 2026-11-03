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

printf 'All usb-approve checks passed\n'
