#!/usr/bin/env bash
# נקודת כניסה אינטראקטיבית ו- CLI לאישור (SRS v4.5, Sections 12 and 15).
# מאפשר אישור מכשירי USB בבדיקת TTL זמני או קבוע, עם אפשרות dry-run.
# נדרשת הרשאת root לשינויים במדיניות.

set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

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
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
CLOCK_STATE_FILE="${USBAM_CLOCK_STATE_FILE:-$STATE_DIR/clock_state.json}"
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"

APPROVAL_TYPE=""
TTL_SECONDS=""
DRY_RUN=0
declare -a REQUESTED_DEVICES=()
declare -a SELECTED_DEVICES=()
declare -A SELECTED_RULES=()
declare -A SEEN_DEVICES=()
declare -A SELECTED_BLOCK_REASONS=()

usage() {
  cat <<EOF
Usage: $0 --device <ID> [--device <ID> ...] --type <permanent|temporary>
          [--ttl <seconds>] [--dry-run] [--help]
   $0 [--type <permanent|temporary> [--ttl <seconds>]] [--dry-run]

Without --device, select blocked devices interactively with whiptail.
Temporary approvals use TEMP_TTL_SECONDS when --ttl is omitted.
Dry-run performs read-only queries and does not change policy, TTL, Audit, or state.
EOF
  # הסבר: מציג את אפשרויות השורה הפקודה. ללא --device, בחירה אינטראקטיבית
  # של מכשירים חסומים באמצעות whiptail. אישורים זמניים משתמשים ב-TEMP_TTL_SECONDS
  # כאשר --ttl לא צוין. dry-run מבצע שאילתות לקריאה בלבד ואינו משנה מדיניות.
}

validation_error() {
  result_start
  result_validation_failed "$1"
  result_print_json
  exit "$EXIT_VALIDATION"
}

operation_error() {
  result_start
  result_operation_failed "$1"
  result_print_json
  exit "$EXIT_OPERATION"
}

parse_args() {
  # פותח ארגומנטים מהשורה הפקודה
  while (( $# )); do
    case "$1" in
      --device)
        if (( $# < 2 )) || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          validation_error "--device requires a numeric USBGuard device ID"
        fi
        REQUESTED_DEVICES+=("$2")
        shift 2
        ;;
      --type)
        if (( $# < 2 )) || [[ "$2" != "permanent" && "$2" != "temporary" ]]; then
          validation_error "--type must be permanent or temporary"
        fi
        [[ -z "$APPROVAL_TYPE" ]] ||
          validation_error "--type may be specified only once"
        APPROVAL_TYPE="$2"
        shift 2
        ;;
      --ttl)
        if (( $# < 2 )) || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          validation_error "--ttl requires an integer number of seconds"
        fi
        [[ -z "$TTL_SECONDS" ]] || validation_error "--ttl may be specified only once"
        TTL_SECONDS="$2"
        shift 2
        ;;
      --dry-run)
        if (( DRY_RUN != 0 )); then
          validation_error "--dry-run may be specified only once"
        fi
        DRY_RUN=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        validation_error "unknown argument: $1"
        ;;
    esac
  done

  # אימות הדדי של ארגומנטים - TTL תקף רק לאישורים זמניים,
  # TTL חייב להיות בטווח 60-2592000 שניות,
  # --type נדרש כאשר --device specified,
  # בחירה אינטראקטיבית דורשת טרמינל
  if [[ -n "$TTL_SECONDS" && "$APPROVAL_TYPE" == "permanent" ]]; then
    validation_error "--ttl is valid only for temporary approvals"
  fi
  if [[ -n "$TTL_SECONDS" ]] &&
    (( TTL_SECONDS < 60 || TTL_SECONDS > 2592000 )); then
    validation_error "--ttl must be between 60 and 2592000 seconds"
  fi
  if (( ${#REQUESTED_DEVICES[@]} > 0 )) && [[ -z "$APPROVAL_TYPE" ]]; then
    validation_error "--type is required when --device is specified"
  fi
  if (( ${#REQUESTED_DEVICES[@]} == 0 )) && [[ ! -t 0 ]]; then
    validation_error "interactive device selection requires a terminal"
  fi
}

load_approval_config() {
  # טוען הגדרות אישור - אם קובץ קיים, טוען אותו; אחרת מגדיר ערכים ברירת מחדל ממפתחי CONFIG_KEY_SPECS
  if [[ -e "$CONFIG_PATH" || -L "$CONFIG_PATH" ]]; then
    if [[ -L "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]] ||
      ! load_config "$CONFIG_PATH"; then
      validation_error "configuration is unavailable or invalid"
    fi
  else
    CONFIG_VALUES=()
    local key value_type default_value
    for key in "${!CONFIG_KEY_SPECS[@]}"; do
      IFS='|' read -r value_type default_value _ <<< "${CONFIG_KEY_SPECS[$key]}"
      CONFIG_VALUES["$key"]="$default_value"
    done
  fi

  if [[ -z "$TTL_SECONDS" ]]; then
    TTL_SECONDS="${CONFIG_VALUES[TEMP_TTL_SECONDS]}"
  fi
  if [[ -n "${USBAM_LOCK_FILE:-}" ]]; then
    LOCK_FILE="$USBAM_LOCK_FILE"
  fi
  USBAM_LOCK_FILE="$LOCK_FILE"
  STATE_DIR="${USBAM_STATE_DIR:-$STATE_DIR}"
  TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
  CLOCK_STATE_FILE="${USBAM_CLOCK_STATE_FILE:-$STATE_DIR/clock_state.json}"
  RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
  USBAM_DAEMON_CONFIG_PATH="${USBAM_DAEMON_CONFIG_PATH:-/etc/usbguard/usbguard-daemon.conf}"
}

collect_blocked_devices() {
  # אוסף מכשירים חסומים - מרשימת המכשירים החסומים של USBGuard,
  # ממיר כל רשומת block לרישיון allow ומבצעת אימות תקינות
  if ! list_blocked_devices; then
    operation_error "unable to retrieve blocked USBGuard devices"
  fi

  SELECTED_RULES=()
  local record device_id device_rule
  for record in "${USBAM_BLOCKED_DEVICES[@]}"; do
    if ! usbguard_parse_rule_line "$record" device_id device_rule; then
      operation_error "USBGuard returned an invalid blocked-device record"
    fi
    if [[ ! "$device_rule" =~ ^block[[:space:]]+(.+)$ ]]; then
      operation_error "USBGuard returned a non-blocked device in the blocked list"
    fi
    device_rule="allow ${BASH_REMATCH[1]}"
    if ! usbguard_validate_rule "$device_rule"; then
      operation_error "blocked device cannot be converted to a safe allow rule"
    fi
    if [[ -n "${SELECTED_RULES[$device_id]+present}" ]; then
      operation_error "USBGuard returned duplicate device IDs"
    fi
    SELECTED_RULES["$device_id"]="$device_rule"
  done
}

select_devices_interactively() {
  # בחירה אינטראקטיבית של מכשירים - באמצעות whiptail מציג רשימת מכשירים חסומים
  # ומאפשר בחירה, לאחר מכן בוחר סוג אישור (זמני/קבוע) ומגדיר TTL אם נדרש
  if (( ${#SELECTED_RULES[@]} == 0 )); then
    operation_error "there are no blocked USBGuard devices to approve"
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    operation_error "whiptail is required for interactive device selection"
  fi

  local -a choices=()
  local device_id
  for device_id in "${!SELECTED_RULES[@]}"; do
    choices+=("$device_id" "${SELECTED_RULES[$device_id]}" "OFF")
  done
  local selected
  if ! selected="$(whiptail --title "USBGuard Approval Manager" \
    --checklist "Select blocked devices to approve" 20 78 10 \
    "${choices[@]}" 3>&1 1>&2 2>&3)"; then
    return 130
  fi
  selected="${selected//\"/}"
  read -r -a SELECTED_DEVICES <<< "$selected"
  if (( ${#SELECTED_DEVICES[@]} == 0 )); then
    return 130
  fi

  local choice
  if ! choice="$(whiptail --title "Approval type" --menu \
    "Choose approval duration" 12 60 2 \
    temporary "Temporary approval (TTL)" \
    permanent "Permanent approval" 3>&1 1>&2 2>&3)"; then
    return 130
  fi
  APPROVAL_TYPE="$choice"
  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    local default_ttl="${CONFIG_VALUES[TEMP_TTL_SECONDS]}"
    if ! TTL_SECONDS="$(whiptail --title "Temporary approval" --inputbox \
      "TTL in seconds (60-2592000)" 10 60 "$default_ttl" 3>&1 1>&2 2>&3)"; then
      return 130
    fi
    if [[ ! "$TTL_SECONDS" =~ ^[0-9]+$ ]] ||
      (( TTL_SECONDS < 60 || TTL_SECONDS > 2592000 )); then
      validation_error "TTL must be between 60 and 2592000 seconds"
    fi
  elif [[ -n "$TTL_SECONDS" ]]; then
    validation_error "--ttl is valid only for temporary approvals"
  fi
  return 0
}

check_selected_ids() {
  # בודקת מזהים שנבחרו - מאמתת שכל מזהה הוא מספר שלם,
  # מזהים כפולים אינם מותרים, ומזהה תוכנן קיים ברשימת המכשירים החסומים
  local device_id
  for device_id in "${SELECTED_DEVICES[@]}"; do
    if [[ ! "$device_id" =~ ^[0-9]+$ ]]; then
      validation_error "selected device ID is invalid"
    fi
    if [[ -n "${SEEN_DEVICES[$device_id]+present}" ]]; then
      validation_error "duplicate --device IDs are not allowed"
    fi
    SEEN_DEVICES["$device_id"]=1
    if [[ -z "${SELECTED_RULES[$device_id]+present}" ]]; then
      validation_error "device $device_id is not currently blocked or no longer exists"
    fi
  done
}

preflight_selected_devices() {
  # בדיקת תנאי מקדימה למכשירים שנבחרו - בודקת חוקים פעילים,
  # סתירות חוקים, ניגוד עדיפויות, וכללי קבועים שמאלצים מצב של Recovery
  local device_id rule line rule_id active_rule persistent_status
  SELECTED_BLOCK_REASONS=()

  if ! list_active_rules; then
    operation_error "unable to inspect active USBGuard rules before approval"
  fi

  for device_id in "${SELECTED_DEVICES[@]}"; do
    rule="${SELECTED_RULES[$device_id]}"
    local block_reason=""

    for line in "${USBAM_ACTIVE_RULES[@]}"; do
      if usbguard_parse_rule_line "$line" rule_id active_rule &&
        [[ "$active_rule" == "$rule" ]]; then
        block_reason="duplicate_rule"
        break
      fi
    done

    if [[ -z "$block_reason" ]]; then
      USBAM_POLICY_ERROR_CODE=""
      if ! usbguard_check_precedence "$rule"; then
        if [[ "$USBAM_POLICY_ERROR_CODE" == "precedence_conflict" ]]; then
          block_reason="precedence_conflict"
        else
          operation_error "unable to verify rule precedence for device $device_id"
        fi
      fi
    fi

    if [[ -z "$block_reason" ]]; then
      USBAM_POLICY_ERROR_CODE=""
      if usbguard_rule_is_persistent "$rule"; then
        if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
          block_reason="persistent_overlap"
        else
          block_reason="persistent_duplicate"
        fi
      else
        persistent_status=$?
        if (( persistent_status != 1 )); then
          operation_error "unable to inspect persistent policy for device $device_id"
        fi
      fi
    fi

    SELECTED_BLOCK_REASONS["$device_id"]="$block_reason"
  done
}

approval_block_message() {
  # מציגה הודעת אזהרה בהתאם לסוג החסימה
  case "$1" in
    duplicate_rule) printf 'matching rule already exists in active policy' ;;
    precedence_conflict) printf 'an earlier block/reject rule takes precedence' ;;
    persistent_overlap) printf 'matching permanent rule exists; temporary TTL would be redundant' ;;
    persistent_duplicate) printf 'matching rule already exists in persistent policy' ;;
    *) printf 'approval was rejected by policy preflight' ;;
  esac
}

approval_summary() {
  # מציגה סיכום אישור הכולל את סוג האישור, TTL (אם זמני) ורשימת המכשירים עם אזהרות אם יש
  local device_id
  local summary="Review the approval plan. Devices with policy warnings will be skipped."
  summary+=$'\n\n'"Type: $APPROVAL_TYPE"
  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    summary+=$'\n'"TTL: $TTL_SECONDS seconds"
  fi
  for device_id in "${SELECTED_DEVICES[@]}"; do
    summary+=$'\n\n'"Device $device_id"$'\n'"${SELECTED_RULES[$device_id]}"
    if [[ -n "${SELECTED_BLOCK_REASONS[$device_id]:-}" ]]; then
      summary+=$'\n'"WARNING: $(approval_block_message "${SELECTED_BLOCK_REASONS[$device_id]}") — this device will not be changed."
    fi
  done
  printf '%s' "$summary"
}

result_add_failure() {
  # תוסף תוצאה כושלת לרשימת פריטים - מקבלת מזהה התקן, קוד יציאה,
  # פרטים ו-code פרט. תומכת בקודי פירוט שונים כמו inconsistent_state, validation_failed וכו'
  local device_id="$1"
  local exit_code="$2"
  local detail="$3"
  local detail_code="$4"

  if [[ "$detail_code" == "inconsistent_state" ||
    "$detail_code" == "verification_failed" ||
    "$detail_code" == "atomic_write_failed" ||
    "$detail_code" == "device_approval_failed" ||
    "$detail_code" == "device_approval_failed_after_rule" ||
    "$detail_code" == "permanent_rule_outcome_unknown" ||
    "$detail_code" == "persistence_verification_failed" ]]; then
    result_add_item "$device_id" "$RESULT_UNKNOWN" "$EXIT_INCONSISTENT" \
      "$detail" unknown not_applicable "$detail_code"
    BATCH_UNCERTAIN=1
  elif (( exit_code == EXIT_VALIDATION )); then
    result_add_item "$device_id" "$RESULT_VALIDATION_FAILED" "$EXIT_VALIDATION" \
      "$detail" not_applied not_applicable "$detail_code"
    BATCH_FAILED=1
    if (( BATCH_FAILURE_RC == 0 )); then
      BATCH_FAILURE_RC="$EXIT_VALIDATION"
    fi
  elif (( exit_code == EXIT_INCONSISTENT )); then
    result_add_item "$device_id" "$RESULT_RECOVERY_REQUIRED" "$EXIT_INCONSISTENT" \
      "$detail" unknown not_applicable "$detail_code"
    BATCH_UNCERTAIN=1
  else
    result_add_item "$device_id" "$RESULT_OPERATION_FAILED" "$EXIT_OPERATION" \
      "$detail" not_applied not_applicable "$detail_code"
    BATCH_FAILED=1
    if (( BATCH_FAILURE_RC == 0 )); then
      BATCH_FAILURE_RC="$EXIT_OPERATION"
    fi
  fi
}

release_device_lock() {
  # משחררת את הנעילה הגלובלית - מגדירה Trap ל-exit ומפעילה lock_release
  # אם שחרור נעלם עבר בהצלחה, מחזיר 0; אחרת מדפיס שגיאה ומאתחל BATCH_UNCERTAIN
  trap 'lock_release' EXIT
  if lock_release; then
    return 0
  fi
  printf 'usb-approve: ERROR: unable to release the global lock\n' >&2
  BATCH_UNCERTAIN=1
  return 1
}

process_device() {
  # מטפלת בהתקן ספציפי - רוכשת נעילה, מאמתת שתקין המצב,
  # בודקת שהמכשיר עדיין קיים ושינוי המדיניות, ומבצעת אישוי זמני או קבוע
  trap 'lock_release' EXIT
  local device_id="$1"
  local original_rule="${SELECTED_RULES[$device_id]}"
  local current_rule=""
  local current_id current_text
  local rc managed_id="" output_file=""

  if ! lock_acquire 5; then
    result_add_failure "$device_id" "$EXIT_OPERATION" "unable to acquire global lock" "lock_failed"
    return
  fi
  if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
    result_add_failure "$device_id" "$EXIT_INCONSISTENT" \
      "restore journal requires recovery" "restore_recovery_required"
    release_device_lock || return 1
    return
  fi

  if ! list_blocked_devices; then
    result_add_failure "$device_id" "$EXIT_OPERATION" \
      "unable to re-fetch blocked devices under lock" "$USBAM_POLICY_ERROR_CODE"
    release_device_lock || return 1
    return
  fi
  for record in "${USBAM_BLOCKED_DEVICES[@]}"; do
    if usbguard_parse_rule_line "$record" current_id current_text &&
      [[ "$current_id" == "$device_id" ]] &&
      [[ "$current_text" =~ ^block[[:space:]]+(.+)$ ]]; then
      current_rule="allow ${BASH_REMATCH[1]}"
      break
    fi
  done
  if [[ -z "$current_rule" || "$current_rule" != "$original_rule" ]]; then
    result_add_failure "$device_id" "$EXIT_VALIDATION" \
      "device disappeared or changed after selection; no policy was changed" "device_changed"
    release_device_lock || return 1
    return
  fi

  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    if ! output_file="$(mktemp)"; then
      result_add_failure "$device_id" "$EXIT_OPERATION" \
        "unable to reserve private stage output" "temporary_storage_unavailable"
      release_device_lock || return 1
      return
    fi
    if stages_approve_temporary \
      "$current_rule" "$TTL_SECONDS" "$RESULT_CORRELATION_ID" "$device_id" \
      >"$output_file" 2>/dev/null; then
      managed_id="$(<"$output_file")"
      if ! rm -f -- "$output_file"; then
        result_add_failure "$device_id" "$EXIT_INCONSISTENT" \
          "temporary approval completed but private output cleanup failed" \
          "temporary_storage_cleanup_failed"
        release_device_lock || return 1
        return
      fi
      :
    else
      rc=$?
      if ! rm -f -- "$output_file"; then
        result_add_failure "$device_id" "$EXIT_INCONSISTENT" \
          "temporary approval failed and private output cleanup failed" \
          "temporary_storage_cleanup_failed"
        release_device_lock || return 1
        return
      fi
      result_add_failure "$device_id" "$rc" \
        "temporary approval failed: ${STAGES_ERROR_CODE:-unknown}" \
        "${STAGES_ERROR_CODE:-temporary_approval_failed}"
      release_device_lock || return 1
      return
    fi
  else
    if stages_approve_permanent "$current_rule" "$RESULT_CORRELATION_ID" \
      "$device_id" >/dev/null 2>&1; then
      :
    else
      rc=$?
      result_add_failure "$device_id" "$rc" \
        "permanent approval failed: ${STAGES_ERROR_CODE:-unknown}" \
        "${STAGES_ERROR_CODE:-permanent_approval_failed}"
      release_device_lock || return 1
      return
    fi
  fi

  local action="approve_${APPROVAL_TYPE}"
  local audit_details="device_id=$device_id"
  [[ -z "$managed_id" ]] || audit_details+=" managed_id=$managed_id"
  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    audit_details+=" ttl_seconds=$TTL_SECONDS"
  fi
  if log_audit "$action" applied "$RESULT_CORRELATION_ID" "$audit_details"; then
    result_add_item "$device_id" "$RESULT_SUCCESS" "$EXIT_OK" \
      "approval verified${managed_id:+; managed_id=$managed_id}" applied written
    BATCH_SUCCEEDED=$((BATCH_SUCCEEDED + 1))
  else
    result_add_item "$device_id" "$RESULT_POLICY_APPLIED_AUDIT_FAILED" "$EXIT_AUDIT" \
      "policy applied; Audit write failed" applied failed "" "audit_write_failed"
    BATCH_AUDIT_FAILED=1
  fi
  release_device_lock || return 1
}

confirm_approval() {
  # לאישור סופי - אם dry-run, מדלג ישר. דורשת טרמינל לכניסה אינטראקטיבית.
  # מציגה סיכום באמצעות whiptail או מבקשת הזנת "APPROVE"
  if (( DRY_RUN )); then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    validation_error "interactive confirmation is required for policy changes"
  fi

  if command -v whiptail >/dev/null 2>&1; then
    local summary
    summary="$(approval_summary)"
    whiptail --title "Confirm USBGuard approval" --yesno "$summary" 20 78
    return $?
  fi

  printf '%s\n' "$(approval_summary)"
  local answer
  read -r -p 'Type APPROVE to continue: ' answer || return 130
  [[ "$answer" == "APPROVE" ]]
}

process_selected_devices() {
  # מטפלת במכשירים שנבחרו - עוברת על כל מזהה, בודקת אם יש סיבה blocking,
  # ומטפלת במכשיר. אם התקבלה אי-ודאות, עוצרת את שאר המכשירים
  local index device_id
  for ((index = 0; index < ${#SELECTED_DEVICES[@]}; index++)); do
    device_id="${SELECTED_DEVICES[$index]}"
    if [[ -n "${SELECTED_BLOCK_REASONS[$device_id]:-}" ]]; then
      result_add_failure "$device_id" "$EXIT_VALIDATION" \
        "$(approval_block_message "${SELECTED_BLOCK_REASONS[$device_id]}")" \
        "${SELECTED_BLOCK_REASONS[$device_id]}"
      continue
    fi
    process_device "$device_id"
    if (( BATCH_UNCERTAIN )); then
      for ((index++; index < ${#SELECTED_DEVICES[@]}; index++)); do
        device_id="${SELECTED_DEVICES[$index]}"
        result_add_item "$device_id" "$RESULT_OPERATION_FAILED" "$EXIT_OPERATION" \
          "not processed because a previous device requires recovery" \
          not_applied not_applicable "batch_stopped_for_recovery"
        BATCH_FAILED=1
      done
      break
    fi
  done
}

finalize_batch_result() {
  # מסכמת תוצאות batch - בודקת מצבים שונים: אי-ודאות, כשלון audit, כשלון כללי,
  # או הצלחה מלאה, ומגדירה את הודעת התוצאה המתאימה
  if (( BATCH_UNCERTAIN )); then
    result_recovery_required "one or more device outcomes or the global lock state require recovery"
  elif (( BATCH_AUDIT_FAILED )); then
    result_policy_applied_audit_failed "policy applied but one or more Audit writes failed"
  elif (( BATCH_FAILED )); then
    if (( BATCH_SUCCEEDED > 0 )); then
      result_partial "one or more batch items failed" unknown not_applicable
    elif (( BATCH_FAILURE_RC == EXIT_VALIDATION )); then
      result_validation_failed "approval was rejected before policy change"
    else
      result_operation_failed "approval failed"
    fi
  else
    result_success "all selected approvals completed"
    RESULT_POLICY_STATUS="applied"
    RESULT_AUDIT_STATUS="written"
  fi
}

main() {
  # פותח את תהליך האישור המרכזי - מתחילה בהגדרת ארגומנטים, אתחול תוצאות,
  # איסוף מכשירים חסומים, בחירה (אינטראקטיבית או מפורשת), בדיקת תנאים מקדמיים,
  # אישור סופי וביצוע האישוי במכשירים נבחרים
  local selected_rc device_id
  local BATCH_FAILED=0 BATCH_UNCERTAIN=0 BATCH_AUDIT_FAILED=0
  local BATCH_SUCCEEDED=0 BATCH_FAILURE_RC=0
  parse_args "$@"
  result_start
  load_approval_config

  if [[ "$APPROVAL_TYPE" == "temporary" && -n "$TTL_SECONDS" ]] &&
    (( TTL_SECONDS < 60 || TTL_SECONDS > 2592000 )); then
    validation_error "--ttl must be between 60 and 2592000 seconds"
  fi

  # איסוף רשימת המכשירים החסומים ובחירת המכשירים לאישור
  collect_blocked_devices
  if (( ${#REQUESTED_DEVICES[@]} > 0 )); then
    SELECTED_DEVICES=("${REQUESTED_DEVICES[@]}")
  else
    if select_devices_interactively; then
      :
    else
      selected_rc=$?
      result_start
      result_cancelled "interactive approval cancelled before policy change"
      result_print_json
      exit "$EXIT_CANCELLED"
    fi
  fi
  check_selected_ids

  if (( DRY_RUN )); then
    for device_id in "${SELECTED_DEVICES[@]}"; do
      local detail="dry-run: $APPROVAL_TYPE approval"
      [[ "$APPROVAL_TYPE" != "temporary" ]] ||
        detail+="; ttl_seconds=$TTL_SECONDS"
      result_add_item "$device_id" "$RESULT_SUCCESS" "$EXIT_OK" \
        "$detail" not_applicable not_applicable
    done
    result_success "dry-run completed; no state or policy was changed"
    result_print_json
    exit "$EXIT_OK"
  fi
  if [[ "$APPROVAL_TYPE" == "temporary" ]] && [[ -z "$TTL_SECONDS" ]]; then
    validation_error "temporary approval requires a TTL"
  fi
  if (( EUID != 0 )); then
    operation_error "policy-changing approvals require root privileges"
  fi
  if ! check_daemon_status; then
    operation_error "USBGuard daemon or IPC is unavailable"
  fi
  if ! is_g01_verified; then
    result_start
    result_recovery_required "G-01 evidence is not verified; policy changes are disabled"
    result_print_json
    exit "$EXIT_INCONSISTENT"
  fi
  preflight_selected_devices
  RESULT_CORRELATION_ID="$(generate_uuid_v4)"
  if ! validators_is_uuid_v4 "$RESULT_CORRELATION_ID"; then
    operation_error "unable to generate a valid correlation ID"
  fi
  if confirm_approval; then
    :
  else
    selected_rc=$?
    result_start
    result_cancelled "approval cancelled before policy change"
    result_print_json
    exit "$EXIT_CANCELLED"
  fi

  process_selected_devices
  finalize_batch_result
  result_print_json
  exit "$RESULT_EXIT_CODE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
