#!/usr/bin/env bash
# Read-only installation and runtime health validation.

set -uo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_ROOT/scripts/lib/config-reader.sh"
source "$PROJECT_ROOT/scripts/lib/validators.sh"

ROOT="${USBAM_ROOT:-/}"
STATIC_ONLY=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
CONFIG_PATH="/etc/usbguard-approval-manager/approval-manager.conf"
STATE_DIR="/var/lib/usbguard-approval-manager"
BACKUP_DIR="/var/backups/usbguard-approval-manager"
LOG_DIR="/var/log/usbguard-approval-manager"
LOCK_PATH="/run/lock/usbguard-approval-manager.lock"
LIBEXEC_DIR="/usr/libexec/usbguard-approval-manager"
SERVICE_UNIT="usbguard-approval-ttl.service"
TIMER_UNIT="usbguard-approval-ttl.timer"
SUDOERS_FILE="/etc/sudoers.d/usbguard-approval-manager"
LOGROTATE_FILE="/etc/logrotate.d/usbguard-approval-manager"
CONFIG_CONF_REL="/etc/usbguard-approval-manager/config/usbguard-approval-manager.conf.example"

usage() {
  printf 'Usage: %s [--static]\n' "$0"
  printf '  --static  Validate installed files only; skip runtime, IPC and backup checks.\n'
}

while (( $# )); do
  case "$1" in
    --static)
      (( STATIC_ONLY == 0 )) || { usage >&2; exit 7; }
      STATIC_ONLY=1
      shift
      ;;
    --help)
      if (( $# != 1 )); then usage >&2; exit 7; fi
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 7
      ;;
  esac
done

if [[ "$ROOT" != "/" ]]; then
  if [[ "$ROOT" != /* || ! -d "$ROOT" || -L "$ROOT" ]]; then
    printf 'FAIL: USBAM_ROOT must be an existing absolute, non-symlink directory\n' >&2
    exit 1
  fi
  ROOT="$(cd -- "$ROOT" && pwd -P)" || exit 1
  [[ "$ROOT" != "/" ]] || { printf 'FAIL: USBAM_ROOT cannot resolve to /\n' >&2; exit 1; }
fi

path_for() {
  if [[ "$ROOT" == "/" ]]; then
    printf '%s\n' "$1"
  else
    printf '%s%s\n' "${ROOT%/}" "$1"
  fi
}

report_pass() {
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

report_fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

report_skip() {
  printf 'UNVERIFIED: %s\n' "$1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

expected_ids() {
  local group="$1" group_id
  if [[ "$ROOT" != "/" ]]; then
    printf '%s:%s\n' "$(id -u)" "$(id -g)"
    return 0
  fi
  group_id="$(getent group "$group" | awk -F: 'NR == 1 { print $3 }')"
  [[ -n "$group_id" ]] || return 1
  printf '0:%s\n' "$group_id"
}

check_directory() {
  local label="$1" path="$2" mode="$3" group="$4"
  local expected actual
  path="$(path_for "$path")"
  if [[ -L "$path" || ! -d "$path" ]]; then
    report_fail "$label: missing, not a directory, or symbolic link"
    return 1
  fi
  expected="$(expected_ids "$group")" || {
    report_fail "$label: required group '$group' is unavailable"
    return 1
  }
  expected="${expected}:$mode"
  actual="$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" || {
    report_fail "$label: unable to inspect directory"
    return 1
  }
  if [[ "$actual" == "$expected" ]]; then
    report_pass "$label: owner/mode $actual"
    return 0
  fi
  report_fail "$label: expected $expected, got $actual"
  return 1
}

check_file() {
  local label="$1" path="$2" mode="$3" group="$4"
  local expected actual
  path="$(path_for "$path")"
  if [[ -L "$path" || ! -f "$path" ]]; then
    report_fail "$label: missing, not a regular file, or symbolic link"
    return 1
  fi
  expected="$(expected_ids "$group")" || {
    report_fail "$label: required group '$group' is unavailable"
    return 1
  }
  expected="${expected}:$mode"
  actual="$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" || {
    report_fail "$label: unable to inspect file"
    return 1
  }
  if [[ "$actual" == "$expected" ]]; then
    report_pass "$label: owner/mode $actual"
    return 0
  fi
  report_fail "$label: expected $expected, got $actual"
  return 1
}

check_configuration() {
  local path
  path="$(path_for "$CONFIG_PATH")"
  if check_directory "configuration directory" /etc/usbguard-approval-manager 750 root &&
    check_file "configuration" "$CONFIG_PATH" 600 root &&
    load_config "$path"; then
    report_pass "configuration syntax and values"
    return 0
  fi
  report_fail "configuration syntax and values"
  return 1
}

check_units_and_policy_files() {
  local service timer sudoers logrotate
  service="$(path_for "/etc/systemd/system/$SERVICE_UNIT")"
  timer="$(path_for "/etc/systemd/system/$TIMER_UNIT")"
  sudoers="$(path_for "$SUDOERS_FILE")"
  logrotate="$(path_for "$LOGROTATE_FILE")"

  check_directory "application executable directory" "$LIBEXEC_DIR" 750 root || true
  check_directory "application library directory" "$LIBEXEC_DIR/lib" 750 root || true
  check_file "TTL service unit" "/etc/systemd/system/$SERVICE_UNIT" 644 root || true
  check_file "TTL timer unit" "/etc/systemd/system/$TIMER_UNIT" 644 root || true
  check_file "sudoers policy" "$SUDOERS_FILE" 440 root || true
  check_file "logrotate policy" "$LOGROTATE_FILE" 644 root || true
  check_directory "log directory" "$LOG_DIR" 750 usbadmins || true
  check_file "Audit log" "$LOG_DIR/audit.jsonl" 640 usbadmins || true

  if [[ -f "$service" ]] &&
    grep -Fqx 'User=root' "$service" &&
    grep -Fqx 'Group=root' "$service" &&
    grep -Fqx 'ProtectSystem=strict' "$service" &&
    grep -Fqx 'ExecStart=/usr/libexec/usbguard-approval-manager/cleanup-expired.sh' "$service" &&
    grep -Fqx 'ReadWritePaths=/var/lib/usbguard-approval-manager' "$service" &&
    grep -Fqx 'ReadWritePaths=/var/log/usbguard-approval-manager' "$service" &&
    grep -Fqx 'ReadWritePaths=/run/lock/usbguard-approval-manager.lock' "$service" &&
    ! grep -Fq '/var/backups/usbguard-approval-manager' "$service"; then
    report_pass "service privilege, hardening, and write paths"
  else
    report_fail "service privilege, hardening, or write paths"
  fi
  if [[ -f "$timer" ]] &&
    grep -Fqx 'OnBootSec=1min' "$timer" &&
    grep -Fqx 'OnUnitActiveSec=5min' "$timer" &&
    grep -Fqx "Unit=$SERVICE_UNIT" "$timer"; then
    report_pass "timer schedule and service binding"
  else
    report_fail "timer schedule or service binding"
  fi

  reaper_service="$(path_for "/etc/systemd/system/usbguard-approval-manager-reaper.service")"
  reaper_timer="$(path_for "/etc/systemd/system/usbguard-approval-manager-reaper.timer")"
  check_file "Reaper service unit" "/etc/systemd/system/usbguard-approval-manager-reaper.service" 644 root || true
  check_file "Reaper timer unit" "/etc/systemd/system/usbguard-approval-manager-reaper.timer" 644 root || true
  if [[ -f "$reaper_service" ]] &&
    grep -Fqx 'User=root' "$reaper_service" &&
    grep -Fqx 'Group=root' "$reaper_service" &&
    grep -Fqx 'ProtectSystem=strict' "$reaper_service" &&
    grep -Fqx 'ExecStart=/usr/libexec/usbguard-approval-manager/cleanup-expired.sh' "$reaper_service"; then
    report_pass "reaper service privilege and hardening"
  else
    report_fail "reaper service privilege or hardening"
  fi
  if [[ -f "$reaper_timer" ]] &&
    grep -Fqx 'Unit=usbguard-approval-manager-reaper.service' "$reaper_timer"; then
    report_pass "reaper timer service binding"
  else
    report_fail "reaper timer service binding"
  fi

  config_example="$(path_for "$CONFIG_CONF_REL")"
  check_file "config example" "$CONFIG_CONF_REL" 600 root || true

  for lib_file in journal.sh tui.sh usb-list.sh backup.sh restore.sh cleanup-expired.sh; do
    check_file "executable $lib_file" "$LIBEXEC_DIR/$lib_file" 750 root || true
  done
  for lib_file in journal.sh tui.sh; do
    check_file "library $lib_file" "$LIBEXEC_DIR/lib/$lib_file" 640 root || true
  done
  if [[ -f "$sudoers" ]] &&
    grep -Fqx '%usbadmins ALL=(root) NOPASSWD: /usr/libexec/usbguard-approval-manager/usb-approve.sh ""' "$sudoers" &&
    grep -Fqx '%usbadmins ALL=(root) NOPASSWD: /usr/libexec/usbguard-approval-manager/usb-revoke-interactive.sh ""' "$sudoers" &&
    ! grep -Eq '(^|[[:space:]])\*([[:space:]]|$)' "$sudoers"; then
    report_pass "sudoers permits only argument-free interactive entry points"
  else
    report_fail "sudoers is not restricted to approved interactive entry points"
  fi

  if command -v visudo >/dev/null 2>&1; then
    if visudo -c -f "$sudoers" >/dev/null 2>&1; then
      report_pass "visudo syntax validation"
    else
      report_fail "visudo syntax validation"
    fi
  elif (( STATIC_ONLY )); then
    report_skip "visudo unavailable; sudoers semantics were checked textually"
  else
    report_fail "visudo is unavailable"
  fi

  if command -v systemd-analyze >/dev/null 2>&1; then
    local verify_rc
    if [[ "$ROOT" == "/" ]]; then
      systemd-analyze verify "$service" "$timer" >/dev/null 2>&1
      verify_rc=$?
    else
      systemd-analyze --root="$ROOT" verify \
        "/etc/systemd/system/$SERVICE_UNIT" "/etc/systemd/system/$TIMER_UNIT" >/dev/null 2>&1
      verify_rc=$?
    fi
    if (( verify_rc == 0 )); then report_pass "systemd unit syntax"; else report_fail "systemd unit syntax"; fi
  elif (( STATIC_ONLY )); then
    report_skip "systemd-analyze unavailable; required unit fields were checked textually"
  else
    report_fail "systemd-analyze is unavailable"
  fi

  if command -v logrotate >/dev/null 2>&1; then
    if logrotate --debug --state /dev/null "$logrotate" >/dev/null 2>&1; then
      report_pass "logrotate syntax"
    else
      report_fail "logrotate syntax"
    fi
  elif (( STATIC_ONLY )); then
    report_skip "logrotate unavailable; installed configuration was checked for permissions"
  else
    report_fail "logrotate is unavailable"
  fi
}

check_ttl_state() {
  local state ttl
  state="$(path_for "$STATE_DIR")"
  ttl="$state/ttl.json"
  check_directory "state directory" "$STATE_DIR" 700 root || true
  check_file "TTL state file" "$STATE_DIR/ttl.json" 600 root || return 1
  if validate_ttl_json "$ttl"; then
    report_pass "TTL JSON schema"
    return 0
  fi
  report_fail "TTL JSON schema: ${VALIDATORS_ERROR:-invalid}"
  return 1
}

check_backup_directory() {
  local backup_path keep count file mode owner expected backup_status=0
  local lifecycle_helper
  backup_path="$(path_for "$BACKUP_DIR")"
  check_directory "backup directory" "$BACKUP_DIR" 700 root || return 1
  keep="$(get_config BACKUP_KEEP)" || return 1
  local -a backups=()
  shopt -s nullglob
  backups=("$backup_path"/usbguard-approval-manager-*.tar.gz)
  shopt -u nullglob
  count="${#backups[@]}"
  if (( count == 0 )); then
    report_fail "backup availability: no validated backup archive exists"
    backup_status=1
  elif (( count > keep )); then
    report_fail "backup rotation: $count archives exceed BACKUP_KEEP=$keep"
    backup_status=1
  else
    for file in "${backups[@]}"; do
      if [[ -L "$file" || ! -f "$file" ]]; then
        report_fail "backup rotation: unsafe archive entry $(basename -- "$file")"
        backup_status=1
        continue
      fi
      mode="$(stat -c '%a' -- "$file" 2>/dev/null)"
      expected="$(expected_ids root 2>/dev/null)" || expected=""
      owner="$(stat -c '%u:%g' -- "$file" 2>/dev/null)"
      if [[ "$mode" != "600" || "$owner" != "$expected" ]]; then
        report_fail "backup permissions: $(basename -- "$file")"
        backup_status=1
        continue
      fi
      lifecycle_helper="$(path_for "$LIBEXEC_DIR/lib/lifecycle.py")"
      if ! python3 "$lifecycle_helper" validate-backup --backup "$file" >/dev/null 2>&1; then
        report_fail "backup integrity: $(basename -- "$file")"
        backup_status=1
      fi
    done
    if (( backup_status == 0 )); then
      report_pass "backup availability and rotation ($count/$keep archives)"
    fi
  fi
  return "$backup_status"
}

check_runtime() {
  local timeout_seconds ipc_rc timer_rc result start_timestamp
  local service_path log_dir audit_file lock_file
  if (( EUID != 0 )) && [[ "$ROOT" == "/" ]]; then
    report_fail "runtime validation requires root to verify protected ownership"
  fi

  service_path="$(path_for "$LOG_DIR")"
  audit_file="$service_path/audit.jsonl"
  lock_file="$(path_for "$LOCK_PATH")"
  check_directory "log directory" "$LOG_DIR" 750 usbadmins || true
  check_file "Audit log" "$LOG_DIR/audit.jsonl" 640 usbadmins || true
  if [[ ! -r "$audit_file" || ! -w "$audit_file" ]]; then
    report_fail "Audit log is not accessible for read/write"
  else
    report_pass "Audit log accessibility (metadata only)"
  fi

  check_file "lock file" "$LOCK_PATH" 600 root || true
  if [[ -r "$lock_file" && -w "$lock_file" ]]; then
    report_pass "lock file is accessible (not acquired or modified)"
  else
    report_fail "lock file is not accessible"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$TIMER_UNIT"
    timer_rc=$?
    if (( timer_rc == 0 )); then report_pass "TTL timer is active"; else report_fail "TTL timer is not active"; fi
    result="$(systemctl show --property=Result --value "$SERVICE_UNIT" 2>/dev/null)"
    start_timestamp="$(systemctl show --property=ExecMainStartTimestamp --value "$SERVICE_UNIT" 2>/dev/null)"
    if [[ "$result" == "success" && -n "$start_timestamp" ]]; then
      report_pass "last TTL service run completed successfully"
    else
      report_fail "last TTL service run has not succeeded (result=${result:-unknown})"
    fi
  else
    report_fail "systemctl is unavailable"
  fi

  timeout_seconds="$(get_config IPC_TIMEOUT_SECONDS)" || timeout_seconds=5
  if command -v timeout >/dev/null 2>&1 && command -v usbguard >/dev/null 2>&1; then
    timeout --foreground "${timeout_seconds}s" usbguard list-rules >/dev/null 2>&1
    ipc_rc=$?
    if (( ipc_rc == 0 )); then report_pass "USBGuard IPC connectivity"; else report_fail "USBGuard IPC connectivity (exit $ipc_rc)"; fi
  else
    report_fail "USBGuard CLI or timeout is unavailable"
  fi
  check_backup_directory || true
}

main() {
  printf '=== USBGuard Approval Manager health validation%s ===\n' \
    "$([[ "$STATIC_ONLY" == 1 ]] && printf ' (static-only)')"

  check_configuration || true
  check_ttl_state || true
  check_directory "backup directory" "$BACKUP_DIR" 700 root || true
  check_units_and_policy_files
  check_file "lock file" "$LOCK_PATH" 600 root || true

  if (( STATIC_ONLY )); then
    report_skip "timer activation, last-run result, USBGuard IPC, Audit availability, and backup contents"
  else
    check_runtime
  fi

  printf '\nSummary: %d PASS, %d FAIL, %d UNVERIFIED\n' \
    "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  if (( FAIL_COUNT > 0 )); then
    printf 'Overall: FAIL\n'
    return 1
  fi
  if (( STATIC_ONLY )); then
    printf 'Overall: STATIC FILES PASS (runtime checks remain unverified)\n'
  elif (( SKIP_COUNT > 0 )); then
    printf 'Overall: UNVERIFIED\n'
    return 2
  else
    printf 'Overall: PASS\n'
  fi
}

main
