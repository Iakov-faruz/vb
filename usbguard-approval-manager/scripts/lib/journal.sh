#!/usr/bin/env bash
# scripts/lib/journal.sh
# Phase 5 - restore_journal.json management with atomic-write and split-locking
# SRS v4.5: Backup/Restore with journal, G-01 gate, Split-Locking
#
# This library is the only owner of restore_journal.json lifecycle.
# It provides creation, existence check, validation and deletion
# with atomic writes and state/policy split locks.

if [[ -z "${USBAM_JOURNAL_LOADED+x}" ]]; then
  readonly USBAM_JOURNAL_VERSION="1.1.0"
  readonly USBAM_JOURNAL_SCHEMA_VERSION=1

  declare -g JOURNAL_ERROR=""
  declare -g JOURNAL_ERROR_CODE=""

  # Paths - overridable via env for tests
  declare -g JOURNAL_STATE_DIR="${USBAM_STATE_DIR:-/var/lib/usbguard-approval-manager}"
  declare -g JOURNAL_FILE="${USBAM_RESTORE_JOURNAL_FILE:-$JOURNAL_STATE_DIR/restore_journal.json}"

  declare -g JOURNAL_STATE_LOCK_FILE="${USBAM_STATE_LOCK_FILE:-/run/lock/usbguard-approval-manager-state.lock}"
  declare -g JOURNAL_POLICY_LOCK_FILE="${USBAM_POLICY_LOCK_FILE:-/run/lock/usbguard-approval-manager-policy.lock}"
  declare -g JOURNAL_LEGACY_LOCK_FILE="${USBAM_LOCK_FILE:-/run/lock/usbguard-approval-manager.lock}"

  # Split-lock FDs - independent from lock.sh global LOCK_FD
  declare -g JOURNAL_STATE_LOCK_FD=""
  declare -g JOURNAL_STATE_LOCK_HELD=0
  declare -g JOURNAL_STATE_LOCK_OWNER_PID=""
  declare -g JOURNAL_POLICY_LOCK_FD=""
  declare -g JOURNAL_POLICY_LOCK_HELD=0
  declare -g JOURNAL_POLICY_LOCK_OWNER_PID=""

  declare -g JOURNAL_ATOMIC_WRITE_HELPER=""
  declare -g JOURNAL_LAST_CORRELATION_ID=""

  # Resolve helper location
  _journal_resolve_atomic_write() {
    local base_dir candidate
    base_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
      "$base_dir/atomic-write.py" \
      "$base_dir/../lib/atomic-write.py" \
      "$base_dir/../../scripts/lib/atomic-write.py" \
      "/opt/usbguard-approval-manager/scripts/lib/atomic-write.py" \
      "./scripts/lib/atomic-write.py"
    do
      if [[ -f "$candidate" && -r "$candidate" ]]; then
        JOURNAL_ATOMIC_WRITE_HELPER="$candidate"
        return 0
      fi
    done
    # Fallback - assume in same lib dir as this file's parent
    if [[ -r "$base_dir/atomic-write.py" ]]; then
      JOURNAL_ATOMIC_WRITE_HELPER="$base_dir/atomic-write.py"
      return 0
    fi
    JOURNAL_ATOMIC_WRITE_HELPER="$base_dir/atomic-write.py"
    return 0
  }
  _journal_resolve_atomic_write

  declare -gr USBAM_JOURNAL_LOADED=1
fi

journal_error() {
  JOURNAL_ERROR="$1"
  JOURNAL_ERROR_CODE="${2:-journal_failed}"
  printf 'journal: ERROR: %s\n' "$1" >&2
}

journal_generate_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c "import uuid; print(uuid.uuid4())"
  fi
}

journal_is_uuid_v4() {
  local uuid="$1"
  [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

journal_ensure_state_dir() {
  if [[ -z "$JOURNAL_STATE_DIR" ]]; then
    journal_error "state dir is empty" "invalid_path"
    return 1
  fi
  if [[ "$JOURNAL_STATE_DIR" != /* ]]; then
    journal_error "state dir must be absolute" "invalid_path"
    return 1
  fi
  if [[ "$JOURNAL_STATE_DIR" == *".."* ]]; then
    journal_error "state dir must not contain .." "invalid_path"
    return 1
  fi
  if [[ -L "$JOURNAL_STATE_DIR" ]]; then
    journal_error "state dir is a symlink - refusing" "symlink_not_allowed"
    return 1
  fi
  if [[ ! -d "$JOURNAL_STATE_DIR" ]]; then
    if ! mkdir -p "$JOURNAL_STATE_DIR"; then
      journal_error "unable to create state dir $JOURNAL_STATE_DIR" "state_dir_unavailable"
      return 1
    fi
  fi
  if ! chmod 700 "$JOURNAL_STATE_DIR" 2>/dev/null; then
    journal_error "unable to chmod state dir" "chmod_failed"
    return 1
  fi
  # fsync state dir for durability
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "$JOURNAL_STATE_DIR" 2>/dev/null || true
  return 0
}

journal_validate_lock_file() {
  local lock_path="$1"
  local expected actual

  if [[ -z "$lock_path" ]]; then
    journal_error "lock file path empty" "invalid_lock_path"
    return 1
  fi
  if [[ "$lock_path" != /* ]]; then
    journal_error "lock file must be absolute: $lock_path" "invalid_lock_path"
    return 1
  fi
  if [[ -L "$lock_path" ]]; then
    journal_error "lock file is symlink: $lock_path" "symlink_not_allowed"
    return 1
  fi
  if [[ ! -f "$lock_path" ]]; then
    journal_error "lock file missing: $lock_path" "lock_missing"
    return 1
  fi
  if [[ ! -r "$lock_path" || ! -w "$lock_path" ]]; then
    journal_error "lock file not rw: $lock_path" "lock_unavailable"
    return 1
  fi
  # Ownership/mode check: for /run/lock/* expect 0:0:600 when root, else current user 600
  if [[ "$lock_path" == /run/lock/usbguard-approval-manager* ]]; then
    # if running as root, expect 0:0:600, else current user
    if (( $(id -u) == 0 )); then
      expected="0:0:600"
    else
      expected="$(id -u):$(id -g):600" || {
        journal_error "unable to determine expected lock owner" "owner_check_failed"
        return 1
      }
    fi
  else
    expected="$(id -u):$(id -g):600" || {
      journal_error "unable to determine expected lock owner" "owner_check_failed"
      return 1
    }
  fi
  actual="$(stat -c '%u:%g:%a' -- "$lock_path" 2>/dev/null)" || {
    journal_error "unable to stat lock file: $lock_path" "stat_failed"
    return 1
  }
  if [[ "$actual" != "$expected" ]]; then
    journal_error "unsafe lock file $lock_path expected $expected got $actual" "unsafe_lock"
    return 1
  fi
  return 0
}

journal_acquire_state_lock() {
  local timeout="${1:-5}"
  if (( $# != 1 )) || [[ ! "$timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    journal_error "state lock timeout must be non-negative number" "invalid_timeout"
    return 1
  fi
  if (( JOURNAL_STATE_LOCK_HELD != 0 )); then
    journal_error "state lock already held by this process" "lock_already_held"
    return 1
  fi
  if ! journal_validate_lock_file "$JOURNAL_STATE_LOCK_FILE"; then
    # try legacy lock as fallback for backward compatibility
    if [[ "$JOURNAL_STATE_LOCK_FILE" != "$JOURNAL_LEGACY_LOCK_FILE" ]] && [[ -f "$JOURNAL_LEGACY_LOCK_FILE" ]]; then
      if journal_validate_lock_file "$JOURNAL_LEGACY_LOCK_FILE"; then
        # fallback uses legacy file but logs warning
        JOURNAL_STATE_LOCK_FILE="$JOURNAL_LEGACY_LOCK_FILE"
      else
        return 1
      fi
    else
      return 1
    fi
  fi
  if ! exec {JOURNAL_STATE_LOCK_FD}>>"$JOURNAL_STATE_LOCK_FILE"; then
    JOURNAL_STATE_LOCK_FD=""
    journal_error "unable to open state lock file" "open_failed"
    return 1
  fi
  if ! flock --exclusive --wait "$timeout" "$JOURNAL_STATE_LOCK_FD"; then
    exec {JOURNAL_STATE_LOCK_FD}>&-
    JOURNAL_STATE_LOCK_FD=""
    journal_error "timed out acquiring state lock" "lock_timeout"
    return 1
  fi
  JOURNAL_STATE_LOCK_HELD=1
  JOURNAL_STATE_LOCK_OWNER_PID="$BASHPID"
  return 0
}

journal_release_state_lock() {
  if (( JOURNAL_STATE_LOCK_HELD == 0 )); then
    return 0
  fi
  if [[ "$JOURNAL_STATE_LOCK_OWNER_PID" != "$BASHPID" ]]; then
    journal_error "only owner may release state lock" "owner_mismatch"
    return 1
  fi
  JOURNAL_STATE_LOCK_HELD=0
  JOURNAL_STATE_LOCK_OWNER_PID=""
  if ! exec {JOURNAL_STATE_LOCK_FD}>&-; then
    JOURNAL_STATE_LOCK_FD=""
    journal_error "failed to close state lock fd" "close_failed"
    return 1
  fi
  JOURNAL_STATE_LOCK_FD=""
  return 0
}

journal_acquire_policy_lock() {
  local timeout="${1:-5}"
  if (( $# != 1 )) || [[ ! "$timeout" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    journal_error "policy lock timeout must be non-negative number" "invalid_timeout"
    return 1
  fi
  if (( JOURNAL_POLICY_LOCK_HELD != 0 )); then
    journal_error "policy lock already held" "lock_already_held"
    return 1
  fi
  if ! journal_validate_lock_file "$JOURNAL_POLICY_LOCK_FILE"; then
    if [[ "$JOURNAL_POLICY_LOCK_FILE" != "$JOURNAL_LEGACY_LOCK_FILE" ]] && [[ -f "$JOURNAL_LEGACY_LOCK_FILE" ]]; then
      if journal_validate_lock_file "$JOURNAL_LEGACY_LOCK_FILE"; then
        JOURNAL_POLICY_LOCK_FILE="$JOURNAL_LEGACY_LOCK_FILE"
      else
        return 1
      fi
    else
      return 1
    fi
  fi
  if ! exec {JOURNAL_POLICY_LOCK_FD}>>"$JOURNAL_POLICY_LOCK_FILE"; then
    JOURNAL_POLICY_LOCK_FD=""
    journal_error "unable to open policy lock file" "open_failed"
    return 1
  fi
  if ! flock --exclusive --wait "$timeout" "$JOURNAL_POLICY_LOCK_FD"; then
    exec {JOURNAL_POLICY_LOCK_FD}>&-
    JOURNAL_POLICY_LOCK_FD=""
    journal_error "timed out acquiring policy lock" "lock_timeout"
    return 1
  fi
  JOURNAL_POLICY_LOCK_HELD=1
  JOURNAL_POLICY_LOCK_OWNER_PID="$BASHPID"
  return 0
}

journal_release_policy_lock() {
  if (( JOURNAL_POLICY_LOCK_HELD == 0 )); then
    return 0
  fi
  if [[ "$JOURNAL_POLICY_LOCK_OWNER_PID" != "$BASHPID" ]]; then
    journal_error "only owner may release policy lock" "owner_mismatch"
    return 1
  fi
  JOURNAL_POLICY_LOCK_HELD=0
  JOURNAL_POLICY_LOCK_OWNER_PID=""
  if ! exec {JOURNAL_POLICY_LOCK_FD}>&-; then
    JOURNAL_POLICY_LOCK_FD=""
    journal_error "failed to close policy lock fd" "close_failed"
    return 1
  fi
  JOURNAL_POLICY_LOCK_FD=""
  return 0
}

journal_acquire_both_locks() {
  local timeout="${1:-5}"
  if ! journal_acquire_state_lock "$timeout"; then
    return 1
  fi
  if ! journal_acquire_policy_lock "$timeout"; then
    journal_release_state_lock || true
    return 1
  fi
  return 0
}

journal_release_both_locks() {
  # release in reverse order to avoid deadlock
  local rc=0
  if ! journal_release_policy_lock; then
    rc=1
  fi
  if ! journal_release_state_lock; then
    rc=1
  fi
  return $rc
}

journal_exists() {
  [[ -f "$JOURNAL_FILE" ]]
}

journal_validate() {
  local file_path="${1:-$JOURNAL_FILE}"
  JOURNAL_ERROR=""
  JOURNAL_ERROR_CODE=""

  if [[ -L "$file_path" ]]; then
    journal_error "journal file is symlink" "symlink_not_allowed"
    return 1
  fi
  if [[ ! -f "$file_path" ]]; then
    journal_error "journal file not found: $file_path" "not_found"
    return 1
  fi
  if ! jq -e . "$file_path" >/dev/null 2>&1; then
    journal_error "journal file is not valid JSON" "invalid_json"
    return 1
  fi
  # control chars check - python helper would reject but we check via jq raw
  if grep -q $'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]' "$file_path" 2>/dev/null; then
    journal_error "journal contains control characters" "control_chars"
    return 1
  fi
  local schema
  schema="$(jq -r '.schema_version // empty' "$file_path" 2>/dev/null)"
  if [[ "$schema" != "$USBAM_JOURNAL_SCHEMA_VERSION" ]]; then
    journal_error "invalid schema_version $schema" "invalid_schema"
    return 1
  fi
  local required_fields=("created_at" "created_at_utc" "backup_path" "backup_timestamp" "correlation_id" "pid" "reason" "status")
  local field
  for field in "${required_fields[@]}"; do
    if ! jq -e "has(\"$field\")" "$file_path" >/dev/null 2>&1; then
      journal_error "journal missing field $field" "missing_field"
      return 1
    fi
    if [[ "$(jq -r ".${field} // empty" "$file_path" 2>/dev/null)" == "" ]]; then
      # allow 0 for pid/created_at ?
      if [[ "$field" == "created_at" || "$field" == "pid" ]]; then
        continue
      fi
      journal_error "journal field $field empty" "empty_field"
      return 1
    fi
  done
  local cid
  cid="$(jq -r '.correlation_id // empty' "$file_path")"
  if ! journal_is_uuid_v4 "$cid"; then
    journal_error "journal correlation_id not UUID v4" "invalid_correlation_id"
    return 1
  fi
  local status
  status="$(jq -r '.status // empty' "$file_path")"
  case "$status" in
    in_progress|completed|failed) ;;
    *)
      journal_error "journal status invalid: $status" "invalid_status"
      return 1
      ;;
  esac
  return 0
}

journal_create() {
  local backup_path="$1"
  local reason="${2:-restore}"
  local correlation_id="${3:-}"

  JOURNAL_ERROR=""
  JOURNAL_ERROR_CODE=""

  if (( $# < 1 || $# > 3 )); then
    journal_error "journal_create requires backup_path" "invalid_arguments"
    return 1
  fi
  if [[ -z "$backup_path" ]]; then
    journal_error "backup_path empty" "invalid_backup_path"
    return 1
  fi
  if [[ "$backup_path" =~ [[:cntrl:]] ]]; then
    journal_error "backup_path contains control characters" "invalid_backup_path"
    return 1
  fi
  if [[ "$backup_path" != /* ]]; then
    journal_error "backup_path must be absolute: $backup_path" "invalid_backup_path"
    return 1
  fi
  if [[ "$reason" =~ [[:cntrl:]] ]]; then
    journal_error "reason contains control characters" "invalid_reason"
    return 1
  fi
  if [[ ${#reason} -gt 128 ]]; then
    journal_error "reason too long" "reason_too_long"
    return 1
  fi

  if ! journal_ensure_state_dir; then
    return 1
  fi

  if [[ -n "$correlation_id" ]]; then
    if ! journal_is_uuid_v4 "$correlation_id"; then
      journal_error "correlation_id must be UUID v4" "invalid_correlation_id"
      return 1
    fi
  else
    correlation_id="$(journal_generate_uuid)"
    if ! journal_is_uuid_v4 "$correlation_id"; then
      journal_error "failed to generate uuid" "uuid_failed"
      return 1
    fi
  fi
  JOURNAL_LAST_CORRELATION_ID="$correlation_id"

  local created_at created_at_utc backup_timestamp pid uid

  if ! created_at="$(date +%s)" || [[ ! "$created_at" =~ ^[0-9]+$ ]]; then
    journal_error "unable to get epoch" "clock_unavailable"
    return 1
  fi
  created_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%s)"
  backup_timestamp="$(basename "$backup_path")"
  if [[ -z "$backup_timestamp" ]]; then
    backup_timestamp="$backup_path"
  fi
  # sanitize backup_timestamp for json (avoid control chars already checked)
  pid="$$"
  uid="$(id -u 2>/dev/null || echo 0)"

  # Build JSON - use jq for safe escaping
  local journal_json
  if ! journal_json="$(jq -n \
    --argjson schema_version "$USBAM_JOURNAL_SCHEMA_VERSION" \
    --argjson created_at "$created_at" \
    --arg created_at_utc "$created_at_utc" \
    --arg backup_path "$backup_path" \
    --arg backup_timestamp "$backup_timestamp" \
    --arg correlation_id "$correlation_id" \
    --argjson pid "$pid" \
    --argjson uid "$uid" \
    --arg reason "$reason" \
    --arg status "in_progress" \
    '{
      schema_version: $schema_version,
      created_at: $created_at,
      created_at_utc: $created_at_utc,
      backup_path: $backup_path,
      backup_timestamp: $backup_timestamp,
      correlation_id: $correlation_id,
      pid: $pid,
      initiator_uid: $uid,
      reason: $reason,
      status: $status
    }')"; then
    journal_error "failed to build journal json" "json_build_failed"
    return 1
  fi

  # Ensure atomic-write helper exists
  if [[ ! -r "$JOURNAL_ATOMIC_WRITE_HELPER" ]]; then
    # attempt fallback relative discovery
    local alt="$JOURNAL_STATE_DIR/../scripts/lib/atomic-write.py"
    if [[ -r "$alt" ]]; then
      JOURNAL_ATOMIC_WRITE_HELPER="$alt"
    else
      journal_error "atomic-write helper not found" "helper_missing"
      return 1
    fi
  fi

  if ! python3 "$JOURNAL_ATOMIC_WRITE_HELPER" --file "$JOURNAL_FILE" --data "$journal_json"; then
    journal_error "atomic write of journal failed" "atomic_write_failed"
    return 1
  fi

  if ! chmod 600 "$JOURNAL_FILE" 2>/dev/null; then
    journal_error "chmod journal failed" "chmod_failed"
    return 1
  fi
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "$JOURNAL_STATE_DIR" 2>/dev/null || true

  # Validate what we wrote
  if ! journal_validate "$JOURNAL_FILE"; then
    journal_error "journal invalid after creation: $JOURNAL_ERROR" "post_write_invalid"
    return 1
  fi

  return 0
}

journal_read() {
  local file_path="${1:-$JOURNAL_FILE}"
  if [[ ! -f "$file_path" ]]; then
    journal_error "journal file not found for read" "not_found"
    return 1
  fi
  cat -- "$file_path"
}

journal_delete() {
  JOURNAL_ERROR=""
  JOURNAL_ERROR_CODE=""
  local file_path="${1:-$JOURNAL_FILE}"

  if [[ -L "$file_path" ]]; then
    journal_error "journal file is symlink - refusing delete" "symlink_not_allowed"
    return 1
  fi
  if [[ ! -f "$file_path" ]]; then
    # idempotent delete - missing is ok
    return 0
  fi

  if ! rm -f -- "$file_path"; then
    journal_error "failed to delete journal file" "delete_failed"
    return 1
  fi
  # fsync dir to ensure deletion durable
  local dir
  dir="$(dirname -- "$file_path")"
  python3 -c 'import os,sys; fd=os.open(sys.argv[1], os.O_DIRECTORY); os.fsync(fd); os.close(fd)' "$dir" 2>/dev/null || true
  return 0
}

journal_check_and_block() {
  local file_path="${1:-$JOURNAL_FILE}"
  if [[ -f "$file_path" ]]; then
    # If file exists, try validate - even invalid journal must block
    if journal_validate "$file_path" 2>/dev/null; then
      printf 'journal: ERROR: restore journal exists at %s - recovery required, blocking operation\n' "$file_path" >&2
    else
      printf 'journal: ERROR: invalid restore journal exists at %s - recovery required\n' "$file_path" >&2
    fi
    return 9
  fi
  return 0
}

# Helper to get correlation_id from last create
journal_last_correlation_id() {
  printf '%s\n' "$JOURNAL_LAST_CORRELATION_ID"
}
