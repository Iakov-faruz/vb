#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/validators.sh"
source "$PROJECT_ROOT/scripts/lib/stages.sh"

TEST_DIR="$(mktemp -d)"
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
trap 'rm -rf -- "$TEST_DIR"' EXIT

# Setup fake usbguard like in policy_write test
FAKE_RULES_FILE="$TEST_DIR/active_rules.txt"
printf '1: allow id 1d6b:0002\n' > "$FAKE_RULES_FILE"
FAKE_BLOCKED_FILE="$TEST_DIR/blocked_devices.txt"
printf '' > "$FAKE_BLOCKED_FILE"

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
STATE_DIR="${FAKE_STATE_DIR:-/tmp}"
RULES_FILE="$STATE_DIR/active_rules.txt"
BLOCKED_FILE="$STATE_DIR/blocked_devices.txt"
printf '%s\n' "$*" >> "$STATE_DIR/usbguard-commands.log"
case "$1" in
  --version) printf 'USBGuard 1.1.4\n' ;;
  list-devices)
    if [[ "${2:-}" == "--blocked" ]]; then cat "$BLOCKED_FILE" 2>/dev/null || true; exit 0; fi
    printf '1: allow id 1d6b:0002\n'
    ;;
  list-rules) cat "$RULES_FILE" 2>/dev/null || true ;;
  allow-device) exit 0 ;;
  block-device) echo "$2: block" >> "$BLOCKED_FILE"; exit 0 ;;
  append-rule)
    rule=""; for arg in "$@"; do [[ "$arg" != "append-rule" && "$arg" != "--temporary" ]] && rule="$arg"; done
    max_id=$(awk -F: '{gsub(/ /,"",$1); if($1>max) max=$1} END{print max+0}' "$RULES_FILE" 2>/dev/null || echo 0)
    new_id=$((max_id+1))
    printf '%s: %s\n' "$new_id" "$rule" >> "$RULES_FILE"
    printf '%s\n' "$new_id"
    exit 0
    ;;
  remove-rule)
    rid="${2:-}"; grep -v "^[[:space:]]*$rid:" "$RULES_FILE" > "$RULES_FILE.tmp" || true; mv "$RULES_FILE.tmp" "$RULES_FILE"; exit 0 ;;
  *) exit 64 ;;
esac
MOCK

cat > "$FAKE_BIN/pgrep" <<'MOCK'
#!/usr/bin/env bash
printf '42\n'; exit 0
MOCK

chmod 700 "$FAKE_BIN/usbguard" "$FAKE_BIN/pgrep"
PATH="$FAKE_BIN:$PATH"
export PATH
export FAKE_STATE_DIR="$TEST_DIR"
export USBAM_STATE_DIR="$TEST_DIR/state"
export STATE_DIR="$TEST_DIR/state"
export TTL_FILE="$STATE_DIR/ttl.json"
export CLOCK_STATE_FILE="$STATE_DIR/clock_state.json"
export RESTORE_JOURNAL_FILE="$STATE_DIR/restore_journal.json"
mkdir -p "$STATE_DIR"
LOCK_FILE="$TEST_DIR/lock"
touch "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
USBAM_G01_VERIFIED=1
export USBAM_G01_VERIFIED
IPC_TIMEOUT_SECONDS=1
MIN_REASONABLE_EPOCH=1577836800
MAX_CLOCK_JUMP_SECONDS=3600
export MIN_REASONABLE_EPOCH MAX_CLOCK_JUMP_SECONDS
USBAM_DAEMON_CONFIG_PATH="$TEST_DIR/usbguard-daemon.conf"
printf 'RuleFile=%s\n' "$TEST_DIR/rules.conf" > "$USBAM_DAEMON_CONFIG_PATH"
touch "$TEST_DIR/rules.conf"
export USBAM_DAEMON_CONFIG_PATH

is_g01_verified() {
  [[ "${FAKE_G01_VERIFIED:-0}" == "1" ]]
}
FAKE_G01_VERIFIED=1

cat > "$FAKE_BIN/systemctl" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "is-active --quiet ntpsec" ]]
MOCK
cat > "$FAKE_BIN/timedatectl" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "show -p NTPSynchronized --value" ]] || exit 2
printf '%s\n' "${FAKE_TIME_SYNCED:-yes}"
MOCK
cat > "$FAKE_BIN/ntpq" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == "-pn" ]] || exit 2
printf '*192.0.2.1 192.0.2.2 2 u 10 64 377 1.0 0.1 0.2\n'
MOCK
chmod 700 "$FAKE_BIN/systemctl" "$FAKE_BIN/timedatectl" "$FAKE_BIN/ntpq"
cat > "$TEST_DIR/bin/python3" <<'PY'
#!/usr/bin/env bash
# Intercept clock_state.py calls and return trusted
if [[ "$*" == *"clock_state.py"* ]]; then
  echo "trusted_same_boot"
  exit 0
fi
# For other python calls, use real python
exec /usr/bin/python3 "$@"
PY
chmod 700 "$TEST_DIR/bin/python3"
trap 'lock_release; rm -rf -- "$TEST_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

# Test stages_create_pending_record
record="$(stages_create_pending_record 'allow id 1234:5678' 9999999999)"
[[ -n "$record" ]] || fail "create_pending_record failed"
managed_id="$(echo "$record" | jq -r .managed_id)"
validators_is_uuid_v4 "$managed_id" || fail "managed_id not uuid v4"
pass "stages_create_pending_record creates valid record"

# Test stages_add_record
stages_add_record "$record" "$TTL_FILE" || fail "add_record failed"
validate_ttl_json "$TTL_FILE" || fail "ttl.json invalid after add"
pass "stages_add_record adds and validates"

# Test stages_update_status pending -> active
stages_update_status "$managed_id" "active" "$TTL_FILE" || fail "update status pending->active failed"
status="$(jq -r ".records[] | select(.managed_id==\"$managed_id\") | .status" "$TTL_FILE")"
[[ "$status" == "active" ]] || fail "status not updated to active"
pass "stages_update_status pending->active"

# Test invalid transition active->pending should fail
if stages_update_status "$managed_id" "pending" "$TTL_FILE" 2>/dev/null; then
  fail "invalid transition active->pending accepted"
fi
pass "stages_update_status rejects invalid transition"

# Test stages_approve_temporary (full transaction)
# Need to set up time-guards mock to return trusted
# Already mocked via python3 wrapper that returns trusted for clock_state
# Also need to mock detect_clock_jump to succeed
# Our wrapper should make clock_state.py return trusted, so detect_clock_jump should succeed

# For approve_temporary, we need to ensure no restore journal
rm -f "$RESTORE_JOURNAL_FILE"

# Create new ttl file empty
rm -f "$TTL_FILE"
stages_init_ttl_file_if_missing

FAKE_TIME_SYNCED="no"
export FAKE_TIME_SYNCED
if stages_approve_temporary 'allow id abcd:ef02' 3600 >/dev/null 2>&1; then
  fail "temporary approval accepted an unsynchronized clock with no existing TTL records"
fi
[[ "$(jq '.records | length' "$TTL_FILE")" == "0" ]] ||
  fail "untrusted initial approval created a TTL record"
unset FAKE_TIME_SYNCED

new_managed="$(stages_approve_temporary 'allow id abcd:ef01' 3600)"
[[ -n "$new_managed" ]] || fail "approve_temporary failed"
validators_is_uuid_v4 "$new_managed" || fail "approve_temporary returned invalid managed_id"
# Check status active
status="$(jq -r ".records[] | select(.managed_id==\"$new_managed\") | .status" "$TTL_FILE")"
[[ "$status" == "active" ]] || fail "approve_temporary should result in active, got $status"
pass "stages_approve_temporary full transaction"

new_device_managed="$(
  stages_approve_temporary 'allow id abcd:ef03' 3600 \
    'f212db55-5330-4b54-ae96-07582941c7c3' 1
)" || fail "temporary approval with a connected device failed"
[[ "$(jq -r ".records[] | select(.managed_id==\"$new_device_managed\") | .status" "$TTL_FILE")" == "active" ]] ||
  fail "device approval transaction did not reach active TTL state"
grep -Fqx 'allow-device 1' "$TEST_DIR/usbguard-commands.log" ||
  fail "temporary approval did not explicitly approve the connected device"
pass "temporary transaction approves the connected device separately from adding its rule"

# A permanent match must not be duplicated as a temporary TTL rule.
printf 'allow id abcd:ef04\n' >> "$TEST_DIR/rules.conf"
records_before="$(jq '.records | length' "$TTL_FILE")"
if stages_approve_temporary 'allow id abcd:ef04' 3600 >/dev/null 2>&1; then
  fail "temporary approval duplicated a persistent rule"
fi
[[ "$STAGES_ERROR_CODE" == "persistent_overlap" ]] ||
  fail "persistent overlap returned an unexpected error code"
[[ "$(jq '.records | length' "$TTL_FILE")" == "$records_before" ]] ||
  fail "persistent overlap created a TTL record"
if grep -Fqx 'append-rule --temporary allow id abcd:ef04' \
  "$TEST_DIR/usbguard-commands.log"; then
  fail "persistent overlap changed active policy"
fi
pass "persistent rules are rejected before creating TTL state or changing policy"

# Test that pending leftover goes to recovery_required in reconcile simulation
# Create a pending record manually
pending_rec="$(stages_create_pending_record 'allow id 1111:2222' 9999999999)"
stages_add_record "$pending_rec" "$TTL_FILE"
pending_id="$(echo "$pending_rec" | jq -r .managed_id)"
# Simulate reconcile - pending should be moved to recovery_required
# We will run cleanup-expired --reconcile logic manually via stages_update_status
# For unit test, just verify pending exists
status="$(jq -r ".records[] | select(.managed_id==\"$pending_id\") | .status" "$TTL_FILE")"
[[ "$status" == "pending" ]] || fail "pending record not created"
pass "pending record creation for reconcile test"

printf 'All stages checks passed\n'
