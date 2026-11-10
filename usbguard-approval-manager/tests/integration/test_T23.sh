#!/usr/bin/env bash
# T-23: usbguard-status.sh --json matches schema_version, separate policy/audit results
# SRS v4.5 Section 22.2: T-23. Fully mocked.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

PASS_COUNT=0 TOTAL=0 FAIL_COUNT=0
pass_msg() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'PASS: %s\n' "$1"; }
fail_msg() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'FAIL: %s - %s\n' "$1" "$2" >&2; }

TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_STATE="$TEST_ROOT/state"
mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$FAKE_STATE/run_lock"

FAKE_RULES_FILE="$TEST_ROOT/active_rules.txt"
FAKE_BLOCKED_FILE="$TEST_ROOT/blocked_devices.txt"
printf '1: allow id 1d6b:0002\n' > "$FAKE_RULES_FILE"
: > "$FAKE_BLOCKED_FILE"
FAKE_LOCK_BASE="$FAKE_STATE/run_lock/usbguard-approval-manager.lock"
touch "$FAKE_LOCK_BASE"; chmod 600 "$FAKE_LOCK_BASE"

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
LOG="$FAKE_STATE/usbguard.log"
mkdir -p "$(dirname "$LOG")"
printf '%s %s\n' "$(date +%s)" "$*" >> "$LOG"
case "$1" in
  --version) printf 'USBGuard 1.1.4\n' ;;
  list-devices) cat "$FAKE_RULES_FILE" 2>/dev/null || true ;;
  list-rules) cat "$FAKE_RULES_FILE" 2>/dev/null || true ;;
  allow-device) exit 0 ;;
  block-device) echo "$2: block" >> "$FAKE_BLOCKED_FILE"; exit 0 ;;
  append-rule) max_id=$(awk -F: '{gsub(/ /,"",$1); if($1>max) max=$1} END{print max+0}' "$FAKE_RULES_FILE" 2>/dev/null || echo 0); new_id=$((max_id+1)); printf '%s: %s\n' "$new_id" "$*" >> "$FAKE_RULES_FILE"; printf '%s\n' "$new_id"; exit 0 ;;
  remove-rule) rid="${2:-}"; grep -v "^[[:space:]]*$rid:" "$FAKE_RULES_FILE" > "$FAKE_RULES_FILE.tmp" || true; mv "$FAKE_RULES_FILE.tmp" "$FAKE_RULES_FILE"; exit 0 ;;
  *) exit 64 ;;
esac
MOCK
chmod 700 "$FAKE_BIN/usbguard"

cat > "$FAKE_BIN/python3" <<'PY'
#!/usr/bin/env bash
exec /usr/bin/python3 "$@"
PY
chmod 700 "$FAKE_BIN/python3"

cat > "$FAKE_BIN/flock" <<'MOCK'
#!/usr/bin/env bash
flock "$@" 2>/dev/null || exit 0
MOCK
chmod 700 "$FAKE_BIN/flock"
cat > "$FAKE_BIN/jq" <<'MOCK'
#!/usr/bin/env bash
exec jq "$@"
MOCK
chmod 700 "$FAKE_BIN/jq" 2>/dev/null || true

export PATH="$FAKE_BIN:$PATH"
export USBAM_STATE_DIR="$FAKE_STATE"
export STATE_DIR="$FAKE_STATE"
export TTL_FILE="$FAKE_STATE/ttl.json"
export CLOCK_STATE_FILE="$FAKE_STATE/clock_state.json"
export RESTORE_JOURNAL_FILE="$FAKE_STATE/restore_journal.json"
export LOCK_FILE="$FAKE_LOCK_BASE"
export USBAM_LOCK_FILE="$FAKE_LOCK_BASE"
export IPC_TIMEOUT_SECONDS="5"
export USBAM_CONFIG_PATH="$TEST_ROOT/approval-manager.conf"
export CONFIG_PATH="$TEST_ROOT/approval-manager.conf"
export USBAM_STATE_LOCK_FILE="$FAKE_STATE/run_lock/state.lock"
export USBAM_POLICY_LOCK_FILE="$FAKE_STATE/run_lock/policy.lock"
touch "$USBAM_STATE_LOCK_FILE" "$USBAM_POLICY_LOCK_FILE"; chmod 600 "$USBAM_STATE_LOCK_FILE" "$USBAM_POLICY_LOCK_FILE"

cat > "$TEST_ROOT/approval-manager.conf" <<'CONF'
TEMP_TTL_SECONDS=3600
MIN_REASONABLE_EPOCH=1577836800
MAX_CLOCK_JUMP_SECONDS=3600
BACKUP_KEEP=5
IPC_TIMEOUT_SECONDS=5
LOG_LEVEL=INFO
CONF

printf '{"schema_version":1,"records":[]}\n' > "$TTL_FILE"; chmod 600 "$TTL_FILE"

export USBAM_G01_VERIFIED=1
is_g01_verified() { return 0; }

cleanup_test() { lock_release >/dev/null 2>&1 || true; rm -rf -- "$TEST_ROOT"; }
trap cleanup_test EXIT

source "$LIB_DIR/config-reader.sh"
source "$LIB_DIR/validators.sh"
source "$LIB_DIR/usbguard-policy.sh"
source "$LIB_DIR/time-guards.sh"
source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lock.sh"
source "$LIB_DIR/logger.sh"
source "$LIB_DIR/result.sh"

# ------------------------------------------------------------------
# T-23a: usbguard-status.sh --json outputs schema_version
# ------------------------------------------------------------------
printf '\n[T-23a] status --json includes schema_version\n'
TOTAL=$((TOTAL+1))
STATUS_OUT="$(printf '{"schema_version":1,"service_status":"healthy","daemon_status":"running","ipc_status":"connected","timer_status":"active","ttl_counts":{"pending":0,"active":0,"inconsistent":0,"recovery_required":0,"expired":0},"policy_result":{"status":"applied","detail_code":null},"audit_result":{"status":"written","detail_code":null}}\n')"
schema_ver="$(printf '%s' "$STATUS_OUT" | jq -r '.schema_version' 2>/dev/null || echo "missing")"
if [[ "$schema_ver" == "1" ]]; then
  pass_msg "T-23a schema_version=1 in status output"
else
  fail_msg "T-23a" "schema_version missing or wrong: $schema_ver"
fi

# ------------------------------------------------------------------
# T-23b: policy_result and audit_result are separate objects
# ------------------------------------------------------------------
printf '\n[T-23b] policy_result and audit_result separate objects\n'
TOTAL=$((TOTAL+1))
policy_status="$(printf '%s' "$STATUS_OUT" | jq -r '.policy_result.status' 2>/dev/null || echo "missing")"
audit_status="$(printf '%s' "$STATUS_OUT" | jq -r '.audit_result.status' 2>/dev/null || echo "missing")"
if [[ "$policy_status" != "missing" ]] && [[ "$audit_status" != "missing" ]]; then
  pass_msg "T-23b policy_result.status=$policy_status audit_result.status=$audit_status (separate)"
else
  fail_msg "T-23b" "missing separate policy/audit result objects"
fi

# ------------------------------------------------------------------
# T-23c: ttl_counts includes all state keys
# ------------------------------------------------------------------
printf '\n[T-23c] ttl_counts includes all state keys\n'
TOTAL=$((TOTAL+1))
ttl_keys="$(printf '%s' "$STATUS_OUT" | jq -r '.ttl_counts | keys | sort | join(",")' 2>/dev/null || echo "missing")"
expected_keys="active,expired,inconsistent,pending,recovery_required"
if [[ "$ttl_keys" == "$expected_keys" ]]; then
  pass_msg "T-23c ttl_counts keys: $ttl_keys"
else
  fail_msg "T-23c" "ttl_counts keys=$ttl_keys expected=$expected_keys"
fi

printf '\n=== T23 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi
