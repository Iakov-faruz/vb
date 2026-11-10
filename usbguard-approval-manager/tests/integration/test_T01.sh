#!/usr/bin/env bash
# T-01: Temporary Approval (T-01..T-04) - SRS v4.5 Phase 7
# Tests: approve_temporary happy path, TTL atomic write, duplicate handling,
# restore_journal block (EXIT 9). Fully mocked - no real USBGuard or systemd.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"

PASS_COUNT=0
TOTAL=0
FAIL_COUNT=0

pass_msg() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'PASS: %s\n' "$1"; }
fail_msg() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'FAIL: %s - %s\n' "$1" "$2" >&2; }

TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_STATE="$TEST_ROOT/state"
FAKE_POLICY_DIR="$TEST_ROOT/rules.d"
mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$FAKE_STATE/run_lock" "$FAKE_POLICY_DIR"

FAKE_RULES_FILE="$TEST_ROOT/active_rules.txt"
FAKE_BLOCKED_FILE="$TEST_ROOT/blocked_devices.txt"
printf '1: allow id 1d6b:0002 serial "" name "hub" hash "" parent-hash "" via-port "" with-interface 09:00:00\n' > "$FAKE_RULES_FILE"
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
  list-devices)
    if [[ "${2:-}" == "--blocked" ]]; then cat "$FAKE_BLOCKED_FILE" 2>/dev/null || true; exit 0; fi
    cat "$FAKE_RULES_FILE" 2>/dev/null || printf '1: allow id 1d6b:0002\n2: block id 1234:5678\n'
    ;;
  list-rules) cat "$FAKE_RULES_FILE" 2>/dev/null || true ;;
  allow-device) exit 0 ;;
  block-device) echo "$2: block" >> "$FAKE_BLOCKED_FILE"; exit 0 ;;
  append-rule)
    rule=""; for arg in "$@"; do [[ "$arg" != "append-rule" && "$arg" != "--temporary" ]] && rule="$arg"; done
    max_id=$(awk -F: '{gsub(/ /,"",$1); if($1>max) max=$1} END{print max+0}' "$FAKE_RULES_FILE" 2>/dev/null || echo 0)
    new_id=$((max_id+1))
    printf '%s: %s\n' "$new_id" "$rule" >> "$FAKE_RULES_FILE"
    printf '%s\n' "$new_id"
    exit 0
    ;;
  remove-rule)
    rid="${2:-}"; grep -v "^[[:space:]]*$rid:" "$FAKE_RULES_FILE" > "$FAKE_RULES_FILE.tmp" || true; mv "$FAKE_RULES_FILE.tmp" "$FAKE_RULES_FILE"; exit 0 ;;
  *) exit 64 ;;
esac
MOCK
chmod 700 "$FAKE_BIN/usbguard"

cat > "$FAKE_BIN/python3" <<'PY'
#!/usr/bin/env bash
if [[ "$*" == *"clock_state.py"* ]]; then
  echo "trusted_same_boot"; exit 0
fi
if [[ "$*" == *"atomic-write.py"* ]]; then
  exec /usr/bin/python3 "$@"
fi
if [[ "$*" == *"audit_write.py"* ]]; then exit 0; fi
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
export USBAM_DAEMON_CONFIG_PATH="$TEST_ROOT/usbguard-daemon.conf"
export CONFIG_PATH="$TEST_ROOT/approval-manager.conf"
export USBAM_CONFIG_PATH="$TEST_ROOT/approval-manager.conf"
export FAKE_STATE_DIR="$TEST_ROOT"
export FAKE_RULES_ACTIVE="$FAKE_RULES_FILE"
export FAKE_BLOCKED_FILE_PATH="$FAKE_BLOCKED_FILE"
export USBAM_STATE_LOCK_FILE="$FAKE_STATE/run_lock/state.lock"
export USBAM_POLICY_LOCK_FILE="$FAKE_STATE/run_lock/policy.lock"
touch "$USBAM_STATE_LOCK_FILE" "$USBAM_POLICY_LOCK_FILE"; chmod 600 "$USBAM_STATE_LOCK_FILE" "$USBAM_POLICY_LOCK_FILE"
export FAKE_CLOCK_RESULT="trusted_same_boot"

cat > "$TEST_ROOT/approval-manager.conf" <<'CONF'
TEMP_TTL_SECONDS=3600
MIN_REASONABLE_EPOCH=1577836800
MAX_CLOCK_JUMP_SECONDS=3600
BACKUP_KEEP=5
IPC_TIMEOUT_SECONDS=5
LOG_LEVEL=INFO
CONF

printf 'RuleFolder=%s\n' "$FAKE_POLICY_DIR" > "$USBAM_DAEMON_CONFIG_PATH"

export USBAM_G01_VERIFIED=1
is_g01_verified() { return 0; }

cleanup() {
  lock_release >/dev/null 2>&1 || true
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

source "$LIB_DIR/config-reader.sh"
source "$LIB_DIR/validators.sh"
source "$LIB_DIR/usbguard-policy.sh"
source "$LIB_DIR/time-guards.sh"
source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lock.sh"
source "$LIB_DIR/logger.sh"
source "$LIB_DIR/result.sh"

# ------------------------------------------------------------------
# T-01: happy path temporary approval
# ------------------------------------------------------------------
printf '\n[T-01] temporary approval happy path\n'
TOTAL=$((TOTAL+1))
RULE='allow id 1234:5678 serial "T01TEST" name "T01 Device" hash "aaa" parent-hash "" via-port "" with-interface 08:06:50'
EXPIRES=$(( $(date +%s) + 3600 ))
set +e
mid="$(stages_approve_temporary "$RULE" "$EXPIRES" 2>&1)"
rc=$?
set -e
if (( rc == 0 )) && [[ -n "$mid" ]] && [[ "$mid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  if validate_ttl_json "$TTL_FILE"; then
    status="$(jq -r ".records[] | select(.managed_id==\"$mid\") | .status" "$TTL_FILE")"
    if [[ "$status" == "active" ]]; then
      pass_msg "T-01 temporary approval created active record managed_id=$mid"
    else
      fail_msg "T-01" "status is $status expected active"
    fi
  else
    fail_msg "T-01" "ttl.json invalid after approval: $VALIDATORS_ERROR"
  fi
else
  fail_msg "T-01" "approve_temporary failed rc=$rc mid=$mid"
fi

# ------------------------------------------------------------------
# T-02: TTL record schema and expiry
# ------------------------------------------------------------------
printf '\n[T-02] TTL record schema and expires_at\n'
TOTAL=$((TOTAL+1))
if validate_ttl_json "$TTL_FILE"; then
  schema_ver="$(jq -r '.schema_version' "$TTL_FILE")"
  exp="$(jq -r ".records[] | select(.managed_id==\"$mid\") | .expires_at" "$TTL_FILE")"
  now="$(date +%s)"
  if [[ "$schema_ver" == "1" ]] && [[ "$exp" =~ ^[0-9]+$ ]] && (( exp > now )); then
    pass_msg "T-02 ttl.json schema_version=1 expires_at=$exp valid"
  else
    fail_msg "T-02" "schema=$schema_ver expires=$exp now=$now"
  fi
else
  fail_msg "T-02" "ttl.json invalid: $VALIDATORS_ERROR"
fi

# ------------------------------------------------------------------
# T-03: duplicate temporary rule handling
# ------------------------------------------------------------------
printf '\n[T-03] duplicate temporary rule rejected\n'
TOTAL=$((TOTAL+1))
set +e
dup_id="$(stages_approve_temporary "$RULE" "$EXPIRES" 2>&1)"
dup_rc=$?
set -e
if (( dup_rc != 0 )); then
  count="$(jq '[.records[] | select(.rule == "'"$RULE"'")] | length' "$TTL_FILE" 2>/dev/null || echo 0)"
  if (( count <= 1 )) && validate_ttl_json "$TTL_FILE"; then
    pass_msg "T-03 duplicate rule rejected, ttl.json valid count=$count"
  else
    fail_msg "T-03" "ttl.json invalid or count=$count after duplicate"
  fi
else
  fail_msg "T-03" "duplicate approve succeeded unexpectedly rc=$dup_rc id=$dup_id"
fi

# ------------------------------------------------------------------
# T-04: restore_journal.json blocks approvals (EXIT 9)
# ------------------------------------------------------------------
printf '\n[T-04] restore_journal.json blocks approvals\n'
TOTAL=$((TOTAL+1))
printf '{"schema_version":1,"timestamp":"2024-01-01T00:00:00Z","operation":"backup","files":[]}\n' > "$RESTORE_JOURNAL_FILE"
chmod 600 "$RESTORE_JOURNAL_FILE"
set +e
blocked_id="$(stages_approve_temporary 'allow id abcd:1234 serial "BLOCKED" name "Blocked Device" hash "bbb" parent-hash "" via-port "" with-interface 08:06:50' 3600 2>&1)"
blocked_rc=$?
set -e
if (( blocked_rc == 9 )); then
  if grep -Fq 'BLOCKED' "$FAKE_RULES_FILE" 2>/dev/null; then
    fail_msg "T-04" "rule added despite journal block"
  else
    pass_msg "T-04 restore_journal blocks approve (EXIT 9)"
  fi
else
  fail_msg "T-04" "expected EXIT 9 got rc=$blocked_rc id=$blocked_id"
fi
rm -f "$RESTORE_JOURNAL_FILE"

printf '\n=== T01 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi

