#!/usr/bin/env bash
# Separate operational logging from the protected Audit JSONL stream.
#
# --- הסבר בעברית ---
# ספריית לוגים: הפרדה בין לוג תפעולי (syslog) לזרם Audit מוגן (JSONL).
# לוג תפעולי: הודעות info/error דרך פקודת logger (syslog).
# לוג Audit: writing protected through audit_write.py (root:usbadmins, mode 0640).
# כל פונקציה מחזירה nonzero בכשל כתיבה; caller חייב keep policy result.
#
# פונקציות:
#   log_operational <priority> <message> - כתיבה ל-syslog עם tag usbguard-approval-manager
#   log_info <msg...>                   - קיצור ל-user.info
#   log_error <msg...>                  - קיצור ל-user.err
#   log_audit <action> <policy_result> <correlation_id> [details] - Audit JSONL
#
# אזהרה: Audit write failure must be reported; policy outcome preserved.
"
# Separate operational logging from the protected Audit JSONL stream.

if [[ "$(declare -p USBAM_LOGGER_LIBRARY_LOADED 2>/dev/null || true)" != "declare -r USBAM_LOGGER_LIBRARY_LOADED="* ]]; then
  readonly USBAM_LOGGER_VERSION="1.0.0"
  readonly USBAM_LOGGER_SYSLOG_TAG="usbguard-approval-manager"
  readonly USBAM_LOGGER_AUDIT_WRITER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/audit_write.py"
  declare -gr USBAM_LOGGER_LIBRARY_LOADED=1
fi

# --- לוג: כתיבה תפעולית ל-syslog ---
# בודק control chars, זמינות logger, כותב עם tag/priority.
log_operational() {
  # כתיבת לוג תפעולי ל-syslog
  # בודקת ש-message אינה מכילה תווים שליטה, וודאית ש-utils של logger זמינים
  local LC_ALL=C
  local priority="$1"
  local message="$2"

  if [[ "$message" =~ [[:cntrl:]] ]]; then
    printf 'logger: ERROR: operational message contains control characters\n' >&2
    return 1
  fi
  if ! command -v logger >/dev/null 2>&1; then
    printf 'logger: ERROR: system logger utility is unavailable\n' >&2
    return 1
  fi
  if ! logger --tag "$USBAM_LOGGER_SYSLOG_TAG" --priority "$priority" -- "$message"; then
    printf 'logger: ERROR: failed to write operational log\n' >&2
    return 1
  fi
}

# --- לוג: info ---
log_info() {
  log_operational user.info "$*"
}

# --- לוג: error ---
log_error() {
  log_operational user.err "$*"
}

# --- לוג: Audit JSONL via python helper ---
# 4 args: action, policy_result, correlation_id, optional details.
log_audit() {
  # כתיבת Einnot Audit JSONL דרך helper של python
  # מקבלת 3-4 ארגומנטים: action, policy_result, correlation_id, ופרטים אופציונליים
  # מדפיסה שגיאה אם מספר ארגומנטים שגוי, אם audit_writer חסר/לא קריא,
  # או אם הכתיבה כשלה - caller must preserve policy outcome
  if (( $# < 3 || $# > 4 )); then
    printf 'logger: ERROR: log_audit requires action, policy result, correlation ID, and optional details\n' >&2
    return 2
  fi
  if [[ ! -r "$USBAM_LOGGER_AUDIT_WRITER" ]]; then
    printf 'logger: ERROR: Audit writer is missing or unreadable\n' >&2
    return 1
  fi
  if ! python3 "$USBAM_LOGGER_AUDIT_WRITER" \
    --action "$1" \
    --policy-result "$2" \
    --correlation-id "$3" \
    --details "${4:-}"; then
    printf 'logger: ERROR: Audit write failed; policy outcome must be preserved\n' >&2
    return 1
  fi
}
