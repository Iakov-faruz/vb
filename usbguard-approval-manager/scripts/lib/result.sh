#!/usr/bin/env bash
# scripts/lib/result.sh
# USBGuard Approval Manager — Error / Result Model
#
# --- הסבר בעברית ---
# מודל תוצאות/שגיאות משותף (SRS §21, SEC-16).
# מגדיר קודי יציאה (EXIT_*), מצבי תוצאה (RESULT_*), ופונקציות לניהול
# state גלובלי (RESULT_STATE, RESULT_EXIT_CODE, RESULT_DETAIL, ...),
# והדפסת JSON סופי (result_print_json).
# משמש כל סקריפט להחזרת תוצאה עקיבה ו-exit codes תקניים.
#
# קודי יציאה:
#   0=OK, 1=operation failure, 7=validation, 9=inconsistent/recovery, 13=partial/cancelled, 14=audit.
#
# פונקציות עיקריות:
#   result_start                      - איפוס state ל-RESULT_SUCCESS
#   result_set <state> <exit> [detail]- קביעת state/exit/detail
#   result_success/policy_failed/...  - קיצורי state
#   result_add_item ...               - הוספת item ל-JSON
#   result_print_json                 - הדפסת JSON
#   result_exit                       - exit עם RESULT_EXIT_CODE
# scripts/lib/result.sh
# USBGuard Approval Manager — Error / Result Model
#
# Shared operation outcomes, JSON results, and exit codes (SRS section 21 and SEC-16).
#
# Exit codes:
#   EXIT_OK=0           Operation succeeded
#   EXIT_OPERATION=1    Precondition/operational failure before policy change
#   EXIT_VALIDATION=7   Input/config validation failure
#   EXIT_INCONSISTENT=9 Unknown policy outcome / recovery required
#   EXIT_PARTIAL=13     Batch: some devices succeeded, some failed
#   EXIT_AUDIT=14       Policy applied but audit write failed
#   EXIT_CANCELLED=130  User cancelled (SIGINT/SIGTERM), no policy change

if [[ "$(declare -p RESULT_MODEL_LOADED 2>/dev/null || true)" != \
  "declare -r RESULT_MODEL_LOADED="* ]]; then
  readonly RESULT_MODEL_VERSION="1.2.0"

# ---------------------------------------------------------------------------
# Exit code constants
# ---------------------------------------------------------------------------
  readonly EXIT_OK=0
  readonly EXIT_OPERATION=1
  readonly EXIT_VALIDATION=7
  readonly EXIT_INCONSISTENT=9
  readonly EXIT_PARTIAL=13
  readonly EXIT_AUDIT=14
  readonly EXIT_CANCELLED=130

# ---------------------------------------------------------------------------
# Result state constants
# ---------------------------------------------------------------------------
  readonly RESULT_SUCCESS="SUCCESS"
  readonly RESULT_OPERATION_FAILED="OPERATION_FAILED"
  readonly RESULT_VALIDATION_FAILED="VALIDATION_FAILED"
  readonly RESULT_POLICY_FAILED="POLICY_FAILED"
  readonly RESULT_POLICY_APPLIED_AUDIT_FAILED="POLICY_APPLIED_AUDIT_FAILED"
  readonly RESULT_UNKNOWN="UNKNOWN"
  readonly RESULT_RECOVERY_REQUIRED="RECOVERY_REQUIRED"
  readonly RESULT_PARTIAL="PARTIAL"
  readonly RESULT_CANCELLED="CANCELLED"

  declare -g RESULT_STATE="$RESULT_SUCCESS"
  declare -g RESULT_EXIT_CODE="$EXIT_OK"
  declare -g RESULT_DETAIL=""
  declare -g RESULT_CORRELATION_ID=""
  declare -g RESULT_POLICY_STATUS="not_applicable"
  declare -g RESULT_AUDIT_STATUS="not_applicable"
  declare -g RESULT_POLICY_DETAIL_CODE=""
  declare -g RESULT_AUDIT_DETAIL_CODE=""
  declare -ga RESULT_ITEM_JSON=()
  declare -gr RESULT_MODEL_LOADED=1
fi

# --- תוצאה: איפוס state ---
# מאפס את כל שדות RESULT_* לברירת מחדל (success, exit 0).
result_start() {
  RESULT_CORRELATION_ID=""
  RESULT_STATE="$RESULT_SUCCESS"
  RESULT_EXIT_CODE="$EXIT_OK"
  RESULT_DETAIL=""
  RESULT_POLICY_STATUS="not_applicable"
  RESULT_AUDIT_STATUS="not_applicable"
  RESULT_POLICY_DETAIL_CODE=""
  RESULT_AUDIT_DETAIL_CODE=""
  RESULT_ITEM_JSON=()
}

# --- תוצאה: בדיקת מיפוי state/exit ---
result_mapping_supported() {
  # בודקת אם שילוב state ו-exit_code נתמך - תומכת במיפויים המוגדרים של result codes
  case "$1:$2" in
    "$RESULT_SUCCESS:$EXIT_OK"|\
      "$RESULT_OPERATION_FAILED:$EXIT_OPERATION"|\
      "$RESULT_VALIDATION_FAILED:$EXIT_VALIDATION"|\
      "$RESULT_POLICY_FAILED:$EXIT_OPERATION"|\
      "$RESULT_POLICY_APPLIED_AUDIT_FAILED:$EXIT_AUDIT"|\
      "$RESULT_UNKNOWN:$EXIT_INCONSISTENT"|\
      "$RESULT_RECOVERY_REQUIRED:$EXIT_INCONSISTENT"|\
      "$RESULT_PARTIAL:$EXIT_PARTIAL"|\
      "$RESULT_CANCELLED:$EXIT_CANCELLED") return 0 ;;
    *) return 1 ;;
  esac
}

# --- תוצאה: state מדיניות תקין ---
result_policy_status_supported() {
  # בודקת אם status של policy נתמך - values: applied|not_applied|unknown|not_applicable
  case "$1" in
    applied|not_applied|unknown|not_applicable) return 0 ;;
    *) return 1 ;;
  esac
}

# --- תוצאה: state audit תקין ---
result_audit_status_supported() {
  # בודקת אם status של audit נתמך - values: written|failed|not_applicable
  case "$1" in
    written|failed|not_applicable) return 0 ;;
    *) return 1 ;;
  esac
}

# --- תוצאה: סטטוסי item תקינים ---
result_item_statuses_supported() {
  # בודקת אם שילוב state:policy_status:audit_status נתמך - תומכת בקומבינציות מוגדרות
  local state="$1"
  local policy_status="$2"
  local audit_status="$3"

  case "$state:$policy_status:$audit_status" in
    "$RESULT_SUCCESS:not_applicable:not_applicable"|\
      "$RESULT_SUCCESS:applied:written"|\
      "$RESULT_OPERATION_FAILED:not_applied:not_applicable"|\
      "$RESULT_VALIDATION_FAILED:not_applied:not_applicable"|\
      "$RESULT_POLICY_FAILED:not_applied:not_applicable"|\
      "$RESULT_POLICY_APPLIED_AUDIT_FAILED:applied:failed"|\
      "$RESULT_UNKNOWN:unknown:not_applicable"|\
      "$RESULT_RECOVERY_REQUIRED:unknown:not_applicable"|\
      "$RESULT_CANCELLED:not_applied:not_applicable") return 0 ;;
    "$RESULT_PARTIAL":*)
      result_policy_status_supported "$policy_status" &&
        result_audit_status_supported "$audit_status"
      return
      ;;
    *) return 1 ;;
  esac
}

# --- תוצאה: קביעת state/exit/detail ---
# מאמת מיפוי, מעדכן גלובלים.
result_set() {
  # קובעת state גלובלי של תוצאה - מאמתת mapping נתמך, גנרטור correlation_id,
  # ומעדכנת את כל משתני ה-state הקשורים (RESULT_STATE, RESULT_EXIT_CODE,
  # RESULT_DETAIL, RESULT_POLICY_STATUS, RESULT_AUDIT_STATUS וכו')
  local state="$1"
  local exit_code="$2"
  local detail="${3:-}"
  local correlation_id="$RESULT_CORRELATION_ID"

  if ! result_mapping_supported "$state" "$exit_code"; then
    printf 'result: ERROR: unsupported result state or exit-code mapping\n' >&2
    return 1
  fi

  if [[ -z "$correlation_id" ]]; then
    if [[ ! -r /proc/sys/kernel/random/uuid ]] ||
      ! IFS= read -r correlation_id < /proc/sys/kernel/random/uuid; then
      printf 'result: ERROR: unable to generate correlation ID\n' >&2
      return 1
    fi
  fi

  RESULT_STATE="$state"
  RESULT_EXIT_CODE="$exit_code"
  RESULT_DETAIL="$detail"
  RESULT_CORRELATION_ID="$correlation_id"

  RESULT_POLICY_DETAIL_CODE=""
  RESULT_AUDIT_DETAIL_CODE=""
  case "$state" in
    "$RESULT_POLICY_FAILED")
      RESULT_POLICY_STATUS="not_applied"
      RESULT_AUDIT_STATUS="not_applicable"
      ;;
    "$RESULT_POLICY_APPLIED_AUDIT_FAILED")
      RESULT_POLICY_STATUS="applied"
      RESULT_AUDIT_STATUS="failed"
      ;;
    "$RESULT_UNKNOWN"|"$RESULT_RECOVERY_REQUIRED")
      RESULT_POLICY_STATUS="unknown"
      RESULT_AUDIT_STATUS="not_applicable"
      ;;
    "$RESULT_PARTIAL")
      RESULT_POLICY_STATUS="unknown"
      RESULT_AUDIT_STATUS="not_applicable"
      ;;
    "$RESULT_OPERATION_FAILED"|"$RESULT_VALIDATION_FAILED"|"$RESULT_CANCELLED")
      RESULT_POLICY_STATUS="not_applied"
      RESULT_AUDIT_STATUS="not_applicable"
      ;;
    *)
      RESULT_POLICY_STATUS="not_applicable"
      RESULT_AUDIT_STATUS="not_applicable"
      ;;
  esac
}

# --- תוצאה: getter state ---
result_get_state() {
  # מחזירה את מצב התוצאה הנוכחי (RESULT_STATE)
  printf '%s\n' "$RESULT_STATE"
}

# --- תוצאה: getter exit code ---
result_get_exit_code() {
  # מחזירה את קוד היציאה הנוכחי (RESULT_EXIT_CODE)
  printf '%s\n' "$RESULT_EXIT_CODE"
}

# --- תוצאה: getter detail ---
result_get_detail() {
  # מחזירה את פרטי התוצאה הנוכחיים (RESULT_DETAIL)
  printf '%s\n' "$RESULT_DETAIL"
}

# --- תוצאה: success ---
result_success() {
  result_set "$RESULT_SUCCESS" "$EXIT_OK" "${1:-}"
}

# --- תוצאה: policy applied ---
result_policy_applied() {
  result_set "$RESULT_SUCCESS" "$EXIT_OK" "${1:-}"
  RESULT_POLICY_STATUS="applied"
  RESULT_AUDIT_STATUS="written"
}

# --- תוצאה: operation failed ---
result_operation_failed() {
  result_set "$RESULT_OPERATION_FAILED" "$EXIT_OPERATION" "${1:-}"
}

# --- תוצאה: validation failed ---
result_validation_failed() {
  result_set "$RESULT_VALIDATION_FAILED" "$EXIT_VALIDATION" "${1:-}"
}

# --- תוצאה: policy failed ---
result_policy_failed() {
  result_set "$RESULT_POLICY_FAILED" "$EXIT_OPERATION" "${1:-}"
}

# --- תוצאה: policy applied but audit failed ---
result_policy_applied_audit_failed() {
  result_set "$RESULT_POLICY_APPLIED_AUDIT_FAILED" "$EXIT_AUDIT" "${1:-}"
}

# --- תוצאה: unknown policy outcome ---
result_unknown() {
  result_set "$RESULT_UNKNOWN" "$EXIT_INCONSISTENT" "${1:-}"
}

# --- תוצאה: recovery required ---
result_recovery_required() {
  result_set "$RESULT_RECOVERY_REQUIRED" "$EXIT_INCONSISTENT" "${1:-}"
}

# --- תוצאה: partial (batch) ---
result_partial() {
  local detail="${1:-}"
  local policy_status="${2:-unknown}"
  local audit_status="${3:-not_applicable}"
  local policy_detail_code="${4:-}"
  local audit_detail_code="${5:-}"

  if ! result_policy_status_supported "$policy_status" ||
    ! result_audit_status_supported "$audit_status"; then
    printf 'result: ERROR: unsupported policy or audit result status\n' >&2
    return 1
  fi

  result_set "$RESULT_PARTIAL" "$EXIT_PARTIAL" "$detail" || return
  RESULT_POLICY_STATUS="$policy_status"
  RESULT_AUDIT_STATUS="$audit_status"
  RESULT_POLICY_DETAIL_CODE="$policy_detail_code"
  RESULT_AUDIT_DETAIL_CODE="$audit_detail_code"
}

# --- תוצאה: add item to JSON array ---
result_add_item() {
  if (( $# < 6 || $# > 8 )); then
    printf 'result: ERROR: per-item result requires 6 to 8 arguments\n' >&2
    return 2
  fi

  local item_id="$1"
  local state="$2"
  local exit_code="$3"
  local detail="${4:-}"
  local policy_status="$5"
  local audit_status="$6"
  local policy_detail_code="${7:-}"
  local audit_detail_code="${8:-}"
  local item_json

  if [[ -z "$item_id" ]] ||
    ! result_mapping_supported "$state" "$exit_code" ||
    ! result_item_statuses_supported "$state" "$policy_status" "$audit_status"; then
    printf 'result: ERROR: invalid per-item result\n' >&2
    return 1
  fi

  printf -v item_json \
    '{"item_id":"%s","result_state":"%s","exit_code":%s,"detail":"%s","policy_result":{"status":"%s","detail_code":%s},"audit_result":{"status":"%s","detail_code":%s}}' \
    "$(result_json_escape "$item_id")" \
    "$(result_json_escape "$state")" \
    "$exit_code" \
    "$(result_json_escape "$detail")" \
    "$(result_json_escape "$policy_status")" \
    "$(result_json_optional_string "$policy_detail_code")" \
    "$(result_json_escape "$audit_status")" \
    "$(result_json_optional_string "$audit_detail_code")"
  RESULT_ITEM_JSON+=("$item_json")
}

# --- תוצאה: cancelled ---
result_cancelled() {
  result_set "$RESULT_CANCELLED" "$EXIT_CANCELLED" "${1:-}"
}

# --- תוצאה: exit with RESULT_EXIT_CODE ---
result_exit() {
  exit "$RESULT_EXIT_CODE"
}

# --- תוצאה: JSON escape ---
result_json_escape() {
  local LC_ALL=C
  local value="$1"
  local escaped=""
  local character hex
  local index

  # Iterate as bytes so UTF-8 text stays intact while JSON controls are escaped.
  for ((index = 0; index < ${#value}; index++)); do
    character="${value:index:1}"
    case "$character" in
      '"') escaped+='\"' ;;
      '\') escaped+='\\' ;;
      $'\b') escaped+='\b' ;;
      $'\f') escaped+='\f' ;;
      $'\n') escaped+='\n' ;;
      $'\r') escaped+='\r' ;;
      $'\t') escaped+='\t' ;;
      *)
        printf -v hex '%02X' "'$character"
        if (( 16#$hex < 32 || 16#$hex == 127 )); then
          escaped+="\\u00${hex}"
        else
          escaped+="$character"
        fi
        ;;
    esac
  done

  printf '%s' "$escaped"
}

# --- תוצאה: optional string JSON ---
result_json_optional_string() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf 'null'
  else
    printf '"%s"' "$(result_json_escape "$value")"
  fi
}

# --- תוצאה: הדפסת JSON ---
result_print_json() {
  local state detail correlation_id policy_status audit_status
  local policy_detail_code audit_detail_code item_json
  local item_index
  state="$(result_json_escape "$RESULT_STATE")"
  detail="$(result_json_escape "$RESULT_DETAIL")"
  correlation_id="$(result_json_escape "$RESULT_CORRELATION_ID")"
  policy_status="$(result_json_escape "$RESULT_POLICY_STATUS")"
  audit_status="$(result_json_escape "$RESULT_AUDIT_STATUS")"
  policy_detail_code="$(result_json_optional_string "$RESULT_POLICY_DETAIL_CODE")"
  audit_detail_code="$(result_json_optional_string "$RESULT_AUDIT_DETAIL_CODE")"

  printf '{\n'
  printf '  "result_state": "%s",\n' "$state"
  printf '  "exit_code": %s,\n' "$RESULT_EXIT_CODE"
  printf '  "detail": "%s",\n' "$detail"
  printf '  "correlation_id": "%s",\n' "$correlation_id"
  printf '  "policy_result": {"status":"%s","detail_code":%s},\n' \
    "$policy_status" "$policy_detail_code"
  printf '  "audit_result": {"status":"%s","detail_code":%s},\n' \
    "$audit_status" "$audit_detail_code"
  printf '  "items": ['
  for ((item_index = 0; item_index < ${#RESULT_ITEM_JSON[@]}; item_index++)); do
    item_json="${RESULT_ITEM_JSON[item_index]}"
    if (( item_index > 0 )); then
      printf ','
    fi
    printf '\n    %s' "$item_json"
  done
  if (( ${#RESULT_ITEM_JSON[@]} > 0 )); then
    printf '\n  '
  fi
  printf ']\n'
  printf '}\n'
}

# ---------------------------------------------------------------------------
# Self-test when run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "result.sh version $RESULT_MODEL_VERSION"
  echo "Exit codes:"
  echo "  EXIT_OK=$EXIT_OK"
  echo "  EXIT_OPERATION=$EXIT_OPERATION"
  echo "  EXIT_VALIDATION=$EXIT_VALIDATION"
  echo "  EXIT_INCONSISTENT=$EXIT_INCONSISTENT"
  echo "  EXIT_PARTIAL=$EXIT_PARTIAL"
  echo "  EXIT_AUDIT=$EXIT_AUDIT"
  echo "  EXIT_CANCELLED=$EXIT_CANCELLED"
fi
