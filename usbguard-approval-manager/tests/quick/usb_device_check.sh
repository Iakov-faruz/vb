#!/usr/bin/env bash
# Quick USB device status check - run on the lab VM
# Usage: sudo env USBAM_TEST_USB_ID=048d:1234 bash tests/quick/usb_device_check.sh
set -euo pipefail
umask 077

if [[ $EUID -ne 0 ]]; then
    printf '[-] Error: This script must be run with root privileges (sudo).\n' >&2
    exit 1
fi

TEST_USB_ID="${USBAM_TEST_USB_ID:-048d:1234}"
[[ "$TEST_USB_ID" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] || {
  printf '[-] Error: TEST_USB_ID must be a VID:PID in hexadecimal.\n' >&2
  exit 1
}
PASS=0; FAIL=0

pass() { printf '%bPASS%b: %s\n' '\033[0;32m' '\033[0m' "$1"; PASS=$((PASS+1)); }
fail() { printf '%bFAIL%b: %s\n' '\033[0;31m' '\033[0m' "$1"; FAIL=$((FAIL+1)); }

printf '=== USB device check: %s ===\n' "$TEST_USB_ID"

# Verify the selected physical USB is present exactly once.
if ! command -v lsusb >/dev/null 2>&1; then
  fail "lsusb not available"
else
  matches="$(lsusb -d "$TEST_USB_ID" 2>/dev/null || true)"
  count="$(grep -c . <<<"$matches" || true)"
  if [[ "$count" == "1" ]]; then
    pass "exactly one USB device with VID:PID $TEST_USB_ID"
    printf '  lsusb: %s\n' "$matches"
  else
    fail "expected 1 device with VID:PID $TEST_USB_ID; found $count"
  fi
fi

# Read kernel authorization without assuming that an unauthorized USB
# mass-storage device has a corresponding block node.
sysfs_match_count=0
initial_authorized=""
for candidate in /sys/bus/usb/devices/*/; do
  [[ -r "$candidate/idVendor" && -r "$candidate/idProduct" && -r "$candidate/authorized" ]] || continue
  vendor="$(<"$candidate/idVendor")"
  product="$(<"$candidate/idProduct")"
  if [[ "${vendor,,}:${product,,}" == "${TEST_USB_ID,,}" ]]; then
    sysfs_match_count=$((sysfs_match_count + 1))
    authorized="$(<"$candidate/authorized")"
    printf '  sysfs path: %s\n' "$candidate"
    printf '  authorized: %s\n' "$authorized"
    if [[ "$authorized" == "0" || "$authorized" == "1" ]]; then
      initial_authorized="$authorized"
      pass "USB device kernel authorization state is valid ($authorized)"
    else
      fail "USB device has an invalid authorized bit ($authorized)"
    fi
  fi
done
if [[ "$sysfs_match_count" != "1" ]]; then
  fail "expected exactly one sysfs entry for VID:PID $TEST_USB_ID; found $sysfs_match_count"
fi

# Verify disk presence matches the authorization state and no USB disk is mounted.
if ! command -v lsblk >/dev/null 2>&1; then
  fail "lsblk not available"
else
  disk_count="$(lsblk -nrpo NAME,TRAN,TYPE,MOUNTPOINT | awk '$2=="usb" && $3=="disk"{c++} END{print c+0}')"
  mounted_count="$(lsblk -nrpo NAME,TRAN,TYPE,MOUNTPOINT | awk '$2=="usb" && $3=="disk" && $4!=""{c++} END{print c+0}')"
  printf '  usb disk count: %s (mounted: %s)\n' "$disk_count" "$mounted_count"
  if [[ "$disk_count" == "$initial_authorized" ]]; then
    pass "USB disk presence matches the kernel authorization state"
  else
    fail "USB disk count $disk_count does not match authorization state $initial_authorized"
  fi
  if [[ "$mounted_count" == "0" ]]; then
    pass "no USB disk is mounted"
  else
    fail "USB disk is mounted; unmount before testing"
  fi
fi

printf '\n=== Result: %d pass, %d fail ===\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
