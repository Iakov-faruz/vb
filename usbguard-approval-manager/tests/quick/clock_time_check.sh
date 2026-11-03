#!/usr/bin/env bash
# Quick clock / time-guard verification check - run on the lab VM
# Usage: sudo bash tests/quick/clock_time_check.sh
set -eo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/time-guards.sh"

declare -A CONFIG_VALUES

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

printf '=== Clock / time-guard check ===\n'
printf 'check_time_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# 1. Current epoch
if epoch="$(get_current_epoch)"; then
  printf '  epoch=%s\n' "$epoch"
  [[ "$epoch" =~ ^[0-9]+$ ]] && pass "epoch is a non-negative integer" || fail "epoch is not an integer"
else
  fail "could not read current epoch"
fi

# 2. Clock reasonable (MIN_REASONABLE_EPOCH)
CONFIG_VALUES[MIN_REASONABLE_EPOCH]="1577836800"
CONFIG_VALUES[MAX_CLOCK_JUMP_SECONDS]="3600"
if is_clock_reasonable "$(date +%s)"; then
  pass "current clock is reasonable (>= MIN_REASONABLE_EPOCH)"
else
  fail "current clock is not reasonable"
fi

# 3. boot_id
if boot_id="$(clock_read_boot_id)"; then
  printf '  boot_id=%s\n' "$boot_id"
  [[ "$boot_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && pass "boot_id is valid UUID" || fail "boot_id is not a valid UUID"
else
  fail "could not read boot_id"
fi

# 4. boottime seconds
if boottime="$(clock_read_boottime_seconds)"; then
  printf '  boottime_seconds=%s\n' "$boottime"
  [[ "$boottime" =~ ^[0-9]+$ ]] && pass "boottime is a non-negative integer" || fail "boottime is not an integer"
else
  fail "could not read boottime_seconds"
fi

# 5. Verify the configured system NTP provider and selected peer
CLOCK_SYNC_PROVIDER=""
CLOCK_SYNC_STATUS=""
if clock_sync_evidence; then
  printf '  sync_provider=%s\n' "$CLOCK_SYNC_PROVIDER"
  printf '  sync_status=%s\n' "$CLOCK_SYNC_STATUS"
  pass "clock synchronization evidence is verified"
else
  fail "clock synchronization evidence unavailable (${CLOCK_TRUST_DETAIL_CODE:-unknown})"
fi

# 6. Probe clock trust using a disposable state file
STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/usbam-clock-check.XXXXXX")"
rm -f -- "$STATE_FILE"
trap 'rm -f -- "$STATE_FILE"' EXIT
if detect_clock_jump "$STATE_FILE" no; then
  printf '  CLOCK_TRUST_STATUS=%s\n' "${CLOCK_TRUST_STATUS:-<unset>}"
  printf '  CLOCK_TRUST_DETAIL_CODE=%s\n' "${CLOCK_TRUST_DETAIL_CODE:-<unset>}"
  pass "clock trust probe accepted current synchronization evidence"
else
  rc=$?
  printf '  CLOCK_TRUST_STATUS=%s\n' "${CLOCK_TRUST_STATUS:-<unset>}"
  printf '  CLOCK_TRUST_DETAIL_CODE=%s\n' "${CLOCK_TRUST_DETAIL_CODE:-<unset>}"
  fail "clock trust probe rejected current evidence (exit $rc)"
fi
printf '  MAX_CLOCK_JUMP_SECONDS=%s (example threshold; not approved)\n' \
  "${CONFIG_VALUES[MAX_CLOCK_JUMP_SECONDS]}"

printf '\n=== Result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
