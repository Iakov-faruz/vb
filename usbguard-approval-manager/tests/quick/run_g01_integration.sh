#!/usr/bin/env bash
# Quick G-01 integration test runner; it never manages the installed service.
# Usage: sudo env USBAM_TEST_USB_ID=048d:1234 USBAM_G01_EXPECTED_HOSTNAME=vbox \
#   USBAM_G01_ALLOW_WRITE=1 USBAM_G01_CONFIRM=YES bash tests/quick/run_g01_integration.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

[[ "$EUID" == "0" ]] || fail "run as root in the isolated lab VM"
[[ "${USBAM_G01_CONFIRM:-}" == "YES" ]] ||
  fail "set USBAM_G01_CONFIRM=YES after confirming isolation and recovery"
[[ "${USBAM_G01_ALLOW_WRITE:-}" == "1" ]] ||
  fail "set USBAM_G01_ALLOW_WRITE=1 to explicitly allow the lab USB test"
[[ -n "${USBAM_G01_EXPECTED_HOSTNAME:-}" ]] ||
  fail "USBAM_G01_EXPECTED_HOSTNAME is required"
[[ -n "${USBAM_TEST_USB_ID:-}" ]] ||
  fail "USBAM_TEST_USB_ID is required"

printf '=== G-01 isolated integration test ===\n'
printf 'hostname=%s\n' "$(hostname)"
printf 'test_usb_id=%s\n' "$USBAM_TEST_USB_ID"
printf 'check_time_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if USBAM_G01_EXPECTED_HOSTNAME="$USBAM_G01_EXPECTED_HOSTNAME" \
  USBAM_G01_ALLOW_WRITE="$USBAM_G01_ALLOW_WRITE" \
  USBAM_G01_CONFIRM="$USBAM_G01_CONFIRM" \
  USBAM_TEST_USB_ID="$USBAM_TEST_USB_ID" \
  USBAM_G01_REPORT_DIR="${USBAM_G01_REPORT_DIR:-/var/tmp/usbguard-approval-manager-g01}" \
  bash "$PROJECT_ROOT/tests/integration/test_g01_adapter.sh"; then
  exit 0
else
  status=$?
fi

if [[ "$status" == "9" ]]; then
  printf 'G-01 remains UNVERIFIED; the integration test returned expected gate status 9.\n'
else
  printf 'G-01 integration test failed with status %s.\n' "$status" >&2
fi
exit "$status"
