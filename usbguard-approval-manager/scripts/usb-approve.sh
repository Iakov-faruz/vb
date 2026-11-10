#!/usr/bin/env bash
# Interactive and CLI approval entry point (SRS v4.5, Sections 12 and 15).
#
# סקירה כללית — מה הסקריפט עושה?
# הסקריפט הוא נקודת הכניסה לאישור התקני USBGuard במערכת.
# הוא מאפשר:
# 1. אישור התקנים חסומים דרך USBGuard — אינטראקטיבית (whiptail) או דרך CLI.
# 2. שני סוגי אישור:
#    - permanent — אישור קבוע במדיניות.
#    - temporary — אישור זמני עם TTL (Time To Live) שמנוהל ע"י המערכת.
# 3. dry-run — בדיקה לקריאה בלבד, בלי לשנות מדיניות/TTL/Audit/מצב.
# 4. עיבוד אצווה (batch) של כמה התקנים בבת אחת, עם אגרגציית תוצאות.
#
# זרימת עבודה ברמה גבוהה:
# main()
#  ├─ parse_args()                 ← פרסור וולידציית ארגומנטים
#  ├─ result_start()/load_config() ← אתחול תוצאה וקונפיגורציה
#  ├─ collect_blocked_devices()    ← שליפת התקנים חסומים והמרה לכללי allow
#  ├─ בחירה: --device או אינטראקטיבית (whiptail)
#  ├─ check_selected_ids()         ← אימות מזהים שנבחרו
#  ├─ [dry-run] דיווח ויציאה
#  ├─ בדיקות: root, daemon, G-01
#  ├─ preflight_selected_devices() ← זיהוי התנגשויות/כפילויות מדיניות
#  ├─ יצירת correlation ID + confirm_approval()
#  ├─ process_selected_devices()   ← לולאה על התקנים
#  │   └─ process_device()
#  │       ├─ lock_acquire()
#  │       ├─ בדיקת restore journal
#  │       ├─ אימות מחדש תחת נעילה (מניעת TOCTOU)
#  │       ├─ stages_approve_temporary/permanent
#  │       ├─ log_audit()
#  │       └─ lock_release()
#  └─ finalize_batch_result() + result_print_json()

# הגדרות מעטפת:
# -u  = שגיאה על שימוש במשתנה לא מוגדר.
# pipefail = כשל בפקודה בתוך pipeline מחזיר כשל.
# שים לב: לא משתמשים ב- -e כדי לשמור שליטה מלאה בקודי יציאה מפורשים.
set -uo pipefail

# umask 077 מוודא שקבצים/פלטים זמניים פרטיים נוצרו עם הרשאות מינימליות.
umask 077

# איתור נתיבי הסקריפט והספריות הנלוות (lib) בצורה יציבה יחסית למיקום הקובץ.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# טעינת מודולים לפי אחריות:
# config-reader  - טעינת קונפיגורציה וערכי ברירת מחדל
# validators     - ולידציות (למשל UUID)
# usbguard-policy- שאילתות/בדיקות מול USBGuard
# stages         - מימוש שלבי האישור בפועל
# lock           - נעילה גלובלית למניעת מרוצים
# logger         - כתיבת Audit
# result         - בניית תוצאת JSON וקודי יציאה
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

# נתיבי מערכת וקבצי מצב — ניתן לעקוף דרך משתני סביבה USBAM_* (לבדיקות/פריסה).
CONFIG_PATH="${USBAM_CONFIG_PATH:-/etc/usbguard-approval-manager/approval-manager.conf}"
STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"                          # רישום אישורים זמניים
CLOCK_STATE_FILE="${USBAM_CLOCK_STATE_FILE:-$STATE_DIR/clock_state.json}" # מעקב סטיית/שינוי שעון
RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}" # יומן שחזור
LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"  # נעילה גלובלית

# מצב ריצה גלובלי שנבנה במהלך הפרסור והעיבוד.
APPROVAL_TYPE=""          # סוג אישור: permanent | temporary
TTL_SECONDS=""            # TTL בשניות (רלוונטי ל-temporary)
DRY_RUN=0                 # דגל dry-run: 1 = ללא שינויי מערכת

declare -a REQUESTED_DEVICES=()      # מזהים שהתקבלו מ---device ב-CLI
declare -a SELECTED_DEVICES=()       # מזהים שנבחרו בפועל לעיבוד
declare -A SELECTED_RULES=()         # מיפוי device_id -> כלל allow מוכן
declare -A SEEN_DEVICES=()           # הגנה מזיהוי כפילויות בבחירה
declare -A SELECTED_BLOCK_REASONS=() # מיפוי device_id -> סיבת דילוג/preflight block

# usage — הדפסת עזרה קצרה על אופן השימוש בסקריפט.
# ללא --device: בחירה אינטראקטיבית (whiptail) מתוך התקנים חסומים.
# עם --device: מצב CLI מפורש. --dry-run מריץ בדיקות ללא שינוי מערכת.
usage() {
  cat <<EOF
Usage: $0 --device <ID> [--device <ID> ...] --type <permanent|temporary>
          [--ttl <seconds>] [--dry-run] [--help]
   $0 [--type <permanent|temporary> [--ttl <seconds>]] [--dry-run]

Without --device, select blocked devices interactively with whiptail.
Temporary approvals use TEMP_TTL_SECONDS when --ttl is omitted.
Dry-run performs read-only queries and does not change policy, TTL, Audit, or state.
EOF
}

# validation_error — כשל בקלט/בפרמטרים (בעיה בבקשת המשתמש).
# מאתחל תוצאה, מסמן validation_failed, מדפיס JSON ויוצא בקוד המתאים.
validation_error() {
  result_start
  result_validation_failed "$1"
  result_print_json
  exit "$EXIT_VALIDATION"
}

# operation_error — כשל תפעולי במהלך הריצה (למשל תלות מערכת לא זמינה).
# שונה מ-validation כי הקלט יכול להיות תקין אך המערכת לא הצליחה לבצע.
operation_error() {
  result_start
  result_operation_failed "$1"
  result_print_json
  exit "$EXIT_OPERATION"
}

# parse_args — פרסור ארגומנטים ובדיקות עקביות.
# תומך ב: --device <ID> (חוזר), --type permanent|temporary, --ttl <seconds>, --dry-run, --help.
# מבצע ולידציה מיידית של פורמט ושל כללי שימוש (למשל TTL רק ל-temporary, טווח 60..2592000).
parse_args() {
  while (( $# )); do
    case "$1" in
      --device)
        # כל --device חייב לקבל מזהה מספרי (USBGuard device ID).
        if (( $# < 2 )) || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          validation_error "--device requires a numeric USBGuard device ID"
        fi
        REQUESTED_DEVICES+=("$2")
        shift 2
        ;;
      --type)
        # סוג האישור מוגדר פעם אחת בלבד: permanent או temporary.
        if (( $# < 2 )) || [[ "$2" != "permanent" && "$2" != "temporary" ]]; then
          validation_error "--type must be permanent or temporary"
        fi
        [[ -z "$APPROVAL_TYPE" ]] ||
          validation_error "--type may be specified only once"
        APPROVAL_TYPE="$2"
        shift 2
        ;;
      --ttl)
        # TTL בשניות; מוגדר פעם אחת בלבד ונבדק לטווח חוקי בהמשך.
        if (( $# < 2 )) || [[ ! "$2" =~ ^[0-9]+$ ]]; then
          validation_error "--ttl requires an integer number of seconds"
        fi
        [[ -z "$TTL_SECONDS" ]] || validation_error "--ttl may be specified only once"
        TTL_SECONDS="$2"
        shift 2
        ;;
      --dry-run)
        # dry-run: הרצה לקריאה בלבד, ללא שינוי מדיניות/מצב/Audit.
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

  # --- בדיקות עקביות לאחר הפרסור ---
  # TTL מותר רק כאשר סוג האישור הוא temporary.
  if [[ -n "$TTL_SECONDS" && "$APPROVAL_TYPE" == "permanent" ]]; then
    validation_error "--ttl is valid only for temporary approvals"
  fi
  # הגבלת טווח TTL: בין דקה (60) ל-30 יום (2,592,000 שניות).
  if [[ -n "$TTL_SECONDS" ]] &&
    (( TTL_SECONDS < 60 || TTL_SECONDS > 2592000 )); then
    validation_error "--ttl must be between 60 and 2592000 seconds"
  fi
  # במצב CLI מפורש (--device) חובה לציין גם --type.
  if (( ${#REQUESTED_DEVICES[@]} > 0 )) && [[ -z "$APPROVAL_TYPE" ]]; then
    validation_error "--type is required when --device is specified"
  fi
  # בחירה אינטראקטיבית (ללא --device) מחייבת TTY/טרמינל.
  if (( ${#REQUESTED_DEVICES[@]} == 0 )) && [[ ! -t 0 ]]; then
    validation_error "interactive device selection requires a terminal"
  fi
}

# load_approval_config — טעינת קונפיגורציה והשלמת ברירות מחדל.
# אם קובץ הקונפיג קיים: חייב להיות קובץ רגיל (לא symlink) ונטען בהצלחה.
# אם לא קיים: נופלים לערכי ברירת מחדל המוגדרים ב-CONFIG_KEY_SPECS.
load_approval_config() {
  if [[ -e "$CONFIG_PATH" || -L "$CONFIG_PATH" ]]; then
    # מדיניות אבטחה: דחיית symlink/לא-קובץ כדי למנוע עקיפת קונפיגורציה.
    if [[ -L "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]] ||
      ! load_config "$CONFIG_PATH"; then
      validation_error "configuration is unavailable or invalid"
    fi
  else
    # מילוי CONFIG_VALUES מערכי ברירת המחדל כשהקובץ חסר.
    CONFIG_VALUES=()
    local key value_type default_value
    for key in "${!CONFIG_KEY_SPECS[@]}"; do
      IFS='|' read -r value_type default_value _ <<< "${CONFIG_KEY_SPECS[$key]}"
      CONFIG_VALUES["$key"]="$default_value"
    done
  fi

  # אם לא סופק TTL ב-CLI, משתמשים ב-TEMP_TTL_SECONDS מהקונפיג.
  if [[ -z "$TTL_SECONDS" ]]; then
    TTL_SECONDS="${CONFIG_VALUES[TEMP_TTL_SECONDS]}"
  fi

  # ייצוא/ריענון נתיבים סופיים למשתני הסביבה בהם משתמשים מודולי lib.
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

# collect_blocked_devices — שליפת כל ההתקנים החסומים מ-USBGuard.
# לכל רשומה: מפענחים "ID: rule", מוודים שהיא חסומה, ממירים ל-"allow ...",
# מאמתים את הכלל ומאחסנים אותו ב-SELECTED_RULES לפי device_id.
collect_blocked_devices() {
  if ! list_blocked_devices; then
    operation_error "unable to retrieve blocked USBGuard devices"
  fi

  SELECTED_RULES=()
  local record device_id device_rule
  for record in "${USBAM_BLOCKED_DEVICES[@]}"; do
    # פרסור שורת כלל שמחזיר USBGuard (צפוי: "<id>: <rule>").
    if ! usbguard_parse_rule_line "$record" device_id device_rule; then
      operation_error "USBGuard returned an invalid blocked-device record"
    fi
    # אנו מצפים רק לרשומות חסומות; אחרת זה מצב חריג.
    if [[ ! "$device_rule" =~ ^block[[:space:]]+(.+)$ ]]; then
      operation_error "USBGuard returned a non-blocked device in the blocked list"
    fi
    # בניית כלל האישור בפועל מתוך כלל ה-block הקיים.
    device_rule="allow ${BASH_REMATCH[1]}"
    # ולידציה בטיחותית של הכלל שנוצר לפני כל שימוש בו.
    if ! usbguard_validate_rule "$device_rule"; then
      operation_error "blocked device cannot be converted to a safe allow rule"
    fi
    # זיהוי כפילות מזהים בתשובת USBGuard (לא אמור להתרחש).
    if [[ -n "${SELECTED_RULES[$device_id]+present}" ]]; then
      operation_error "USBGuard returned duplicate device IDs"
    fi
    SELECTED_RULES["$device_id"]="$device_rule"
  done
}

# select_devices_interactively — בחירה אינטראקטיבית עם whiptail.
# מציג checklist של התקנים חסומים, מאפשר בחירת סוג אישור ול-TTL אם temporary.
# החזרה 130 מסמלת ביטול/יציאה של המשתמש (בדומה ל-Ctrl+C).
select_devices_interactively() {
  if (( ${#SELECTED_RULES[@]} == 0 )); then
    operation_error "there are no blocked USBGuard devices to approve"
  fi
  if ! command -v whiptail >/dev/null 2>&1; then
    operation_error "whiptail is required for interactive device selection"
  fi

  # בניית פריטי checklist בפורמט: <tag> <item> <status>.
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
  # whiptail מחזיר מזהים עטופים במרכאות — מסירים אותן ומפצלים למערך.
  selected="${selected//\"/}"
  read -r -a SELECTED_DEVICES <<< "$selected"
  if (( ${#SELECTED_DEVICES[@]} == 0 )); then
    return 130
  fi

  # בחירת סוג האישור באינטראקציה.
  local choice
  if ! choice="$(whiptail --title "Approval type" --menu \
    "Choose approval duration" 12 60 2 \
    temporary "Temporary approval (TTL)" \
    permanent "Permanent approval" 3>&1 1>&2 2>&3)"; then
    return 130
  fi
  APPROVAL_TYPE="$choice"
  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    # עבור temporary מבקשים TTL, עם ברירת מחדל מהקונפיגורציה.
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
    # הגנה נוספת: TTL לא רלוונטי לאישור קבוע.
    validation_error "--ttl is valid only for temporary approvals"
  fi
  return 0
}

# check_selected_ids — ולידציה סופית של מזהי ההתקנים שנבחרו.
# מוודא שהמזהים מספריים, ייחודיים, ושעדיין קיימים ברשימת החסומים.
check_selected_ids() {
  local device_id
  for device_id in "${SELECTED_DEVICES[@]}"; do
    if [[ ! "$device_id" =~ ^[0-9]+$ ]]; then
      validation_error "selected device ID is invalid"
    fi
    if [[ -n "${SEEN_DEVICES[$device_id]+present}" ]]; then
      validation_error "duplicate --device IDs are not allowed"
    fi
    SEEN_DEVICES["$device_id"]=1
    # אם אין כלל allow מוכן עבור המזהה — הוא לא חסום כרגע או נעלם.
    if [[ -z "${SELECTED_RULES[$device_id]+present}" ]]; then
      validation_error "device $device_id is not currently blocked or no longer exists"
    fi
  done
}

# preflight_selected_devices — בדיקות בטיחות לפני שינוי מדיניות.
# מזהה מצבים שבהם אישור יידחה/ידולג:
# - duplicate_rule: כלל זהה כבר פעיל.
# - precedence_conflict: כלל block/reject קודם גובר.
# - persistent_overlap/duplicate: חפיפה/כפילות מול מדיניות קבועה.
# הסיבות נשמרות ב-SELECTED_BLOCK_REASONS ומטופלות בזמן העיבוד.
preflight_selected_devices() {
  local device_id rule line rule_id active_rule persistent_status
  SELECTED_BLOCK_REASONS=()

  if ! list_active_rules; then
    operation_error "unable to inspect active USBGuard rules before approval"
  fi

  for device_id in "${SELECTED_DEVICES[@]}"; do
    rule="${SELECTED_RULES[$device_id]}"
    local block_reason=""

    # (א) בדיקת כפילות מול הכללים הפעילים כרגע.
    for line in "${USBAM_ACTIVE_RULES[@]}"; do
      if usbguard_parse_rule_line "$line" rule_id active_rule &&
        [[ "$active_rule" == "$rule" ]]; then
        block_reason="duplicate_rule"
        break
      fi
    done

    # (ב) בדיקת קדימות: האם כלל חוסם קודם יבטל את ההשפעה של allow?
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

    # (ג) בדיקת חפיפה מול מדיניות קבועה (persistent).
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
        # קוד 1 = לא נמצא (תקין). כל קוד אחר מצביע על כשל בבדיקה עצמה.
        if (( persistent_status != 1 )); then
          operation_error "unable to inspect persistent policy for device $device_id"
        fi
      fi
    fi

    SELECTED_BLOCK_REASONS["$device_id"]="$block_reason"
  done
}

# approval_block_message — מיפוי קוד סיבת חסימה להודעה קריאה לאדם.
approval_block_message() {
  case "$1" in
    duplicate_rule) printf 'matching rule already exists in active policy' ;;
    precedence_conflict) printf 'an earlier block/reject rule takes precedence' ;;
    persistent_overlap) printf 'matching permanent rule exists; temporary TTL would be redundant' ;;
    persistent_duplicate) printf 'matching rule already exists in persistent policy' ;;
    *) printf 'approval was rejected by policy preflight' ;;
  esac
}

# approval_summary — סיכום תוכנית האישור לפני ביצוע.
# משמש להצגה אינטראקטיבית (whiptail/טרמינל) ומדגיש מכשירים שידולגו.
approval_summary() {
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

# result_add_failure — רישום כשל פר-התקן בתוצאת ה-batch.
# ממפה קודי כשל לקטגוריות: uncertain/inconsistent, validation, recovery או operation,
# ומעדכן דגלי אגרגציה (BATCH_UNCERTAIN / BATCH_FAILED / BATCH_FAILURE_RC).
result_add_failure() {
  local device_id="$1"
  local exit_code="$2"
  local detail="$3"
  local detail_code="$4"

  # כשלים שמצביעים על מצב מערכת לא ודאי/לא עקבי — דורשים זהירות/שחזור.
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
    # בקשה/מצב קלט לא תקין עבור התקן זה.
    result_add_item "$device_id" "$RESULT_VALIDATION_FAILED" "$EXIT_VALIDATION" \
      "$detail" not_applied not_applicable "$detail_code"
    BATCH_FAILED=1
    if (( BATCH_FAILURE_RC == 0 )); then
      BATCH_FAILURE_RC="$EXIT_VALIDATION"
    fi
  elif (( exit_code == EXIT_INCONSISTENT )); then
    # המערכת מסמנת במפורש צורך בשחזור.
    result_add_item "$device_id" "$RESULT_RECOVERY_REQUIRED" "$EXIT_INCONSISTENT" \
      "$detail" unknown not_applicable "$detail_code"
    BATCH_UNCERTAIN=1
  else
    # כשל תפעולי רגיל (ללא אינדיקציה לאי-עקביות).
    result_add_item "$device_id" "$RESULT_OPERATION_FAILED" "$EXIT_OPERATION" \
      "$detail" not_applied not_applicable "$detail_code"
    BATCH_FAILED=1
    if (( BATCH_FAILURE_RC == 0 )); then
      BATCH_FAILURE_RC="$EXIT_OPERATION"
    fi
  fi
}

# release_device_lock — שחרור הנעילה הגלובלית בצורה בטוחה.
# מגדיר trap כגיבוי ומסמן BATCH_UNCERTAIN אם השחרור נכשל (כי מצב הנעילה לא ודאי).
release_device_lock() {
  trap 'lock_release' EXIT
  if lock_release; then
    return 0
  fi
  printf 'usb-approve: ERROR: unable to release the global lock\n' >&2
  BATCH_UNCERTAIN=1
  return 1
}

# process_device — עיבוד אישור עבור התקן בודד (הליבה של הריצה).
# שלבים:
# 1. רכישת נעילה גלובלית.
# 2. חסימה אם קיים restore journal (דורש שחזור קודם).
# 3. שליפה ואימות מחדש של ההתקן תחת נעילה (הגנה מ-TOCTOU).
# 4. ביצוע האישור לפי סוג (temporary/permanent) דרך stages_*.
# 5. כתיבת Audit ורישום תוצאה לפי הצלחה/כשל.
process_device() {
  trap 'lock_release' EXIT
  local device_id="$1"
  local original_rule="${SELECTED_RULES[$device_id]}"
  local current_rule=""
  local record current_id current_text
  local rc managed_id="" output_file=""

  # --- שלב 1: נעילה גלובלית למניעת מרוץ עם תהליכים אחרים ---
  if ! lock_acquire 5; then
    result_add_failure "$device_id" "$EXIT_OPERATION" "unable to acquire global lock" "lock_failed"
    return
  fi

  # --- שלב 2: אם יש יומן שחזור פתוח — אסור לבצע שינויים נוספים ---
  if [[ -e "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
    result_add_failure "$device_id" "$EXIT_INCONSISTENT" \
      "restore journal requires recovery" "restore_recovery_required"
    release_device_lock || return 1
    return
  fi

  # --- שלב 3: אימות מחדש תחת הנעילה ---
  # מונע TOCTOU: ההתקן יכול להיעלם/להשתנות בין הסריקה הראשונית לביצוע.
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
  # אם לא נמצא כלל תואם זהה למקורי — לא משנים מדיניות עבור התקן זה.
  if [[ -z "$current_rule" || "$current_rule" != "$original_rule" ]]; then
    result_add_failure "$device_id" "$EXIT_VALIDATION" \
      "device disappeared or changed after selection; no policy was changed" "device_changed"
    release_device_lock || return 1
    return
  fi

  # --- שלב 4: ביצוע האישור בפועל ---
  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    # temporary: stages_approve_temporary עשוי להחזיר managed_id דרך stdout;
    # משתמשים בקובץ זמני פרטי כדי ללכוד אותו בלי לערבב עם לוגים.
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
      # כשל בניקוי קובץ זמני מסומן כאי-עקביות כי זה סימן לבעיה במצב מערכת.
      if ! rm -f -- "$output_file"; then
        result_add_failure "$device_id" "$EXIT_INCONSISTENT" \
          "temporary approval completed but private output cleanup failed" \
          "temporary_storage_cleanup_failed"
        release_device_lock || return 1
        return
      fi
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
    # permanent: אישור קבוע ללא מעקב TTL/mananged_id.
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

  # --- שלב 5: Audit ורישום תוצאה ---
  local action="approve_${APPROVAL_TYPE}"
  local audit_details="device_id=$device_id"
  [[ -z "$managed_id" ]] || audit_details+=" managed_id=$managed_id"
  if [[ "$APPROVAL_TYPE" == "temporary" ]]; then
    audit_details+=" ttl_seconds=$TTL_SECONDS"
  fi

  if log_audit "$action" applied "$RESULT_CORRELATION_ID" "$audit_details"; then
    # הצלחה מלאה: המדיניות הוחלה ונרשם Audit.
    result_add_item "$device_id" "$RESULT_SUCCESS" "$EXIT_OK" \
      "approval verified${managed_id:+; managed_id=$managed_id}" applied written
    BATCH_SUCCEEDED=$((BATCH_SUCCEEDED + 1))
  else
    # המדיניות הוחלה אך כתיבת Audit נכשלה — מצב רגיש שמסומן בנפרד.
    result_add_item "$device_id" "$RESULT_POLICY_APPLIED_AUDIT_FAILED" "$EXIT_AUDIT" \
      "policy applied; Audit write failed" applied failed "" "audit_write_failed"
    BATCH_AUDIT_FAILED=1
  fi
  release_device_lock || return 1
}

# confirm_approval — בקשת אישור משתמש לפני שינוי מדיניות.
# dry-run מדלג על אישור; ריצות משנות מחייבות טרמינל אינטראקטיבי.
# משתמש ב-whiptail אם זמין, אחרת דורש הקלדת "APPROVE".
confirm_approval() {
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

# process_selected_devices — לולאת עיבוד על כל ההתקנים שנבחרו.
# דילוג על התקנים שנחסמו ב-preflight.
# Fail-fast: אם התקן נכנס למצב לא ודאי (BATCH_UNCERTAIN), עוצרים את יתר הבאטץ'
# ומסמנים את הנותרים כ-not processed/batch_stopped_for_recovery.
process_selected_devices() {
  local index device_id
  for ((index = 0; index < ${#SELECTED_DEVICES[@]}; index++)); do
    device_id="${SELECTED_DEVICES[$index]}"
    # אם יש סיבת חסימה מ-preflight — לא מנסים לבצע שינוי עבור התקן זה.
    if [[ -n "${SELECTED_BLOCK_REASONS[$device_id]:-}" ]]; then
      result_add_failure "$device_id" "$EXIT_VALIDATION" \
        "$(approval_block_message "${SELECTED_BLOCK_REASONS[$device_id]}")" \
        "${SELECTED_BLOCK_REASONS[$device_id]}"
      continue
    fi
    process_device "$device_id"
    # עצירת באטץ' מוקדמת כדי לא להחמיר מצב מערכת לא עקבי.
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

# finalize_batch_result — קובע את תוצאת הבאטץ' הסופית לפי סדר עדיפויות:
# 1) מצב לא ודאי/דורש שחזור (החמור ביותר)
# 2) מדיניות הוחלה אך Audit נכשל
# 3) כשל מלא/חלקי
# 4) הצלחה מלאה
finalize_batch_result() {
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

# main — פונקציית התזמור הראשית של הסקריפט.
# מבצעת: פרסור, אתחול, שליפת התקנים, בחירה, בדיקות מקדימות, אישור משתמש,
# עיבוד בפועל, סיכום תוצאה והדפסת JSON עם קוד יציאה מתאים.
main() {
  local selected_rc device_id
  # דגלי אגרגציה ברמת באטץ' (נצרכים ע"י process_device/finalize_batch_result).
  local BATCH_FAILED=0 BATCH_UNCERTAIN=0 BATCH_AUDIT_FAILED=0
  local BATCH_SUCCEEDED=0 BATCH_FAILURE_RC=0

  # שלב הכנה: פרמטרים, מבנה תוצאה וקונפיגורציה.
  parse_args "$@"
  result_start
  load_approval_config

  # ולידציה נוספת ל-TTL שהגיע מקונפיגורציה (ולא רק מה-CLI).
  if [[ "$APPROVAL_TYPE" == "temporary" && -n "$TTL_SECONDS" ]] &&
    (( TTL_SECONDS < 60 || TTL_SECONDS > 2592000 )); then
    validation_error "--ttl must be between 60 and 2592000 seconds"
  fi

  # שלב איסוף ובחירת התקנים (CLI מפורש או אינטראקטיבי).
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

  # dry-run: מדווח מה היה מתבצע אך לא משנה מדיניות/TTL/Audit/מצב.
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

  # בדיקות חובה לפני שינוי מערכת בפועל.
  if [[ "$APPROVAL_TYPE" == "temporary" ]] && [[ -z "$TTL_SECONDS" ]]; then
    validation_error "temporary approval requires a TTL"
  fi
  if (( EUID != 0 )); then
    operation_error "policy-changing approvals require root privileges"
  fi
  if ! check_daemon_status; then
    operation_error "USBGuard daemon or IPC is unavailable"
  fi
  # שער G-01: ללא ראיות מאומתות, שינוי מדיניות נחסם כדי לשמור על בטיחות.
  if ! is_g01_verified; then
    result_start
    result_recovery_required "G-01 evidence is not verified; policy changes are disabled"
    result_print_json
    exit "$EXIT_INCONSISTENT"
  fi

  # Preflight, יצירת מזהה קורלציה, אישור משתמש וביצוע בפועל.
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

# הרצת main רק כאשר הסקריפט מופעל ישירות (ולא כאשר הוא נטען כ-source).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi