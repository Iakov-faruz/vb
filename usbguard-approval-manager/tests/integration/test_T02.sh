#!/usr/bin/env bash
# T-02: Permanent Approval (T-05..T-08) - SRS v4.5 Phase 7
# Tests: approve_permanent happy path, precedence conflict, device approval.
# Fully mocked - no real USBGuard or systemd.
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
FAKE_POLICY_DIR="$TEST_ROOT/rules.d"
mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$FAKE_STATE/run_lock" "$FAKE_POLICY_DIR"

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

printf 'RuleFolder=%s\n' "$FAKE_POLICY_DIR" > "$USBAM_DAEMON_CONFIG_PATH"

export USBAM_G01_VERIFIED=1
is_g01_verified() { return 0; }

cleanup() { lock_release >/dev/null 2>&1 || true; rm -rf -- "$TEST_ROOT"; }
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
# T-05: permanent approval happy path
# ------------------------------------------------------------------
printf '\n[T-05] permanent approval happy path\n'
TOTAL=$((TOTAL+1))
RULE='allow id 9abc:def0 serial "T02PERM" name "Permanent Device" hash "ccc" parent-hash "" via-port "" with-interface 08:06:50'
set +e
out="$(stages_approve_permanent "$RULE" "" "dev-9abc" 2>&1)"
rc=$?
set -e
if (( rc == 0 )); then
  pass_msg "T-05 permanent approval succeeded: $out"
else
  fail_msg "T-05" "approve_permanent failed rc=$rc out=$out"
fi

# ------------------------------------------------------------------
# T-06: precedence conflict - same rule permanent twice
# ------------------------------------------------------------------
printf '\n[T-06] precedence conflict for duplicate permanent rule\n'
TOTAL=$((TOTAL+1))
set +e
out2="$(stages_approve_permanent "$RULE" "" "dev-9abc" 2>&1)"
rc2=$?
set -e
if (( rc2 == 7 )); then
  pass_msg "T-06 duplicate permanent rule rejected with EXIT 7 (precedence conflict)"
else
  fail_msg "T-06" "expected EXIT 7 got rc=$rc2 out=$out2"
fi

# ------------------------------------------------------------------
# T-07: G-01 not verified blocks permanent approval (EXIT 7)
# ------------------------------------------------------------------
printf '\n[T-07] G-01 not verified blocks permanent approval\n'
TOTAL=$((TOTAL+1))
is_g01_verified() { return 1; }
set +e
out3="$(stages_approve_permanent 'allow id 1111:2222 serial "NOG01" name "No G01" hash "" parent-hash "" via-port "" with-interface 08:06:50' "" "dev-1111" 2>&1)"
rc3=$?
set -e
is_g01_verified() { return 0; }
if (( rc3 == 7 )); then
  pass_msg "T-07 permanent approval blocked without G-01 (EXIT 7)"
else
  fail_msg "T-07" "expected EXIT 7 got rc=$rc3 out=$out3"
fi

# ------------------------------------------------------------------
# T-08: restore journal blocks permanent approval (EXIT 9)
# ------------------------------------------------------------------
printf '\n[T-08] restore_journal blocks permanent approval\n'
TOTAL=$((TOTAL+1))
printf '{"schema_version":1,"operation":"backup","files":[]}\n' > "$RESTORE_JOURNAL_FILE"
chmod 600 "$RESTORE_JOURNAL_FILE"
set +e
out4="$(stages_approve_permanent 'allow id 3333:4444 serial "JRN" name "Journal Blocked" hash "" parent-hash "" via-port "" with-interface 08:06:50' "" "dev-3333" 2>&1)"
rc4=$?
set -e
rm -f "$RESTORE_JOURNAL_FILE"
if (( rc4 == 9 )); then
  pass_msg "T-08 permanent approval blocked by restore journal (EXIT 9)"
else
  fail_msg "T-08" "expected EXIT 9 got rc=$rc4 out=$out4"
fi

printf '\n=== T02 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi

