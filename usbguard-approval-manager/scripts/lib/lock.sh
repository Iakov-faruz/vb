#!/usr/bin/env bash
# Shared process lock for state and policy mutations.
#
# --- הסבר בעברית ---
# ספריית נעילה משותפת (process lock) לכל פעולות שינוי מצב/מדיניות.
# מטרת הספרייה: להבטיח שרק תהליך אחד מבצע מוטציה במקביל (exclusivity),
# ולמנוע race conditions על קבצי state/policy. הנעילה משתמשת ב-flock(2)
# על קובץ נעילה ייעודי (/run/lock/...), ומוודאית בעלות/הרשאות קובץ.
# כל פונקציה מחזירה 0 בהצלחה, nonzero בכשל; הודעות שגיאה ל-stderr.
#
# פונקציות עיקריות:
#   lock_acquire <timeout>   - רכישת נעילה אקסקלוסיבית עם timeout
#   lock_release             - שחרור הנעילה (נקרא גם ב-EXIT trap)
#   lock_validate_file      - בדיקת קובץ הנעילה (regular, לא symlink, בעלות/mode)
#   lock_install_exit_trap  - התקנת trap לשחרור אוטומטי ביציאה
# Shared process lock for state and policy mutations.

if [[ "$(declare -p USBAM_LOCK_LIBRARY_LOADED 2>/dev/null || true)" != "declare -r USBAM_LOCK_LIBRARY_LOADED="* ]]; then
  readonly USBAM_LOCK_DEFAULT_PATH="/run/lock/usbguard-approval-manager.lock"
  declare -g LOCK_FILE="$USBAM_LOCK_DEFAULT_PATH"
  declare -g LOCK_FD=""
  declare -g LOCK_HELD=0
  declare -g LOCK_OWNER_PID=""
  declare -gr USBAM_LOCK_LIBRARY_LOADED=1
fi

lock_error() {
  printf 'lock: ERROR: %s\n' "$1" >&2
}

# --- נעילה: בדיקת קובץ הנעילה ---
# מוודא שהקובץ קיים, רגיל (לא symlink), עם בעלות/mode בטוחים.
lock_validate_file() {
  local expected actual

  if [[ -L "$LOCK_FILE" || ! -f "$LOCK_FILE" ]]; then
    lock_error "lock file is missing, not regular, or a symbolic link: $LOCK_FILE"
    return 1
  fi

  if [[ "$LOCK_FILE" == "$USBAM_LOCK_DEFAULT_PATH" ]]; then
    expected="0:0:600"
  else
    expected="$(id -u):$(id -g):600" || {
      lock_error "unable to determine current lock-file owner"
      return 1
    }
  fi

  actual="$(stat -c '%u:%g:%a' -- "$LOCK_FILE")" || {
    lock_error "unable to inspect lock file: $LOCK_FILE"
    return 1
  }
  if [[ "$actual" != "$expected" ]]; then
    lock_error "unsafe lock-file ownership or mode: expected $expected, got $actual"
    return 1
  fi
}

# --- נעילה: התקנת EXIT trap ---
# מבטיחה שחרור נעילה אוטומטי ביציאה; דוחה אם trap קיים.
lock_install_exit_trap() {
  local current_trap
  current_trap="$(trap -p EXIT)"
  case "$current_trap" in
    "trap -- 'lock_release' EXIT"|"trap -- 'lock_release;"*" EXIT") return 0 ;;
  esac
  # Accept traps that call lock_release (e.g. test cleanup traps)
  if [[ "$current_trap" == *"lock_release"* ]]; then
    return 0
  fi
  if [[ -z "$current_trap" ]]; then
    trap 'lock_release' EXIT
    return 0
  fi
  lock_error "an EXIT trap already exists; run lock_release first in it before acquiring the lock"
  return 1
}

# --- נעילה: רכישת נעילה ---
# timeout חובה (שניות). בודק שלא כבר מוחזק, מאמת קובץ, פותח fd, flock.
lock_acquire() {
  # רכישת נעילה אקסקלוסיבית עם timeout
  # מאמתת ש-Lock אינו מוחזק כבר, מאמתת את קובץ הנעילה,
  # פותח את הקובץ ומפעילה flock עם timeout שנקבע.
  local timeout="${1:-}"

  if (( $# != 1 )) ||
    [[ ! "$timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    lock_error "timeout must be a non-negative number of seconds"
    return 1
  fi
  if (( LOCK_HELD != 0 )); then
    lock_error "this process already holds the global lock"
    return 1
  fi
  if ! lock_validate_file; then
    return 1
  fi

  if ! exec {LOCK_FD}>>"$LOCK_FILE"; then
    LOCK_FD=""
    lock_error "unable to open lock file: $LOCK_FILE"
    return 1
  fi

  if ! flock --exclusive --wait "$timeout" "$LOCK_FD"; then
    exec {LOCK_FD}>&-
    LOCK_FD=""
    lock_error "timed out or failed while acquiring the global lock"
    return 1
  fi

  LOCK_HELD=1
  LOCK_OWNER_PID="$BASHPID"
  if ! lock_install_exit_trap; then
    lock_release
    return 1
  fi
}

# --- נעילה: שחרור ---
# רק התהליך שרכש יכול לשחרר. סוגר fd ומאפס state.
lock_release() {
  # שחרור הנעילה - מאמתת ש-Lock Held, ש-Owner PID תואם,
  # ומאתירה את תיאור lock descriptor. מחזירה 0 בהצלחה.
  if (( LOCK_HELD == 0 )); then
    return 0
  fi
  if [[ "$LOCK_OWNER_PID" != "$BASHPID" ]]; then
    lock_error "only the process that acquired the lock may release it"
    return 1
  fi

  LOCK_HELD=0
  LOCK_OWNER_PID=""
  if ! exec {LOCK_FD}>&-; then
    LOCK_FD=""
    lock_error "failed to close the lock descriptor"
    return 1
  fi
  LOCK_FD=""
}
