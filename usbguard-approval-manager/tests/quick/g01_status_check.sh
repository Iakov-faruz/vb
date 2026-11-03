#!/usr/bin/env bash
# Quick G-01 status check (read-only preflight) - run on the lab VM
# Usage: sudo env USBAM_G01_EXPECTED_HOSTNAME=vbox bash tests/quick/g01_status_check.sh
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

expected_hostname="${USBAM_G01_EXPECTED_HOSTNAME:-vbox}"
report_dir="${USBAM_G01_REPORT_DIR:-/var/tmp/usbguard-approval-manager-status}"

PASS=0; FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

printf '=== G-01 status check ===\n'
printf 'check_time_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'hostname=%s (expected: %s)\n' "$(hostname)" "$expected_hostname"

if [[ "$EUID" != "0" ]]; then
  fail "run as root to inspect protected G-01 evidence"
  exit 1
fi
if [[ "$(hostname)" != "$expected_hostname" ]]; then
  fail "hostname mismatch: got $(hostname), expected $expected_hostname"
  printf '\n=== Result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
  exit 1
fi
pass "hostname matches expected"

if [[ "$report_dir" != /* || -L "$report_dir" ]]; then
  fail "report directory must be an absolute, non-symlink path"
  exit 1
fi
if [[ ! -e "$report_dir" ]]; then
  install -d -o root -g root -m 700 -- "$report_dir" ||
    { fail "could not create private report directory"; exit 1; }
fi
if [[ ! -d "$report_dir" || -L "$report_dir" ||
  "$(stat -c '%u:%a' -- "$report_dir")" != "0:700" ]]; then
  fail "report directory must be a root-owned mode-0700 directory"
  exit 1
fi

if ! source "$PROJECT_ROOT/scripts/lib/usbguard-policy.sh"; then
  fail "could not load the USBGuard policy adapter"
  exit 1
fi

# USBGuard version
if get_usbguard_version >/dev/null 2>&1; then
  printf 'usbguard_version=%s\n' "${USBAM_POLICY_VERSION:-unknown}"
  pass "usbguard version available"
else
  fail "usbguard version unavailable (${USBAM_POLICY_ERROR_CODE:-unknown})"
fi

# Daemon status
if check_daemon_status; then
  printf 'daemon_status=%s\n' "${USBAM_DAEMON_STATUS:-unknown}"
  printf 'ipc_status=%s\n' "${USBAM_IPC_STATUS:-unknown}"
  pass "daemon status check passed"
else
  rc=$?
  printf 'daemon_status=%s\n' "${USBAM_DAEMON_STATUS:-unknown}"
  printf 'ipc_status=%s\n' "${USBAM_IPC_STATUS:-unknown}"
  printf 'daemon_check_exit=%s\n' "$rc"
  fail "daemon status check failed (exit $rc)"
fi

# Validate the marker using the same fail-closed check as policy mutations.
marker_status="invalid-or-missing"
if is_g01_verified; then
  marker_status="valid"
  printf 'g01_verified_marker=%s\n' "$marker_status"
  pass "G-01 evidence marker is valid"
else
  printf 'g01_verified_marker=%s\n' "$marker_status"
  fail "G-01 evidence marker is invalid or missing"
fi

# G-01 status file
g01_status_file="/var/lib/usbguard-approval-manager/g01-status"
if [[ -f "$g01_status_file" ]]; then
  printf 'g01_status_file=%s\n' "$(cat "$g01_status_file")"
else
  printf 'g01_status_file=%s (missing)\n' "$g01_status_file"
fi

# Save the summary in a uniquely created, private report file.
report_file="$(mktemp "$report_dir/g01-quick-check-$(date -u '+%Y%m%dT%H%M%SZ').XXXXXX")" ||
  { fail "could not create report file"; exit 1; }
{
  printf 'G01_QUICK_CHECK_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'HOSTNAME=%s\n' "$(hostname)"
  printf 'PASS=%d\n' "$PASS"
  printf 'FAIL=%d\n' "$FAIL"
  printf 'G01_MARKER=%s\n' "$marker_status"
} > "$report_file"
printf '\nreport saved to: %s\n' "$report_file"

printf '\n=== Result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
