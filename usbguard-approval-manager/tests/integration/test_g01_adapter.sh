#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usb_disk_count() {
  lsblk -nrpo NAME,TRAN,TYPE,MOUNTPOINT |
    awk '$2 == "usb" && $3 == "disk" { count++ } END { print count+0 }'
}

usb_mounted_disk_count() {
  lsblk -nrpo NAME,TRAN,TYPE,MOUNTPOINT |
    awk '$2 == "usb" && $3 == "disk" && $4 != "" { count++ } END { print count+0 }'
}

wait_for_usb_disk() {
  local attempts="${1:-100}" count attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    count="$(usb_disk_count)"
    [[ "$count" == "1" ]] && return 0
    sleep 0.1
  done
  return 1
}

[[ "$(id -u)" == "0" ]] || fail "run only as root inside the disposable lab VM"
[[ "${USBAM_G01_CONFIRM:-}" == "YES" ]] ||
  fail "set USBAM_G01_CONFIRM=YES only after confirming the isolated VM and recovery snapshot"
[[ -n "${USBAM_G01_EXPECTED_HOSTNAME:-}" ]] ||
  fail "USBAM_G01_EXPECTED_HOSTNAME is required"
[[ "$(hostname)" == "$USBAM_G01_EXPECTED_HOSTNAME" ]] ||
  fail "hostname mismatch: expected $USBAM_G01_EXPECTED_HOSTNAME, got $(hostname)"

test_usb_id="${USBAM_TEST_USB_ID:-}"
[[ "$test_usb_id" =~ ^[[:xdigit:]]{4}:[[:xdigit:]]{4}$ ]] ||
  fail "USBAM_TEST_USB_ID must be the disposable USB's VID:PID"
command -v lsusb >/dev/null 2>&1 || fail "lsusb is required"
command -v lsblk >/dev/null 2>&1 || fail "lsblk is required"
command -v usbguard >/dev/null 2>&1 || fail "usbguard CLI is required"
command -v usbguard-daemon >/dev/null 2>&1 || fail "usbguard-daemon is required"
command -v systemctl >/dev/null 2>&1 || fail "systemctl is required to verify installed-service state"
command -v pgrep >/dev/null 2>&1 || fail "pgrep is required to verify daemon state"
command -v install >/dev/null 2>&1 || fail "install is required to create a private evidence directory"

# Never attach to or restart the installed USBGuard service.
if systemctl is-active --quiet usbguard; then
  fail "installed usbguard service is active; refusing to run"
fi
if pgrep -x usbguard-daemon >/dev/null 2>&1; then
  fail "a usbguard-daemon process already exists; refusing to run"
fi
if [[ -S /run/usbguard/ipc.sock ]]; then
  fail "USBGuard IPC socket already exists; refusing to use an unknown daemon"
fi

usb_matches="$(lsusb -d "$test_usb_id")"
usb_match_count="$(grep -c . <<< "$usb_matches" || true)"
[[ "$usb_match_count" == "1" ]] ||
  fail "expected exactly one attached USB device with VID:PID $test_usb_id; found $usb_match_count"
usb_disk_count="$(usb_disk_count)"
usb_mounted_count="$(usb_mounted_disk_count)"
[[ "$usb_disk_count" == "1" ]] ||
  fail "expected exactly one USB disk attached; found $usb_disk_count"
[[ "$usb_mounted_count" == "0" ]] ||
  fail "the USB disk is mounted; unmount it before testing"
USB_SYSFS_PATH=""
usb_sysfs_count=0
for candidate in /sys/bus/usb/devices/*; do
  [[ -r "$candidate/idVendor" && -r "$candidate/idProduct" &&
    -r "$candidate/authorized" ]] || continue
  vendor="$(<"$candidate/idVendor")"
  product="$(<"$candidate/idProduct")"
  if [[ "${vendor,,}:${product,,}" == "${test_usb_id,,}" ]]; then
    USB_SYSFS_PATH="$candidate"
    usb_sysfs_count=$((usb_sysfs_count + 1))
  fi
done
[[ "$usb_sysfs_count" == "1" ]] ||
  fail "expected exactly one sysfs device for $test_usb_id; found $usb_sysfs_count"

TEST_DIR="$(mktemp -d /run/usbam-g01.XXXXXX)"
RULE_FILE="$TEST_DIR/rules.conf"
RULE_FOLDER="$TEST_DIR/rules.d"
DAEMON_CONFIG="$TEST_DIR/usbguard-daemon.conf"
DAEMON_LOG="$TEST_DIR/usbguard-daemon.log"
DAEMON_PID=""
TEST_DEVICE_ID=""
REPORT_DIR="${USBAM_G01_REPORT_DIR:-/var/tmp/usbguard-approval-manager-g01}"
[[ "$REPORT_DIR" == /* ]] || fail "report directory must be an absolute path"
[[ ! -L "$REPORT_DIR" ]] || fail "report directory must not be a symbolic link"
if [[ ! -e "$REPORT_DIR" ]]; then
  install -d -o root -g root -m 700 -- "$REPORT_DIR"
fi
[[ -d "$REPORT_DIR" && ! -L "$REPORT_DIR" ]] ||
  fail "report directory must be a non-symlink directory"
[[ "$(stat -c '%u:%a' -- "$REPORT_DIR")" == "0:700" ]] ||
  fail "report directory must be root-owned with mode 0700"
REPORT_FILE="$(mktemp "$REPORT_DIR/g01-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
exec > >(tee -a "$REPORT_FILE") 2>&1

cleanup() {
  local status=$?
  local target_id="$TEST_DEVICE_ID"
  local cleanup_failed=0
  local daemon_stopped=1
  trap - EXIT INT TERM
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null &&
    [[ -r "/proc/$DAEMON_PID/cmdline" ]] &&
    tr '\0' ' ' < "/proc/$DAEMON_PID/cmdline" | grep -Fq -- "$DAEMON_CONFIG"; then
    if [[ -z "$target_id" ]]; then
      local target_record
      target_record="$(usbguard list-devices 2>/dev/null |
        grep -E "^[[:space:]]*[0-9]+: (allow|block|reject) .*id $test_usb_id([[:space:]]|$)" |
        head -n 1 || true)"
      target_id="${target_record%%:*}"
      target_id="${target_id//[[:space:]]/}"
    fi
    if [[ "$target_id" =~ ^[0-9]+$ ]]; then
      usbguard allow-device "$target_id" ||
        printf 'WARNING: failed to restore device %s before daemon shutdown\n' "$target_id" >&2
    fi
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
      printf 'WARNING: isolated daemon is still running; skipping kernel recovery\n' >&2
      cleanup_failed=1
      daemon_stopped=0
    fi
    DAEMON_PID=""
  fi
  if (( daemon_stopped )); then
    if [[ -n "$USB_SYSFS_PATH" &&
      -r "$USB_SYSFS_PATH/idVendor" &&
      -r "$USB_SYSFS_PATH/idProduct" &&
      -r "$USB_SYSFS_PATH/authorized" ]]; then
      local sysfs_id
      sysfs_id="$(<"$USB_SYSFS_PATH/idVendor"):$(<"$USB_SYSFS_PATH/idProduct")"
      if [[ "${sysfs_id,,}" != "${test_usb_id,,}" ]]; then
        printf 'WARNING: USB sysfs path no longer identifies the selected test device\n' >&2
        cleanup_failed=1
      else
        if [[ "$(<"$USB_SYSFS_PATH/authorized")" == "0" ]]; then
          printf 'RECOVERY: reauthorizing the confirmed test USB after isolated daemon shutdown\n'
          if ! printf '1' > "$USB_SYSFS_PATH/authorized" ||
            [[ "$(<"$USB_SYSFS_PATH/authorized")" != "1" ]]; then
            printf 'WARNING: failed to restore kernel authorization for test USB %s\n' "$test_usb_id" >&2
            cleanup_failed=1
          fi
        fi
        local restored_disks restored_mounts
        if ! wait_for_usb_disk 100; then
          restored_disks="$(usb_disk_count)"
          printf 'WARNING: USB recovery check found %s disks after waiting 10 seconds\n' \
            "$restored_disks" >&2
          cleanup_failed=1
        else
          restored_disks="$(usb_disk_count)"
          restored_mounts="$(usb_mounted_disk_count)"
          if [[ "$restored_disks" != "1" || "$restored_mounts" != "0" ]]; then
            printf 'WARNING: USB recovery check found %s disks and %s mounted disks\n' \
              "$restored_disks" "$restored_mounts" >&2
            cleanup_failed=1
          else
            printf 'RECOVERY: one unmounted USB disk is present after isolated daemon shutdown\n'
          fi
        fi
      fi
    else
      printf 'WARNING: test USB sysfs entry is unavailable during cleanup\n' >&2
      cleanup_failed=1
    fi
  fi
  rm -rf -- "$TEST_DIR"
  if (( cleanup_failed )); then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$RULE_FILE" <<EOF
block id $test_usb_id
EOF
mkdir -m 700 -- "$RULE_FOLDER"
cat > "$DAEMON_CONFIG" <<EOF
RuleFile=$RULE_FILE
RuleFolder=$RULE_FOLDER
ImplicitPolicyTarget=allow
PresentDevicePolicy=apply-policy
PresentControllerPolicy=keep
IPCAllowedUsers=root
EOF
chmod 600 -- "$DAEMON_CONFIG"
[[ "$(stat -c '%u:%a' -- "$DAEMON_CONFIG")" == "0:600" ]] ||
  fail "temporary daemon configuration must be root-owned with mode 0600"

source "$PROJECT_ROOT/scripts/lib/usbguard-policy.sh"
USBAM_DAEMON_CONFIG_PATH="$DAEMON_CONFIG"
printf 'G-01 isolated adapter verification\n'
printf 'UTC: %s\nHost: %s\nKernel: %s\nUSB VID:PID: %s\n' \
  "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(hostname)" "$(uname -r)" "$test_usb_id"
printf 'Installed USBGuard service: inactive\nPolicy/config under test: %s\n' "$TEST_DIR"

printf '\n--- Gate 1: device state versus temporary rules ---\n'
usbguard-daemon -c "$DAEMON_CONFIG" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    cat "$DAEMON_LOG" >&2
    fail "isolated USBGuard daemon exited during startup"
  fi
  if usbguard list-devices >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
usbguard list-devices >/dev/null 2>&1 || {
  cat "$DAEMON_LOG" >&2
  fail "isolated USBGuard IPC did not become ready"
}
[[ -r "/proc/$DAEMON_PID/cmdline" ]] &&
  tr '\0' ' ' < "/proc/$DAEMON_PID/cmdline" | grep -Fq -- "$DAEMON_CONFIG" ||
  fail "the responding USBGuard daemon is not the isolated test process"
[[ "$(pgrep -x usbguard-daemon | wc -l)" == "1" ]] ||
  fail "more than one USBGuard daemon is present"

device_records="$(usbguard list-devices | grep -E "^[[:space:]]*[0-9]+: block .*id $test_usb_id([[:space:]]|$)" || true)"
device_record_count="$(grep -c . <<< "$device_records" || true)"
[[ "$device_record_count" == "1" ]] ||
  fail "expected one blocked USBGuard record for $test_usb_id; found $device_record_count"
device_record="$device_records"
[[ "$device_record" == *"08:"* ]] ||
  fail "the selected USB is not identified as mass storage; refusing to block a different device class"
TEST_DEVICE_ID="${device_record%%:*}"
TEST_DEVICE_ID="${TEST_DEVICE_ID//[[:space:]]/}"
[[ "$(<"$USB_SYSFS_PATH/authorized")" == "0" ]] ||
  fail "the initial block rule did not deauthorize the physical USB in the kernel"
printf 'Initial device state: %s\n' "$device_record"

rules_before="$(usbguard list-rules)"
rules_file_before="$(sha256sum "$RULE_FILE" | awk '{print $1}')"
temp_allow_rule="allow id $test_usb_id"
temp_rule_id="$(usbguard append-rule --temporary "$temp_allow_rule")"
[[ "$temp_rule_id" =~ ^[0-9]+$ ]] ||
  fail "USBGuard did not return a temporary rule ID"
[[ "$(sha256sum "$RULE_FILE" | awk '{print $1}')" == "$rules_file_before" ]] ||
  fail "append-rule --temporary changed the isolated persistent RuleFile"
device_after_rule="$(usbguard list-devices | grep -E "^[[:space:]]*$TEST_DEVICE_ID: " || true)"
[[ "$device_after_rule" == *": block "* ]] ||
  fail "a later temporary allow unexpectedly overrode the earlier block rule"
[[ "$(<"$USB_SYSFS_PATH/authorized")" == "0" ]] ||
  fail "append-rule --temporary changed the physical USB authorization state"
precedence_state="$device_after_rule"
printf 'PASS: append-rule --temporary alone did not unblock the connected device\n'
usbguard remove-rule "$temp_rule_id"
[[ "$(usbguard list-rules)" == "$rules_before" ]] ||
  fail "temporary rule cleanup did not restore the isolated rule list"

usbguard allow-device "$TEST_DEVICE_ID"
device_after_allow="$(usbguard list-devices | grep -E "^[[:space:]]*$TEST_DEVICE_ID: " || true)"
[[ "$device_after_allow" == *": allow "* ]] ||
  fail "allow-device did not change the connected device to allow"
[[ "$(<"$USB_SYSFS_PATH/authorized")" == "1" ]] ||
  fail "allow-device did not authorize the physical USB in the kernel"
wait_for_usb_disk 100 ||
  fail "allow-device did not restore the USB disk block device"
[[ "$(usbguard list-rules)" == "$rules_before" ]] ||
  fail "allow-device unexpectedly changed the policy rule list"
[[ "$(sha256sum "$RULE_FILE" | awk '{print $1}')" == "$rules_file_before" ]] ||
  fail "allow-device unexpectedly changed the isolated persistent RuleFile"
printf 'PASS: allow-device changed the connected device without adding a persistent rule\n'

printf '\n--- Gate 1b: block-device versus policy rules ---\n'
usbguard block-device "$TEST_DEVICE_ID"
device_after_block="$(usbguard list-devices | grep -E "^[[:space:]]*$TEST_DEVICE_ID: " || true)"
[[ "$device_after_block" == *": block "* ]] ||
  fail "block-device did not set the connected device state to block"
[[ "$(<"$USB_SYSFS_PATH/authorized")" == "0" ]] ||
  fail "block-device did not deauthorize the physical USB in the kernel"
printf 'PASS: block-device deauthorized the connected USB without changing policy\n'
usbguard allow-device "$TEST_DEVICE_ID"
device_after_restore="$(usbguard list-devices | grep -E "^[[:space:]]*$TEST_DEVICE_ID: " || true)"
[[ "$device_after_restore" == *": allow "* ]] ||
  fail "allow-device did not restore the connected device after block-device"
[[ "$(<"$USB_SYSFS_PATH/authorized")" == "1" ]] ||
  fail "allow-device did not restore kernel authorization after block-device"
wait_for_usb_disk 100 ||
  fail "allow-device did not restore the USB disk after block-device"
[[ "$(usbguard list-rules)" == "$rules_before" ]] ||
  fail "block-device or its restoration unexpectedly changed policy rules"
[[ "$(sha256sum "$RULE_FILE" | awk '{print $1}')" == "$rules_file_before" ]] ||
  fail "block-device or its restoration unexpectedly changed the persistent RuleFile"
printf 'PASS: allow-device restored the physical USB after block-device\n'

printf '\n--- Gate 2: clock evidence (observation only) ---\n'
for service in ntpsec ntp chrony systemd-timesyncd; do
  printf '%s: ' "$service"
  systemctl is-active "$service" 2>&1 || true
done
timedatectl show -p NTPSynchronized -p NTP 2>&1 || true
if command -v ntpq >/dev/null 2>&1; then
  ntpq -c rv 2>&1 || true
  ntpq -pn 2>&1 || true
fi
if command -v chronyc >/dev/null 2>&1; then
  chronyc tracking 2>&1 || true
fi
grep -R -h -E '^(server|pool|peer)[[:space:]]' \
  /etc/ntp.conf /etc/ntpsec/ntp.conf /etc/chrony/chrony.conf 2>/dev/null || true
grep -R -h '^MAX_CLOCK_JUMP_SECONDS=' "$PROJECT_ROOT/conf" 2>/dev/null || true
printf 'CLOCK_GATE: OBSERVATIONS ONLY; this script does not approve a time source or threshold.\n'

printf '\n--- Gate 3: reboot/clock-jump recovery ---\n'
printf 'REBOOT_GATE: UNVERIFIED; this script does not reboot or change the clock.\n'
printf 'Run the synchronized-clock and unsynchronized/clock-jump reboot cases separately, then record policy and recovery_required state.\n'

printf '\n--- Gate 4: block-before-allow precedence ---\n'
[[ "$precedence_state" == *": block "* ]] ||
  fail "earlier block rule did not take precedence over the later allow rule"
printf 'PASS: earlier block remained effective after the later temporary allow: %s\n' "$precedence_state"

printf '\n--- Gate 5: persistence in isolated RuleFile only ---\n'
persistent_rule="allow id aaaa:bbbb serial \"G01-PERSIST-$(date +%s)\""
usbguard append-rule "$persistent_rule"
grep -Fqx "$persistent_rule" "$RULE_FILE" ||
  fail "permanent rule was not written to the isolated RuleFile"
printf 'PASS: permanent rule was written only to %s\n' "$RULE_FILE"

kill "$DAEMON_PID"
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""
for _ in $(seq 1 50); do
  [[ ! -S /run/usbguard/ipc.sock ]] && break
  sleep 0.1
done
[[ ! -S /run/usbguard/ipc.sock ]] ||
  fail "isolated daemon did not release its IPC socket after stop"

usbguard-daemon -c "$DAEMON_CONFIG" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 50); do
  if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    cat "$DAEMON_LOG" >&2
    fail "isolated USBGuard daemon exited during persistence restart"
  fi
  if usbguard list-rules >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
[[ -r "/proc/$DAEMON_PID/cmdline" ]] &&
  tr '\0' ' ' < "/proc/$DAEMON_PID/cmdline" | grep -Fq -- "$DAEMON_CONFIG" ||
  fail "the responding USBGuard daemon is not the isolated test process"
[[ "$(pgrep -x usbguard-daemon | wc -l)" == "1" ]] ||
  fail "more than one USBGuard daemon is present after restart"
persisted_rules="$(usbguard list-rules)"
grep -Fq "$persistent_rule" <<< "$persisted_rules" ||
  fail "permanent rule did not survive isolated daemon restart"
printf 'PASS: permanent rule survived restart of the isolated daemon\n'
persisted_rule_line="$(grep -F "$persistent_rule" <<< "$persisted_rules")"
persisted_rule_id="${persisted_rule_line%%:*}"
[[ "$persisted_rule_id" =~ ^[0-9]+$ ]] ||
  fail "could not resolve the persisted rule ID for removal"
usbguard remove-rule "$persisted_rule_id"
if grep -Fqx "$persistent_rule" "$RULE_FILE" ||
  grep -Fq "$persistent_rule" <<< "$(usbguard list-rules)"; then
  fail "remove-rule did not remove the persistent rule"
fi
printf 'PASS: remove-rule removed the persistent rule from the isolated policy\n'

printf '\nG-01 OVERALL: UNVERIFIED\n'
printf 'G1/G4/G5 observations above use only the disposable USB and temporary policy under %s.\n' "$TEST_DIR"
printf 'G2 clock trust and G3 reboot recovery remain required before marking G-01 PASS.\n'
printf 'Evidence report: %s\n' "$REPORT_FILE"
printf 'The script did not start/restart the installed service or read/modify installed policy.\n'
exit 9
