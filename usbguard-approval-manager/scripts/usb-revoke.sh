#!/usr/bin/env bash
# usb-revoke.sh - זריחת גלוי מפורש (SRS v4.5 Section 14.2, FR-27, T-27)
# כלי נפרד למנהל, אינו חלק מה-Reaper, דורשת אישור אינטראקטיבי
# פועלת רק עם רשומת TTL פג תוקף, מזהה מכשיר טרי, נעילה, re-fetch, אימות G-01

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# Load libs
# shellcheck source=/dev/null
source "$LIB_DIR/config-reader.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/validators.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/usbguard-policy.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/stages.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/lock.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/logger.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/result.sh"

CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="$STATE_DIR/ttl.json"
LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"

MANAGED_ID=""
DEVICE_ID=""
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $0 --managed-id <UUID> --device <device-id> [--dry-run] [--help]

Explicit revoke - block device after TTL expired

Options:
  --managed-id <UUID>   TTL record managed_id (must be expired)
  --device <ID>         Current device ID from fresh list-devices (e.g., 5)
  --dry-run             Show what would be done without changing policy
  --help                Show this help

This tool:
- Only works with expired TTL records
- Requires device ID from current USBGuard state (not from old record)
- Requires interactive confirmation
- Acquires lock, re-fetches, validates, checks independent allow rules
- Only runs block-device if G-01 verified and all checks pass
- Never modifies ttl.json - expired record remains final

Exit codes:
  0 success, 1 operational failure, 7 validation, 9 inconsistent, 130 cancelled
EOF
  # הסבר: מציג אפשרויות שורת פקודה. הכלי פועל רק עם רשומות TTL פגות תוקף,
  # דורש מזהה מכשיר מרשימת ההתקנים הנוכחית, ואישור אינטראקטיבי.
  # אינה משנה ttl.json - הרשומה הפגה נותרת final.
}

parse_args() {
  # פותח ארגומנטים מהשורה הפקודה
  while (( $# )); do
    case "$1" in
      --managed-id)
        if (( $# < 2 )) || [[ -z "$2" ]]; then
          printf 'ERROR: --managed-id requires a UUID v4 value\n' >&2
          exit 7
        fi
        MANAGED_ID="${2:-}"
        shift 2
        ;;
      --device)
        if (( $# < 2 )) || [[ -z "$2" ]]; then
          printf 'ERROR: --device requires a numeric device ID\n' >&2
          exit 7
        fi
        DEVICE_ID="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown argument %s\n' "$1" >&2
        usage >&2
        exit 7
        ;;
    esac
  done

  # אימות ש-Necessary args ניתנו
  if [[ -z "$MANAGED_ID" || -z "$DEVICE_ID" ]]; then
    printf 'ERROR: --managed-id and --device are required\n' >&2
    usage >&2
    exit 7
  fi

  if ! validators_is_uuid_v4 "$MANAGED_ID"; then
    printf 'ERROR: --managed-id must be UUID v4\n' >&2
    exit 7
  fi

  if [[ ! "$DEVICE_ID" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: --device must be numeric device ID from current list-devices\n' >&2
    exit 7
  fi
}

log_info() {
  printf 'usb-revoke: INFO: %s\n' "$1"
}

log_error() {
  printf 'usb-revoke: ERROR: %s\n' "$1" >&2
}

confirm_interactive() {
  # מאשרת אינטראקטיבית - אם dry-run, מדפסת הודעה וחוזרת הצלחה.
  # בודקת אם stdin הוא tty ומבקשת אישור y/N מהמשתמש
  local prompt="$1"
  local answer
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN] Would prompt: %s\n' "$prompt"
    return 0
  fi
  # Check if stdin is tty
  if [[ ! -t 0 ]]; then
    log_error "interactive confirmation required but stdin is not a tty"
    return 1
  fi
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      log_info "User cancelled"
      return 130
      ;;
  esac
}

main() {
  parse_args "$@"

  result_start

  # טוען config אם קיים
  if [[ -f "$CONFIG_PATH" ]]; then
    load_config "$CONFIG_PATH" || {
      log_error "config invalid"
      result_validation_failed "config invalid"
      result_print_json
      exit 7
    }
  fi

  # בודקת יומן שחזור - אם קיים, חסימת revoke blocked
  if [[ -f "$STATE_DIR/restore_journal.json" ]]; then
    log_error "restore journal exists - recovery required, blocking revoke"
    result_recovery_required "restore journal exists"
    result_print_json
    exit 9
  fi

  # בודקת daemon
  if ! check_daemon_status; then
    log_error "daemon not running or IPC unavailable"
    result_operation_failed "daemon unavailable"
    result_print_json
    exit 1
  fi

  #Validate ttl.json
  if ! validate_ttl_json "$TTL_FILE"; then
    log_error "ttl.json invalid: $VALIDATORS_ERROR"
    result_recovery_required "ttl.json invalid"
    result_print_json
    exit 9
  fi

  # Find TTL record - must be expired
  local record_json
  record_json="$(jq -c ".records[] | select(.managed_id == \"$MANAGED_ID\")" "$TTL_FILE" 2>/dev/null || true)"
  if [[ -z "$record_json" ]]; then
    log_error "managed_id $MANAGED_ID not found in ttl.json"
    result_validation_failed "managed_id not found"
    result_print_json
    exit 7
  fi

  local record_status record_rule record_expires
  record_status="$(jq -r '.status' <<< "$record_json")"
  record_rule="$(jq -r '.rule' <<< "$record_json")"
  record_expires="$(jq -r '.expires_at' <<< "$record_json")"

  if [[ "$record_status" != "expired" ]]; then
    log_error "record $MANAGED_ID status is $record_status, must be expired for revoke"
    result_validation_failed "record not expired"
    result_print_json
    exit 7
  fi

  log_info "Found expired record $MANAGED_ID: $record_rule expires_at=$record_expires"

  # Get fresh device list
  if ! list_blocked_devices; then
    log_error "failed to list blocked devices"
    result_operation_failed "list blocked devices failed"
    result_print_json
    exit 1
  fi

  # Check if device already blocked
  local is_blocked=0
  local line
  for line in "${USBAM_BLOCKED_DEVICES[@]}"; do
    if [[ "$line" =~ ^[[:space:]]*$DEVICE_ID: ]]; then
      is_blocked=1
      break
    fi
  done

  if (( is_blocked )); then
    log_info "Device $DEVICE_ID already blocked - nothing to do"
    printf 'Device %s is already blocked. No action needed.\n' "$DEVICE_ID"
    result_success "device already blocked"
    result_print_json
    exit 0
  fi

  # Get active rules and device details - need to list devices (not just blocked)
  if ! usbguard_policy_run_readonly list-devices >/dev/null 2>&1; then
    log_error "failed to list devices for verification"
    result_operation_failed "list devices failed"
    result_print_json
    exit 1
  fi

  # For simplicity, we check if device ID exists in full device list
  # The mock may not support list-devices without --blocked, but real USBGuard does
  # We'll try to parse USBAM_POLICY_STDOUT as device list
  local device_found=0
  local device_line
  # Use the stdout from last list-devices call (or re-run with our wrapper)
  # Actually we need to call list_blocked_devices and also need to get allowed devices
  # For this implementation, we will attempt to get device details via a helper
  # If device not found at all, it's disconnected
  if ! list_active_rules; then
    log_error "failed to list active rules for effective policy check"
    result_operation_failed "list active rules failed"
    result_print_json
    exit 1
  fi

  # Check if device is allowed via independent rule (not the expired one)
  # The expired rule is already removed, so any allow rule that matches device is independent
  # Extract id pattern from expired record rule
  local id_pattern
  id_pattern="$(usbguard_extract_id_pattern "$record_rule")"
  log_info "Checking independent allow rules for id_pattern=$id_pattern"

  local independent_allow_found=0
  local independent_rule_id=""
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    local rid rtext
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rtext" =~ ^allow && -n "$id_pattern" && "$rtext" == *"$id_pattern"* ]]; then
      independent_allow_found=1
      independent_rule_id="$rid"
      break
    fi
  done

  if (( independent_allow_found )); then
    log_info "Device $DEVICE_ID allowed via independent permanent rule $independent_rule_id - will not block"
    printf 'Device %s is allowed by independent rule %s (id %s).\n' "$DEVICE_ID" "$id_pattern" "$independent_rule_id"
    printf 'Blocking it would affect other legitimate use. Revoke aborted per FR-27.\n'
    result_validation_failed "device allowed via independent rule $independent_rule_id"
    result_print_json
    exit 7
  fi

  # Check if device ID is currently connected and allowed
  # We need to list all devices (not just blocked) - try to parse
  local all_devices_output
  all_devices_output="$USBAM_POLICY_STDOUT"  # from last list_active_rules? Actually need list-devices
  # Re-run list-devices to get all
  if usbguard_policy_run_readonly list-devices >/dev/null 2>&1; then
    all_devices_output="$USBAM_POLICY_STDOUT"
    device_found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ ^[[:space:]]*$DEVICE_ID: ]]; then
        device_found=1
        device_line="$line"
        break
      fi
    done <<< "$all_devices_output"
    if (( device_found == 0 )); then
      log_info "Device $DEVICE_ID not found in current device list - may be disconnected"
      printf 'Device %s not currently connected. Cannot block disconnected device per spec.\n' "$DEVICE_ID"
      result_validation_failed "device disconnected"
      result_print_json
      exit 7
    fi
    log_info "Device $DEVICE_ID found: $device_line"
  else
    log_error "Unable to verify device $DEVICE_ID connection status"
    result_operation_failed "device verification failed"
    result_print_json
    exit 1
  fi

  # Display details and ask confirmation
  printf '\n=== USB Revoke Confirmation ===\n'
  printf 'Managed ID: %s (expired record)\n' "$MANAGED_ID"
  printf 'Rule: %s\n' "$record_rule"
  printf 'Device ID: %s\n' "$DEVICE_ID"
  printf 'Device details: %s\n' "$device_line"
  printf 'Action: block-device %s\n' "$DEVICE_ID"
  printf 'Consequence: Device will be blocked for future connections until explicitly allowed.\n'
  printf 'G-01 verification required: %s\n' "$(is_g01_verified && echo yes || echo no)"
  printf '\n'

  if ! is_g01_verified; then
    log_error "G-01 not verified - block-device requires G-01 verification (SEC-19)"
    result_validation_failed "G-01 not verified for block-device"
    result_print_json
    exit 7
  fi

  if confirm_interactive "Confirm block device $DEVICE_ID?"; then
    :
  else
    local rc=$?
    if (( rc == 130 )); then
      result_cancelled "user cancelled"
      result_print_json
      exit 130
    else
      result_operation_failed "confirmation failed"
      result_print_json
      exit 1
    fi
  fi

  if (( DRY_RUN )); then
    log_info "[DRY-RUN] Would block device $DEVICE_ID"
    result_success "dry-run - would block $DEVICE_ID"
    result_print_json
    exit 0
  fi

  # Acquire lock and re-fetch
  LOCK_FILE="$LOCK_FILE"
  if ! lock_acquire 5; then
    log_error "unable to acquire lock"
    result_operation_failed "lock failed"
    result_print_json
    exit 1
  fi

  # Re-fetch and re-validate under lock (TOCTOU protection)
  log_info "Re-fetching under lock for TOCTOU protection"

  if ! validate_ttl_json "$TTL_FILE"; then
    lock_release
    log_error "ttl.json invalid after lock"
    result_recovery_required "ttl.json invalid under lock"
    result_print_json
    exit 9
  fi

  record_json="$(jq -c ".records[] | select(.managed_id == \"$MANAGED_ID\")" "$TTL_FILE" 2>/dev/null || true)"
  if [[ -z "$record_json" ]]; then
    lock_release
    log_error "managed_id $MANAGED_ID disappeared under lock"
    result_validation_failed "record disappeared"
    result_print_json
    exit 7
  fi

  record_status="$(jq -r '.status' <<< "$record_json")"
  if [[ "$record_status" != "expired" ]]; then
    lock_release
    log_error "record $MANAGED_ID status changed to $record_status under lock"
    result_validation_failed "record status changed"
    result_print_json
    exit 7
  fi

  # Re-check daemon
  if ! check_daemon_status; then
    lock_release
    log_error "daemon unavailable under lock"
    result_operation_failed "daemon unavailable under lock"
    result_print_json
    exit 1
  fi

  # Re-check device still connected and not blocked and no independent rule
  if ! usbguard_policy_run_readonly list-devices >/dev/null 2>&1; then
    lock_release
    log_error "failed to re-list devices under lock"
    result_operation_failed "re-list devices failed"
    result_print_json
    exit 1
  fi

  device_found=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*$DEVICE_ID: ]]; then
      device_found=1
      break
    fi
  done <<< "$USBAM_POLICY_STDOUT"

  if (( device_found == 0 )); then
    lock_release
    log_error "device $DEVICE_ID disconnected under lock"
    result_validation_failed "device disconnected under lock"
    result_print_json
    exit 7
  fi

  if ! list_active_rules; then
    lock_release
    log_error "failed to re-list active rules under lock"
    result_operation_failed "list active rules failed under lock"
    result_print_json
    exit 1
  fi

  independent_allow_found=0
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    local rid rtext
    usbguard_parse_rule_line "$line" rid rtext || continue
    if [[ "$rtext" =~ ^allow && -n "$id_pattern" && "$rtext" == *"$id_pattern"* ]]; then
      independent_allow_found=1
      break
    fi
  done

  if (( independent_allow_found )); then
    lock_release
    log_error "independent allow rule appeared under lock"
    result_validation_failed "independent rule appeared under lock"
    result_print_json
    exit 7
  fi

  # Now block
  log_info "All checks passed under lock, executing block-device $DEVICE_ID"

  if ! block_device "$DEVICE_ID"; then
    lock_release
    log_error "block-device $DEVICE_ID failed: $USBAM_POLICY_ERROR_CODE $USBAM_POLICY_STDERR"
    result_policy_failed "block-device failed: $USBAM_POLICY_ERROR_CODE"
    result_print_json
    exit 1
  fi

  # Verify blocked
  if ! list_blocked_devices; then
    lock_release
    log_error "failed to verify blocked status after block-device"
    result_unknown "verification failed after block-device"
    result_print_json
    exit 9
  fi

  is_blocked=0
  for line in "${USBAM_BLOCKED_DEVICES[@]}"; do
    if [[ "$line" =~ ^[[:space:]]*$DEVICE_ID: ]]; then
      is_blocked=1
      break
    fi
  done

  if (( is_blocked == 0 )); then
    lock_release
    log_error "device $DEVICE_ID not found in blocked list after block-device"
    result_unknown "device not blocked after block-device"
    result_print_json
    exit 9
  fi

  log_info "Device $DEVICE_ID successfully blocked"

  # Audit - separate policy result and audit result
  local audit_helper="$LIB_DIR/audit_write.py"
  if [[ -x "$audit_helper" ]]; then
    local audit_json
    audit_json="$(jq -n \
      --arg actor_uid "$(id -u)" \
      --arg action "revoke" \
      --arg managed_id "$MANAGED_ID" \
      --arg device_id "$DEVICE_ID" \
      --arg rule "$record_rule" \
      '{
        timestamp_utc: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
        actor_uid: ($actor_uid | tonumber),
        action: $action,
        policy_result: "applied",
        correlation_id: $managed_id,
        details: {
          device_id: $device_id,
          rule: $rule,
          result: "blocked"
        }
      }')"
    if ! python3 "$audit_helper" --data "$audit_json" 2>/dev/null; then
      lock_release
      log_error "policy applied but audit write failed"
      result_policy_applied_audit_failed "audit write failed after block-device"
      result_print_json
      exit 14
    fi
  fi

  lock_release

  printf 'Device %s successfully blocked for expired record %s\n' "$DEVICE_ID" "$MANAGED_ID"
  result_policy_applied "device $DEVICE_ID blocked"
  result_print_json
  exit 0
}

main "$@"
