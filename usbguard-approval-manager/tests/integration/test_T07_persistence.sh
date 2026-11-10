#!/usr/bin/env bash
# T-07: Phase 7 Persistence & Failure Simulation (T-25..T-28) - SRS v4.5 Phase 7
# Tests: TTL persistence, expired record cleanup, commit failure recovery (T-26 style).
# Fully mocked.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"
CLEANUP="$PROJECT_ROOT/scripts/cleanup-expired.sh"

PASS_COUNT=0 TOTAL=0 FAIL_COUNT=0
pass_msg() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'PASS: %s\n' "$1"; }
fail_msg() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'FAIL: %s - %s\n' "$1" "$2" >&2; }

TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_STATE="$TEST_ROOT/state"
mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$FAKE_STATE/run_lock"

FAKE_RULES_FILE="$TEST_ROOT/active_rules.txt"
FAKE_BLOCKED_FILE="$TEST_ROOT/blocked_devices.txt"
printf '1: allow id 1d6b:0002\n2: block id 1234:5678\n' > "$FAKE_RULES_FILE"
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
if [[ "$*" == *"clock_state.py"* ]]; then echo "trusted_same_boot"; exit 0; fi
if [[ "$*" == *"atomic-write.py"* ]]; then exec /usr/bin/python3 "$@"; fi
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

printf 'RuleFolder=%s\n' "$TEST_ROOT/rules.d" > "$USBAM_DAEMON_CONFIG_PATH"
mkdir -p "$TEST_ROOT/rules.d"

printf '{"schema_version":1,"records":[]}\n' > "$TTL_FILE"
chmod 600 "$TTL_FILE"
printf '{"trusted":true,"boot_id":"persist-boot","epoch":%s}\n' "$(date +%s)" > "$CLOCK_STATE_FILE"
chmod 600 "$CLOCK_STATE_FILE"

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
# T-25: TTL record persists across simulated restart
# ------------------------------------------------------------------
printf '\n[T-25] TTL record persists across simulated restart\n'
TOTAL=$((TOTAL+1))
RULE25='allow id 11:22 serial "T07PERSIST" name "Persist Device" hash "hp25" parent-hash "" via-port "" with-interface 08:06:50'
HASH25="$(validators_hash_rule "$RULE25")"
MID25="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
CID25="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
EXP25=$(( $(date +%s) + 7200 ))
jq -n \
  --arg mid "$MID25" --arg rule "$RULE25" --arg sha "$HASH25" --argjson exp "$EXP25" \
  --arg status "active" --arg cid "$CID25" \
  '{managed_id:$mid, rule:$rule, rule_sha256:$sha, expires_at:$exp, status:$status, correlation_id:$cid}' > "$TTL_FILE"
# Simulate restart: re-read ttl.json
if validate_ttl_json "$TTL_FILE"; then
  stored_rule="$(jq -r '.records[0].rule' "$TTL_FILE")"
  stored_status="$(jq -r '.records[0].status' "$TTL_FILE")"
  if [[ "$stored_rule" == "$RULE25" && "$stored_status" == "active" ]]; then
    pass_msg "T-25 TTL record persists across restart"
  else
    fail_msg "T-25" "rule=$stored_rule status=$stored_status"
  fi
else
  fail_msg "T-25" "ttl.json invalid after persist: $VALIDATORS_ERROR"
fi

# ------------------------------------------------------------------
# T-26: commit failure recovery - rule added but TTL status update fails
# ------------------------------------------------------------------
printf '\n[T-26] commit failure leaves TTL in recovery_required\n'
TOTAL=$((TOTAL+1))
# Temporarily break atomic-write to simulate failure
mv "$FAKE_BIN/python3" "$FAKE_BIN/python3.real"
cat > "$FAKE_BIN/python3" <<'PY'
#!/usr/bin/env bash
if [[ "$*" == *"atomic-write.py"* ]]; then exit 1; fi
exec /usr/bin/python3.real "$@"
PY
chmod 700 "$FAKE_BIN/python3"
RULE26='allow id 33:44 serial "T07FAIL" name "Fail Device" hash "hp26" parent-hash "" via-port "" with-interface 08:06:50'
EXP26=$(( $(date +%s) + 3600 ))
set +e
mid26="$(stages_approve_temporary "$RULE26" "$EXP26" 2>&1)"
rc26=$?
set -e
# Restore python3
mv "$FAKE_BIN/python3.real" "$FAKE_BIN/python3"
if (( rc26 != 0 )); then
  status26="$(jq -r ".records[] | select(.managed_id==\"$mid26\") | .status" "$TTL_FILE" 2>/dev/null || echo "notfound")"
  if [[ "$status26" == "recovery_required" ]] || [[ "$status26" == "inconsistent" ]]; then
    pass_msg "T-26 commit failure marks TTL recovery_required/inconsistent ($status26)"
  else
    fail_msg "T-26" "expected recovery_required/inconsistent got $status26"
  fi
else
  fail_msg "T-26" "expected failure but approve_temporary succeeded rc=$rc26"
fi

# ------------------------------------------------------------------
# T-27: expired record cleanup marks recovery_required when persistent rule exists
# ------------------------------------------------------------------
printf '\n[T-27] expired record with persistent match -> recovery_required\n'
TOTAL=$((TOTAL+1))
RULE27='allow id 55:66 serial "T07PERSIST2" name "Persistent Match" hash "hp27" parent-hash "" via-port "" with-interface 08:06:50'
HASH27="$(validators_hash_rule "$RULE27")"
MID27="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
CID27="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
EXP27=$(( $(date +%s) - 10 ))
jq -n \
  --arg mid "$MID27" --arg rule "$RULE27" --arg sha "$HASH27" --argjson exp "$EXP27" \
  --arg status "active" --arg cid "$CID27" \
  '{managed_id:$mid, rule:$rule, rule_sha256:$sha, expires_at:$exp, status:$status, correlation_id:$cid}' > "$TTL_FILE"
printf '10: %s\n' "$RULE27" > "$FAKE_RULES_FILE"
printf '%s\n' "$RULE27" > "$TEST_ROOT/rules.conf"
printf 'RuleFile=%s\n' "$TEST_ROOT/rules.conf" > "$USBAM_DAEMON_CONFIG_PATH"
set +e
bash "$CLEANUP" > "$TEST_ROOT/cleanup27.log" 2>&1
rc27=$?
set -e
if (( rc27 == 0 )); then
  status27="$(jq -r ".records[] | select(.managed_id==\"$MID27\") | .status" "$TTL_FILE")"
  if grep -Fq "$RULE27" "$FAKE_RULES_FILE" && [[ "$status27" == "recovery_required" ]]; then
    pass_msg "T-27 persistent rule preserved, TTL recovery_required"
  else
    fail_msg "T-27" "status=$status27 rule_present=$(grep -Fcq "$RULE27" "$FAKE_RULES_FILE" && echo yes || echo no)"
  fi
else
  fail_msg "T-27" "cleanup-expired failed rc=$rc27"
fi

# ------------------------------------------------------------------
# T-28: final state consistency - all TTL records valid
# ------------------------------------------------------------------
printf '\n[T-28] final TTL state consistency\n'
TOTAL=$((TOTAL+1))
if validate_ttl_json "$TTL_FILE"; then
  record_count="$(jq '.records | length' "$TTL_FILE")"
  pass_msg "T-28 final TTL valid with $record_count record(s)"
else
  fail_msg "T-28" "final TTL invalid: $VALIDATORS_ERROR"
fi

printf '\n=== T07 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi

