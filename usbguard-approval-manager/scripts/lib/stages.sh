#!/usr/bin/env bash
# stages.sh - TTL lifecycle and commit logic (SRS v4.5 Section 12, 13)
# handles pending -> active -> expired transitions with atomic writes
#
# --- הסבר בעברית ---
# ניהול מחזור חיים של TTL ו לוגיקה של commit (SRS v4.5 סעיפים 12, 13).
# מנהלת מעברים של TTL - pending -> active -> expired עם כתיבה אטומית.
# אחריות: מעקב אחר חוקי TTL פעילים, פקיעת חוקים, וייצוא כללי קבע מאומן.
# משתמשת בנעילות split-state ו-split-policy למניעת תנאים של race.
#
# משתני מפתח: STAGES_ERROR, STAGES_ERROR_CODE, STATE_DIR, TTL_FILE, CLOCK_STATE_FILE,
# RESTORE_JOURNAL_FILE, USBAM_LAST_MANAGED_ID, USBAM_LAST_CORRELATION_ID

if [[ -z "${USBAM_STAGES_LOADED+x}" ]]; then
  readonly USBAM_STAGES_VERSION="1.0.0"
  declare -g STAGES_ERROR=""
  declare -g STAGES_ERROR_CODE=""
  declare -g STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
  # נתיב ברירת מחדל לתיקיית מצב - בו מאוחסן ttl.json
  declare -g TTL_FILE="${USBAM_TTL_FILE:-$STATE_DIR/ttl.json}"
  # נתיב ברירת מחדל לקובץ מצב השעון - משמש לאימות קפיצת שעון
  declare -g CLOCK_STATE_FILE="${USBAM_CLOCK_STATE_FILE:-$STATE_DIR/clock_state.json}"
  # נתיב ברירת מחדל ליומן שחזור - משמש להתאוששות לאחר שחזור
  declare -g RESTORE_JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$STATE_DIR/restore_journal.json}"
  # משתני מעקב אחר האחרון שטופל
  declare -g USBAM_LAST_MANAGED_ID=""
  declare -g USBAM_LAST_CORRELATION_ID=""
  declare -gr USBAM_STAGES_LOADED=1
fi

# Source dependencies if not already loaded
SCRIPT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_LIB_DIR/config-reader.sh"
source "$SCRIPT_LIB_DIR/validators.sh"
source "$SCRIPT_LIB_DIR/usbguard-policy.sh"
source "$SCRIPT_LIB_DIR/time-guards.sh"
source "$SCRIPT_LIB_DIR/result.sh"
source "$SCRIPT_LIB_DIR/lock.sh"

if [[ -n "${USBAM_LOCK_FILE:-}" ]]; then
  LOCK_FILE="$USBAM_LOCK_FILE"
fi

# --- stages: הדפסת שגיאה ---
stages_error() {
  STAGES_ERROR="$1"
  STAGES_ERROR_CODE="${2:-stages_failed}"
  printf 'stages: ERROR: %s\n' "$1" >&2
}

# --- stages: הרצת לוגיקה תחת lock ---
stages_run_locked() {
  # מריצה פעולה תחת נעילה - רוכשת lock אם נדרש, מפעילה את הפעולה המבוקשת,
  # ומשחררת את הלock בתום הפעולה. מגנה מפני מצבים של lock_not_owned.
  local operation="$1"
  local acquired_lock=0 rc
  shift

  if (( LOCK_HELD == 0 )); then
    if ! lock_acquire 5; then
      stages_error "unable to acquire the state and policy lock" "lock_failed"
      return 1
    fi
    acquired_lock=1
  elif [[ "$LOCK_OWNER_PID" != "$BASHPID" ]]; then
    stages_error "current process does not own the state and policy lock" "lock_not_owned"
    return 1
  fi

  if "$operation" "$@"; then
    rc=0
  else
    rc=$?
  fi

  if (( acquired_lock )) && ! lock_release; then
    stages_error "failed to release the state and policy lock" "lock_release_failed"
    return 9
  fi
  return "$rc"
}

# --- stages: הבטחת תיקיית state ---
stages_ensure_state_dir() {
  # וודאת תיקיית מצב - דורשת lock Held, אינה מאפשרת סימבול-לינק,
  # יוצרת תיקייה אם אינה קיימת ומגדירה הרשאות 700
  if (( LOCK_HELD == 0 )) || [[ "$LOCK_OWNER_PID" != "$BASHPID" ]]; then
    stages_error "state directory changes require the global lock" "lock_not_held"
    return 1
  fi
  if [[ -L "$STATE_DIR" ]]; then
    stages_error "state directory must not be a symbolic link" "unsafe_state_dir"
    return 1
  fi
  if [[ ! -d "$STATE_DIR" ]]; then
    if ! mkdir -p "$STATE_DIR"; then
      stages_error "unable to create state directory $STATE_DIR" "state_dir_unavailable"
      return 1
    fi
  fi
  if ! chmod 700 "$STATE_DIR"; then
    stages_error "unable to secure state directory $STATE_DIR" "state_dir_permissions"
    return 1
  fi
  return 0
}

# --- stages: אתחול TTL file אם חסר ---
_stages_init_ttl_file_if_missing() {
  # אתחול ttl.json אם אינו קיים - וודאת תיקיית מצב, יצירת JSON ראשוני אם נדרש,
  # ושימוש בכתיבה אטומית דרך atomic-write.py
  if ! stages_ensure_state_dir; then
    return 1
  fi
  if [[ ! -f "$TTL_FILE" ]]; then
    local initial_json='{"schema_version":1,"records":[]}'
    local atomic_helper="$SCRIPT_LIB_DIR/atomic-write.py"
    if [[ ! -r "$atomic_helper" ]] ||
      ! python3 "$atomic_helper" --file "$TTL_FILE" --data "$initial_json"; then
      stages_error "failed to initialize ttl.json atomically" "init_failed"
      return 1
    fi
  fi
  return 0
}

# Create a pending record JSON object (not yet written to file)
# --- stages: יצירת record ממתין ---
stages_create_pending_record() {
  # יוצרת אובייקט JSON של רשומת pending - אינה כתובה לקובץ עד לשלב מאוחר יותר
  local rule="$1"
  local expires_at="$2"
  local correlation_id="${3:-}"

  if (( $# < 2 || $# > 3 )); then
    stages_error "stages_create_pending_record requires rule and expires_at" "invalid_arguments"
    return 1
  fi

  # Validate rule via usbguard-policy helper
  # אימות חוק באמצעות helper של usbguard-policy
  if ! declare -F usbguard_validate_rule >/dev/null 2>&1; then
    stages_error "usbguard policy validator not loaded" "dependency_missing"
    return 1
  fi

  if ! usbguard_validate_rule "$rule"; then
    stages_error "invalid rule for pending record" "invalid_rule"
    return 1
  fi

  if [[ ! "$expires_at" =~ ^[0-9]+$ ]] || (( expires_at <= 0 )); then
    stages_error "expires_at must be positive integer" "invalid_expires_at"
    return 1
  fi

  local managed_id
  managed_id="$(generate_uuid_v4)"
  if ! validators_is_uuid_v4 "$managed_id"; then
    stages_error "failed to generate valid managed_id" "uuid_generation_failed"
    return 1
  fi

  if [[ -z "$correlation_id" ]]; then
    correlation_id="$(generate_uuid_v4)"
  fi
  if ! validators_is_uuid_v4 "$correlation_id"; then
    stages_error "correlation_id must be UUID v4" "invalid_correlation_id"
    return 1
  fi

  local canonical_rule
  canonical_rule="$(usbguard_canonicalize_rule "$rule")"
  local rule_hash
  rule_hash="$(validators_hash_rule "$canonical_rule")"

  USBAM_LAST_MANAGED_ID="$managed_id"
  USBAM_LAST_CORRELATION_ID="$correlation_id"

  # Build JSON record
  # Build JSON record with managed_id, rule, sha256, expires_at, status, and correlation_id
  jq -n \
    --arg managed_id "$managed_id" \
    --arg rule "$canonical_rule" \
    --arg sha256 "$rule_hash" \
    --argjson expires_at "$expires_at" \
    --arg status "pending" \
    --arg correlation_id "$correlation_id" \
    '{
      managed_id: $managed_id,
      rule: $rule,
      rule_sha256: $sha256,
      expires_at: $expires_at,
      status: $status,
      correlation_id: $correlation_id
    }'
}

# Atomically add a record to ttl.json
# --- stages: הוספת record ---
_stages_add_record() {
  # מוספת רשומה חדשה ל-ttl.json בכתיבה אטומית
  # מאמתת תוכן קיים, מוסיפה את הרשומה החדשה via jq, ומבצעת write אטומי
  local record_json="$1"
  local file_path="${2:-$TTL_FILE}"

  if (( $# < 1 || $# > 2 )); then
    stages_error "stages_add_record requires record JSON" "invalid_arguments"
    return 1
  fi

  if ! stages_ensure_state_dir; then
    return 1
  fi
  if ! stages_init_ttl_file_if_missing; then
    return 1
  fi

  if ! validate_ttl_json "$file_path"; then
    stages_error "existing ttl.json invalid, cannot add record: $VALIDATORS_ERROR" "existing_invalid"
    return 1
  fi

  # Append record
  local new_content
  if ! new_content="$(jq --argjson new_record "$record_json" '.records += [$new_record]' "$file_path")"; then
    stages_error "failed to append record to ttl.json" "jq_failed"
    return 1
  fi

  local atomic_helper="$SCRIPT_LIB_DIR/atomic-write.py"
  if [[ ! -r "$atomic_helper" ]] ||
    ! python3 "$atomic_helper" --file "$file_path" --data "$new_content"; then
    stages_error "atomic write of ttl.json failed" "atomic_write_failed"
    return 1
  fi

  if ! validate_ttl_json "$file_path"; then
    stages_error "ttl.json invalid after adding record" "post_write_invalid"
    return 1
  fi

  return 0
}

# Update record status with transition validation
# --- stages: עדכון סטטוס ---
_stages_update_status() {
  # מעדכנת את סטטוס הרשומה עם אימות מעבר סטטוס
  # מאמתת מעבר חוקי (pending->active, expired->...), וכותבת את השינוי אטומי
  local managed_id="$1"
  local new_status="$2"
  local file_path="${3:-$TTL_FILE}"

  if (( $# < 2 || $# > 3 )); then
    stages_error "stages_update_status requires managed_id and new_status" "invalid_arguments"
    return 1
  fi

  if ! validators_is_uuid_v4 "$managed_id"; then
    stages_error "managed_id must be UUID v4" "invalid_managed_id"
    return 1
  fi

  case "$new_status" in
    pending|active|inconsistent|recovery_required|expired)
      ;;
    *)
      stages_error "invalid target status $new_status" "invalid_status"
      return 1
      ;;
  esac

  if ! validate_ttl_json "$file_path"; then
    stages_error "ttl.json invalid before status update" "existing_invalid"
    return 1
  fi

  local current_status
  current_status="$(jq -r ".records[] | select(.managed_id == \"$managed_id\") | .status // empty" "$file_path")"
  if [[ -z "$current_status" ]]; then
    stages_error "managed_id $managed_id not found" "not_found"
    return 1
  fi

  if ! validate_ttl_record_transition "$current_status" "$new_status"; then
    stages_error "transition $current_status -> $new_status not allowed for $managed_id" "invalid_transition"
    return 1
  fi

  local new_content
  if ! new_content="$(jq --arg mid "$managed_id" --arg ns "$new_status" '(.records[] | select(.managed_id == $mid) | .status) = $ns' "$file_path")"; then
    stages_error "failed to update status via jq" "jq_failed"
    return 1
  fi

  local atomic_helper="$SCRIPT_LIB_DIR/atomic-write.py"
  if [[ ! -r "$atomic_helper" ]] ||
    ! python3 "$atomic_helper" --file "$file_path" --data "$new_content"; then
    stages_error "atomic write failed for status update" "atomic_write_failed"
    return 1
  fi

  if ! validate_ttl_json "$file_path"; then
    stages_error "ttl.json invalid after status update" "post_write_invalid"
    return 1
  fi

  return 0
}

# Full temporary approval transaction (stages.sh core)
# Usage: stages_approve_temporary <rule> <ttl_seconds> [correlation_id]
# Returns managed_id on success, updates ttl.json to active
# עסקת אישוי זמני מלא (ליבת stages.sh)
# שימוש: stages_approve_temporary <rule> <ttl_seconds> [correlation_id]
# מחזירה managed_id בהצלחה, מעדכנת ttl.json למצב active
# --- stages: אישור זמני ---
_stages_approve_temporary() {
  # Full temporary approval transaction (stages.sh core)
  # Usage: stages_approve_temporary <rule> <ttl_seconds> [correlation_id]
  # Returns managed_id on success, updates ttl.json to active
  # עסקת אישוי זמני מלא (ליבת stages.sh)
  # שימוש: stages_approve_temporary <rule> <ttl_seconds> [correlation_id]
  # מחזירה managed_id בהצלחה, מעדכנת ttl.json למצב active
  local rule="$1"
  local ttl_seconds="$2"
  local correlation_id="${3:-}"
  local device_id="${4:-}"
  local expires_at current_epoch

  if (( $# < 2 || $# > 4 )); then
    stages_error "stages_approve_temporary requires rule, ttl_seconds, and optional device ID" "invalid_arguments"
    return 1
  fi

  if [[ ! "$ttl_seconds" =~ ^[0-9]+$ ]] || (( ttl_seconds < 60 )); then
    stages_error "ttl_seconds must be >=60" "invalid_ttl"
    return 1
  fi

  # Check restore journal - if exists, block
  # בדיקת יומן שחזור - אם קיים, חסימת כל שינוי מדיניות
  if [[ -f "$RESTORE_JOURNAL_FILE" ]]; then
    stages_error "restore journal exists, recovery required before any policy change" "restore_journal_exists"
    return 9
  fi

  if ! is_g01_verified; then
    stages_error "G-01 verification is required before policy changes" "g01_not_verified"
    return 7
  fi

  if ! validate_ttl_json "$TTL_FILE"; then
    stages_error "ttl.json is invalid; recovery is required before policy changes" "existing_invalid"
    return 9
  fi

  local canonical_rule
  canonical_rule="$(usbguard_canonicalize_rule "$rule")"
  if ! usbguard_check_precedence "$canonical_rule"; then
    stages_error "precedence conflict for rule $canonical_rule" "precedence_conflict"
    return 7
  fi

  local line active_id active_rule
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    if usbguard_parse_rule_line "$line" active_id active_rule &&
      [[ "$active_rule" == "$canonical_rule" ]]; then
      stages_error "matching rule already exists in active policy" "duplicate_rule"
      return 7
    fi
  done

  if usbguard_rule_is_persistent "$canonical_rule"; then
    stages_error "matching permanent rule already exists; TTL would be redundant" \
      "persistent_overlap"
    return 7
  else
    local persistent_check_status=$?
    if (( persistent_check_status != 1 )); then
      stages_error "persistent policy could not be checked safely" \
        "${USBAM_POLICY_ERROR_CODE:-persistent_policy_unavailable}"
      return 9
    fi
  fi

  local has_records
  has_records="$(has_non_expired_records "$TTL_FILE")"
  if ! detect_clock_jump "$CLOCK_STATE_FILE" "$has_records"; then
    local trust_status="$CLOCK_TRUST_STATUS"
    stages_error "clock not trusted, cannot create TTL record: $trust_status ($CLOCK_TRUST_DETAIL_CODE)" "clock_untrusted"
    return 9
  fi

  # Get current epoch only after establishing a trusted clock sample.
  # קריאת אפוך נוכחי רק לאחר establishment of a trusted clock sample
  if ! current_epoch="$(date +%s)"; then
    stages_error "unable to read current epoch" "clock_unavailable"
    return 1
  fi
  expires_at=$((current_epoch + ttl_seconds))

  # Step 1: Create pending record
  # שלב 1: יצירת רשומת pending
  local pending_record
  if ! pending_record="$(stages_create_pending_record "$rule" "$expires_at" "$correlation_id")"; then
    return 1
  fi
  local managed_id
  managed_id="$(echo "$pending_record" | jq -r .managed_id 2>/dev/null)"
  if [[ -z "$managed_id" || "$managed_id" == "null" ]]; then
    managed_id="$USBAM_LAST_MANAGED_ID"
  fi
  local corr_id
  corr_id="$(echo "$pending_record" | jq -r .correlation_id 2>/dev/null)"
  if [[ -z "$corr_id" || "$corr_id" == "null" ]]; then
    corr_id="$USBAM_LAST_CORRELATION_ID"
  fi

  # Step 2: Write pending to ttl.json
  # שלב 2: כתיבת pending ל-ttl.json
  if ! stages_add_record "$pending_record" "$TTL_FILE"; then
    return 1
  fi

  # A live device and its future policy rule are separate USBGuard operations.
  # התקן חי וממשת המדיניות העתידית הם פעולות נפרדות של USBGuard.
  if [[ -n "$device_id" ]] && ! approve_device "$device_id"; then
    if ! stages_update_status "$managed_id" "recovery_required" "$TTL_FILE"; then
      stages_error "device approval failed and TTL record could not be marked for recovery: ${STAGES_ERROR_CODE:-status_update_failed}" \
        "atomic_write_failed"
      return 9
    fi
    stages_error "device approval failed after TTL record creation" "device_approval_failed"
    return 9
  fi

  # Try to add temporary rule
  if ! add_temporary_rule "$canonical_rule"; then
    # Compensation: check actual state
    # If rule was actually added but verification failed, we need to handle
    if usbguard_find_rule_id_by_canonical "$canonical_rule" >/dev/null 2>&1; then
      # Rule exists, but we are in inconsistent state - try to update to active if we can verify
      if ! stages_update_status "$managed_id" "inconsistent" "$TTL_FILE"; then
        stages_error "temporary rule outcome is uncertain and TTL record could not be marked inconsistent: ${STAGES_ERROR_CODE:-status_update_failed}" \
          "atomic_write_failed"
        return 9
      fi
      stages_error "temporary rule added but verification uncertain" "inconsistent_state"
      return 9
    else
      local rule_check_error="$USBAM_POLICY_ERROR_CODE"
      if ! stages_update_status "$managed_id" "recovery_required" "$TTL_FILE"; then
        stages_error "temporary rule failed and TTL record could not be marked for recovery: ${STAGES_ERROR_CODE:-status_update_failed}" \
          "atomic_write_failed"
        return 9
      fi
      if [[ -n "$device_id" ]] || [[ "$rule_check_error" != "rule_not_found" ]]; then
        stages_error "temporary approval outcome is uncertain: $USBAM_POLICY_ERROR_CODE" "inconsistent_state"
        return 9
      fi
      stages_error "failed to add temporary rule: $USBAM_POLICY_ERROR_CODE" "policy_failed"
      return 1
    fi
  fi

  # Step 4: Verify rule exists and device approved
  if ! usbguard_find_rule_id_by_canonical "$canonical_rule" >/dev/null; then
    stages_update_status "$managed_id" "inconsistent" "$TTL_FILE" || true
    stages_error "temporary rule not found after addition" "verification_failed"
    return 9
  fi

  # Step 5: Update to active
  if ! stages_update_status "$managed_id" "active" "$TTL_FILE"; then
    # If status update fails after policy applied, we are in a critical state
    # The rule is active but ttl.json still pending - this is inconsistent
    stages_error "policy applied but ttl.json update to active failed" "atomic_write_failed"
    return 9
  fi

  printf '%s\n' "$managed_id"
  return 0
}

# Permanent approval transaction
# --- stages: אישור קבוע ---
_stages_approve_permanent() {
  # עסקת אישוי קבוע - בודקת תנאים מקדימים, מוסיפה חוק קבוע,
  # ואם צוין התקן - מאשרת אותו. תומכת בסיווג שגיאות שונות.
  local rule="$1"
  local correlation_id="${2:-}"
  local device_id="${3:-}"

  if (( $# < 1 || $# > 3 )); then
    stages_error "stages_approve_permanent requires rule and optional device ID" "invalid_arguments"
    return 1
  fi

  if [[ -f "$RESTORE_JOURNAL_FILE" ]]; then
    stages_error "restore journal exists, recovery required" "restore_journal_exists"
    return 9
  fi

  if ! is_g01_verified; then
    stages_error "G-01 verification is required before policy changes" "g01_not_verified"
    return 7
  fi

  local canonical_rule
  canonical_rule="$(usbguard_canonicalize_rule "$rule")"

  if ! usbguard_check_precedence "$canonical_rule"; then
    stages_error "precedence conflict" "precedence_conflict"
    return 7
  fi

  if ! add_permanent_rule "$canonical_rule"; then
    local policy_error="$USBAM_POLICY_ERROR_CODE"
    case "$policy_error" in
      verification_failed|persistence_verification_failed|command_failed|command_timeout)
        stages_error "permanent rule outcome is uncertain: $policy_error" \
          "permanent_rule_outcome_unknown"
        return 9
        ;;
      precedence_conflict|duplicate_rule)
        stages_error "permanent rule rejected: $policy_error" "precedence_conflict"
        return 7
        ;;
      *)
        stages_error "failed to add permanent rule: $policy_error" "policy_failed"
        return 1
        ;;
    esac
  fi

  if [[ -n "$device_id" ]] && ! approve_device "$device_id"; then
    stages_error "permanent rule was added but device approval failed" \
      "device_approval_failed_after_rule"
    return 9
  fi

  # For permanent, we don't create TTL record, but we should audit
  printf 'Permanent rule added: %s (ID %s)\n' "$canonical_rule" "$USBAM_LAST_RULE_ID"
  return 0
}

# --- stages: ייבוא זמני ---
_stages_import_temporary() {
  local rule="$1"
  local expires_at="$2"
  local canonical_rule current_epoch has_records pending_record managed_id
  local active_id active_rule line

  if (( $# != 2 )) || [[ ! "$expires_at" =~ ^[0-9]+$ ]] || (( expires_at <= 0 )); then
    stages_error "stages_import_temporary requires a rule and positive absolute expiry" \
      "invalid_arguments"
    return 1
  fi
  if [[ -f "$RESTORE_JOURNAL_FILE" || -L "$RESTORE_JOURNAL_FILE" ]]; then
    stages_error "restore journal exists, recovery required before any policy change" \
      "restore_journal_exists"
    return 9
  fi
  if ! is_g01_verified; then
    stages_error "G-01 verification is required before policy changes" "g01_not_verified"
    return 7
  fi
  if ! validate_ttl_json "$TTL_FILE"; then
    stages_error "ttl.json is invalid; recovery is required before policy changes" "existing_invalid"
    return 9
  fi
  if ! usbguard_validate_rule "$rule"; then
    stages_error "invalid imported temporary rule" "invalid_rule"
    return 1
  fi
  canonical_rule="$(usbguard_canonicalize_rule "$rule")"
  if ! usbguard_check_precedence "$canonical_rule"; then
    stages_error "precedence conflict for imported rule" "precedence_conflict"
    return 7
  fi
  for line in "${USBAM_ACTIVE_RULES[@]}"; do
    if usbguard_parse_rule_line "$line" active_id active_rule &&
      [[ "$active_rule" == "$canonical_rule" ]]; then
      stages_error "matching rule already exists in active policy" "duplicate_rule"
      return 7
    fi
  done
  if usbguard_rule_is_persistent "$canonical_rule"; then
    stages_error "matching permanent rule already exists; TTL would be redundant" \
      "persistent_overlap"
    return 7
  else
    local persistent_check_status=$?
    if (( persistent_check_status != 1 )); then
      stages_error "persistent policy could not be checked safely" \
        "${USBAM_POLICY_ERROR_CODE:-persistent_policy_unavailable}"
      return 9
    fi
  fi
  has_records="$(has_non_expired_records "$TTL_FILE")"
  if ! detect_clock_jump "$CLOCK_STATE_FILE" "$has_records"; then
    stages_error "clock not trusted, cannot import TTL record: $CLOCK_TRUST_STATUS" \
      "clock_untrusted"
    return 9
  fi
  if ! current_epoch="$(date +%s)" || (( expires_at <= current_epoch )); then
    stages_error "imported TTL has expired or the current clock is unavailable" \
      "expired_import"
    return 1
  fi

  if ! pending_record="$(stages_create_pending_record "$canonical_rule" "$expires_at")"; then
    return 1
  fi
  managed_id="$(printf '%s' "$pending_record" | jq -r '.managed_id // empty')"
  if [[ -z "$managed_id" ]]; then
    managed_id="$USBAM_LAST_MANAGED_ID"
  fi
  if [[ ! "$managed_id" =~ ^[0-9a-fA-F-]{36}$ ]] ||
    ! stages_add_record "$pending_record" "$TTL_FILE"; then
    stages_error "unable to persist imported pending TTL record" "atomic_write_failed"
    return 9
  fi
  if ! add_temporary_rule "$canonical_rule"; then
    local policy_error="$USBAM_POLICY_ERROR_CODE"
    if usbguard_find_rule_id_by_canonical "$canonical_rule" >/dev/null 2>&1; then
      stages_update_status "$managed_id" "inconsistent" "$TTL_FILE" || true
      stages_error "imported temporary rule outcome is uncertain" "inconsistent_state"
      return 9
    fi
    if ! stages_update_status "$managed_id" "recovery_required" "$TTL_FILE"; then
      stages_error "failed rule addition and TTL recovery marker write" "atomic_write_failed"
      return 9
    fi
    stages_error "failed to add imported temporary rule: $policy_error" "policy_failed"
    return 1
  fi
  if ! usbguard_find_rule_id_by_canonical "$canonical_rule" >/dev/null; then
    stages_update_status "$managed_id" "inconsistent" "$TTL_FILE" || true
    stages_error "imported temporary rule was not found after addition" "verification_failed"
    return 9
  fi
  if ! stages_update_status "$managed_id" "active" "$TTL_FILE"; then
    stages_error "imported policy applied but TTL activation failed" "atomic_write_failed"
    return 9
  fi
  printf '%s\n' "$managed_id"
}

# --- stages: wrapper אתחול ---
stages_init_ttl_file_if_missing() {
  stages_run_locked _stages_init_ttl_file_if_missing "$@"
}

# --- stages: wrapper הוספה ---
stages_add_record() {
  stages_run_locked _stages_add_record "$@"
}

# --- stages: wrapper עדכון ---
stages_update_status() {
  stages_run_locked _stages_update_status "$@"
}

# --- stages: wrapper אישור זמני ---
stages_approve_temporary() {
  stages_run_locked _stages_approve_temporary "$@"
}

# --- stages: wrapper אישור קבוע ---
stages_approve_permanent() {
  stages_run_locked _stages_approve_permanent "$@"
}

# --- stages: wrapper ייבוא זמני ---
stages_import_temporary() {
  stages_run_locked _stages_import_temporary "$@"
}
