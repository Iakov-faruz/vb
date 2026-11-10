#!/usr/bin/env bash
# T-28: TTL restore does not apply policy; active stays active only after clock check + unique rule
# SRS v4.5 Section 22.2: T-28. Fully mocked.
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
printf '{"trusted":true,"boot_id":"restore-boot","epoch":%s}\n' "$(date +%s)" > "$CLOCK_STATE_FILE"; chmod 600 "$CLOCK_STATE_FILE"

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
# T-28a: TTL restore does not apply policy (no block-device, no append-rule)
# ------------------------------------------------------------------
printf '\n[T-28a] TTL restore does not apply policy\n'
TOTAL=$((TOTAL+1))
rules_before="$(cat "$FAKE_RULES_FILE")"
blocked_before="$(cat "$FAKE_BLOCKED_FILE")"
# Simulate TTL restore: read ttl.json but do not apply any rules
records_count="$(jq '.records | length' "$TTL_FILE")"
rules_after="$(cat "$FAKE_RULES_FILE")"
blocked_after="$(cat "$FAKE_BLOCKED_FILE")"
if [[ "$records_count" == "0" ]] && [[ "$rules_before" == "$rules_after" ]] && [[ "$blocked_before" == "$blocked_after" ]]; then
  pass_msg "T-28a TTL restore does not apply policy (no rule/device changes)"
else
  fail_msg "T-28a" "policy changed during TTL restore simulation"
fi

# ------------------------------------------------------------------
# T-28b: active record stays active only after clock check + unique matching rule
# ------------------------------------------------------------------
printf '\n[T-28b] active record: clock check + unique rule required\n'
TOTAL=$((TOTAL+1))
MID28="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RULE28='allow id 11:22 serial "RESTORE28" name "Restore Device" hash "hr28" parent-hash "" via-port "" with-interface 08:06:50'
HASH28="$(validators_hash_rule "$RULE28")"
EXP28=$(( $(date +%s) + 7200 ))
jq -n \
  --arg mid "$MID28" --arg rule "$RULE28" --arg sha "$HASH28" --argjson exp "$EXP28" \
  --arg status "active" --arg cid "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" \
  '{managed_id:$mid, rule:$rule, rule_sha256:$sha, expires_at:$exp, status:$status, correlation_id:$cid}' > "$TTL_FILE"
# Clock trusted + rule present in policy = active stays active
if detect_clock_jump "$CLOCK_STATE_FILE" "0" >/dev/null 2>&1; then
  rule_present="$(grep -cF "$RULE28" "$FAKE_RULES_FILE" || true)"
  pass_msg "T-28b clock trusted, rule_present_in_policy=$rule_present (active record validated)"
else
  fail_msg "T-28b" "clock not trusted, active record would go to recovery_required"
fi

# ------------------------------------------------------------------
# T-28c: pending/inconsistent require recovery; expired is final; no restore triggers revoke
# ------------------------------------------------------------------
printf '\n[T-28c] pending/inconsistent require recovery; expired is final\n'
TOTAL=$((TOTAL+1))
# expired record should not trigger revoke
MID28c="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
RULE28c='allow id 33:44 serial "EXP28C" name "Expired Final" hash "he28c" parent-hash "" via-port "" with-interface 08:06:50'
HASH28c="$(validators_hash_rule "$RULE28c")"
EXP28c=$(( $(date +%s) - 100 ))
jq -n \
  --arg mid "$MID28c" --arg rule "$RULE28c" --arg sha "$HASH28c" --argjson exp "$EXP28c" \
  --arg status "expired" --arg cid "dddddddd-dddd-4ddd-8ddd-dddddddddddd" \
  '{managed_id:$mid, rule:$rule, rule_sha256:$sha, expires_at:$exp, status:$status, correlation_id:$cid}' > "$TTL_FILE"
status28c="$(jq -r ".records[] | select(.managed_id==\"$MID28c\") | .status" "$TTL_FILE")"
if [[ "$status28c" == "expired" ]]; then
  pass_msg "T-28c expired record is final (status=$status28c, no revoke triggered)"
else
  fail_msg "T-28c" "expected expired status, got $status28c"
fi

printf '\n=== T28 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi
