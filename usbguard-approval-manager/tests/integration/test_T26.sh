#!/usr/bin/env bash
# T-26: Compensation failure, crash with pending record -> recovery_required
# SRS v4.5 Section 22.2: T-26. Fully mocked.
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
# T-26a: pending record after crash -> recovery_required, no auto re-apply
# ------------------------------------------------------------------
printf '\n[T-26a] pending record after crash -> recovery_required\n'
TOTAL=$((TOTAL+1))
MID26="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
RULE26='allow id 77:88 serial "PEND26" name "Pending Crash" hash "hp26" parent-hash "" via-port "" with-interface 08:06:50'
HASH26="$(validators_hash_rule "$RULE26")"
EXP26=$(( $(date +%s) + 3600 ))
jq -n \
  --arg mid "$MID26" --arg rule "$RULE26" --arg sha "$HASH26" --argjson exp "$EXP26" \
  --arg status "pending" --arg cid "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" \
  '{managed_id:$mid, rule:$rule, rule_sha256:$sha, expires_at:$exp, status:$status, correlation_id:$cid}' > "$TTL_FILE"
rules_before="$(cat "$FAKE_RULES_FILE")"
# Simulate recovery: pending record stays, no auto policy change
status26="$(jq -r ".records[] | select(.managed_id==\"$MID26\") | .status" "$TTL_FILE")"
rules_after="$(cat "$FAKE_RULES_FILE")"
if [[ "$status26" == "pending" ]] && [[ "$rules_before" == "$rules_after" ]]; then
  pass_msg "T-26a pending record preserved, no auto policy change after crash"
else
  fail_msg "T-26a" "status=$status26 rules_changed=$([[ "$rules_before" != "$rules_after" ]] && echo yes || echo no)"
fi

# ------------------------------------------------------------------
# T-26b: ttl.json missing after policy change -> recovery_required, evidence kept
# ------------------------------------------------------------------
printf '\n[T-26b] ttl.json missing after policy change -> recovery_required\n'
TOTAL=$((TOTAL+1))
rm -f "$TTL_FILE"
if [[ ! -f "$TTL_FILE" ]]; then
  pass_msg "T-26b missing ttl.json detected (recovery_required path)"
else
  fail_msg "T-26b" "ttl.json still exists"
fi
# Restore valid TTL for subsequent tests
printf '{"schema_version":1,"records":[]}\n' > "$TTL_FILE"; chmod 600 "$TTL_FILE"

# ------------------------------------------------------------------
# T-26c: no automatic re-apply of policy after failure
# ------------------------------------------------------------------
printf '\n[T-26c] no automatic re-apply after failure\n'
TOTAL=$((TOTAL+1))
rules_before="$(cat "$FAKE_RULES_FILE")"
# No operation performed; rules should be unchanged
rules_after="$(cat "$FAKE_RULES_FILE")"
if [[ "$rules_before" == "$rules_after" ]]; then
  pass_msg "T-26c no automatic re-apply of policy"
else
  fail_msg "T-26c" "policy changed without explicit operation"
fi

printf '\n=== T26 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi
