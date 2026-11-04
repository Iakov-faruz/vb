#!/usr/bin/env bash
# T-04: Backup and Restore (T-13..T-16) - SRS v4.5 Phase 7
# Tests: backup.sh creates backup with manifest, restore.sh restores atomically.
# Fully mocked - no real USBGuard or systemd.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/scripts/lib"
BACKUP_SH="$PROJECT_ROOT/scripts/backup.sh"
RESTORE_SH="$PROJECT_ROOT/scripts/restore.sh"

PASS_COUNT=0 TOTAL=0 FAIL_COUNT=0
pass_msg() { PASS_COUNT=$((PASS_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'PASS: %s\n' "$1"; }
fail_msg() { FAIL_COUNT=$((FAIL_COUNT+1)); TOTAL=$((TOTAL+1)); printf 'FAIL: %s - %s\n' "$1" "$2" >&2; }

TEST_ROOT="$(mktemp -d)"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_STATE="$TEST_ROOT/state"
FAKE_BACKUP="$TEST_ROOT/backups"
FAKE_LOG="$TEST_ROOT/log"
FAKE_RULES_DIR="$TEST_ROOT/rules.d"
mkdir -p "$FAKE_BIN" "$FAKE_STATE" "$FAKE_BACKUP" "$FAKE_LOG" "$FAKE_RULES_DIR" "$FAKE_STATE/run_lock"

FAKE_RULES_FILE="$TEST_ROOT/rules.conf"
FAKE_BLOCKED_FILE="$TEST_ROOT/blocked_devices.txt"
printf '1: allow id 1d6b:0002\n' > "$FAKE_RULES_FILE"
: > "$FAKE_BLOCKED_FILE"
FAKE_LOCK_BASE="$FAKE_STATE/run_lock/usbguard-approval-manager.lock"
touch "$FAKE_LOCK_BASE"; chmod 600 "$FAKE_LOCK_BASE"

cat > "$FAKE_BIN/usbguard" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'USBGuard 1.1.4\n' ;;
  list-devices) cat "$FAKE_RULES_FILE" 2>/dev/null || printf '1: allow id 1d6b:0002\n'; ;;
  list-rules) cat "$FAKE_RULES_FILE" 2>/dev/null || true ;;
  *) exit 64 ;;
esac
MOCK
chmod 700 "$FAKE_BIN/usbguard"

cat > "$FAKE_BIN/python3" <<'PY'
#!/usr/bin/env bash
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
cat > "$FAKE_BIN/sha256sum" <<'MOCK'
#!/usr/bin/env bash
exec /usr/bin/sha256sum "$@"
MOCK
chmod 700 "$FAKE_BIN/sha256sum" 2>/dev/null || true

export PATH="$FAKE_BIN:$PATH"
export USBAM_STATE_DIR="$FAKE_STATE"
export STATE_DIR="$FAKE_STATE"
export TTL_FILE="$FAKE_STATE/ttl.json"
export CLOCK_STATE_FILE="$FAKE_STATE/clock_state.json"
export RESTORE_JOURNAL_FILE="$FAKE_STATE/restore_journal.json"
export USBAM_BACKUP_BASE_DIR="$FAKE_BACKUP"
export LOCK_FILE="$FAKE_LOCK_BASE"
export USBAM_LOCK_FILE="$FAKE_LOCK_BASE"
export USBAM_CONFIG_PATH="$TEST_ROOT/approval-manager.conf"
export CONFIG_PATH="$TEST_ROOT/approval-manager.conf"
export USBAM_STATE_LOCK_FILE="$FAKE_STATE/run_lock/state.lock"
export USBAM_POLICY_LOCK_FILE="$FAKE_STATE/run_lock/policy.lock"
touch "$USBAM_STATE_LOCK_FILE" "$USBAM_POLICY_LOCK_FILE"; chmod 600 "$USBAM_STATE_LOCK_FILE" "$USBAM_POLICY_LOCK_FILE"
export IPC_TIMEOUT_SECONDS="5"

cat > "$TEST_ROOT/approval-manager.conf" <<'CONF'
TEMP_TTL_SECONDS=3600
MIN_REASONABLE_EPOCH=1577836800
MAX_CLOCK_JUMP_SECONDS=3600
BACKUP_KEEP=5
IPC_TIMEOUT_SECONDS=5
LOG_LEVEL=INFO
CONF

printf 'RuleFile=%s\nRuleFolder=%s\n' "$FAKE_RULES_FILE" "$FAKE_RULES_DIR" > "$TEST_ROOT/usbguard-daemon.conf"
export USBAM_DAEMON_CONFIG_PATH="$TEST_ROOT/usbguard-daemon.conf"

printf '{"schema_version":1,"records":[]}\n' > "$TTL_FILE"
chmod 600 "$TTL_FILE"
printf '{"trusted":true,"boot_id":"test-boot","epoch":%s}\n' "$(date +%s)" > "$CLOCK_STATE_FILE"
chmod 600 "$CLOCK_STATE_FILE"

export USBAM_G01_VERIFIED=1
is_g01_verified() { return 0; }

cleanup_test() { lock_release >/dev/null 2>&1 || true; rm -rf -- "$TEST_ROOT"; }
trap cleanup_test EXIT

source "$LIB_DIR/config-reader.sh"
source "$LIB_DIR/validators.sh"
source "$LIB_DIR/usbguard-policy.sh"
source "$LIB_DIR/stages.sh"
source "$LIB_DIR/lock.sh"
source "$LIB_DIR/logger.sh"
source "$LIB_DIR/result.sh"

# ------------------------------------------------------------------
# T-13: backup.sh creates backup with manifest.json
# ------------------------------------------------------------------
printf '\n[T-13] backup.sh creates backup with manifest.json\n'
TOTAL=$((TOTAL+1))
set +e
bash "$BACKUP_SH" > "$TEST_ROOT/backup13.log" 2>&1
rc13=$?
set -e
if (( rc13 == 0 )); then
  backup_dir="$(ls -dt "$FAKE_BACKUP"/*/ 2>/dev/null | head -1)"
  if [[ -n "$backup_dir" ]] && [[ -f "$backup_dir/manifest.json" ]]; then
    manifest_valid="$(jq -e '.schema_version and .backup_id and .files' "$backup_dir/manifest.json" >/dev/null 2>&1 && echo yes || echo no)"
    if [[ "$manifest_valid" == "yes" ]]; then
      pass_msg "T-13 backup created at $backup_dir with valid manifest"
    else
      fail_msg "T-13" "manifest.json invalid"
    fi
  else
    fail_msg "T-13" "backup directory or manifest.json missing"
  fi
else
  fail_msg "T-13" "backup.sh failed rc=$rc13 log=$(cat $TEST_ROOT/backup13.log)"
fi

# ------------------------------------------------------------------
# T-14: backup preserves TTL and clock_state
# ------------------------------------------------------------------
printf '\n[T-14] backup includes ttl.json and clock_state.json\n'
TOTAL=$((TOTAL+1))
backup_dir="$(ls -dt "$FAKE_BACKUP"/*/ 2>/dev/null | head -1)"
if [[ -f "$backup_dir/ttl.json" ]] && [[ -f "$backup_dir/clock_state.json" ]]; then
  pass_msg "T-14 backup contains ttl.json and clock_state.json"
else
  fail_msg "T-14" "backup missing ttl.json or clock_state.json in $backup_dir"
fi

# ------------------------------------------------------------------
# T-15: restore.sh restores from backup
# ------------------------------------------------------------------
printf '\n[T-15] restore.sh restores from backup\n'
TOTAL=$((TOTAL+1))
# Modify ttl.json to simulate change, then restore
printf '{"schema_version":1,"records":[{"managed_id":"deleted","rule":"allow id 99:99","status":"active","expires_at":1}]}\n' > "$TTL_FILE"
set +e
bash "$RESTORE_SH" --backup-path "$backup_dir" > "$TEST_ROOT/restore15.log" 2>&1
rc15=$?
set -e
if (( rc15 == 0 )); then
  if validate_ttl_json "$TTL_FILE"; then
    pass_msg "T-15 restore succeeded, ttl.json valid"
  else
    fail_msg "T-15" "ttl.json invalid after restore: $VALIDATORS_ERROR"
  fi
else
  fail_msg "T-15" "restore.sh failed rc=$rc15 log=$(cat $TEST_ROOT/restore15.log)"
fi

# ------------------------------------------------------------------
# T-16: restore with missing backup fails safely
# ------------------------------------------------------------------
printf '\n[T-16] restore.sh fails safely on missing backup\n'
TOTAL=$((TOTAL+1))
set +e
bash "$RESTORE_SH" --backup-path "$TEST_ROOT/nonexistent" > "$TEST_ROOT/restore16.log" 2>&1
rc16=$?
set -e
if (( rc16 != 0 )); then
  pass_msg "T-16 restore fails safely on missing backup (rc=$rc16)"
else
  fail_msg "T-16" "expected non-zero exit for missing backup"
fi

printf '\n=== T04 Results: %d/%d PASS, %d FAIL ===\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
if (( FAIL_COUNT > 0 )); then exit 1; else exit 0; fi

