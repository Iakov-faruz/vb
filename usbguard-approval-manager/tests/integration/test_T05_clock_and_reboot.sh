#!/usr/bin/env bash
# T-05: Clock and Reboot (T-17..T-20) - SRS v4.5 Phase 7
# Tests: clock trust, boot_id stability, clock jump detection after simulated reboot.
# Fully mocked.
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

FAKE_LOCK_BASE="$FAKE_STATE/run_lock/usbguard-approval-manager.lock"
touch "$FAKE_LOCK_BASE"; chmod 600 "$FAKE_LOCK_BASE"

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

printf '{"schema_version":1,"records":[]}\n' > "$TTL_FILE"
chmod 600 "$TTL_FILE"

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
# T-17: clock state is trusted on same boot
# ------------------------------------------------------------------
printf '\n[T-17] clock trusted on same boot\n'
TOTAL=$((TOTAL+1))
if detect_clock_jump "$CLOCK_STATE_FILE" "0" >/dev/null 2>&1; then
  pass_msg "T-17 clock state trusted (same boot)"
else
  fail_msg "T-17" "clock jump detected unexpectedly: $CLOCK_TRUST_STATUS"
fi

# ------------------------------------------------------------------
# T-18: clock jump detected when boot_id changes (simulated reboot)
# ------------------------------------------------------------------
printf '\n[T-18] clock jump detected after simulated reboot\n'
TOTAL=$((TOTAL+1))
# Write a clock state with a different boot_id to simulate reboot
printf '{"trusted":true,"boot_id":"new-boot-id-after-reboot","epoch":%s}\n' "$(date +%s)" > "$CLOCK_STATE_FILE"
if ! detect_clock_jump "$CLOCK_STATE_FILE" "0" >/dev/null 2>&1; then
  pass_msg "T-18 clock jump detected after boot_id change"
else
  fail_msg "T-18" "clock jump NOT detected after boot_id change"
fi

# ------------------------------------------------------------------
# T-19: MIN_REASONABLE_EPOCH rejects unreasonably old clock
# ------------------------------------------------------------------
printf '\n[T-19] unreasonably old epoch rejected\n'
TOTAL=$((TOTAL+1))
printf '{"trusted":true,"boot_id":"same-boot","epoch":1000000}\n' > "$CLOCK_STATE_FILE"
if ! detect_clock_jump "$CLOCK_STATE_FILE" "0" >/dev/null 2>&1; then
  pass_msg "T-19 unreasonably old epoch rejected"
else
  fail_msg "T-19" "old epoch was unexpectedly accepted"
fi

# ------------------------------------------------------------------
# T-20: TTL records survive clock check when trusted
# ------------------------------------------------------------------
printf '\n[T-20] TTL records valid when clock trusted\n'
TOTAL=$((TOTAL+1))
printf '{"trusted":true,"boot_id":"same-boot","epoch":%s}\n' "$(date +%s)" > "$CLOCK_STATE_FILE"
has_records="$(has_non_expired_records "$TTL_FILE")"
if [[ "$has_records" == "0" ]]; then
  pass_msg "T-20 no non-expired records (empty TTL) with trusted clock"
else
  fail_msg "T-20" "unexpected has_records=$has_records"
fi

printf '\n=== T05 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi

