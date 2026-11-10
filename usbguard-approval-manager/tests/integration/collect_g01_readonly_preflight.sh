#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
daemon_config_path="${USBAM_DAEMON_CONFIG_PATH:-/etc/usbguard/usbguard-daemon.conf}"
source "$PROJECT_ROOT/scripts/lib/usbguard-policy.sh"

USBAM_DAEMON_CONFIG_PATH="$daemon_config_path"
expected_hostname="${USBAM_G01_EXPECTED_HOSTNAME:-}"
actual_hostname="$(hostname 2>/dev/null)" || actual_hostname=""

printf 'G01_PREFLIGHT_STARTED_UTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'HOSTNAME=%q\n' "$actual_hostname"
printf 'OS=%q\n' "$(uname -s 2>/dev/null || printf unknown)"
printf 'KERNEL=%q\n' "$(uname -r 2>/dev/null || printf unknown)"

if [[ -z "$expected_hostname" || "$actual_hostname" != "$expected_hostname" ]]; then
  printf 'T01_RESULT=UNVERIFIED\n'
  printf 'G01_STATUS=UNVERIFIED\n'
  printf 'DETAIL=expected_hostname_missing_or_mismatched\n'
  exit 9
fi

preflight_incomplete=0

if get_usbguard_version >/dev/null; then
  printf 'USBGuard_VERSION=%q\n' "$USBAM_POLICY_VERSION"
else
  printf 'USBGuard_VERSION=UNAVAILABLE\n'
  printf 'USBGuard_VERSION_ERROR=%q\n' "$USBAM_POLICY_ERROR_CODE"
  printf 'USBGuard_VERSION_STDERR=%q\n' "$USBAM_POLICY_STDERR"
  preflight_incomplete=1
fi

if get_persistent_policy_paths; then
  for source_name in RuleFile RuleFolder; do
    if [[ -v "USBAM_PERSISTENT_POLICY_PATHS[$source_name]" ]]; then
      printf '%s=%q\n' "$source_name" \
        "${USBAM_PERSISTENT_POLICY_PATHS[$source_name]}"
    fi
  done
else
  printf 'POLICY_SOURCES=UNAVAILABLE\n'
  printf 'POLICY_SOURCES_ERROR=%q\n' "$USBAM_POLICY_ERROR_CODE"
  preflight_incomplete=1
fi

if check_daemon_status; then
  printf 'DAEMON_STATUS=%q\n' "$USBAM_DAEMON_STATUS"
  printf 'IPC_STATUS=%q\n' "$USBAM_IPC_STATUS"
else
  status=$?
  printf 'DAEMON_STATUS=%q\n' "$USBAM_DAEMON_STATUS"
  printf 'IPC_STATUS=%q\n' "$USBAM_IPC_STATUS"
  printf 'DAEMON_CHECK_EXIT=%s\n' "$status"
  printf 'DAEMON_CHECK_ERROR=%q\n' "$USBAM_POLICY_ERROR_CODE"
  printf 'DAEMON_CHECK_STDERR=%q\n' "$USBAM_POLICY_STDERR"
  preflight_incomplete=1
fi

if [[ "$USBAM_IPC_STATUS" == "connected" ]]; then
  if list_blocked_devices; then
    printf 'BLOCKED_DEVICE_COUNT=%s\n' "${#USBAM_BLOCKED_DEVICES[@]}"
    for record in "${USBAM_BLOCKED_DEVICES[@]}"; do
      printf 'BLOCKED_DEVICE=%q\n' "$record"
    done
  else
    printf 'BLOCKED_DEVICES_ERROR=%q\n' "$USBAM_POLICY_ERROR_CODE"
    preflight_incomplete=1
  fi

  if list_active_rules; then
    printf 'ACTIVE_RULE_COUNT=%s\n' "${#USBAM_ACTIVE_RULES[@]}"
    for record in "${USBAM_ACTIVE_RULES[@]}"; do
      printf 'ACTIVE_RULE=%q\n' "$record"
    done
  else
    printf 'ACTIVE_RULES_ERROR=%q\n' "$USBAM_POLICY_ERROR_CODE"
    preflight_incomplete=1
  fi
else
  printf 'ACTIVE_RULES=UNAVAILABLE_IPC_NOT_CONNECTED\n'
  printf 'BLOCKED_DEVICES=UNAVAILABLE_IPC_NOT_CONNECTED\n'
  preflight_incomplete=1
fi

# --- Quick diagnostic checks (clock time guard + USB device) ---

parse_quick_result() {
  local out="$1" line
  line="$(printf '%s\n' "$out" | grep -E '^=== Result: [0-9]+ pass, [0-9]+ fail ===' || true)"
  if [[ "$line" =~ ===\ Result:\ ([0-9]+)\ pass,\ ([0-9]+)\ fail\ === ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '0 0\n'
  fi
}

if [[ -f "$PROJECT_ROOT/tests/quick/clock_time_check.sh" ]]; then
  clock_out="$(bash "$PROJECT_ROOT/tests/quick/clock_time_check.sh" 2>&1)" || clock_rc=$?
  clock_rc="${clock_rc:-0}"
  read -r clock_pass clock_fail < <(parse_quick_result "$clock_out")
  printf 'CLOCK_CHECK_RC=%s\n' "$clock_rc"
  printf 'CLOCK_CHECK_PASS=%s\n' "$clock_pass"
  printf 'CLOCK_CHECK_FAIL=%s\n' "$clock_fail"
else
  printf 'CLOCK_CHECK_RC=127\n'
  printf 'CLOCK_CHECK_PASS=0\n'
  printf 'CLOCK_CHECK_FAIL=0\n'
fi

if [[ -f "$PROJECT_ROOT/tests/quick/usb_device_check.sh" ]]; then
  usb_out="$(USBAM_TEST_USB_ID="${USBAM_TEST_USB_ID:-048d:1234}" bash "$PROJECT_ROOT/tests/quick/usb_device_check.sh" 2>&1)" || usb_rc=$?
  usb_rc="${usb_rc:-0}"
  read -r usb_pass usb_fail < <(parse_quick_result "$usb_out")
  printf 'USB_CHECK_RC=%s\n' "$usb_rc"
  printf 'USB_CHECK_PASS=%s\n' "$usb_pass"
  printf 'USB_CHECK_FAIL=%s\n' "$usb_fail"
else
  printf 'USB_CHECK_RC=127\n'
  printf 'USB_CHECK_PASS=0\n'
  printf 'USB_CHECK_FAIL=0\n'
fi

if (( preflight_incomplete )); then
  printf 'T01_RESULT=UNVERIFIED\n'
else
  printf 'T01_RESULT=READ_ONLY_EVIDENCE_COLLECTED\n'
fi

# Snapshot, USB passthrough, and independent recovery require operator evidence.
printf 'G01_STATUS=UNVERIFIED\n'
printf 'POLICY_CHANGING_TESTS=NOT_RUN\n'
exit 9
