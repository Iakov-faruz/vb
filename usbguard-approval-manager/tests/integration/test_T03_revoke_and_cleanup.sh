#!/usr/bin/env bash
# T-03: Revoke and Cleanup (T-09..T-12) - SRS v4.5 Phase 7
# Tests: cleanup-expired removes expired temporary rules, preserves permanent
# rules, and marks TTL records correctly. Fully mocked.
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

# Helper to create a TTL record
create_ttl_record() {
  local mid="$1" rule="$2" hash="$3" exp="$4" status="$5" cid="$6"
  jq -n \
    --arg mid "$mid" --arg rule "$rule" --arg sha "$hash" --argjson exp "$exp" \
    --arg status "$status" --arg cid "$cid" \
    '{managed_id:$mid, rule:$rule, rule_sha256:$sha, expires_at:$exp, status:$status, correlation_id:$cid}'
}

# ------------------------------------------------------------------
# T-09: expired temporary rule is removed from active policy + TTL updated
# ------------------------------------------------------------------
printf '\n[T-09] expired temporary rule removed from active policy\n'
TOTAL=$((TOTAL+1))
RULE9='allow id aa:bb serial "T03EXP" name "Expired Temp" hash "hash9" parent-hash "" via-port "" with-interface 08:06:50'
HASH9="$(validators_hash_rule "$RULE9")"
MID9="11111111-1111-4111-8111-111111111111"
CID9="22222222-2222-4222-8222-222222222222"
EXP9=$(( $(date +%s) - 10 ))
create_ttl_record "$MID9" "$RULE9" "$HASH9" "$EXP9" "active" "$CID9" > "$TTL_FILE"
printf '10: %s\n' "$RULE9" > "$FAKE_RULES_FILE"
set +e
bash "$CLEANUP" > "$TEST_ROOT/cleanup9.log" 2>&1
rc9=$?
set -e
if (( rc9 == 0 )); then
  if ! grep -Fq "$RULE9" "$FAKE_RULES_FILE"; then
    pass_msg "T-09 expired rule removed from active policy (rc=0)"
  else
    fail_msg "T-09" "expired rule still present in active policy"
  fi
else
  fail_msg "T-09" "cleanup-expired failed rc=$rc9 log=$(cat $TEST_ROOT/cleanup9.log)"
fi

# ------------------------------------------------------------------
# T-10: permanent rule is preserved by cleanup-expired
# ------------------------------------------------------------------
printf '\n[T-10] permanent rule preserved by cleanup-expired\n'
TOTAL=$((TOTAL+1))
RULE10='allow id cc:dd serial "T03PERM" name "Permanent Keep" hash "hash10" parent-hash "" via-port "" with-interface 08:06:50'
HASH10="$(validators_hash_rule "$RULE10")"
MID10="33333333-3333-4333-8333-333333333333"
CID10="44444444-4444-4444-8444-444444444444"
EXP10=$(( $(date +%s) - 10 ))
create_ttl_record "$MID10" "$RULE10" "$HASH10" "$EXP10" "active" "$CID10" > "$TTL_FILE"
printf '10: %s\n' "$RULE10" > "$FAKE_RULES_FILE"
printf '%s\n' "$RULE10" > "$TEST_ROOT/rules.conf"
printf 'RuleFile=%s\n' "$TEST_ROOT/rules.conf" > "$USBAM_DAEMON_CONFIG_PATH"
set +e
bash "$CLEANUP" > "$TEST_ROOT/cleanup10.log" 2>&1
rc10=$?
set -e
if (( rc10 == 0 )); then
  if grep -Fq "$RULE10" "$FAKE_RULES_FILE"; then
    status10="$(jq -r ".records[] | select(.managed_id==\"$MID10\") | .status" "$TTL_FILE")"
    if [[ "$status10" == "recovery_required" ]]; then
      pass_msg "T-10 permanent rule preserved, TTL marked recovery_required"
    else
      fail_msg "T-10" "status is $status10 expected recovery_required"
    fi
  else
    fail_msg "T-10" "permanent rule was removed from active policy"
  fi
else
  fail_msg "T-10" "cleanup-expired failed rc=$rc10 log=$(cat $TEST_ROOT/cleanup10.log)"
fi

# ------------------------------------------------------------------
# T-11: cleanup-expired with open restore journal exits 9
# ------------------------------------------------------------------
printf '\n[T-11] cleanup-expired blocked by open restore journal\n'
TOTAL=$((TOTAL+1))
printf '{"schema_version":1,"operation":"backup","files":[]}\n' > "$RESTORE_JOURNAL_FILE"
chmod 600 "$RESTORE_JOURNAL_FILE"
set +e
bash "$CLEANUP" > "$TEST_ROOT/cleanup11.log" 2>&1
rc11=$?
set -e
rm -f "$RESTORE_JOURNAL_FILE"
if [[ "$rc11" == "9" ]]; then
  pass_msg "T-11 cleanup-expired exits 9 with open restore journal"
else
  fail_msg "T-11" "expected EXIT 9 got rc=$rc11 log=$(cat $TEST_ROOT/cleanup11.log)"
fi

# ------------------------------------------------------------------
# T-12: cleanup-expired with expired record still allowed by persistent rule
# ------------------------------------------------------------------
printf '\n[T-12] expired rule still allowed by persistent policy rule\n'
TOTAL=$((TOTAL+1))
RULE12='allow id ee:ff serial "T03PERSIST" name "Still Persistent" hash "hash12" parent-hash "" via-port "" with-interface 08:06:50'
HASH12="$(validators_hash_rule "$RULE12")"
MID12="55555555-5555-4555-8555-555555555555"
CID12="66666666-6666-4666-8666-666666666666"
EXP12=$(( $(date +%s) - 10 ))
create_ttl_record "$MID12" "$RULE12" "$HASH12" "$EXP12" "active" "$CID12" > "$TTL_FILE"
printf '10: %s\n' "$RULE12" > "$FAKE_RULES_FILE"
printf '11: %s\n' "$RULE12" >> "$FAKE_RULES_FILE"
set +e
bash "$CLEANUP" > "$TEST_ROOT/cleanup12.log" 2>&1
rc12=$?
set -e
if (( rc12 == 0 )); then
  if grep -Fq "EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED" "$TEST_ROOT/cleanup12.log"; then
    pass_msg "T-12 reports EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED"
  else
    fail_msg "T-12" "missing EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED in log"
  fi
else
  fail_msg "T-12" "cleanup-expired failed rc=$rc12 log=$(cat $TEST_ROOT/cleanup12.log)"
fi

printf '\n=== T03 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi

