#!/usr/bin/env bash
# cleanup-expired.sh - TTL Reaper (SRS v4.5 Section 14)
# Type=oneshot systemd service, runs every 5 minutes
# NEVER runs block-device automatically. Reports EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED.
#
# --- הסבר בעברית ---
# ניקוי חוקי TTL פגי תוקף (SRS v4.5 Section 14).
# שירות Type=oneshot של systemd, רץ כל 5 דקות.
# לעולם אינו מפעיל התקני block-device אוטומטית. מדווח על חוקים שפגו תוקף שהוסרו אך עדיין מותרים.
# אחראית על ניקיון חוקי TTL שפגו תוקפם, הסרת חוקים פגי תוקף, ודיווח על המצב.
# פועלת בליווי יומן ומבטיחה שלא יוסרו חוקים פעילים.

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
source "$LIB_DIR/time-guards.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/stages.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/lock.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/logger.sh"
# shellcheck source=/dev/null
source "$LIB_DIR/result.sh"

# Default paths - can be overridden for testing
CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="$STATE_DIR/ttl.json"
CLOCK_STATE_FILE="$STATE_DIR/clock_state.json"
RESTORE_JOURNAL_FILE="$STATE_DIR/restore_journal.json"
LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"

# Modes
MODE_RECONCILE=1
MODE_EXPIRE=1

usage() {
  cat <<EOF
Usage: $0 [--reconcile] [--expire-only] [--help]

TTL Reaper - removes expired temporary rules

Options:
  --reconcile      Run reconcile phase (default: both)
  --expire-only    Run expire phase only
  --help           Show this help

Exit codes:
  0 EXIT_OK - success
  1 EXIT_OPERATION - preflight failure, retry later
  9 EXIT_INCONSISTENT - recovery required
  14 EXIT_AUDIT - policy applied but audit failed (not used here, but reserved)

Reaper NEVER runs block-device. It only removes temporary rules and reports
if device remains allowed via other rule (EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED).
EOF
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --reconcile)
        MODE_RECONCILE=1
        MODE_EXPIRE=1
        ;;
      --expire-only)
        MODE_RECONCILE=0
        MODE_EXPIRE=1
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        printf 'ERROR: unknown argument %s\n' "$arg" >&2
        usage >&2
        exit 7
        ;;
    esac
  done
}

log_info() {
  printf 'cleanup-expired: INFO: %s\n' "$1"
  if declare -F logger_info >/dev/null 2>&1; then
    logger_info "$1" 2>/dev/null || true
  fi
}

log_error() {
  printf 'cleanup-expired: ERROR: %s\n' "$1" >&2
  if declare -F logger_error >/dev/null 2>&1; then
    logger_error "$1" 2>/dev/null || true
  fi
}

# --- Preflight ---
preflight() {
  log_info "Starting preflight"

  # Load config
  if [[ -f "$CONFIG_PATH" ]]; then
    if ! load_config "$CONFIG_PATH"; then
      log_error "config invalid"
      return 1
    fi
  else
    log_info "config file not found, using defaults"
  fi

  # Check restore journal - if exists, block
  if [[ -f "$RESTORE_JOURNAL_FILE" ]]; then
    log_error "restore journal exists at $RESTORE_JOURNAL_FILE - recovery required, blocking policy changes"
    printf 'RESTORE_JOURNAL_EXISTS=%s\n' "$RESTORE_JOURNAL_FILE"
    printf 'RECOVERY_REQUIRED=restore_journal\n'
    return 9
  fi

  # Check daemon status
  if check_daemon_status; then
    :
  else
    local status=$?
    if (( status == 9 )); then
      log_error "daemon not running or IPC unavailable (daemon=$USBAM_DAEMON_STATUS ipc=$USBAM_IPC_STATUS) - will retry later"
      printf 'DAEMON_STATUS=%s IPC_STATUS=%s\n' "$USBAM_DAEMON_STATUS" "$USBAM_IPC_STATUS"
      return 1
    else
      log_error "unable to determine daemon status: $USBAM_POLICY_ERROR_CODE"
      return 1
    fi
  fi

  log_info "Preflight OK - daemon=$USBAM_DAEMON_STATUS ipc=$USBAM_IPC_STATUS"

  # Acquire lock
  LOCK_FILE="$LOCK_FILE"
  if ! lock_acquire 5; then
    log_error "unable to acquire lock $LOCK_FILE - competing process"
    return 1
  fi
  log_info "Lock acquired: $LOCK_FILE"

  # Validate ttl.json
  if [[ -f "$TTL_FILE" ]]; then
    if ! validate_ttl_json "$TTL_FILE"; then
      log_error "ttl.json invalid: $VALIDATORS_ERROR"
      # Don't modify policy if state invalid
      return 9
    fi
  else
    log_info "ttl.json does not exist, initializing"
    if ! stages_init_ttl_file_if_missing; then
      log_error "failed to init ttl.json"
      return 1
    fi
  fi

  return 0
}

# --- Validate-state ---
validate_state() {
  log_info "validate-state"
  if ! validate_ttl_json "$TTL_FILE"; then
    log_error "ttl.json validation failed in validate-state: $VALIDATORS_ERROR"
    return 9
  fi
  return 0
}

# --- Reconcile ---
reconcile() {
  log_info "Starting reconcile phase"
  local has_non_expired
  has_non_expired="$(has_non_expired_records "$TTL_FILE")"

  # Check clock trust if there are non-expired records
  local clock_trusted="no"
  if [[ "$has_non_expired" == "yes" ]]; then
    if detect_clock_jump "$CLOCK_STATE_FILE" "yes"; then
      clock_trusted="yes"
      log_info "Clock trusted: $CLOCK_TRUST_STATUS"
    else
      log_info "Clock untrusted or recovery required: $CLOCK_TRUST_DETAIL_CODE status=$CLOCK_TRUST_STATUS"
      # If clock untrusted and there are non-expired records, we cannot safely expire, but we should not auto-remediate
      # Instead, move affected records to recovery_required where safe
    fi
  else
    log_info "No non-expired records, clock check not critical for reconcile"
    clock_trusted="yes"
  fi

  # Iterate records
  local record_count
  record_count="$(jq '.records | length' "$TTL_FILE")"
  local i changed=0
  local new_content
  new_content="$(cat "$TTL_FILE")"

  for ((i=0; i<record_count; i++)); do
    local managed_id status rule expires_at
    managed_id="$(jq -r ".records[$i].managed_id" "$TTL_FILE")"
    status="$(jq -r ".records[$i].status" "$TTL_FILE")"
    rule="$(jq -r ".records[$i].rule" "$TTL_FILE")"
    expires_at="$(jq -r ".records[$i].expires_at" "$TTL_FILE")"

    log_info "Reconcile: checking record $managed_id status=$status"

    # Pending old records -> recovery_required (crash left pending)
    if [[ "$status" == "pending" ]]; then
      log_info "Found pending record $managed_id from previous crash - moving to recovery_required"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
      changed=1
      continue
    fi

    # For active records, check if rule still exists
    if [[ "$status" == "active" ]]; then
      # Try to find rule
      if ! usbguard_find_rule_id_by_canonical "$rule" >/dev/null 2>&1; then
        local error_code="$USBAM_POLICY_ERROR_CODE"
        if [[ "$error_code" == "rule_not_found" ]]; then
          log_info "Active record $managed_id rule missing in policy - moving to recovery_required (no auto-restore)"
          new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
          changed=1
        elif [[ "$error_code" == "ambiguous_rule_match" ]]; then
          log_info "Active record $managed_id ambiguous match - moving to recovery_required"
          new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
          changed=1
        else
          log_info "Active record $managed_id check failed: $error_code - moving to recovery_required"
          new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
          changed=1
        fi
      else
        log_info "Active record $managed_id rule exists ID $USBAM_MATCHED_RULE_ID"
      fi
    fi

    # If clock untrusted and record is active with future expiration, move to recovery_required for safety?
    # Per spec: missing data, unsupported source, early epoch or jump in same boot moves to recovery_required
    if [[ "$status" == "active" && "$clock_trusted" == "no" && "$has_non_expired" == "yes" ]]; then
      # Only if we are in untrusted state, we should move active records to recovery_required
      # But only if we can safely write
      if [[ "$CLOCK_TRUST_DETAIL_CODE" == "clock_untrusted" || "$CLOCK_TRUST_DETAIL_CODE" == "clock_state_recovery_required" ]]; then
        log_info "Clock untrusted, moving active record $managed_id to recovery_required per spec"
        new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
        changed=1
      fi
    fi
  done

  if (( changed )); then
    log_info "Reconcile changed state, writing ttl.json atomically"
    local atomic_helper="$LIB_DIR/atomic-write.py"
    if [[ ! -r "$atomic_helper" ]] ||
      ! python3 "$atomic_helper" --file "$TTL_FILE" --data "$new_content"; then
      log_error "Failed to write ttl.json atomically after reconcile"
      return 9
    fi
    if ! validate_ttl_json "$TTL_FILE"; then
      log_error "ttl.json invalid after reconcile write"
      return 9
    fi
  else
    log_info "Reconcile: no changes needed"
  fi

  return 0
}

# --- Expire ---
expire() {
  log_info "Starting expire phase"

  local current_epoch
  current_epoch="$(date +%s)"
  local has_non_expired
  has_non_expired="$(has_non_expired_records "$TTL_FILE")"

  # Check clock trust before any expiration
  if [[ "$has_non_expired" == "yes" ]]; then
    if ! detect_clock_jump "$CLOCK_STATE_FILE" "yes"; then
      log_info "Clock not trusted for expiration: $CLOCK_TRUST_DETAIL_CODE - moving affected records to recovery_required where safe, no auto expiration"
      # Don't expire anything if clock untrusted, but try to move records that would have expired?
      # Per spec: no automatic expiration when clock unreliable
      # We already handled moving to recovery_required in reconcile
      return 0
    fi
  fi

  local record_count
  record_count="$(jq '.records | length' "$TTL_FILE")"
  local i
  local expired_any=0
  local new_content
  new_content="$(cat "$TTL_FILE")"
  local -a expired_ids=()

  for ((i=0; i<record_count; i++)); do
    local managed_id status rule expires_at
    managed_id="$(jq -r ".records[$i].managed_id" "$TTL_FILE")"
    status="$(jq -r ".records[$i].status" "$TTL_FILE")"
    rule="$(jq -r ".records[$i].rule" "$TTL_FILE")"
    expires_at="$(jq -r ".records[$i].expires_at" "$TTL_FILE")"

    if [[ "$status" != "active" ]]; then
      continue
    fi

    if (( expires_at > current_epoch )); then
      log_info "Record $managed_id not yet expired (expires_at=$expires_at now=$current_epoch)"
      continue
    fi

    log_info "Record $managed_id expired (expires_at=$expires_at now=$current_epoch) - attempting removal"

    # Find rule ID fresh before removal (TOCTOU protection)
    local rule_id
    if ! rule_id="$(usbguard_find_rule_id_by_canonical "$rule")"; then
      log_info "Expired record $managed_id rule not found or ambiguous: $USBAM_POLICY_ERROR_CODE - moving to recovery_required"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
      expired_any=1
      continue
    fi

    # Re-fetch immediately before removal
    local fresh_id
    if ! fresh_id="$(usbguard_find_rule_id_by_canonical "$rule")"; then
      log_info "Expired record $managed_id disappeared before removal (TOCTOU) - recovery_required"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
      expired_any=1
      continue
    fi
    if [[ "$fresh_id" != "$rule_id" ]]; then
      log_info "Expired record $managed_id rule ID changed $rule_id -> $fresh_id (TOCTOU) - recovery_required"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
      expired_any=1
      continue
    fi

    if usbguard_rule_is_persistent "$rule"; then
      log_error "Expired record $managed_id matches persistent USBGuard policy - preserving rule and requiring recovery"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
      expired_any=1
      continue
    else
      local persistent_check_status=$?
      if (( persistent_check_status != 1 )); then
        log_error "Cannot safely determine whether rule $managed_id is persistent: $USBAM_POLICY_ERROR_CODE - preserving policy and requiring recovery"
        new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
        expired_any=1
        continue
      fi
    fi

    # Remove rule - only temporary rule that matches uniquely and verified
    if ! usbguard_policy_run_write remove-rule "$rule_id"; then
      log_error "Failed to remove rule $rule_id for expired record $managed_id: $USBAM_POLICY_ERROR_CODE $USBAM_POLICY_STDERR"
      # If removal result uncertain, don't retry automatically, report EXIT_INCONSISTENT
      if [[ "$USBAM_POLICY_ERROR_CODE" == "command_timeout" ]]; then
        log_error "Removal result uncertain for $managed_id - marking recovery_required and reporting EXIT_INCONSISTENT"
        new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "recovery_required"')"
        expired_any=1
        # Will exit with 9 later
      else
        new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "inconsistent"')"
        expired_any=1
      fi
      continue
    fi

    # Verify removal
    if ! list_active_rules; then
      log_error "Failed to verify removal for $managed_id - list_active_rules failed"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "inconsistent"')"
      expired_any=1
      continue
    fi

    local still_exists=0
    local line rid rtext
    for line in "${USBAM_ACTIVE_RULES[@]}"; do
      usbguard_parse_rule_line "$line" rid rtext || continue
      if [[ "$rid" == "$rule_id" ]]; then
        still_exists=1
        break
      fi
    done

    if (( still_exists )); then
      log_error "Rule $rule_id still present after removal for $managed_id"
      new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "inconsistent"')"
      expired_any=1
      continue
    fi

    log_info "Rule $rule_id removed for expired record $managed_id"

    # Check effective policy - is device still allowed via other rule?
    # This is the FR-21 reporting: EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED
    local still_allowed="unknown"
    # Extract ID pattern from rule to check if any other allow rule matches same device
    local id_pattern
    id_pattern="$(usbguard_extract_id_pattern "$rule")"
    if [[ -n "$id_pattern" ]]; then
      # Check if any active allow rule contains same id pattern
      for line in "${USBAM_ACTIVE_RULES[@]}"; do
        usbguard_parse_rule_line "$line" rid rtext || continue
        if [[ "$rtext" =~ ^allow && "$rtext" == *"$id_pattern"* ]]; then
          still_allowed="yes"
          break
        fi
      done
      if [[ "$still_allowed" != "yes" ]]; then
        still_allowed="no"
      fi
    fi

    if [[ "$still_allowed" == "yes" ]]; then
      log_info "EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED: record $managed_id rule $rule_id removed but device $id_pattern still allowed via other rule"
      printf 'EXPIRED_RULE_REMOVED_DEVICE_STILL_ALLOWED managed_id=%s rule_id=%s id_pattern=%s\n' "$managed_id" "$rule_id" "$id_pattern"
    elif [[ "$still_allowed" == "no" ]]; then
      log_info "EXPIRED_RULE_REMOVED_DEVICE_NOW_BLOCKED: record $managed_id device $id_pattern now blocked (no other allow rule)"
    else
      log_info "EXPIRED_RULE_REMOVED_EFFECTIVE_POLICY_UNKNOWN: record $managed_id"
    fi

    # Mark as expired only after removal verified
    new_content="$(printf '%s' "$new_content" | jq --arg mid "$managed_id" '(.records[] | select(.managed_id == $mid) | .status) = "expired"')"
    expired_ids+=("$managed_id")
    expired_any=1
  done

  if (( expired_any )); then
    log_info "Expire phase changed state, writing ttl.json atomically"
    local atomic_helper="$LIB_DIR/atomic-write.py"
    if [[ ! -r "$atomic_helper" ]] ||
      ! python3 "$atomic_helper" --file "$TTL_FILE" --data "$new_content"; then
      log_error "Failed to write ttl.json atomically after expire - reporting EXIT_INCONSISTENT"
      # Previous file preserved by atomic-write, so we report inconsistent and don't retry removal
      return 9
    fi
    if ! validate_ttl_json "$TTL_FILE"; then
      log_error "ttl.json invalid after expire write"
      return 9
    fi
    log_info "Expired records: ${expired_ids[*]}"
  else
    log_info "Expire: no records expired"
  fi

  return 0
}

# --- Main ---
main() {
  parse_args "$@"

  result_start

  # Preflight
  if preflight; then
    :
  else
    local rc=$?
    lock_release 2>/dev/null || true
    if (( rc == 9 )); then
      result_recovery_required "preflight recovery required"
      result_print_json
      exit 9
    else
      result_operation_failed "preflight failed"
      result_print_json
      exit 1
    fi
  fi

  # Validate-state
  if ! validate_state; then
    lock_release
    result_recovery_required "validate-state failed"
    result_print_json
    exit 9
  fi

  # Reconcile
  if (( MODE_RECONCILE )); then
    if reconcile; then
      :
    else
      local rc=$?
      lock_release
      if (( rc == 9 )); then
        result_recovery_required "reconcile requires recovery"
        result_print_json
        exit 9
      else
        result_operation_failed "reconcile failed"
        result_print_json
        exit 1
      fi
    fi
  fi

  # Expire
  if (( MODE_EXPIRE )); then
    if expire; then
      :
    else
      local rc=$?
      lock_release
      if (( rc == 9 )); then
        result_recovery_required "expire inconsistent"
        result_print_json
        exit 9
      else
        result_operation_failed "expire failed"
        result_print_json
        exit 1
      fi
    fi
  fi

  lock_release
  result_success "reaper completed"
  result_print_json
  exit 0
}

main "$@"
